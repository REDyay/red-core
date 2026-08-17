use crate::{DaemonCommand, send_json};
use serde::Serialize;
use std::io;
use std::process::{Command, Output, Stdio};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};
use tokio::time::{MissedTickBehavior, interval};

const REFRESH_INTERVAL: Duration = Duration::from_secs(60);
const DDC_REDETECT_INTERVAL: Duration = Duration::from_secs(10 * 60);
const MINIMUM_PERCENTAGE: u8 = 1;
const BRIGHTNESSCTL_TIMEOUT: Duration = Duration::from_secs(5);
const DDCUTIL_TIMEOUT: Duration = Duration::from_secs(12);
const COMMAND_POLL_INTERVAL: Duration = Duration::from_millis(20);

static DDCUTIL_COMMAND_LOCK: Mutex<()> = Mutex::new(());

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct BrightnessDisplay {
    id: String,
    name: String,
    kind: &'static str,
    backend: &'static str,
    percentage: u8,
    max_value: u32,
    writable: bool,
    device: Option<String>,
    bus: Option<u32>,
    display_number: Option<u32>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct BrightnessState {
    event: &'static str,
    service_available: bool,
    available: bool,
    simulated: bool,
    brightnessctl_available: bool,
    ddcutil_available: bool,
    displays: Vec<BrightnessDisplay>,
}

impl BrightnessState {
    fn real(
        brightnessctl_available: bool,
        ddcutil_available: bool,
        displays: Vec<BrightnessDisplay>,
    ) -> Self {
        Self {
            event: "brightness-state",
            service_available: true,
            available: displays.iter().any(|display| display.writable),
            simulated: false,
            brightnessctl_available,
            ddcutil_available,
            displays,
        }
    }

    fn simulated(displays: Vec<BrightnessDisplay>) -> Self {
        Self {
            event: "brightness-state",
            service_available: true,
            available: displays.iter().any(|display| display.writable),
            simulated: true,
            brightnessctl_available: false,
            ddcutil_available: false,
            displays,
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct BrightnessActionResult<'a> {
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
        &BrightnessActionResult {
            event: "brightness-action-result",
            action,
            success,
            message,
        },
        "brightness action result",
    );
}

fn send_state(state: &BrightnessState) -> bool {
    send_json(state, "brightness state")
}

fn send_if_changed(last_state: &mut Option<BrightnessState>, state: BrightnessState) {
    if last_state.as_ref() == Some(&state) {
        return;
    }

    if send_state(&state) {
        *last_state = Some(state);
    }
}

fn percentage(current: u32, maximum: u32) -> u8 {
    if maximum == 0 {
        return 0;
    }

    ((f64::from(current) * 100.0 / f64::from(maximum)).round() as u32).min(100) as u8
}

fn raw_brightness(maximum: u32, requested_percentage: u8) -> u32 {
    let maximum = maximum.max(1);
    let requested_percentage = requested_percentage.clamp(MINIMUM_PERCENTAGE, 100);
    let raw = (u64::from(maximum) * u64::from(requested_percentage) + 50) / 100;

    u32::try_from(raw).unwrap_or(maximum).clamp(1, maximum)
}

fn command_error(program: &str, output: &Output) -> String {
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();

    if stderr.is_empty() {
        format!("{program} exited with {}", output.status)
    } else {
        format!(
            "{program}: {}",
            stderr.chars().take(300).collect::<String>()
        )
    }
}

fn is_not_found(error: &io::Error) -> bool {
    error.kind() == io::ErrorKind::NotFound
}

fn output_with_timeout(
    program: &str,
    arguments: Vec<String>,
    timeout: Duration,
) -> io::Result<Output> {
    let mut child = Command::new(program)
        .args(arguments)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let deadline = Instant::now() + timeout;

    loop {
        if child.try_wait()?.is_some() {
            return child.wait_with_output();
        }

        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();

            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                format!("{program} timed out after {} seconds", timeout.as_secs()),
            ));
        }

        thread::sleep(COMMAND_POLL_INTERVAL);
    }
}

fn run_command_blocking(program: &'static str, arguments: Vec<String>) -> io::Result<Output> {
    let _ddcutil_guard = if program == "ddcutil" {
        Some(
            DDCUTIL_COMMAND_LOCK
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner()),
        )
    } else {
        None
    };
    let timeout = if program == "ddcutil" {
        DDCUTIL_TIMEOUT
    } else {
        BRIGHTNESSCTL_TIMEOUT
    };

    output_with_timeout(program, arguments, timeout)
}

async fn run_command(program: &'static str, arguments: Vec<String>) -> io::Result<Output> {
    tokio::task::spawn_blocking(move || run_command_blocking(program, arguments))
        .await
        .map_err(io::Error::other)?
}

fn parse_brightnessctl(output: &str) -> Vec<BrightnessDisplay> {
    output
        .lines()
        .filter_map(|line| {
            let fields: Vec<&str> = line.split(',').map(str::trim).collect();

            if fields.len() < 5 || fields[1] != "backlight" {
                return None;
            }

            let device = fields[0].trim_matches('"');
            let current = fields[2].parse::<u32>().ok()?;
            let maximum = fields[3].parse::<u32>().ok()?;

            if device.is_empty() || maximum == 0 {
                return None;
            }

            Some(BrightnessDisplay {
                id: format!("backlight:{device}"),
                name: device.to_string(),
                kind: "internal",
                backend: "brightnessctl",
                percentage: percentage(current, maximum),
                max_value: maximum,
                writable: true,
                device: Some(device.to_string()),
                bus: None,
                display_number: None,
            })
        })
        .collect()
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct DdcDisplay {
    number: u32,
    bus: Option<u32>,
    name: String,
}

fn parse_bus(value: &str) -> Option<u32> {
    let marker = "/dev/i2c-";
    let start = value.find(marker)? + marker.len();
    let digits: String = value[start..]
        .chars()
        .take_while(char::is_ascii_digit)
        .collect();

    digits.parse().ok()
}

fn parse_display_number(value: &str) -> Option<u32> {
    value
        .strip_prefix("Display ")?
        .split_whitespace()
        .next()?
        .parse()
        .ok()
}

fn monitor_name(value: &str, number: u32, bus: Option<u32>) -> String {
    let value = value.trim();

    if value.is_empty() {
        return bus.map_or_else(
            || format!("External display {number}"),
            |bus| format!("External display (I2C {bus})"),
        );
    }

    let mut fields = value.split(':');
    let manufacturer = fields.next().unwrap_or_default().trim();
    let model = fields.next().unwrap_or_default().trim();

    if !model.is_empty() {
        model.to_string()
    } else if !manufacturer.is_empty() {
        manufacturer.to_string()
    } else {
        bus.map_or_else(
            || format!("External display {number}"),
            |bus| format!("External display (I2C {bus})"),
        )
    }
}

fn parse_ddc_detect(output: &str) -> Vec<DdcDisplay> {
    let mut displays = Vec::new();
    let mut current_number = None;
    let mut current_bus = None;
    let mut current_monitor = String::new();

    let push_current = |displays: &mut Vec<DdcDisplay>,
                        number: &mut Option<u32>,
                        bus: &mut Option<u32>,
                        name: &mut String| {
        if let Some(display_number) = number.take() {
            let bus_number = bus.take();

            displays.push(DdcDisplay {
                number: display_number,
                bus: bus_number,
                name: monitor_name(name, display_number, bus_number),
            });
        } else {
            bus.take();
        }

        name.clear();
    };

    for line in output.lines() {
        let trimmed = line.trim();

        if trimmed.starts_with("Display ") {
            push_current(
                &mut displays,
                &mut current_number,
                &mut current_bus,
                &mut current_monitor,
            );
            current_number = parse_display_number(trimmed);
        } else if let Some(value) = trimmed.strip_prefix("I2C bus:") {
            current_bus = parse_bus(value);
        } else if let Some(value) = trimmed.strip_prefix("Monitor:") {
            current_monitor = value.trim().to_string();
        }
    }

    push_current(
        &mut displays,
        &mut current_number,
        &mut current_bus,
        &mut current_monitor,
    );
    displays.sort_by_key(|display| display.number);
    displays.dedup_by_key(|display| display.number);
    displays
}

fn ddc_selection_arguments(
    bus: Option<u32>,
    display_number: Option<u32>,
) -> Result<Vec<String>, String> {
    if let Some(bus) = bus {
        Ok(vec!["--bus".to_string(), bus.to_string()])
    } else if let Some(display_number) = display_number {
        Ok(vec!["--display".to_string(), display_number.to_string()])
    } else {
        Err("External display selector is missing".to_string())
    }
}

fn parse_numeric_token(token: &str) -> Option<u32> {
    let token = token.trim_matches(|character: char| {
        !character.is_ascii_alphanumeric() && character != 'x' && character != 'X'
    });

    if let Some(hex) = token
        .strip_prefix("0x")
        .or_else(|| token.strip_prefix("0X"))
    {
        u32::from_str_radix(hex, 16).ok()
    } else {
        token.parse().ok()
    }
}

fn number_after(value: &str, marker: &str) -> Option<u32> {
    let start = value.find(marker)? + marker.len();
    value[start..]
        .split_whitespace()
        .find_map(parse_numeric_token)
}

fn parse_ddc_brightness(output: &str) -> Option<(u32, u32)> {
    let lower = output.to_ascii_lowercase();

    if let (Some(current), Some(maximum)) = (
        number_after(&lower, "current value ="),
        number_after(&lower, "max value ="),
    ) {
        return (maximum > 0).then_some((current, maximum));
    }

    let numbers: Vec<u32> = output
        .split_whitespace()
        .filter_map(parse_numeric_token)
        .collect();

    if numbers.len() < 2 {
        return None;
    }

    let current = numbers[numbers.len() - 2];
    let maximum = numbers[numbers.len() - 1];
    (maximum > 0).then_some((current, maximum))
}

async fn read_brightnessctl() -> (bool, Vec<BrightnessDisplay>) {
    let output = run_command(
        "brightnessctl",
        vec!["--machine-readable".to_string(), "--list".to_string()],
    )
    .await;

    match output {
        Ok(output) => {
            let displays = if output.status.success() {
                parse_brightnessctl(&String::from_utf8_lossy(&output.stdout))
            } else {
                Vec::new()
            };

            (true, displays)
        }
        Err(error) if is_not_found(&error) => (false, Vec::new()),
        Err(error) => {
            eprintln!("Could not run brightnessctl: {error}");
            (true, Vec::new())
        }
    }
}

async fn detect_ddcutil() -> (bool, Vec<DdcDisplay>) {
    let detect = run_command(
        "ddcutil",
        vec![
            "detect".to_string(),
            "--brief".to_string(),
            "--enable-usb".to_string(),
        ],
    )
    .await;

    let detect = match detect {
        Ok(output) => output,
        Err(error) if is_not_found(&error) => return (false, Vec::new()),
        Err(error) => {
            eprintln!("Could not run ddcutil: {error}");
            return (true, Vec::new());
        }
    };

    (
        true,
        parse_ddc_detect(&String::from_utf8_lossy(&detect.stdout)),
    )
}

async fn read_detected_ddc(detected: Vec<DdcDisplay>) -> Vec<BrightnessDisplay> {
    let mut displays = Vec::new();

    for display in detected {
        let mut arguments = vec!["getvcp".to_string(), "10".to_string()];
        let Ok(selection) = ddc_selection_arguments(display.bus, Some(display.number)) else {
            continue;
        };
        arguments.extend(selection);
        arguments.extend(["--brief".to_string(), "--enable-usb".to_string()]);
        let result = run_command("ddcutil", arguments).await;

        let Ok(result) = result else {
            continue;
        };

        if !result.status.success() {
            continue;
        }

        let Some((current, maximum)) =
            parse_ddc_brightness(&String::from_utf8_lossy(&result.stdout))
        else {
            continue;
        };

        displays.push(BrightnessDisplay {
            id: display.bus.map_or_else(
                || format!("ddc-display:{}", display.number),
                |bus| format!("ddc:{bus}"),
            ),
            name: display.name,
            kind: "external",
            backend: "ddcutil",
            percentage: percentage(current, maximum),
            max_value: maximum,
            writable: true,
            device: None,
            bus: display.bus,
            display_number: Some(display.number),
        });
    }

    displays
}

async fn read_ddcutil() -> (bool, Vec<BrightnessDisplay>) {
    let (available, detected) = detect_ddcutil().await;

    if !available {
        return (false, Vec::new());
    }

    (true, read_detected_ddc(detected).await)
}

pub(crate) async fn read_real_state() -> BrightnessState {
    let ((brightnessctl_available, mut internal), (ddcutil_available, mut external)) =
        tokio::join!(read_brightnessctl(), read_ddcutil());

    internal.append(&mut external);
    BrightnessState::real(brightnessctl_available, ddcutil_available, internal)
}

async fn set_internal_display(
    device: &str,
    maximum: u32,
    requested_percentage: u8,
) -> Result<(), String> {
    if device.is_empty() || device.contains('/') || device.len() > 128 {
        return Err("Invalid internal display identifier".to_string());
    }

    let value = raw_brightness(maximum, requested_percentage).to_string();
    let output = run_command(
        "brightnessctl",
        vec![
            "--device".to_string(),
            device.to_string(),
            "--class".to_string(),
            "backlight".to_string(),
            "--quiet".to_string(),
            "set".to_string(),
            value,
        ],
    )
    .await
    .map_err(|error| format!("brightnessctl: {error}"))?;

    if output.status.success() {
        Ok(())
    } else {
        Err(command_error("brightnessctl", &output))
    }
}

async fn set_external_display(
    bus: Option<u32>,
    display_number: Option<u32>,
    maximum: u32,
    requested_percentage: u8,
) -> Result<(), String> {
    let value = raw_brightness(maximum, requested_percentage).to_string();
    let mut arguments = vec!["setvcp".to_string(), "10".to_string(), value];
    arguments.extend(ddc_selection_arguments(bus, display_number)?);
    arguments.push("--enable-usb".to_string());
    let output = run_command("ddcutil", arguments)
        .await
        .map_err(|error| format!("ddcutil: {error}"))?;

    if output.status.success() {
        Ok(())
    } else {
        Err(command_error("ddcutil", &output))
    }
}

async fn set_display(display: &BrightnessDisplay, requested_percentage: u8) -> Result<(), String> {
    match display.backend {
        "brightnessctl" => {
            let device = display
                .device
                .as_deref()
                .ok_or_else(|| "Internal display identifier is missing".to_string())?;
            set_internal_display(device, display.max_value, requested_percentage).await
        }
        "ddcutil" => {
            set_external_display(
                display.bus,
                display.display_number,
                display.max_value,
                requested_percentage,
            )
            .await
        }
        _ => Err("Unsupported brightness backend".to_string()),
    }
}

pub(crate) async fn apply_preview(command: &DaemonCommand) -> Result<(), String> {
    let display_id = command
        .display
        .as_deref()
        .ok_or_else(|| "Missing display identifier".to_string())?;
    let requested = command
        .percentage
        .ok_or_else(|| "Missing brightness percentage".to_string())?;
    let maximum = command.max_value.unwrap_or(100).clamp(1, 65_535);

    if let Some(device) = display_id.strip_prefix("backlight:") {
        set_internal_display(device, maximum, requested).await
    } else if let Some(bus) = display_id.strip_prefix("ddc:") {
        let bus = bus
            .parse::<u32>()
            .map_err(|_| "Invalid external display bus".to_string())?;
        set_external_display(Some(bus), None, maximum, requested).await
    } else if let Some(number) = display_id.strip_prefix("ddc-display:") {
        let number = number
            .parse::<u32>()
            .map_err(|_| "Invalid external display number".to_string())?;
        set_external_display(None, Some(number), maximum, requested).await
    } else {
        Err("Unsupported brightness display identifier".to_string())
    }
}

pub(crate) async fn apply_real(command: &DaemonCommand) -> Result<(), String> {
    if matches!(command.action.as_str(), "get-state" | "refresh-brightness") {
        return Ok(());
    }

    let display_id = command
        .display
        .as_deref()
        .ok_or_else(|| "Missing display identifier".to_string())?;
    let state = read_real_state().await;
    let display = state
        .displays
        .iter()
        .find(|display| display.id == display_id)
        .ok_or_else(|| "Display is no longer available".to_string())?;

    let requested = match command.action.as_str() {
        "set-brightness" => command
            .percentage
            .ok_or_else(|| "Missing brightness percentage".to_string())?,
        "step-brightness" => {
            let delta = command
                .delta
                .ok_or_else(|| "Missing brightness step".to_string())?;
            (i16::from(display.percentage) + delta).clamp(1, 100) as u8
        }
        _ => return Err(format!("Unknown brightness action: {}", command.action)),
    };

    set_display(display, requested).await
}

pub(crate) async fn send_real_state() {
    send_state(&read_real_state().await);
}

pub(crate) async fn run_monitor() {
    let mut last_state = None;
    let mut refresh = interval(REFRESH_INTERVAL);
    let mut ddcutil_available = false;
    let mut detected_ddc = Vec::new();
    let mut next_ddc_detection = Instant::now();
    refresh.set_missed_tick_behavior(MissedTickBehavior::Delay);

    loop {
        refresh.tick().await;

        if Instant::now() >= next_ddc_detection {
            (ddcutil_available, detected_ddc) = detect_ddcutil().await;
            next_ddc_detection = Instant::now() + DDC_REDETECT_INTERVAL;
        }

        let ((brightnessctl_available, mut displays), external) = tokio::join!(
            read_brightnessctl(),
            read_detected_ddc(detected_ddc.clone())
        );
        displays.extend(external);
        send_if_changed(
            &mut last_state,
            BrightnessState::real(brightnessctl_available, ddcutil_available, displays),
        );
    }
}

pub(crate) struct BrightnessSimulator {
    state: BrightnessState,
}

impl BrightnessSimulator {
    pub(crate) fn new() -> Self {
        Self {
            state: Self::initial_state(),
        }
    }

    fn initial_state() -> BrightnessState {
        BrightnessState::simulated(vec![
            BrightnessDisplay {
                id: "sim-internal".to_string(),
                name: "Built-in Display".to_string(),
                kind: "internal",
                backend: "simulation",
                percentage: 68,
                max_value: 100,
                writable: true,
                device: None,
                bus: None,
                display_number: None,
            },
            BrightnessDisplay {
                id: "sim-external".to_string(),
                name: "Red Core Monitor".to_string(),
                kind: "external",
                backend: "simulation",
                percentage: 42,
                max_value: 100,
                writable: true,
                device: None,
                bus: None,
                display_number: None,
            },
        ])
    }

    pub(crate) fn send_state(&self) {
        send_state(&self.state);
    }

    pub(crate) fn apply(&mut self, command: &DaemonCommand) -> Result<(), String> {
        match command.action.as_str() {
            "get-state" | "refresh-brightness" => Ok(()),
            "set-brightness" | "preview-brightness" | "step-brightness" => {
                let display_id = command
                    .display
                    .as_deref()
                    .ok_or_else(|| "Missing display identifier".to_string())?;
                let display = self
                    .state
                    .displays
                    .iter_mut()
                    .find(|display| display.id == display_id)
                    .ok_or_else(|| "Display is no longer available".to_string())?;
                let requested = if matches!(
                    command.action.as_str(),
                    "set-brightness" | "preview-brightness"
                ) {
                    command
                        .percentage
                        .ok_or_else(|| "Missing brightness percentage".to_string())?
                } else {
                    let delta = command
                        .delta
                        .ok_or_else(|| "Missing brightness step".to_string())?;
                    (i16::from(display.percentage) + delta).clamp(1, 100) as u8
                };

                display.percentage = requested.clamp(1, 100);
                Ok(())
            }
            "remove-brightness-display" => {
                let display_id = command
                    .display
                    .as_deref()
                    .ok_or_else(|| "Missing display identifier".to_string())?;
                self.state
                    .displays
                    .retain(|display| display.id != display_id);
                self.state.available = !self.state.displays.is_empty();
                Ok(())
            }
            "remove-all-brightness-displays" => {
                self.state.displays.clear();
                self.state.available = false;
                Ok(())
            }
            "reset-brightness-simulation" | "add-brightness-display" => {
                self.state = Self::initial_state();
                Ok(())
            }
            _ => Err(format!("Unknown brightness action: {}", command.action)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn command(action: &str) -> DaemonCommand {
        DaemonCommand {
            module: Some("brightness".to_string()),
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

    #[test]
    fn parses_brightnessctl_machine_output() {
        let displays = parse_brightnessctl(
            "intel_backlight,backlight,480,960,50%\ninput3::capslock,leds,0,1,0%\n",
        );

        assert_eq!(displays.len(), 1);
        assert_eq!(displays[0].id, "backlight:intel_backlight");
        assert_eq!(displays[0].percentage, 50);
    }

    #[test]
    fn parses_ddcutil_detect_output() {
        let displays = parse_ddc_detect(
            "Display 1\n   I2C bus: /dev/i2c-7\n   Monitor: ACR:Acer X243W:SERIAL\n",
        );

        assert_eq!(
            displays,
            [DdcDisplay {
                number: 1,
                bus: Some(7),
                name: "Acer X243W".to_string(),
            }]
        );
    }

    #[test]
    fn parses_ddc_display_without_i2c_bus_for_usb_fallback() {
        let displays = parse_ddc_detect(
            "Display 2\n   USB device: /dev/usb/hiddev3\n   Monitor: EIZ:USB Monitor:SERIAL\n",
        );

        assert_eq!(
            displays,
            [DdcDisplay {
                number: 2,
                bus: None,
                name: "USB Monitor".to_string(),
            }]
        );
        assert_eq!(
            ddc_selection_arguments(displays[0].bus, Some(displays[0].number))
                .expect("display should have a selector"),
            ["--display", "2"]
        );
    }

    #[test]
    fn ddc_selection_prefers_stable_i2c_bus() {
        assert_eq!(
            ddc_selection_arguments(Some(6), Some(1)).expect("bus should be preferred"),
            ["--bus", "6"]
        );
    }

    #[test]
    fn raw_brightness_never_turns_the_backlight_fully_off() {
        assert_eq!(raw_brightness(100, 0), 1);
        assert_eq!(raw_brightness(100, 1), 1);
        assert_eq!(raw_brightness(50, 1), 1);
        assert_eq!(raw_brightness(1000, 1), 10);
    }

    #[test]
    fn command_timeout_stops_a_hung_process() {
        let started = Instant::now();
        let error = output_with_timeout("sleep", vec!["2".to_string()], Duration::from_millis(40))
            .expect_err("sleep should be terminated by the timeout");

        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn parses_normal_and_brief_ddc_brightness() {
        assert_eq!(
            parse_ddc_brightness("VCP code 0x10 (Brightness): current value = 35, max value = 100"),
            Some((35, 100))
        );
        assert_eq!(parse_ddc_brightness("VCP 10 C 42 100"), Some((42, 100)));
    }

    #[test]
    fn simulation_sets_and_steps_each_display() {
        let mut simulator = BrightnessSimulator::new();
        let mut set = command("set-brightness");
        set.display = Some("sim-internal".to_string());
        set.percentage = Some(25);
        simulator.apply(&set).expect("brightness should change");

        let mut step = command("step-brightness");
        step.display = Some("sim-internal".to_string());
        step.delta = Some(-10);
        simulator.apply(&step).expect("brightness should step");

        assert_eq!(simulator.state.displays[0].percentage, 15);
    }

    #[test]
    fn simulation_hides_when_all_displays_are_removed() {
        let mut simulator = BrightnessSimulator::new();
        simulator
            .apply(&command("remove-all-brightness-displays"))
            .expect("displays should be removed");

        assert!(!simulator.state.available);
        assert!(simulator.state.displays.is_empty());
    }
}
