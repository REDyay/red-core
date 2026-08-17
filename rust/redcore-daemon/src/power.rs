use crate::{DaemonCommand, send_json};
use dbus::nonblock::Proxy;
use serde::Serialize;
use std::env;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;

const LOCKERS: [&str; 4] = ["swaylock", "hyprlock", "gtklock", "waylock"];
const LOGIN1_DESTINATION: &str = "org.freedesktop.login1";
const LOGIN1_PATH: &str = "/org/freedesktop/login1";
const LOGIN1_INTERFACE: &str = "org.freedesktop.login1.Manager";
const LOGIN1_TIMEOUT: Duration = Duration::from_secs(3);

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct PowerState {
    event: &'static str,
    service_available: bool,
    power_off_available: bool,
    reboot_available: bool,
    suspend_available: bool,
    lock_available: bool,
    locker: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PowerActionResult<'a> {
    event: &'static str,
    action: &'a str,
    request_id: Option<u64>,
    success: bool,
    message: Option<String>,
}

fn executable(path: &Path) -> bool {
    fs::metadata(path)
        .map(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

fn find_program(name: &str) -> Option<PathBuf> {
    let candidate = Path::new(name);

    if candidate.components().count() > 1 {
        return executable(candidate).then(|| candidate.to_path_buf());
    }

    env::var_os("PATH")
        .into_iter()
        .flat_map(|value| env::split_paths(&value).collect::<Vec<_>>())
        .map(|directory| directory.join(name))
        .find(|path| executable(path))
}

fn locker_program() -> Option<(&'static str, PathBuf)> {
    LOCKERS
        .into_iter()
        .find_map(|name| find_program(name).map(|path| (name, path)))
}

fn suspend_supported() -> bool {
    fs::read_to_string("/sys/power/state")
        .map(|states| {
            states
                .split_whitespace()
                .any(|state| matches!(state, "freeze" | "mem"))
        })
        .unwrap_or(false)
}

fn capability_allowed(value: &str) -> bool {
    matches!(value, "yes" | "challenge")
}

async fn logind_capabilities() -> Option<(bool, bool, bool)> {
    let (resource, connection) = dbus_tokio::connection::new_system_sync().ok()?;
    let resource = tokio::spawn(async move {
        let error = resource.await;
        eprintln!("Power D-Bus connection stopped: {error}");
    });
    let proxy = Proxy::new(
        LOGIN1_DESTINATION,
        LOGIN1_PATH,
        LOGIN1_TIMEOUT,
        connection,
    );
    let power_off: Result<(String,), _> = proxy.method_call(LOGIN1_INTERFACE, "CanPowerOff", ()).await;
    let reboot: Result<(String,), _> = proxy.method_call(LOGIN1_INTERFACE, "CanReboot", ()).await;
    let suspend: Result<(String,), _> = proxy.method_call(LOGIN1_INTERFACE, "CanSuspend", ()).await;
    resource.abort();

    Some((
        capability_allowed(&power_off.ok()?.0),
        capability_allowed(&reboot.ok()?.0),
        capability_allowed(&suspend.ok()?.0),
    ))
}

fn state_from_capabilities(
    power_off_available: bool,
    reboot_available: bool,
    suspend_available: bool,
) -> PowerState {
    let locker = locker_program();

    PowerState {
        event: "power-state",
        service_available: power_off_available
            || reboot_available
            || suspend_available
            || locker.is_some(),
        power_off_available,
        reboot_available,
        suspend_available,
        lock_available: locker.is_some(),
        locker: locker.map(|(name, _)| name.to_string()).unwrap_or_default(),
    }
}

pub(crate) async fn state() -> PowerState {
    let systemctl_available = find_program("systemctl").is_some();
    let fallback_suspend = systemctl_available && suspend_supported();
    let (power_off, reboot, suspend) = logind_capabilities().await.unwrap_or((
        systemctl_available,
        systemctl_available,
        fallback_suspend,
    ));

    state_from_capabilities(power_off, reboot, suspend && suspend_supported())
}

pub(crate) async fn send_state() {
    send_json(&state().await, "power state");
}

pub(crate) fn send_action_result(command: &DaemonCommand, result: Result<String, String>) {
    let (success, message) = match result {
        Ok(message) => (true, Some(message)),
        Err(message) => (false, Some(message)),
    };

    send_json(
        &PowerActionResult {
            event: "power-action-result",
            action: &command.action,
            request_id: command.request_id,
            success,
            message,
        },
        "power action result",
    );
}

fn systemctl_verb(action: &str) -> Option<&'static str> {
    match action {
        "power-off" => Some("poweroff"),
        "reboot" => Some("reboot"),
        "suspend" => Some("suspend"),
        _ => None,
    }
}

fn command_error(program: &str, stderr: &[u8], status: std::process::ExitStatus) -> String {
    let message = String::from_utf8_lossy(stderr).trim().to_string();

    if message.is_empty() {
        format!("{program} exited with {status}")
    } else {
        format!(
            "{program}: {}",
            message.chars().take(300).collect::<String>()
        )
    }
}

async fn request_system_action(action: &str) -> Result<String, String> {
    let verb = systemctl_verb(action).ok_or_else(|| "Unsupported power action".to_string())?;
    let program =
        find_program("systemctl").ok_or_else(|| "systemctl is unavailable".to_string())?;
    let program_name = program.display().to_string();

    if action == "suspend" && !suspend_supported() {
        return Err("Suspend is not supported by this device".to_string());
    }

    let output = tokio::task::spawn_blocking(move || {
        Command::new(program)
            .args(["--no-block", verb])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .output()
    })
    .await
    .map_err(|error| format!("Could not run systemctl: {error}"))?
    .map_err(|error| format!("Could not run systemctl: {error}"))?;

    if !output.status.success() {
        return Err(command_error(&program_name, &output.stderr, output.status));
    }

    Ok(format!("{action} requested"))
}

fn request_lock() -> Result<String, String> {
    let (name, program) =
        locker_program().ok_or_else(|| "No supported screen locker is installed".to_string())?;

    let mut child = Command::new(program)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("Could not start {name}: {error}"))?;
    thread::Builder::new()
        .name(format!("redcore-{name}-wait"))
        .spawn(move || {
            let _ = child.wait();
        })
        .map_err(|error| format!("Could not monitor {name}: {error}"))?;

    Ok(format!("Started {name}"))
}

pub(crate) async fn apply_command(command: &DaemonCommand) -> Result<String, String> {
    match command.action.as_str() {
        "get-state" => {
            send_state().await;
            Ok("Power state refreshed".to_string())
        }
        "lock" => request_lock(),
        "power-off" | "reboot" | "suspend" => request_system_action(&command.action).await,
        _ => Err(format!("Unknown power action: {}", command.action)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_known_system_actions_are_mapped() {
        assert_eq!(systemctl_verb("power-off"), Some("poweroff"));
        assert_eq!(systemctl_verb("reboot"), Some("reboot"));
        assert_eq!(systemctl_verb("suspend"), Some("suspend"));
        assert_eq!(systemctl_verb("hibernate"), None);
        assert_eq!(systemctl_verb("anything"), None);
    }

    #[test]
    fn state_uses_stable_json_fields() {
        let value = serde_json::to_value(state_from_capabilities(true, true, true))
            .expect("power state should serialize");

        assert_eq!(value["event"], "power-state");
        assert!(value["serviceAvailable"].is_boolean());
        assert!(value["powerOffAvailable"].is_boolean());
        assert!(value["rebootAvailable"].is_boolean());
        assert!(value["suspendAvailable"].is_boolean());
        assert!(value["lockAvailable"].is_boolean());
        assert!(value["locker"].is_string());
    }

    #[test]
    fn logind_challenge_is_an_available_action() {
        assert!(capability_allowed("yes"));
        assert!(capability_allowed("challenge"));
        assert!(!capability_allowed("no"));
        assert!(!capability_allowed("na"));
    }
}
