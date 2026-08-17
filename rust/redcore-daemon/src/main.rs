mod battery;
mod brightness;
mod media;
mod network;
mod power;
mod system_monitor;
mod workspaces;

use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::env;
use std::io::{self, Write};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::task::JoinHandle;
use tokio::time::{MissedTickBehavior, interval, sleep};

const DAEMON_PROTOCOL_VERSION: u32 = 5;

const INITIAL_RETRY_DELAY: Duration = Duration::from_secs(2);
const MAX_RETRY_DELAY: Duration = Duration::from_secs(60);
const HEALTH_CHECK_INTERVAL: Duration = Duration::from_secs(60);
const SIMULATED_ADAPTER_NAME: &str = "hci-sim0";

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
struct BluetoothAdapter {
    name: String,
    alias: String,
    powered: bool,
    discovering: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
struct BluetoothDevice {
    adapter: String,
    address: String,
    name: String,
    kind: String,
    paired: bool,
    trusted: bool,
    connected: bool,
    rssi: Option<i16>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
struct BluetoothState {
    event: &'static str,
    service_available: bool,
    available: bool,
    simulated: bool,
    adapters: Vec<BluetoothAdapter>,
    devices: Vec<BluetoothDevice>,
}

impl BluetoothState {
    fn unavailable() -> Self {
        Self {
            event: "bluetooth-state",
            service_available: false,
            available: false,
            simulated: false,
            adapters: Vec::new(),
            devices: Vec::new(),
        }
    }

    #[cfg(test)]
    fn ready(adapters: Vec<BluetoothAdapter>) -> Self {
        Self {
            event: "bluetooth-state",
            service_available: true,
            available: !adapters.is_empty(),
            simulated: false,
            adapters,
            devices: Vec::new(),
        }
    }

    fn simulated(adapters: Vec<BluetoothAdapter>, devices: Vec<BluetoothDevice>) -> Self {
        Self {
            event: "bluetooth-state",
            service_available: true,
            available: !adapters.is_empty(),
            simulated: true,
            adapters,
            devices,
        }
    }
}

fn bluetooth_device_kind(icon: Option<&str>, class: Option<u32>) -> String {
    let icon = icon.unwrap_or_default().to_ascii_lowercase();

    if icon.contains("headset") || icon.contains("headphone") {
        "headphones"
    } else if icon.contains("speaker") || icon.contains("audio-card") {
        "speaker"
    } else if icon.contains("keyboard") {
        "keyboard"
    } else if icon.contains("phone") || class.is_some_and(|value| value >> 8 & 0x1f == 0x02) {
        "phone"
    } else {
        "unknown"
    }
    .to_string()
}

async fn read_device(adapter: &bluer::Adapter, address: bluer::Address) -> Option<BluetoothDevice> {
    let device = adapter.device(address).ok()?;
    let name = device
        .alias()
        .await
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| address.to_string());
    let icon = device.icon().await.ok().flatten();
    let class = device.class().await.ok().flatten();

    Some(BluetoothDevice {
        adapter: adapter.name().to_string(),
        address: address.to_string(),
        name,
        kind: bluetooth_device_kind(icon.as_deref(), class),
        paired: device.is_paired().await.unwrap_or(false),
        trusted: device.is_trusted().await.unwrap_or(false),
        connected: device.is_connected().await.unwrap_or(false),
        rssi: device.rssi().await.ok().flatten(),
    })
}

async fn read_state(session: &bluer::Session) -> Result<BluetoothState, bluer::Error> {
    let mut adapter_names = session.adapter_names().await?;
    adapter_names.sort_unstable();

    let mut adapters = Vec::new();
    let mut devices = Vec::new();
    let mut first_property_error = None;

    for name in adapter_names {
        let adapter = match session.adapter(&name) {
            Ok(adapter) => adapter,
            Err(error) => {
                if first_property_error.is_none() {
                    first_property_error = Some(error);
                }

                continue;
            }
        };

        let powered = match adapter.is_powered().await {
            Ok(powered) => powered,
            Err(error) => {
                if first_property_error.is_none() {
                    first_property_error = Some(error);
                }

                continue;
            }
        };

        let alias = adapter.alias().await.unwrap_or_else(|_| name.clone());
        let discovering = adapter.is_discovering().await.unwrap_or(false);

        if let Ok(mut addresses) = adapter.device_addresses().await {
            addresses.sort_unstable();

            for address in addresses {
                if let Some(device) = read_device(&adapter, address).await {
                    devices.push(device);
                }
            }
        }

        adapters.push(BluetoothAdapter {
            name,
            alias,
            powered,
            discovering,
        });
    }

    if adapters.is_empty()
        && let Some(error) = first_property_error
    {
        return Err(error);
    }

    devices.sort_by(|left, right| {
        left.adapter
            .cmp(&right.adapter)
            .then_with(|| left.address.cmp(&right.address))
    });

    Ok(BluetoothState {
        event: "bluetooth-state",
        service_available: true,
        available: !adapters.is_empty(),
        simulated: false,
        adapters,
        devices,
    })
}

pub(crate) fn send_json<T: Serialize>(value: &T, description: &str) -> bool {
    let json = match serde_json::to_string(value) {
        Ok(json) => json,

        Err(error) => {
            eprintln!("Could not serialize {description}: {error}");
            return false;
        }
    };

    let mut stdout = io::stdout().lock();

    if writeln!(stdout, "{json}")
        .and_then(|_| stdout.flush())
        .is_err()
    {
        eprintln!("Could not write {description}");
        return false;
    }

    true
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DaemonReady {
    event: &'static str,
    protocol_version: u32,
}

fn send_daemon_ready() {
    send_json(
        &DaemonReady {
            event: "daemon-ready",
            protocol_version: DAEMON_PROTOCOL_VERSION,
        },
        "daemon readiness",
    );
}

fn send_state(state: &BluetoothState) -> bool {
    send_json(state, "Bluetooth state")
}

fn send_if_changed(last_state: &mut Option<BluetoothState>, state: BluetoothState) -> bool {
    if last_state.as_ref() == Some(&state) {
        return false;
    }

    if !send_state(&state) {
        return false;
    }

    *last_state = Some(state);
    true
}

fn next_retry_delay(current: Duration) -> Duration {
    current.saturating_mul(2).min(MAX_RETRY_DELAY)
}

async fn wait_before_retry(retry_delay: &mut Duration) {
    sleep(*retry_delay).await;
    *retry_delay = next_retry_delay(*retry_delay);
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DaemonCommand {
    pub(crate) module: Option<String>,
    pub(crate) action: String,
    pub(crate) adapter: Option<String>,
    pub(crate) address: Option<String>,
    pub(crate) powered: Option<bool>,
    pub(crate) enabled: Option<bool>,
    pub(crate) profile: Option<String>,
    pub(crate) scenario: Option<String>,
    pub(crate) display: Option<String>,
    pub(crate) percentage: Option<u8>,
    pub(crate) max_value: Option<u32>,
    pub(crate) delta: Option<i16>,
    pub(crate) workspace_index: Option<i64>,
    pub(crate) app_id: Option<String>,
    pub(crate) icon_name: Option<String>,
    pub(crate) windows: Option<Vec<serde_json::Value>>,
    pub(crate) media: Option<media::MediaCommandPayload>,
    pub(crate) request_id: Option<u64>,
    pub(crate) device: Option<String>,
    pub(crate) ssid: Option<String>,
    pub(crate) password: Option<String>,
    pub(crate) security_mode: Option<String>,
    pub(crate) saved_uuid: Option<String>,
    pub(crate) uuid: Option<String>,
    pub(crate) hidden: Option<bool>,
    pub(crate) autoconnect: Option<bool>,
    pub(crate) autoconnect_priority: Option<i32>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct BluetoothActionResult<'a> {
    event: &'static str,
    action: &'a str,
    success: bool,
    message: Option<&'a str>,
}

fn send_bluetooth_action_result(action: &str, result: Result<(), &str>) {
    let (success, message) = match result {
        Ok(()) => (true, None),
        Err(message) => (false, Some(message)),
    };

    let response = BluetoothActionResult {
        event: "bluetooth-action-result",
        action,
        success,
        message,
    };

    send_json(&response, "Bluetooth action result");
}

struct BluetoothSimulator {
    state: BluetoothState,
}

impl BluetoothSimulator {
    fn new() -> Self {
        Self {
            state: Self::initial_state(),
        }
    }

    fn initial_state() -> BluetoothState {
        BluetoothState::simulated(
            vec![BluetoothAdapter {
                name: SIMULATED_ADAPTER_NAME.to_string(),
                alias: "Red Core Simulated Adapter".to_string(),
                powered: true,
                discovering: false,
            }],
            vec![
                BluetoothDevice {
                    adapter: SIMULATED_ADAPTER_NAME.to_string(),
                    address: "02:00:00:00:00:01".to_string(),
                    name: "Red Core Headphones".to_string(),
                    kind: "headphones".to_string(),
                    paired: true,
                    trusted: true,
                    connected: true,
                    rssi: Some(-42),
                },
                BluetoothDevice {
                    adapter: SIMULATED_ADAPTER_NAME.to_string(),
                    address: "02:00:00:00:00:02".to_string(),
                    name: "Red Phone".to_string(),
                    kind: "phone".to_string(),
                    paired: true,
                    trusted: true,
                    connected: false,
                    rssi: Some(-55),
                },
            ],
        )
    }

    fn requested_adapter<'a>(&self, command: &'a DaemonCommand) -> &'a str {
        command.adapter.as_deref().unwrap_or(SIMULATED_ADAPTER_NAME)
    }

    fn adapter_index(&self, name: &str) -> Result<usize, String> {
        self.state
            .adapters
            .iter()
            .position(|adapter| adapter.name == name)
            .ok_or_else(|| format!("Adapter {name} was not found"))
    }

    fn device_index(&self, adapter: &str, address: &str) -> Result<usize, String> {
        self.state
            .devices
            .iter()
            .position(|device| device.adapter == adapter && device.address == address)
            .ok_or_else(|| format!("Device {address} was not found"))
    }

    fn ensure_powered(&self, adapter: &str) -> Result<(), String> {
        let index = self.adapter_index(adapter)?;

        if self.state.adapters[index].powered {
            Ok(())
        } else {
            Err(format!("Adapter {adapter} is powered off"))
        }
    }

    fn add_nearby_devices(&mut self, adapter: &str) {
        let nearby = [
            BluetoothDevice {
                adapter: adapter.to_string(),
                address: "02:00:00:00:00:03".to_string(),
                name: "Red Core Keyboard".to_string(),
                kind: "keyboard".to_string(),
                paired: false,
                trusted: false,
                connected: false,
                rssi: Some(-48),
            },
            BluetoothDevice {
                adapter: adapter.to_string(),
                address: "02:00:00:00:00:04".to_string(),
                name: "Pocket Speaker".to_string(),
                kind: "speaker".to_string(),
                paired: false,
                trusted: false,
                connected: false,
                rssi: Some(-67),
            },
        ];

        for device in nearby {
            if !self
                .state
                .devices
                .iter()
                .any(|known| known.adapter == device.adapter && known.address == device.address)
            {
                self.state.devices.push(device);
            }
        }
    }

    fn apply(&mut self, command: &DaemonCommand) -> Result<bool, String> {
        let adapter_name = self.requested_adapter(command).to_string();

        match command.action.as_str() {
            "get-state" => Ok(true),

            "set-powered" => {
                let powered = command
                    .powered
                    .ok_or_else(|| "Missing powered value".to_string())?;
                let index = self.adapter_index(&adapter_name)?;

                self.state.adapters[index].powered = powered;

                if !powered {
                    self.state.adapters[index].discovering = false;

                    for device in &mut self.state.devices {
                        if device.adapter == adapter_name {
                            device.connected = false;
                        }
                    }
                }

                Ok(false)
            }

            "scan" => {
                let enabled = command
                    .enabled
                    .ok_or_else(|| "Missing enabled value".to_string())?;

                self.ensure_powered(&adapter_name)?;

                let index = self.adapter_index(&adapter_name)?;
                self.state.adapters[index].discovering = enabled;

                if enabled {
                    self.add_nearby_devices(&adapter_name);
                }

                Ok(false)
            }

            "pair" => {
                self.ensure_powered(&adapter_name)?;

                let address = command
                    .address
                    .as_deref()
                    .ok_or_else(|| "Missing device address".to_string())?;
                let index = self.device_index(&adapter_name, address)?;

                self.state.devices[index].paired = true;
                self.state.devices[index].trusted = true;
                Ok(false)
            }

            "connect" => {
                self.ensure_powered(&adapter_name)?;

                let address = command
                    .address
                    .as_deref()
                    .ok_or_else(|| "Missing device address".to_string())?;
                let index = self.device_index(&adapter_name, address)?;

                if !self.state.devices[index].paired {
                    return Err("Pair the device before connecting".to_string());
                }

                self.state.devices[index].connected = true;
                Ok(false)
            }

            "disconnect" => {
                let address = command
                    .address
                    .as_deref()
                    .ok_or_else(|| "Missing device address".to_string())?;
                let index = self.device_index(&adapter_name, address)?;

                self.state.devices[index].connected = false;
                Ok(false)
            }

            "forget" => {
                let address = command
                    .address
                    .as_deref()
                    .ok_or_else(|| "Missing device address".to_string())?;
                let index = self.device_index(&adapter_name, address)?;

                self.state.devices[index].paired = false;
                self.state.devices[index].trusted = false;
                self.state.devices[index].connected = false;
                Ok(false)
            }

            "remove-adapter" => {
                self.state.adapters.clear();
                self.state.devices.clear();
                self.state.available = false;
                Ok(false)
            }

            "add-adapter" | "reset-simulation" => {
                self.state = Self::initial_state();
                Ok(false)
            }

            _ => Err(format!("Unknown Bluetooth action: {}", command.action)),
        }
    }
}

struct BluetoothController {
    session: bluer::Session,
    _agent: Option<bluer::agent::AgentHandle>,
    discoveries: HashMap<String, JoinHandle<()>>,
}

impl BluetoothController {
    async fn new() -> Result<Self, String> {
        let session = bluer::Session::new()
            .await
            .map_err(|error| format!("Bluetooth service is unavailable: {error}"))?;
        let agent = match session.register_agent(bluer::agent::Agent::default()).await {
            Ok(agent) => Some(agent),
            Err(error) => {
                eprintln!("Bluetooth pairing agent is unavailable: {error}");
                None
            }
        };

        Ok(Self {
            session,
            _agent: agent,
            discoveries: HashMap::new(),
        })
    }

    async fn adapter(&self, name: Option<&str>) -> Result<bluer::Adapter, String> {
        let name = name.ok_or_else(|| "Missing Bluetooth adapter".to_string())?;
        let names = self
            .session
            .adapter_names()
            .await
            .map_err(|error| error.to_string())?;

        if !names.iter().any(|available| available == name) {
            return Err(format!("Bluetooth adapter {name} was not found"));
        }

        self.session
            .adapter(name)
            .map_err(|error| error.to_string())
    }

    fn stop_discovery(&mut self, adapter: &str) {
        if let Some(task) = self.discoveries.remove(adapter) {
            task.abort();
        }
    }

    async fn start_discovery(&mut self, adapter: bluer::Adapter) -> Result<(), String> {
        let name = adapter.name().to_string();
        self.stop_discovery(&name);

        if !adapter
            .is_powered()
            .await
            .map_err(|error| error.to_string())?
        {
            return Err(format!("Bluetooth adapter {name} is powered off"));
        }

        let events = adapter
            .discover_devices_with_changes()
            .await
            .map_err(|error| error.to_string())?;
        let session = self.session.clone();
        let task = tokio::spawn(async move {
            futures_util::pin_mut!(events);

            while events.next().await.is_some() {
                sleep(Duration::from_millis(150)).await;

                if let Ok(state) = read_state(&session).await {
                    send_state(&state);
                }
            }
        });
        self.discoveries.insert(name, task);
        Ok(())
    }

    async fn device(
        &self,
        adapter_name: Option<&str>,
        address: Option<&str>,
    ) -> Result<(bluer::Adapter, bluer::Device), String> {
        let adapter = self.adapter(adapter_name).await?;
        let address = address
            .ok_or_else(|| "Missing Bluetooth device address".to_string())?
            .parse::<bluer::Address>()
            .map_err(|_| "Invalid Bluetooth device address".to_string())?;
        let device = adapter.device(address).map_err(|error| error.to_string())?;
        Ok((adapter, device))
    }

    async fn apply(&mut self, command: &DaemonCommand) -> Result<(), String> {
        match command.action.as_str() {
            "get-state" => {}
            "set-powered" => {
                let adapter = self.adapter(command.adapter.as_deref()).await?;
                let powered = command
                    .powered
                    .ok_or_else(|| "Missing powered value".to_string())?;

                if !powered {
                    self.stop_discovery(adapter.name());
                }
                adapter
                    .set_powered(powered)
                    .await
                    .map_err(|error| error.to_string())?;
            }
            "scan" => {
                let adapter = self.adapter(command.adapter.as_deref()).await?;
                let enabled = command
                    .enabled
                    .ok_or_else(|| "Missing enabled value".to_string())?;

                if enabled {
                    self.start_discovery(adapter).await?;
                } else {
                    self.stop_discovery(adapter.name());
                }
            }
            "pair" => {
                let (_, device) = self
                    .device(command.adapter.as_deref(), command.address.as_deref())
                    .await?;
                device.pair().await.map_err(|error| error.to_string())?;
                device
                    .set_trusted(true)
                    .await
                    .map_err(|error| error.to_string())?;
            }
            "connect" => {
                let (_, device) = self
                    .device(command.adapter.as_deref(), command.address.as_deref())
                    .await?;
                device.connect().await.map_err(|error| error.to_string())?;
            }
            "disconnect" => {
                let (_, device) = self
                    .device(command.adapter.as_deref(), command.address.as_deref())
                    .await?;
                device
                    .disconnect()
                    .await
                    .map_err(|error| error.to_string())?;
            }
            "forget" => {
                let (adapter, device) = self
                    .device(command.adapter.as_deref(), command.address.as_deref())
                    .await?;
                adapter
                    .remove_device(device.address())
                    .await
                    .map_err(|error| error.to_string())?;
            }
            _ => return Err(format!("Unknown Bluetooth action: {}", command.action)),
        }

        let state = read_state(&self.session)
            .await
            .map_err(|error| error.to_string())?;
        send_state(&state);
        Ok(())
    }
}

fn is_battery_command(command: &DaemonCommand) -> bool {
    command.module.as_deref() == Some("battery")
        || matches!(
            command.action.as_str(),
            "set-power-profile"
                | "set-battery-scenario"
                | "remove-battery"
                | "add-battery"
                | "reset-battery-simulation"
        )
}

fn is_brightness_command(command: &DaemonCommand) -> bool {
    command.module.as_deref() == Some("brightness")
        || matches!(
            command.action.as_str(),
            "set-brightness"
                | "preview-brightness"
                | "step-brightness"
                | "refresh-brightness"
                | "remove-brightness-display"
                | "remove-all-brightness-displays"
                | "add-brightness-display"
                | "reset-brightness-simulation"
        )
}

fn is_workspaces_command(command: &DaemonCommand) -> bool {
    command.module.as_deref() == Some("workspaces")
}

fn is_media_command(command: &DaemonCommand) -> bool {
    command.module.as_deref() == Some("media")
}

fn is_network_command(command: &DaemonCommand) -> bool {
    command.module.as_deref() == Some("network")
}

fn is_power_command(command: &DaemonCommand) -> bool {
    command.module.as_deref() == Some("power")
}

fn is_network_state_request(command: &DaemonCommand) -> bool {
    matches!(command.action.as_str(), "get-state" | "snapshot")
}

async fn run_command_loop(
    mut bluetooth: Option<BluetoothSimulator>,
    mut bluetooth_controller: Option<BluetoothController>,
    mut battery: Option<battery::BatterySimulator>,
    mut brightness: Option<brightness::BrightnessSimulator>,
    mut network: Option<network::NetworkSimulator>,
) -> Result<(), String> {
    let mut lines = BufReader::new(tokio::io::stdin()).lines();

    while let Some(line) = lines.next_line().await.map_err(|error| error.to_string())? {
        if line.trim().is_empty() {
            continue;
        }

        let command = match serde_json::from_str::<DaemonCommand>(&line) {
            Ok(command) => command,
            Err(error) => {
                let message = error.to_string();
                send_bluetooth_action_result("invalid-command", Err(&message));
                continue;
            }
        };

        let action = command.action.clone();

        if is_power_command(&command) {
            let state_request = action == "get-state";
            let result = power::apply_command(&command).await;

            if !state_request {
                power::send_action_result(&command, result);
            }

            continue;
        }

        if is_network_command(&command) {
            let state_request = is_network_state_request(&command);

            if let Some(simulator) = &mut network {
                match simulator.apply(&command) {
                    Ok(message) => {
                        if !state_request {
                            network::send_action_result(&command, Ok(message));
                        }
                        simulator.send_state();
                    }
                    Err(error) => {
                        if !state_request {
                            network::send_action_result(&command, Err(error));
                        }
                    }
                }
            } else {
                let result = network::apply_command(&command).await;
                if !state_request {
                    network::send_action_result(&command, result);
                }
            }
            continue;
        }

        if is_workspaces_command(&command) {
            workspaces::apply_command(&command).await;
            continue;
        }

        if is_media_command(&command) {
            media::apply_command(&command);
            continue;
        }

        if is_brightness_command(&command) {
            let is_preview = action == "preview-brightness";

            if let Some(simulator) = &mut brightness {
                match simulator.apply(&command) {
                    Ok(()) => {
                        brightness::send_action_result(&action, Ok(()));

                        if !is_preview {
                            simulator.send_state();
                        }
                    }
                    Err(message) => brightness::send_action_result(&action, Err(&message)),
                }
            } else {
                let result = if is_preview {
                    brightness::apply_preview(&command).await
                } else {
                    brightness::apply_real(&command).await
                };

                match result {
                    Ok(()) => {
                        brightness::send_action_result(&action, Ok(()));

                        if !is_preview {
                            brightness::send_real_state().await;
                        }
                    }
                    Err(message) => brightness::send_action_result(&action, Err(&message)),
                }
            }

            continue;
        }

        if is_battery_command(&command) {
            if let Some(simulator) = &mut battery {
                match simulator.apply(&command) {
                    Ok(_) => {
                        battery::send_action_result(&action, Ok(()));
                        simulator.send_state();
                    }
                    Err(message) => battery::send_action_result(&action, Err(&message)),
                }

                continue;
            }

            if action == "set-power-profile" {
                let result = match command.profile.as_deref() {
                    Some(profile) => battery::set_real_power_profile(profile).await,
                    None => Err("Missing power profile".to_string()),
                };

                match result {
                    Ok(()) => battery::send_action_result(&action, Ok(())),
                    Err(message) => battery::send_action_result(&action, Err(&message)),
                }
            } else {
                battery::send_action_result(
                    &action,
                    Err("Battery simulation command is unavailable in real mode"),
                );
            }

            continue;
        }

        if let Some(simulator) = &mut bluetooth {
            match simulator.apply(&command) {
                Ok(_) => {
                    send_bluetooth_action_result(&action, Ok(()));
                    send_state(&simulator.state);
                }
                Err(message) => send_bluetooth_action_result(&action, Err(&message)),
            }
        } else {
            if bluetooth_controller.is_none() {
                match BluetoothController::new().await {
                    Ok(controller) => bluetooth_controller = Some(controller),
                    Err(message) => {
                        send_bluetooth_action_result(&action, Err(&message));
                        continue;
                    }
                }
            }

            if let Some(controller) = &mut bluetooth_controller {
                match controller.apply(&command).await {
                    Ok(()) => send_bluetooth_action_result(&action, Ok(())),
                    Err(message) => send_bluetooth_action_result(&action, Err(&message)),
                }
            }
        }
    }

    Ok(())
}

async fn monitor_session(
    session: &bluer::Session,
    last_state: &mut Option<BluetoothState>,
    retry_delay: &mut Duration,
) -> Result<(), String> {
    let state = read_state(session)
        .await
        .map_err(|error| error.to_string())?;
    send_if_changed(last_state, state);

    let events = session.events().await.map_err(|error| error.to_string())?;
    futures_util::pin_mut!(events);

    *retry_delay = INITIAL_RETRY_DELAY;

    let mut health_check = interval(HEALTH_CHECK_INTERVAL);
    health_check.set_missed_tick_behavior(MissedTickBehavior::Delay);
    health_check.tick().await;

    loop {
        tokio::select! {
            event = events.next() => {
                if event.is_none() {
                    return Err("Bluetooth event stream ended".to_string());
                }

                let state = read_state(session)
                    .await
                    .map_err(|error| error.to_string())?;

                send_if_changed(last_state, state);
            }

            _ = health_check.tick() => {
                let state = read_state(session)
                    .await
                    .map_err(|error| error.to_string())?;

                send_if_changed(last_state, state);
            }
        }
    }
}

async fn run_bluetooth_monitor() {
    let mut last_state = None;
    let mut retry_delay = INITIAL_RETRY_DELAY;

    loop {
        let session = match bluer::Session::new().await {
            Ok(session) => session,

            Err(error) => {
                if send_if_changed(&mut last_state, BluetoothState::unavailable()) {
                    eprintln!("Bluetooth service is unavailable: {error}");
                }

                wait_before_retry(&mut retry_delay).await;
                continue;
            }
        };

        if let Err(error) = monitor_session(&session, &mut last_state, &mut retry_delay).await
            && send_if_changed(&mut last_state, BluetoothState::unavailable())
        {
            eprintln!("Bluetooth monitoring stopped: {error}");
        }

        wait_before_retry(&mut retry_delay).await;
    }
}

#[tokio::main]
async fn main() {
    let arguments: Vec<String> = env::args().skip(1).collect();

    if arguments
        .iter()
        .any(|argument| argument == "--system-monitor-once")
    {
        system_monitor::run_legacy_stream(true).await;
        return;
    }

    if arguments
        .iter()
        .any(|argument| argument == "--system-monitor")
    {
        system_monitor::run_legacy_stream(false).await;
        return;
    }

    if let Some(index) = arguments
        .iter()
        .position(|argument| argument == "--local-media")
    {
        if let Err(error) = media::run_cli(&arguments[index + 1..]) {
            eprintln!("Red Core Local Media: {error}");
            std::process::exit(1);
        }
        return;
    }

    let simulate_bluetooth = arguments
        .iter()
        .any(|argument| matches!(argument.as_str(), "--simulate" | "--simulate-bluetooth"));
    let simulate_battery = arguments
        .iter()
        .any(|argument| argument == "--simulate-battery");
    let simulate_brightness = arguments
        .iter()
        .any(|argument| argument == "--simulate-brightness");
    let simulate_network = arguments
        .iter()
        .any(|argument| argument == "--simulate-network");

    let bluetooth_simulator = simulate_bluetooth.then(BluetoothSimulator::new);
    let battery_simulator = simulate_battery.then(battery::BatterySimulator::new);
    let brightness_simulator = simulate_brightness.then(brightness::BrightnessSimulator::new);
    let network_simulator = simulate_network.then(network::NetworkSimulator::new);

    send_daemon_ready();

    if let Some(simulator) = &bluetooth_simulator {
        eprintln!("Bluetooth simulation is active");
        send_state(&simulator.state);
    } else {
        tokio::spawn(run_bluetooth_monitor());
    }

    if let Some(simulator) = &battery_simulator {
        eprintln!("Battery simulation is active");
        simulator.send_state();
    } else {
        tokio::spawn(battery::run_monitor());
    }

    if let Some(simulator) = &brightness_simulator {
        eprintln!("Brightness simulation is active");
        simulator.send_state();
    } else {
        tokio::spawn(brightness::run_monitor());
    }

    if let Some(simulator) = &network_simulator {
        eprintln!("Network simulation is active");
        simulator.send_state();
    } else {
        tokio::spawn(network::run_monitor());
    }

    tokio::spawn(system_monitor::run_monitor());
    tokio::spawn(workspaces::run_monitor());
    media::send_state();
    power::send_state().await;

    if let Err(error) = run_command_loop(
        bluetooth_simulator,
        None,
        battery_simulator,
        brightness_simulator,
        network_simulator,
    )
    .await
    {
        eprintln!("Red Core command service stopped: {error}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn adapter(name: &str, powered: bool) -> BluetoothAdapter {
        BluetoothAdapter {
            name: name.to_string(),
            alias: name.to_string(),
            powered,
            discovering: false,
        }
    }

    fn command(action: &str) -> DaemonCommand {
        DaemonCommand {
            module: Some("bluetooth".to_string()),
            action: action.to_string(),
            adapter: None,
            address: None,
            powered: None,
            enabled: None,
            profile: None,
            scenario: None,
            display: None,
            percentage: None,
            max_value: None,
            delta: None,
            workspace_index: None,
            app_id: None,
            icon_name: None,
            windows: None,
            media: None,
            request_id: None,
            device: None,
            ssid: None,
            password: None,
            security_mode: None,
            saved_uuid: None,
            uuid: None,
            hidden: None,
            autoconnect: None,
            autoconnect_priority: None,
        }
    }

    fn device_command(action: &str, address: &str) -> DaemonCommand {
        DaemonCommand {
            module: Some("bluetooth".to_string()),
            action: action.to_string(),
            adapter: None,
            address: Some(address.to_string()),
            powered: None,
            enabled: None,
            profile: None,
            scenario: None,
            display: None,
            percentage: None,
            max_value: None,
            delta: None,
            workspace_index: None,
            app_id: None,
            icon_name: None,
            windows: None,
            media: None,
            request_id: None,
            device: None,
            ssid: None,
            password: None,
            security_mode: None,
            saved_uuid: None,
            uuid: None,
            hidden: None,
            autoconnect: None,
            autoconnect_priority: None,
        }
    }

    #[test]
    fn unavailable_state_has_no_adapter() {
        let state = BluetoothState::unavailable();

        assert!(!state.service_available);
        assert!(!state.available);
        assert!(!state.simulated);
        assert!(state.adapters.is_empty());
        assert!(state.devices.is_empty());
    }

    #[test]
    fn network_snapshot_is_not_an_action_result() {
        let mut request = command("snapshot");
        request.module = Some("network".to_string());

        assert!(is_network_state_request(&request));
        request.action = "wifi".to_string();
        assert!(!is_network_state_request(&request));
    }

    #[test]
    fn ready_state_reports_adapter_availability() {
        let without_adapter = BluetoothState::ready(Vec::new());
        let with_adapter = BluetoothState::ready(vec![adapter("hci0", true)]);

        assert!(without_adapter.service_available);
        assert!(!without_adapter.available);
        assert!(with_adapter.service_available);
        assert!(with_adapter.available);
        assert!(!with_adapter.simulated);
    }

    #[test]
    fn identical_states_compare_equal() {
        let first = BluetoothState::ready(vec![adapter("hci0", true)]);
        let second = BluetoothState::ready(vec![adapter("hci0", true)]);
        let changed = BluetoothState::ready(vec![adapter("hci0", false)]);

        assert_eq!(first, second);
        assert_ne!(first, changed);
    }

    #[test]
    fn state_uses_stable_json_fields() {
        let state = BluetoothState::ready(Vec::new());
        let json = serde_json::to_value(state).expect("state should serialize");

        assert_eq!(json["event"], "bluetooth-state");
        assert_eq!(json["serviceAvailable"], true);
        assert_eq!(json["available"], false);
        assert_eq!(json["simulated"], false);
        assert_eq!(json["adapters"], serde_json::json!([]));
        assert_eq!(json["devices"], serde_json::json!([]));
    }

    #[test]
    fn retry_delay_grows_and_stops_at_maximum() {
        assert_eq!(
            next_retry_delay(Duration::from_secs(2)),
            Duration::from_secs(4)
        );
        assert_eq!(
            next_retry_delay(Duration::from_secs(32)),
            Duration::from_secs(60)
        );
        assert_eq!(
            next_retry_delay(Duration::from_secs(60)),
            Duration::from_secs(60)
        );
    }

    #[test]
    fn simulation_starts_with_saved_devices() {
        let simulator = BluetoothSimulator::new();

        assert!(simulator.state.simulated);
        assert!(simulator.state.available);
        assert_eq!(simulator.state.adapters.len(), 1);
        assert_eq!(simulator.state.devices.len(), 2);
        assert!(
            simulator
                .state
                .devices
                .iter()
                .any(|device| device.connected)
        );
    }

    #[test]
    fn simulation_scan_adds_nearby_devices() {
        let mut simulator = BluetoothSimulator::new();
        let mut scan = command("scan");
        scan.enabled = Some(true);

        simulator.apply(&scan).expect("scan should start");

        assert!(simulator.state.adapters[0].discovering);
        assert_eq!(simulator.state.devices.len(), 4);
        assert!(
            simulator
                .state
                .devices
                .iter()
                .any(|device| device.kind == "keyboard" && !device.paired)
        );
    }

    #[test]
    fn simulation_tracks_the_same_device_per_adapter() {
        let mut simulator = BluetoothSimulator::new();
        simulator.state.adapters.push(adapter("hci-sim1", true));

        simulator.add_nearby_devices(SIMULATED_ADAPTER_NAME);
        simulator.add_nearby_devices("hci-sim1");

        let keyboard_adapters: Vec<&str> = simulator
            .state
            .devices
            .iter()
            .filter(|device| device.address == "02:00:00:00:00:03")
            .map(|device| device.adapter.as_str())
            .collect();

        assert_eq!(keyboard_adapters, [SIMULATED_ADAPTER_NAME, "hci-sim1"]);
    }

    #[test]
    fn simulation_pairs_connects_disconnects_and_forgets() {
        let mut simulator = BluetoothSimulator::new();
        let mut scan = command("scan");
        scan.enabled = Some(true);
        simulator.apply(&scan).expect("scan should start");

        let address = "02:00:00:00:00:03";
        simulator
            .apply(&device_command("pair", address))
            .expect("pair should work");
        simulator
            .apply(&device_command("connect", address))
            .expect("connect should work");

        let index = simulator
            .device_index(SIMULATED_ADAPTER_NAME, address)
            .expect("device should exist");
        assert!(simulator.state.devices[index].paired);
        assert!(simulator.state.devices[index].trusted);
        assert!(simulator.state.devices[index].connected);

        simulator
            .apply(&device_command("disconnect", address))
            .expect("disconnect should work");
        assert!(!simulator.state.devices[index].connected);

        simulator
            .apply(&device_command("forget", address))
            .expect("forget should work");
        assert!(!simulator.state.devices[index].paired);
        assert!(!simulator.state.devices[index].trusted);
    }

    #[test]
    fn simulation_rejects_connect_before_pairing() {
        let mut simulator = BluetoothSimulator::new();
        let mut scan = command("scan");
        scan.enabled = Some(true);
        simulator.apply(&scan).expect("scan should start");

        let result = simulator.apply(&device_command("connect", "02:00:00:00:00:04"));

        assert!(result.is_err());
    }

    #[test]
    fn simulation_power_off_stops_scan_and_disconnects_devices() {
        let mut simulator = BluetoothSimulator::new();
        let mut scan = command("scan");
        scan.enabled = Some(true);
        simulator.apply(&scan).expect("scan should start");

        let mut power = command("set-powered");
        power.powered = Some(false);
        simulator.apply(&power).expect("power off should work");

        assert!(!simulator.state.adapters[0].powered);
        assert!(!simulator.state.adapters[0].discovering);
        assert!(
            simulator
                .state
                .devices
                .iter()
                .all(|device| !device.connected)
        );
    }

    #[test]
    fn simulation_removes_and_restores_adapter() {
        let mut simulator = BluetoothSimulator::new();

        simulator
            .apply(&command("remove-adapter"))
            .expect("adapter removal should work");
        assert!(!simulator.state.available);
        assert!(simulator.state.adapters.is_empty());
        assert!(simulator.state.devices.is_empty());

        simulator
            .apply(&command("add-adapter"))
            .expect("adapter addition should work");
        assert!(simulator.state.available);
        assert_eq!(simulator.state.adapters.len(), 1);
    }
}
