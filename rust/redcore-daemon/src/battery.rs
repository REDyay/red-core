use crate::{DaemonCommand, send_json};
use dbus::arg::{PropMap, RefArg};
use dbus::message::MatchRule;
use dbus::nonblock::stdintf::org_freedesktop_dbus::Properties;
use dbus::nonblock::{Proxy, SyncConnection};
use futures_util::StreamExt;
use serde::Serialize;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::task::JoinHandle;
use tokio::time::{MissedTickBehavior, interval, sleep};

const UPOWER_DESTINATION: &str = "org.freedesktop.UPower";
const UPOWER_PATH: &str = "/org/freedesktop/UPower";
const UPOWER_INTERFACE: &str = "org.freedesktop.UPower";
const UPOWER_DEVICE_INTERFACE: &str = "org.freedesktop.UPower.Device";

const POWER_PROFILES_DESTINATION: &str = "org.freedesktop.UPower.PowerProfiles";
const POWER_PROFILES_PATH: &str = "/org/freedesktop/UPower/PowerProfiles";
const POWER_PROFILES_INTERFACE: &str = "org.freedesktop.UPower.PowerProfiles";

const DBUS_TIMEOUT: Duration = Duration::from_secs(5);
const HEALTH_CHECK_INTERVAL: Duration = Duration::from_secs(60);
const INITIAL_RETRY_DELAY: Duration = Duration::from_secs(2);
const MAX_RETRY_DELAY: Duration = Duration::from_secs(60);

const POWER_SAVER: &str = "power-saver";
const BALANCED: &str = "balanced";
const PERFORMANCE: &str = "performance";

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct BatteryState {
    event: &'static str,
    service_available: bool,
    available: bool,
    simulated: bool,
    source: &'static str,
    battery_count: usize,
    percentage: u8,
    percentage_known: bool,
    status: String,
    time_to_empty_seconds: Option<u64>,
    time_to_full_seconds: Option<u64>,
    energy_rate_watts: Option<f64>,
    health_percentage: Option<u8>,
    power_profiles_available: bool,
    active_power_profile: String,
    power_profiles: Vec<String>,
    performance_degraded: String,
}

impl BatteryState {
    fn unavailable(service_available: bool, profiles: PowerProfileState) -> Self {
        Self {
            event: "battery-state",
            service_available,
            available: false,
            simulated: false,
            source: "none",
            battery_count: 0,
            percentage: 0,
            percentage_known: false,
            status: "unavailable".to_string(),
            time_to_empty_seconds: None,
            time_to_full_seconds: None,
            energy_rate_watts: None,
            health_percentage: None,
            power_profiles_available: profiles.available,
            active_power_profile: profiles.active,
            power_profiles: profiles.profiles,
            performance_degraded: profiles.performance_degraded,
        }
    }

    fn from_snapshot(
        service_available: bool,
        source: &'static str,
        snapshot: BatterySnapshot,
        profiles: PowerProfileState,
    ) -> Self {
        let percentage_known = snapshot.percentage.is_some();

        Self {
            event: "battery-state",
            service_available,
            available: true,
            simulated: false,
            source,
            battery_count: snapshot.count,
            percentage: snapshot.percentage.unwrap_or_default(),
            percentage_known,
            status: snapshot.status,
            time_to_empty_seconds: snapshot.time_to_empty_seconds,
            time_to_full_seconds: snapshot.time_to_full_seconds,
            energy_rate_watts: snapshot.energy_rate_watts,
            health_percentage: snapshot.health_percentage,
            power_profiles_available: profiles.available,
            active_power_profile: profiles.active,
            power_profiles: profiles.profiles,
            performance_degraded: profiles.performance_degraded,
        }
    }
}

#[derive(Clone, Debug, Default)]
struct PowerProfileState {
    available: bool,
    active: String,
    profiles: Vec<String>,
    performance_degraded: String,
}

#[derive(Clone, Debug)]
struct BatterySnapshot {
    count: usize,
    percentage: Option<u8>,
    status: String,
    time_to_empty_seconds: Option<u64>,
    time_to_full_seconds: Option<u64>,
    energy_rate_watts: Option<f64>,
    health_percentage: Option<u8>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct BatteryActionResult<'a> {
    event: &'static str,
    action: &'a str,
    success: bool,
    message: Option<&'a str>,
}

pub(crate) fn send_action_result(action: &str, result: Result<(), &str>) {
    let (success, message) = match result {
        Ok(()) => (true, None),
        Err(message) => (false, Some(message)),
    };

    send_json(
        &BatteryActionResult {
            event: "battery-action-result",
            action,
            success,
            message,
        },
        "battery action result",
    );
}

fn send_state(state: &BatteryState) -> bool {
    send_json(state, "battery state")
}

fn send_if_changed(last_state: &mut Option<BatteryState>, state: BatteryState) {
    if last_state.as_ref() == Some(&state) {
        return;
    }

    if send_state(&state) {
        *last_state = Some(state);
    }
}

fn connect_system() -> Result<(JoinHandle<()>, Arc<SyncConnection>), String> {
    let (resource, connection) =
        dbus_tokio::connection::new_system_sync().map_err(|error| error.to_string())?;

    let handle = tokio::spawn(async move {
        let error = resource.await;
        eprintln!("Battery D-Bus connection stopped: {error}");
    });

    Ok((handle, connection))
}

fn property<'a>(properties: &'a PropMap, name: &str) -> Option<&'a dyn RefArg> {
    properties.get(name).map(|value| value.0.as_ref())
}

fn property_bool(properties: &PropMap, name: &str) -> Option<bool> {
    let value = property(properties, name)?;
    value
        .as_i64()
        .map(|number| number != 0)
        .or_else(|| value.as_u64().map(|number| number != 0))
}

fn property_u64(properties: &PropMap, name: &str) -> Option<u64> {
    let value = property(properties, name)?;
    value
        .as_u64()
        .or_else(|| value.as_i64().and_then(|number| u64::try_from(number).ok()))
}

fn property_f64(properties: &PropMap, name: &str) -> Option<f64> {
    property(properties, name)?.as_f64()
}

fn property_string(properties: &PropMap, name: &str) -> Option<String> {
    property(properties, name)?.as_str().map(str::to_string)
}

fn percentage(value: f64) -> u8 {
    value.round().clamp(0.0, 100.0) as u8
}

fn positive_seconds(value: Option<u64>) -> Option<u64> {
    value.filter(|seconds| *seconds > 0)
}

fn rounded_watts(value: f64) -> Option<f64> {
    if value <= 0.0 {
        None
    } else {
        Some((value * 100.0).round() / 100.0)
    }
}

fn status_name(value: u64) -> &'static str {
    match value {
        1 => "charging",
        2 => "discharging",
        3 => "empty",
        4 => "full",
        5 => "pending-charge",
        6 => "pending-discharge",
        _ => "unknown",
    }
}

fn ordered_profiles(mut profiles: Vec<String>) -> Vec<String> {
    profiles.retain(|profile| matches!(profile.as_str(), POWER_SAVER | BALANCED | PERFORMANCE));
    profiles.sort_by_key(|profile| match profile.as_str() {
        POWER_SAVER => 0,
        BALANCED => 1,
        PERFORMANCE => 2,
        _ => 3,
    });
    profiles.dedup();
    profiles
}

async fn read_power_profiles(connection: Arc<SyncConnection>) -> PowerProfileState {
    let proxy = Proxy::new(
        POWER_PROFILES_DESTINATION,
        POWER_PROFILES_PATH,
        DBUS_TIMEOUT,
        connection,
    );

    let active: String = match proxy.get(POWER_PROFILES_INTERFACE, "ActiveProfile").await {
        Ok(active) => active,
        Err(_) => return PowerProfileState::default(),
    };

    let profile_maps: Vec<PropMap> = proxy
        .get(POWER_PROFILES_INTERFACE, "Profiles")
        .await
        .unwrap_or_default();

    let profiles = ordered_profiles(
        profile_maps
            .iter()
            .filter_map(|profile| property_string(profile, "Profile"))
            .collect(),
    );

    let performance_degraded = proxy
        .get(POWER_PROFILES_INTERFACE, "PerformanceDegraded")
        .await
        .unwrap_or_default();

    PowerProfileState {
        available: !profiles.is_empty(),
        active,
        profiles,
        performance_degraded,
    }
}

async fn upower_device_properties(
    connection: Arc<SyncConnection>,
    path: dbus::Path<'static>,
) -> Result<PropMap, dbus::Error> {
    Proxy::new(UPOWER_DESTINATION, path, DBUS_TIMEOUT, connection)
        .get_all(UPOWER_DEVICE_INTERFACE)
        .await
}

fn is_system_battery(properties: &PropMap) -> bool {
    property_u64(properties, "Type") == Some(2)
        && property_bool(properties, "PowerSupply") == Some(true)
        && property_bool(properties, "IsPresent") != Some(false)
}

fn health_from_devices(devices: &[PropMap]) -> Option<u8> {
    let (full, design) = devices
        .iter()
        .filter_map(|device| {
            Some((
                property_f64(device, "EnergyFull")?,
                property_f64(device, "EnergyFullDesign")?,
            ))
        })
        .filter(|(_, design)| *design > 0.0)
        .fold(
            (0.0, 0.0),
            |(full, design), (device_full, device_design)| {
                (full + device_full, design + device_design)
            },
        );

    (design > 0.0).then(|| percentage(full / design * 100.0))
}

fn aggregate_devices(devices: &[PropMap]) -> BatterySnapshot {
    let (total_energy, total_full) = devices
        .iter()
        .filter_map(|device| {
            Some((
                property_f64(device, "Energy")?,
                property_f64(device, "EnergyFull")?,
            ))
        })
        .filter(|(_, full)| *full > 0.0)
        .fold(
            (0.0, 0.0),
            |(energy, full), (device_energy, device_full)| {
                (energy + device_energy, full + device_full)
            },
        );

    let percentages: Vec<f64> = devices
        .iter()
        .filter_map(|device| property_f64(device, "Percentage"))
        .collect();

    let combined_percentage = if total_full > 0.0 {
        Some(total_energy / total_full * 100.0)
    } else if percentages.is_empty() {
        None
    } else {
        Some(percentages.iter().sum::<f64>() / percentages.len() as f64)
    };

    let status = if devices
        .iter()
        .any(|device| property_u64(device, "State") == Some(1))
    {
        "charging"
    } else if devices
        .iter()
        .all(|device| property_u64(device, "State") == Some(4))
    {
        "full"
    } else if devices
        .iter()
        .any(|device| property_u64(device, "State") == Some(2))
    {
        "discharging"
    } else {
        "unknown"
    };

    let energy_rate = devices
        .iter()
        .filter_map(|device| property_f64(device, "EnergyRate"))
        .sum();

    BatterySnapshot {
        count: devices.len(),
        percentage: combined_percentage.map(percentage),
        status: status.to_string(),
        time_to_empty_seconds: None,
        time_to_full_seconds: None,
        energy_rate_watts: rounded_watts(energy_rate),
        health_percentage: health_from_devices(devices),
    }
}

fn snapshot_from_display(display: &PropMap, devices: &[PropMap]) -> BatterySnapshot {
    BatterySnapshot {
        count: devices.len(),
        percentage: property_f64(display, "Percentage").map(percentage),
        status: status_name(property_u64(display, "State").unwrap_or_default()).to_string(),
        time_to_empty_seconds: positive_seconds(property_u64(display, "TimeToEmpty")),
        time_to_full_seconds: positive_seconds(property_u64(display, "TimeToFull")),
        energy_rate_watts: rounded_watts(property_f64(display, "EnergyRate").unwrap_or_default()),
        health_percentage: health_from_devices(devices),
    }
}

async fn read_upower_snapshot(
    connection: Arc<SyncConnection>,
) -> Result<Option<BatterySnapshot>, dbus::Error> {
    let root = Proxy::new(
        UPOWER_DESTINATION,
        UPOWER_PATH,
        DBUS_TIMEOUT,
        connection.clone(),
    );

    let (paths,): (Vec<dbus::Path<'static>>,) = root
        .method_call(UPOWER_INTERFACE, "EnumerateDevices", ())
        .await?;

    let mut devices = Vec::new();

    for path in paths {
        let Ok(properties) = upower_device_properties(connection.clone(), path).await else {
            // UPower devices can disappear between enumeration and property reads.
            continue;
        };

        if is_system_battery(&properties) {
            devices.push(properties);
        }
    }

    if devices.is_empty() {
        return Ok(None);
    }

    let display_path: Result<(dbus::Path<'static>,), dbus::Error> = root
        .method_call(UPOWER_INTERFACE, "GetDisplayDevice", ())
        .await;

    if let Ok((path,)) = display_path
        && let Ok(display) = upower_device_properties(connection, path).await
        && property_u64(&display, "Type") == Some(2)
    {
        return Ok(Some(snapshot_from_display(&display, &devices)));
    }

    Ok(Some(aggregate_devices(&devices)))
}

fn read_trimmed(path: &Path) -> Option<String> {
    fs::read_to_string(path)
        .ok()
        .map(|value| value.trim().to_string())
}

fn read_number(path: &Path) -> Option<f64> {
    read_trimmed(path)?.parse().ok()
}

fn sysfs_battery_directories() -> Vec<PathBuf> {
    let Ok(entries) = fs::read_dir("/sys/class/power_supply") else {
        return Vec::new();
    };

    entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| read_trimmed(&path.join("type")).as_deref() == Some("Battery"))
        .filter(|path| read_trimmed(&path.join("present")).as_deref() != Some("0"))
        .filter(|path| {
            read_trimmed(&path.join("scope"))
                .map(|scope| scope == "System")
                .unwrap_or(true)
        })
        .collect()
}

fn combined_sysfs_status(statuses: &[String]) -> &'static str {
    if statuses.iter().any(|status| status == "charging") {
        "charging"
    } else if !statuses.is_empty() && statuses.iter().all(|status| status == "full") {
        "full"
    } else if statuses.iter().any(|status| status == "discharging") {
        "discharging"
    } else {
        "unknown"
    }
}

fn read_sysfs_state(profiles: PowerProfileState) -> BatteryState {
    let directories = sysfs_battery_directories();

    if directories.is_empty() {
        return BatteryState::unavailable(false, profiles);
    }

    let percentages: Vec<f64> = directories
        .iter()
        .filter_map(|path| read_number(&path.join("capacity")))
        .collect();

    let combined_percentage = if percentages.is_empty() {
        None
    } else {
        Some(percentages.iter().sum::<f64>() / percentages.len() as f64)
    };

    let statuses: Vec<String> = directories
        .iter()
        .filter_map(|path| read_trimmed(&path.join("status")))
        .map(|status| status.to_lowercase().replace(' ', "-"))
        .collect();

    let status = combined_sysfs_status(&statuses);

    let mut full = 0.0;
    let mut design = 0.0;

    for path in &directories {
        let device_full = read_number(&path.join("energy_full"))
            .or_else(|| read_number(&path.join("charge_full")));
        let device_design = read_number(&path.join("energy_full_design"))
            .or_else(|| read_number(&path.join("charge_full_design")));

        if let (Some(device_full), Some(device_design)) = (device_full, device_design) {
            full += device_full;
            design += device_design;
        }
    }

    BatteryState::from_snapshot(
        false,
        "sysfs",
        BatterySnapshot {
            count: directories.len(),
            percentage: combined_percentage.map(percentage),
            status: status.to_string(),
            time_to_empty_seconds: None,
            time_to_full_seconds: None,
            energy_rate_watts: None,
            health_percentage: (design > 0.0).then(|| percentage(full / design * 100.0)),
        },
        profiles,
    )
}

async fn read_real_state(connection: Arc<SyncConnection>) -> BatteryState {
    let profiles = read_power_profiles(connection.clone()).await;

    match read_upower_snapshot(connection).await {
        Ok(Some(snapshot)) => BatteryState::from_snapshot(true, "upower", snapshot, profiles),
        Ok(None) => BatteryState::unavailable(true, profiles),
        Err(_) => read_sysfs_state(profiles),
    }
}

async fn monitor_connection(
    connection: Arc<SyncConnection>,
    last_state: &mut Option<BatteryState>,
) -> Result<(), String> {
    send_if_changed(last_state, read_real_state(connection.clone()).await);

    let upower_properties_rule =
        MatchRule::new_signal("org.freedesktop.DBus.Properties", "PropertiesChanged")
            .with_namespaced_path(UPOWER_PATH);
    let profile_properties_rule =
        MatchRule::new_signal("org.freedesktop.DBus.Properties", "PropertiesChanged")
            .with_namespaced_path(POWER_PROFILES_PATH);
    let device_added_rule =
        MatchRule::new_signal(UPOWER_INTERFACE, "DeviceAdded").with_path(UPOWER_PATH);
    let device_removed_rule =
        MatchRule::new_signal(UPOWER_INTERFACE, "DeviceRemoved").with_path(UPOWER_PATH);

    let (upower_properties_match, upower_properties) = connection
        .add_match(upower_properties_rule)
        .await
        .map_err(|error| error.to_string())?
        .msg_stream();
    let (profile_properties_match, profile_properties) = connection
        .add_match(profile_properties_rule)
        .await
        .map_err(|error| error.to_string())?
        .msg_stream();
    let (device_added_match, device_added) = connection
        .add_match(device_added_rule)
        .await
        .map_err(|error| error.to_string())?
        .msg_stream();
    let (device_removed_match, device_removed) = connection
        .add_match(device_removed_rule)
        .await
        .map_err(|error| error.to_string())?
        .msg_stream();

    let _matches = (
        upower_properties_match,
        profile_properties_match,
        device_added_match,
        device_removed_match,
    );

    let events = futures_util::stream::select(
        futures_util::stream::select(upower_properties, profile_properties),
        futures_util::stream::select(device_added, device_removed),
    );
    futures_util::pin_mut!(events);

    let mut health_check = interval(HEALTH_CHECK_INTERVAL);
    health_check.set_missed_tick_behavior(MissedTickBehavior::Delay);
    health_check.tick().await;

    loop {
        tokio::select! {
            event = events.next() => {
                if event.is_none() {
                    return Err("battery event stream ended".to_string());
                }
            }

            _ = health_check.tick() => {}
        }

        send_if_changed(last_state, read_real_state(connection.clone()).await);
    }
}

pub(crate) async fn run_monitor() {
    let mut last_state = None;
    let mut retry_delay = INITIAL_RETRY_DELAY;

    loop {
        match connect_system() {
            Ok((resource, connection)) => {
                retry_delay = INITIAL_RETRY_DELAY;

                if let Err(error) = monitor_connection(connection, &mut last_state).await {
                    eprintln!("Battery monitoring stopped: {error}");
                }

                resource.abort();
            }

            Err(error) => {
                send_if_changed(
                    &mut last_state,
                    read_sysfs_state(PowerProfileState::default()),
                );
                eprintln!("Battery D-Bus service is unavailable: {error}");
            }
        }

        sleep(retry_delay).await;
        retry_delay = retry_delay.saturating_mul(2).min(MAX_RETRY_DELAY);
    }
}

pub(crate) async fn set_real_power_profile(profile: &str) -> Result<(), String> {
    if !matches!(profile, POWER_SAVER | BALANCED | PERFORMANCE) {
        return Err(format!("Unknown power profile: {profile}"));
    }

    let (resource, connection) = connect_system()?;
    let profiles = read_power_profiles(connection.clone()).await;

    if !profiles.available {
        resource.abort();
        return Err("Power Profiles service is unavailable".to_string());
    }

    if !profiles
        .profiles
        .iter()
        .any(|available| available == profile)
    {
        resource.abort();
        return Err(format!(
            "Power profile {profile} is not supported by this device"
        ));
    }

    let proxy = Proxy::new(
        POWER_PROFILES_DESTINATION,
        POWER_PROFILES_PATH,
        DBUS_TIMEOUT,
        connection,
    );

    let result = proxy
        .set(
            POWER_PROFILES_INTERFACE,
            "ActiveProfile",
            profile.to_string(),
        )
        .await
        .map_err(|error| error.to_string());

    resource.abort();
    result
}

pub(crate) struct BatterySimulator {
    state: BatteryState,
}

impl BatterySimulator {
    pub(crate) fn new() -> Self {
        Self {
            state: Self::initial_state(),
        }
    }

    fn initial_state() -> BatteryState {
        BatteryState {
            event: "battery-state",
            service_available: true,
            available: true,
            simulated: true,
            source: "simulation",
            battery_count: 1,
            percentage: 72,
            percentage_known: true,
            status: "discharging".to_string(),
            time_to_empty_seconds: Some(4 * 60 * 60 + 25 * 60),
            time_to_full_seconds: None,
            energy_rate_watts: Some(8.4),
            health_percentage: Some(94),
            power_profiles_available: true,
            active_power_profile: BALANCED.to_string(),
            power_profiles: vec![
                POWER_SAVER.to_string(),
                BALANCED.to_string(),
                PERFORMANCE.to_string(),
            ],
            performance_degraded: String::new(),
        }
    }

    pub(crate) fn send_state(&self) {
        send_state(&self.state);
    }

    pub(crate) fn apply(&mut self, command: &DaemonCommand) -> Result<bool, String> {
        match command.action.as_str() {
            "get-state" => Ok(true),

            "set-power-profile" => {
                let profile = command
                    .profile
                    .as_deref()
                    .ok_or_else(|| "Missing power profile".to_string())?;

                if !self
                    .state
                    .power_profiles
                    .iter()
                    .any(|available| available == profile)
                {
                    return Err(format!("Power profile {profile} is not supported"));
                }

                self.state.active_power_profile = profile.to_string();
                Ok(false)
            }

            "set-battery-scenario" => {
                let scenario = command
                    .scenario
                    .as_deref()
                    .ok_or_else(|| "Missing battery scenario".to_string())?;

                match scenario {
                    "charging" => {
                        self.state.percentage = 46;
                        self.state.percentage_known = true;
                        self.state.status = "charging".to_string();
                        self.state.time_to_empty_seconds = None;
                        self.state.time_to_full_seconds = Some(65 * 60);
                        self.state.energy_rate_watts = Some(31.5);
                    }
                    "discharging" => {
                        self.state.percentage = 72;
                        self.state.percentage_known = true;
                        self.state.status = "discharging".to_string();
                        self.state.time_to_empty_seconds = Some(4 * 60 * 60 + 25 * 60);
                        self.state.time_to_full_seconds = None;
                        self.state.energy_rate_watts = Some(8.4);
                    }
                    "low" => {
                        self.state.percentage = 9;
                        self.state.percentage_known = true;
                        self.state.status = "discharging".to_string();
                        self.state.time_to_empty_seconds = Some(28 * 60);
                        self.state.time_to_full_seconds = None;
                        self.state.energy_rate_watts = Some(10.2);
                    }
                    "full" => {
                        self.state.percentage = 100;
                        self.state.percentage_known = true;
                        self.state.status = "full".to_string();
                        self.state.time_to_empty_seconds = None;
                        self.state.time_to_full_seconds = None;
                        self.state.energy_rate_watts = None;
                    }
                    _ => return Err(format!("Unknown battery scenario: {scenario}")),
                }

                Ok(false)
            }

            "remove-battery" => {
                self.state.available = false;
                self.state.battery_count = 0;
                self.state.percentage = 0;
                self.state.percentage_known = false;
                self.state.status = "unavailable".to_string();
                self.state.time_to_empty_seconds = None;
                self.state.time_to_full_seconds = None;
                self.state.energy_rate_watts = None;
                self.state.health_percentage = None;
                Ok(false)
            }

            "add-battery" | "reset-battery-simulation" => {
                self.state = Self::initial_state();
                Ok(false)
            }

            _ => Err(format!("Unknown battery action: {}", command.action)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use dbus::arg::Variant;

    fn command(action: &str) -> DaemonCommand {
        DaemonCommand {
            module: Some("battery".to_string()),
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
        }
    }

    fn energy_properties(full: Option<f64>, design: Option<f64>) -> PropMap {
        let mut properties = PropMap::new();

        if let Some(full) = full {
            properties.insert(
                "EnergyFull".to_string(),
                Variant(Box::new(full) as Box<dyn RefArg>),
            );
        }

        if let Some(design) = design {
            properties.insert(
                "EnergyFullDesign".to_string(),
                Variant(Box::new(design) as Box<dyn RefArg>),
            );
        }

        properties
    }

    #[test]
    fn simulation_exposes_all_power_profiles() {
        let simulator = BatterySimulator::new();

        assert!(simulator.state.available);
        assert_eq!(
            simulator.state.power_profiles,
            [POWER_SAVER, BALANCED, PERFORMANCE]
        );
        assert_eq!(simulator.state.active_power_profile, BALANCED);
    }

    #[test]
    fn simulation_changes_power_profile() {
        let mut simulator = BatterySimulator::new();
        let mut profile = command("set-power-profile");
        profile.profile = Some(POWER_SAVER.to_string());

        simulator.apply(&profile).expect("profile should change");

        assert_eq!(simulator.state.active_power_profile, POWER_SAVER);
    }

    #[test]
    fn simulation_rejects_unknown_power_profile() {
        let mut simulator = BatterySimulator::new();
        let mut profile = command("set-power-profile");
        profile.profile = Some("turbo".to_string());

        assert!(simulator.apply(&profile).is_err());
    }

    #[test]
    fn simulation_supports_battery_scenarios() {
        let mut simulator = BatterySimulator::new();
        let mut scenario = command("set-battery-scenario");
        scenario.scenario = Some("low".to_string());

        simulator.apply(&scenario).expect("scenario should change");

        assert_eq!(simulator.state.percentage, 9);
        assert_eq!(simulator.state.status, "discharging");
    }

    #[test]
    fn simulation_clears_readings_when_battery_is_removed() {
        let mut simulator = BatterySimulator::new();

        simulator
            .apply(&command("remove-battery"))
            .expect("battery removal should work");

        assert!(!simulator.state.available);
        assert_eq!(simulator.state.battery_count, 0);
        assert_eq!(simulator.state.percentage, 0);
        assert!(!simulator.state.percentage_known);
        assert_eq!(simulator.state.status, "unavailable");
        assert!(simulator.state.health_percentage.is_none());
    }

    #[test]
    fn missing_sysfs_status_is_unknown_not_full() {
        assert_eq!(combined_sysfs_status(&[]), "unknown");
        assert_eq!(combined_sysfs_status(&["full".to_string()]), "full");
    }

    #[test]
    fn health_uses_only_complete_energy_pairs() {
        let devices = [
            energy_properties(Some(80.0), Some(100.0)),
            energy_properties(None, Some(100.0)),
        ];

        assert_eq!(health_from_devices(&devices), Some(80));
    }

    #[test]
    fn profile_order_is_stable() {
        assert_eq!(
            ordered_profiles(vec![
                PERFORMANCE.to_string(),
                POWER_SAVER.to_string(),
                BALANCED.to_string(),
                PERFORMANCE.to_string(),
            ]),
            [POWER_SAVER, BALANCED, PERFORMANCE]
        );
    }
}
