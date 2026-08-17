use crate::{DaemonCommand, send_json};
use serde::Serialize;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::env;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;
use tokio::time::sleep;

const INITIAL_RETRY_DELAY: Duration = Duration::from_secs(2);
const MAX_RETRY_DELAY: Duration = Duration::from_secs(60);

struct ManagedChild(Option<Child>);

impl ManagedChild {
    fn new(child: Child) -> Self {
        Self(Some(child))
    }

    fn child_mut(&mut self) -> &mut Child {
        self.0.as_mut().expect("managed child should exist")
    }

    fn wait(mut self) -> std::io::Result<ExitStatus> {
        self.0
            .take()
            .expect("managed child should exist")
            .wait()
    }
}

impl Drop for ManagedChild {
    fn drop(&mut self) {
        if let Some(child) = &mut self.0 {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
struct WorkspacesState {
    event: &'static str,
    service_available: bool,
    available: bool,
    workspaces: Vec<Value>,
    active_workspace: i64,
    keyboard_layouts: Vec<String>,
    keyboard_layout_index: i64,
    windows: Vec<Value>,
    reason: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    window_id: Option<String>,
}

impl WorkspacesState {
    fn unavailable() -> Self {
        Self {
            event: "workspaces-state",
            service_available: false,
            available: false,
            workspaces: Vec::new(),
            active_workspace: -1,
            keyboard_layouts: Vec::new(),
            keyboard_layout_index: 0,
            windows: Vec::new(),
            reason: "unavailable".to_string(),
            window_id: None,
        }
    }

    fn ready() -> Self {
        Self {
            service_available: true,
            available: true,
            ..Self::unavailable()
        }
    }

    fn emit(&self) {
        send_json(self, "Workspaces state");
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct WorkspacesActionResult<'a> {
    event: &'static str,
    action: &'a str,
    success: bool,
    message: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AppIconResult<'a> {
    event: &'static str,
    app_id: &'a str,
    icon: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct TerminalAppsResult {
    event: &'static str,
    apps: HashMap<String, String>,
}

fn send_action_result(action: &str, result: Result<(), String>) {
    let (success, message) = match result {
        Ok(()) => (true, None),
        Err(message) => (false, Some(message)),
    };

    send_json(
        &WorkspacesActionResult {
            event: "workspaces-action-result",
            action,
            success,
            message,
        },
        "Workspaces action result",
    );
}

fn value_id(value: &Value) -> Option<String> {
    match value {
        Value::String(value) => Some(value.clone()),
        Value::Number(value) => Some(value.to_string()),
        _ => None,
    }
}

fn object_id(value: &Value) -> Option<String> {
    value.get("id").and_then(value_id)
}

fn set_window(state: &mut WorkspacesState, window: Value) {
    let Some(id) = object_id(&window) else {
        return;
    };

    if let Some(existing) = state
        .windows
        .iter_mut()
        .find(|candidate| object_id(candidate).as_deref() == Some(id.as_str()))
    {
        *existing = window;
    } else {
        state.windows.push(window);
    }
}

fn set_window_layout(state: &mut WorkspacesState, id: &str, layout: Value) {
    let Some(window) = state
        .windows
        .iter_mut()
        .find(|candidate| object_id(candidate).as_deref() == Some(id))
    else {
        return;
    };

    if let Some(object) = window.as_object_mut() {
        object.insert("layout".to_string(), layout);
    }
}

fn apply_layout_changes(state: &mut WorkspacesState, payload: &Value) {
    let changes = payload
        .get("changes")
        .or_else(|| payload.get("layouts"))
        .or_else(|| payload.get("windows"))
        .unwrap_or(payload);

    if let Some(items) = changes.as_array() {
        for item in items {
            if let (Some(id), Some(layout)) =
                (item.get("id").and_then(value_id), item.get("layout"))
            {
                set_window_layout(state, &id, layout.clone());
                continue;
            }

            if let Some(pair) = item.as_array()
                && pair.len() >= 2
                && let Some(id) = value_id(&pair[0])
            {
                set_window_layout(state, &id, pair[1].clone());
            }
        }
        return;
    }

    if let Some(items) = changes.as_object() {
        for (id, value) in items {
            let layout = value.get("layout").unwrap_or(value);
            set_window_layout(state, id, layout.clone());
        }
    }
}

fn apply_niri_event(state: &mut WorkspacesState, event: &Value) -> bool {
    state.service_available = true;
    state.available = true;
    state.window_id = None;

    if let Some(payload) = event.get("WorkspacesChanged") {
        let mut workspaces = payload
            .get("workspaces")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();

        workspaces.sort_by_key(|workspace| {
            workspace
                .get("idx")
                .and_then(Value::as_i64)
                .unwrap_or(i64::MAX)
        });

        if let Some(focused) = workspaces.iter().find(|workspace| {
            workspace
                .get("is_focused")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        }) {
            state.active_workspace = focused.get("id").and_then(Value::as_i64).unwrap_or(-1);
        }

        state.workspaces = workspaces;
        state.reason = "workspaces-changed".to_string();
        return true;
    }

    if let Some(payload) = event.get("WorkspaceActivated")
        && payload
            .get("focused")
            .and_then(Value::as_bool)
            .unwrap_or(false)
    {
        state.active_workspace = payload
            .get("id")
            .and_then(Value::as_i64)
            .unwrap_or(state.active_workspace);
        state.reason = "workspace-activated".to_string();
        return true;
    }

    if let Some(payload) = event.get("KeyboardLayoutsChanged") {
        let layouts = payload.get("keyboard_layouts").unwrap_or(payload);
        state.keyboard_layouts = layouts
            .get("names")
            .and_then(Value::as_array)
            .map(|names| {
                names
                    .iter()
                    .filter_map(Value::as_str)
                    .map(ToString::to_string)
                    .collect()
            })
            .unwrap_or_default();

        if let Some(index) = layouts.get("current_idx").and_then(Value::as_i64) {
            state.keyboard_layout_index = index;
        }

        state.reason = "keyboard-layouts-changed".to_string();
        return true;
    }

    if let Some(payload) = event.get("KeyboardLayoutSwitched")
        && let Some(index) = payload.get("idx").and_then(Value::as_i64)
    {
        state.keyboard_layout_index = index;
        state.reason = "keyboard-layout-switched".to_string();
        return true;
    }

    if let Some(payload) = event.get("WindowsChanged") {
        state.windows = payload
            .get("windows")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        state.reason = "windows-changed".to_string();
        return true;
    }

    if let Some(payload) = event.get("WindowOpenedOrChanged")
        && let Some(window) = payload.get("window")
    {
        state.window_id = object_id(window);
        set_window(state, window.clone());
        state.reason = "window-opened-or-changed".to_string();
        return true;
    }

    if let Some(payload) = event.get("WindowLayoutsChanged") {
        apply_layout_changes(state, payload);
        state.reason = "window-layouts-changed".to_string();
        return true;
    }

    if let Some(payload) = event.get("WindowClosed")
        && let Some(id) = payload.get("id").and_then(value_id)
    {
        state
            .windows
            .retain(|window| object_id(window).as_deref() != Some(id.as_str()));
        state.window_id = Some(id);
        state.reason = "window-closed".to_string();
        return true;
    }

    false
}

fn monitor_session() -> (String, bool) {
    let child = Command::new("niri")
        .args(["msg", "--json", "event-stream"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn();

    let mut child = match child {
        Ok(child) => ManagedChild::new(child),
        Err(error) => {
            return (format!("could not start Niri event stream: {error}"), false);
        }
    };

    let Some(stdout) = child.child_mut().stdout.take() else {
        return ("Niri event stream has no stdout".to_string(), false);
    };
    let lines = BufReader::new(stdout).lines();
    let mut state = WorkspacesState::ready();
    let mut had_events = false;

    for line in lines {
        let line = match line {
            Ok(line) => line,
            Err(error) => return (error.to_string(), had_events),
        };
        let event = match serde_json::from_str::<Value>(&line) {
            Ok(event) => event,
            Err(error) => return (format!("invalid Niri event: {error}"), had_events),
        };

        if apply_niri_event(&mut state, &event) {
            state.emit();
            had_events = true;
        }
    }

    let status = child
        .wait()
        .map(|status| status.to_string())
        .unwrap_or_else(|error| error.to_string());
    (format!("Niri event stream ended with {status}"), had_events)
}

pub(crate) async fn run_monitor() {
    let mut retry_delay = INITIAL_RETRY_DELAY;
    let mut unavailable_sent = false;

    loop {
        let (error, had_events) = tokio::task::spawn_blocking(monitor_session)
            .await
            .unwrap_or_else(|join_error| (join_error.to_string(), false));

        if had_events {
            unavailable_sent = false;
            retry_delay = INITIAL_RETRY_DELAY;
        }

        if !unavailable_sent {
            WorkspacesState::unavailable().emit();
            eprintln!("Workspaces monitoring is unavailable: {error}");
            unavailable_sent = true;
        }

        sleep(retry_delay).await;
        retry_delay = retry_delay.saturating_mul(2).min(MAX_RETRY_DELAY);
    }
}

fn run_niri_action(arguments: Vec<String>) -> Result<(), String> {
    let output = Command::new("niri")
        .arg("msg")
        .arg("action")
        .args(arguments)
        .stdin(Stdio::null())
        .output()
        .map_err(|error| format!("could not run Niri action: {error}"))?;

    if output.status.success() {
        return Ok(());
    }

    let message = String::from_utf8_lossy(&output.stderr).trim().to_string();
    Err(if message.is_empty() {
        format!("Niri action failed with {}", output.status)
    } else {
        message
    })
}

fn normalize(value: &str) -> String {
    value.trim().to_lowercase().replace(['_', ' '], "-")
}

#[derive(Clone, Debug)]
struct DesktopEntry {
    stem: String,
    name: String,
    startup_class: String,
    icon: String,
    categories: String,
}

#[derive(Debug)]
struct DesktopIndex {
    entries: Vec<DesktopEntry>,
    terminal_ids: HashSet<String>,
    icon_dirs: Vec<PathBuf>,
}

fn data_directories() -> Vec<PathBuf> {
    let data_home = env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share")))
        .unwrap_or_else(|| PathBuf::from("/usr/local/share"));
    let mut directories = vec![data_home];

    directories.extend(
        env::var("XDG_DATA_DIRS")
            .unwrap_or_else(|_| "/usr/local/share:/usr/share".to_string())
            .split(':')
            .filter(|value| !value.is_empty())
            .map(PathBuf::from),
    );
    directories
}

fn parse_desktop_entry(text: &str) -> HashMap<String, String> {
    let mut result = HashMap::new();
    let mut in_desktop_entry = false;

    for line in text.lines() {
        let line = line.trim();

        if line.starts_with('[') && line.ends_with(']') {
            in_desktop_entry = line == "[Desktop Entry]";
            continue;
        }

        if !in_desktop_entry || line.is_empty() || line.starts_with('#') {
            continue;
        }

        if let Some((key, value)) = line.split_once('=') {
            result
                .entry(key.trim().to_string())
                .or_insert_with(|| value.trim().to_string());
        }
    }

    result
}

impl DesktopIndex {
    fn load() -> Self {
        let directories = data_directories();
        let mut entries = Vec::new();
        let mut terminal_ids = known_terminals();
        let mut icon_dirs = Vec::new();

        for base in &directories {
            for subdirectory in ["icons", "pixmaps"] {
                let path = base.join(subdirectory);
                if !icon_dirs.contains(&path) {
                    icon_dirs.push(path);
                }
            }

            let application_dir = base.join("applications");
            let Ok(files) = fs::read_dir(application_dir) else {
                continue;
            };

            for file in files.flatten() {
                let path = file.path();
                if path.extension().and_then(|value| value.to_str()) != Some("desktop") {
                    continue;
                }

                let Ok(text) = fs::read_to_string(&path) else {
                    continue;
                };
                let values = parse_desktop_entry(&text);
                let stem = normalize(
                    path.file_stem()
                        .and_then(|value| value.to_str())
                        .unwrap_or_default(),
                );
                let entry = DesktopEntry {
                    stem: stem.clone(),
                    name: normalize(values.get("Name").map(String::as_str).unwrap_or_default()),
                    startup_class: normalize(
                        values
                            .get("StartupWMClass")
                            .map(String::as_str)
                            .unwrap_or_default(),
                    ),
                    icon: values.get("Icon").cloned().unwrap_or_default(),
                    categories: normalize(
                        values
                            .get("Categories")
                            .map(String::as_str)
                            .unwrap_or_default(),
                    ),
                };

                if entry.categories.contains("terminalemulator") {
                    terminal_ids.insert(stem);
                    if !entry.startup_class.is_empty() {
                        terminal_ids.insert(entry.startup_class.clone());
                    }
                }
                entries.push(entry);
            }
        }

        Self {
            entries,
            terminal_ids,
            icon_dirs,
        }
    }

    fn is_terminal(&self, app_id: &str) -> bool {
        let target = normalize(app_id);
        self.terminal_ids.contains(&target)
            || self
                .terminal_ids
                .iter()
                .any(|id| id.ends_with(&format!(".{target}")))
    }

    fn desktop_icon(&self, app_id: &str) -> String {
        let target = normalize(app_id);
        let mut best: Option<(u8, &str)> = None;

        for entry in &self.entries {
            let mut score = if entry.stem == target {
                100
            } else if entry.stem.ends_with(&format!(".{target}")) {
                90
            } else if entry.stem.contains(&target) {
                60
            } else {
                0
            };

            if entry.startup_class == target {
                score = score.max(95);
            }
            if entry.name == target {
                score = score.max(80);
            }

            if score > 0
                && !entry.icon.is_empty()
                && best.is_none_or(|(best_score, _)| score > best_score)
            {
                best = Some((score, entry.icon.as_str()));
            }
        }

        best.map(|(_, icon)| icon.to_string()).unwrap_or_default()
    }
}

fn known_terminals() -> HashSet<String> {
    [
        "foot",
        "footclient",
        "foot-server",
        "kitty",
        "alacritty",
        "wezterm",
        "wezterm-gui",
        "ghostty",
        "konsole",
        "gnome-terminal",
        "gnome-terminal-server",
        "xfce4-terminal",
        "qterminal",
        "lxterminal",
        "tilix",
        "terminator",
    ]
    .into_iter()
    .map(ToString::to_string)
    .collect()
}

fn desktop_index() -> &'static DesktopIndex {
    static INDEX: OnceLock<DesktopIndex> = OnceLock::new();
    INDEX.get_or_init(DesktopIndex::load)
}

fn file_uri(path: &Path) -> String {
    let text = path.to_string_lossy();
    let mut encoded = String::with_capacity(text.len());

    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'-' | b'_' | b'.' | b'~') {
            encoded.push(char::from(byte));
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }

    format!("file://{encoded}")
}

fn find_named_icon(index: &DesktopIndex, app_id: &str, requested_icon: &str) -> String {
    let icon = if requested_icon.trim().is_empty() {
        index.desktop_icon(app_id)
    } else {
        requested_icon.trim().to_string()
    };

    if !icon.is_empty() {
        let direct = PathBuf::from(&icon);
        if direct.is_absolute() && direct.is_file() {
            return file_uri(&direct);
        }
    }

    const EXTENSIONS: [&str; 6] = ["svg", "png", "xpm", "jpg", "jpeg", "webp"];
    let mut names = Vec::new();
    for value in [icon.as_str(), app_id] {
        let Some(base) = Path::new(value)
            .file_name()
            .and_then(|value| value.to_str())
        else {
            continue;
        };
        if base.is_empty() {
            continue;
        }
        names.push(base.to_string());
        if Path::new(base).extension().is_none() {
            names.extend(
                EXTENSIONS
                    .iter()
                    .map(|extension| format!("{base}.{extension}")),
            );
        }
    }
    names.sort();
    names.dedup();

    for directory in &index.icon_dirs {
        for name in &names {
            let candidate = directory.join(name);
            if candidate.is_file() {
                return file_uri(&candidate);
            }
        }
    }

    let mut visited_directories = HashSet::new();
    for directory in &index.icon_dirs {
        let mut stack = vec![directory.clone()];
        while let Some(current) = stack.pop() {
            let identity = current.canonicalize().unwrap_or_else(|_| current.clone());
            if !visited_directories.insert(identity) {
                continue;
            }

            let Ok(children) = fs::read_dir(current) else {
                continue;
            };
            for child in children.flatten() {
                let path = child.path();
                if child.file_type().is_ok_and(|kind| kind.is_dir()) {
                    stack.push(path);
                } else if path
                    .file_name()
                    .and_then(|value| value.to_str())
                    .is_some_and(|value| names.iter().any(|name| name == value))
                {
                    return file_uri(&path);
                }
            }
        }
    }

    String::new()
}

fn resolve_app_icon(app_id: &str, icon_name: &str) -> String {
    static CACHE: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let key = format!("{app_id}\0{icon_name}");

    if let Some(icon) = cache
        .lock()
        .ok()
        .and_then(|values| values.get(&key).cloned())
    {
        return icon;
    }

    let icon = find_named_icon(desktop_index(), app_id, icon_name);
    if let Ok(mut values) = cache.lock() {
        values.insert(key, icon.clone());
    }
    icon
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ProcessInfo {
    pid: i32,
    name: String,
    pgrp: i32,
    tty: i32,
    tpgid: i32,
    depth: usize,
}

fn parse_process_stat(pid: i32, depth: usize, text: &str) -> Option<ProcessInfo> {
    let open = text.find('(')?;
    let close = text.rfind(')')?;
    let fields: Vec<&str> = text.get(close + 2..)?.split_whitespace().collect();

    Some(ProcessInfo {
        pid,
        name: text.get(open + 1..close)?.to_string(),
        pgrp: fields.get(2)?.parse().ok()?,
        tty: fields.get(4)?.parse().ok()?,
        tpgid: fields.get(5)?.parse().ok()?,
        depth,
    })
}

fn process_children(pid: i32) -> Vec<i32> {
    fs::read_to_string(format!("/proc/{pid}/task/{pid}/children"))
        .ok()
        .map(|text| {
            text.split_whitespace()
                .filter_map(|value| value.parse().ok())
                .collect()
        })
        .unwrap_or_default()
}

fn descendants(root_pid: i32) -> Vec<ProcessInfo> {
    let mut result = Vec::new();
    let mut stack = vec![(root_pid, 0usize)];
    let mut visited = HashSet::new();

    while let Some((pid, depth)) = stack.pop() {
        if !visited.insert(pid) {
            continue;
        }

        for child in process_children(pid) {
            let child_depth = depth + 1;
            if let Ok(text) = fs::read_to_string(format!("/proc/{child}/stat"))
                && let Some(info) = parse_process_stat(child, child_depth, &text)
            {
                result.push(info);
            }
            stack.push((child, child_depth));
        }
    }
    result
}

fn choose_foreground_application(mut processes: Vec<ProcessInfo>) -> String {
    const SKIP: [&str; 11] = [
        "sh", "bash", "zsh", "dash", "fish", "nu", "sudo", "doas", "env", "tmux", "screen",
    ];
    let terminals = known_terminals();

    processes
        .retain(|process| process.tty != 0 && process.tpgid > 0 && process.pgrp == process.tpgid);
    processes.sort_by_key(|process| (process.depth, process.pid));

    processes
        .into_iter()
        .find(|process| {
            let name = normalize(&process.name);
            !SKIP.contains(&name.as_str()) && !terminals.contains(&name)
        })
        .map(|process| process.name)
        .unwrap_or_default()
}

fn scan_terminal_apps(windows: Vec<Value>) -> HashMap<String, String> {
    let index = desktop_index();
    let mut result = HashMap::new();

    for window in windows {
        let Some(id) = object_id(&window) else {
            continue;
        };
        let app_id = window
            .get("app_id")
            .and_then(Value::as_str)
            .unwrap_or_default();

        if !index.is_terminal(app_id) {
            continue;
        }

        let foreground = window
            .get("pid")
            .and_then(Value::as_i64)
            .and_then(|pid| i32::try_from(pid).ok())
            .filter(|pid| *pid > 0)
            .map(descendants)
            .map(choose_foreground_application)
            .unwrap_or_default();
        result.insert(id, foreground);
    }

    result
}

pub(crate) async fn apply_command(command: &DaemonCommand) {
    match command.action.as_str() {
        "focus-workspace" => {
            let result = match command.workspace_index {
                Some(index) if index > 0 => tokio::task::spawn_blocking(move || {
                    run_niri_action(vec!["focus-workspace".to_string(), index.to_string()])
                })
                .await
                .unwrap_or_else(|error| Err(error.to_string())),
                _ => Err("Missing or invalid workspace index".to_string()),
            };
            send_action_result(&command.action, result);
        }
        "switch-layout" => {
            let result = tokio::task::spawn_blocking(|| {
                run_niri_action(vec!["switch-layout".to_string(), "next".to_string()])
            })
            .await
            .unwrap_or_else(|error| Err(error.to_string()));
            send_action_result(&command.action, result);
        }
        "resolve-app-icon" => {
            let app_id = command.app_id.clone().unwrap_or_default();
            let icon_name = command.icon_name.clone().unwrap_or_default();
            let lookup_app_id = app_id.clone();
            tokio::spawn(async move {
                let icon = tokio::task::spawn_blocking(move || {
                    resolve_app_icon(&lookup_app_id, &icon_name)
                })
                .await
                .unwrap_or_default();
                send_json(
                    &AppIconResult {
                        event: "app-icon-result",
                        app_id: &app_id,
                        icon,
                    },
                    "application icon result",
                );
            });
        }
        "scan-terminal-apps" => {
            let windows = command.windows.clone().unwrap_or_default();
            tokio::spawn(async move {
                let apps = tokio::task::spawn_blocking(move || scan_terminal_apps(windows))
                    .await
                    .unwrap_or_default();
                send_json(
                    &TerminalAppsResult {
                        event: "terminal-apps-result",
                        apps,
                    },
                    "terminal applications result",
                );
            });
        }
        _ => send_action_result(
            &command.action,
            Err(format!("Unknown Workspaces action: {}", command.action)),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn workspace_snapshot_is_sorted_and_selects_focus() {
        let mut state = WorkspacesState::ready();
        let changed = apply_niri_event(
            &mut state,
            &json!({
                "WorkspacesChanged": {
                    "workspaces": [
                        {"id": 8, "idx": 2, "is_focused": true},
                        {"id": 4, "idx": 1, "is_focused": false}
                    ]
                }
            }),
        );

        assert!(changed);
        assert_eq!(state.workspaces[0]["id"], 4);
        assert_eq!(state.active_workspace, 8);
    }

    #[test]
    fn window_events_add_update_layout_and_remove() {
        let mut state = WorkspacesState::ready();
        apply_niri_event(
            &mut state,
            &json!({"WindowOpenedOrChanged": {"window": {"id": 9, "title": "first"}}}),
        );
        apply_niri_event(
            &mut state,
            &json!({"WindowOpenedOrChanged": {"window": {"id": 9, "title": "changed"}}}),
        );
        apply_niri_event(
            &mut state,
            &json!({"WindowLayoutsChanged": {"changes": [[9, {"pos_in_scrolling_layout": [2, 1]}]]}}),
        );

        assert_eq!(state.windows.len(), 1);
        assert_eq!(state.windows[0]["title"], "changed");
        assert_eq!(
            state.windows[0]["layout"]["pos_in_scrolling_layout"],
            json!([2, 1])
        );

        apply_niri_event(&mut state, &json!({"WindowClosed": {"id": 9}}));
        assert!(state.windows.is_empty());
        assert_eq!(state.window_id.as_deref(), Some("9"));
    }

    #[test]
    fn process_stat_handles_spaces_and_parentheses() {
        let info = parse_process_stat(15, 2, "15 (name with ) paren) S 1 15 15 34816 15 0 0 0")
            .expect("stat should parse");

        assert_eq!(info.name, "name with ) paren");
        assert_eq!(info.pgrp, 15);
        assert_eq!(info.tty, 34816);
        assert_eq!(info.tpgid, 15);
    }

    #[test]
    fn foreground_selection_skips_shell_and_prefers_shallow_process() {
        let process = |pid, name: &str, depth| ProcessInfo {
            pid,
            name: name.to_string(),
            pgrp: pid,
            tty: 1,
            tpgid: pid,
            depth,
        };
        let result = choose_foreground_application(vec![
            process(10, "bash", 1),
            process(12, "helper", 3),
            process(11, "btop", 2),
        ]);

        assert_eq!(result, "btop");
    }

    #[test]
    fn desktop_parser_reads_only_main_group() {
        let entry = parse_desktop_entry(
            "[Desktop Entry]\nName=Foot\nIcon=foot\nCategories=TerminalEmulator;\n[Desktop Action New]\nName=Other\n",
        );

        assert_eq!(entry.get("Name").map(String::as_str), Some("Foot"));
        assert_eq!(entry.get("Icon").map(String::as_str), Some("foot"));
    }

    #[test]
    fn file_uri_encodes_spaces() {
        assert_eq!(
            file_uri(Path::new("/tmp/red core/icon.png")),
            "file:///tmp/red%20core/icon.png"
        );
    }

    #[test]
    fn unavailable_state_has_stable_contract() {
        let value = serde_json::to_value(WorkspacesState::unavailable()).unwrap();
        assert_eq!(value["event"], "workspaces-state");
        assert_eq!(value["serviceAvailable"], false);
        assert_eq!(value["available"], false);
        assert_eq!(value["activeWorkspace"], -1);
        assert_eq!(value["windows"], json!([]));
    }
}
