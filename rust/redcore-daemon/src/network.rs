use crate::{DaemonCommand, send_json};
use dbus::arg::{PropMap, RefArg};
use dbus::message::MatchRule;
use dbus::nonblock::stdintf::org_freedesktop_dbus::Properties;
use dbus::nonblock::{Proxy, SyncConnection};
use dbus::{MessageType, Path as DbusPath};
use futures_util::StreamExt;
use serde::Serialize;
use std::collections::HashMap;
use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::{Duration, Instant};
use tokio::task::JoinHandle;
use tokio::time::{MissedTickBehavior, interval, sleep};

const NM_DESTINATION: &str = "org.freedesktop.NetworkManager";
const NM_PATH: &str = "/org/freedesktop/NetworkManager";
const NM_INTERFACE: &str = "org.freedesktop.NetworkManager";
const NM_DEVICE_INTERFACE: &str = "org.freedesktop.NetworkManager.Device";
const NM_WIFI_INTERFACE: &str = "org.freedesktop.NetworkManager.Device.Wireless";
const NM_WIRED_INTERFACE: &str = "org.freedesktop.NetworkManager.Device.Wired";
const NM_AP_INTERFACE: &str = "org.freedesktop.NetworkManager.AccessPoint";
const NM_ACTIVE_INTERFACE: &str = "org.freedesktop.NetworkManager.Connection.Active";
const NM_IP4_INTERFACE: &str = "org.freedesktop.NetworkManager.IP4Config";
const NM_SETTINGS_PATH: &str = "/org/freedesktop/NetworkManager/Settings";
const NM_SETTINGS_INTERFACE: &str = "org.freedesktop.NetworkManager.Settings";
const NM_SETTINGS_CONNECTION_INTERFACE: &str = "org.freedesktop.NetworkManager.Settings.Connection";

const DBUS_TIMEOUT: Duration = Duration::from_secs(5);
const HEALTH_CHECK_INTERVAL: Duration = Duration::from_secs(60);
const EVENT_DEBOUNCE: Duration = Duration::from_millis(180);
const INITIAL_RETRY_DELAY: Duration = Duration::from_secs(2);
const MAX_RETRY_DELAY: Duration = Duration::from_secs(60);
const NMCLI_TIMEOUT: Duration = Duration::from_secs(30);
const COMMAND_POLL_INTERVAL: Duration = Duration::from_millis(25);
const AP_STALE_AFTER_SECONDS: i64 = 120;
const WIFI_CAP_AP: u64 = 0x40;
const HOTSPOT_PROFILE_PREFIX: &str = "Red Core Hotspot";
const PORTAL_FALLBACK_URL: &str = "http://ping.archlinux.org/nm-check.txt";
const AP_PRIVACY: u64 = 0x1;
const AP_KEY_MGMT_PSK: u64 = 0x100;
const AP_KEY_MGMT_802_1X: u64 = 0x200;
const AP_KEY_MGMT_SAE: u64 = 0x400;
const AP_KEY_MGMT_OWE: u64 = 0x800;
const AP_KEY_MGMT_OWE_TM: u64 = 0x1000;
const AP_KEY_MGMT_SUITE_B_192: u64 = 0x2000;

static SECRET_COUNTER: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct PrimaryConnection {
    connected: bool,
    id: String,
    uuid: String,
    #[serde(rename = "type")]
    kind: String,
    devices: Vec<String>,
    connectivity: String,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AccessPoint {
    ssid: String,
    strength: u8,
    security: String,
    security_mode: String,
    active: bool,
    saved: bool,
    saved_uuid: String,
    autoconnect: bool,
    autoconnect_priority: i32,
    last_seen: i32,
    bssid: String,
    frequency: u32,
    enterprise: bool,
    supported: bool,
    advanced: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct WifiAdapter {
    #[serde(rename = "type")]
    kind: &'static str,
    iface: String,
    ip_address: String,
    gateway: String,
    state: String,
    active_ssid: String,
    active_strength: u8,
    bitrate: u32,
    last_scan_ms: i64,
    scan_busy: bool,
    mode: String,
    hotspot_active: bool,
    hotspot_supported: bool,
    access_points: Vec<AccessPoint>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct EthernetAdapter {
    #[serde(rename = "type")]
    kind: &'static str,
    iface: String,
    ip_address: String,
    gateway: String,
    state: String,
    carrier: bool,
    speed: u32,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SavedNetwork {
    ssid: String,
    uuid: String,
    id: String,
    autoconnect: bool,
    autoconnect_priority: i32,
    interface_name: String,
    security_mode: String,
    security: String,
    hidden: bool,
    enterprise: bool,
    supported: bool,
    advanced: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct NetworkState {
    event: &'static str,
    service_available: bool,
    nm_running: bool,
    version: String,
    simulated: bool,
    wifi_enabled: bool,
    wifi_hardware_enabled: bool,
    connectivity: String,
    portal_url: String,
    primary: PrimaryConnection,
    wifi: Vec<WifiAdapter>,
    ethernet: Vec<EthernetAdapter>,
    saved_networks: Vec<SavedNetwork>,
    advanced_editor_available: bool,
}

impl NetworkState {
    fn unavailable() -> Self {
        Self {
            event: "network-state",
            service_available: false,
            nm_running: false,
            version: String::new(),
            simulated: false,
            wifi_enabled: false,
            wifi_hardware_enabled: false,
            connectivity: "unknown".to_string(),
            portal_url: String::new(),
            primary: PrimaryConnection::default(),
            wifi: Vec::new(),
            ethernet: Vec::new(),
            saved_networks: Vec::new(),
            advanced_editor_available: executable_exists("nmtui"),
        }
    }
}

#[derive(Clone, Debug)]
struct WifiProfile {
    ssid: String,
    uuid: String,
    id: String,
    autoconnect: bool,
    autoconnect_priority: i32,
    interface_name: String,
    security_mode: String,
    hidden: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct SecurityInfo {
    mode: &'static str,
    label: &'static str,
    enterprise: bool,
    supported: bool,
    advanced: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct NetworkActionResult<'a> {
    event: &'static str,
    action: &'a str,
    success: bool,
    message: String,
    request_id: Option<u64>,
    password_required: bool,
    advanced_required: bool,
}

pub(crate) fn send_action_result(command: &DaemonCommand, result: Result<String, ActionError>) {
    let (success, message, password_required, advanced_required) = match result {
        Ok(message) => (true, message, false, false),
        Err(error) => (
            false,
            error.message,
            error.password_required,
            error.advanced_required,
        ),
    };

    send_json(
        &NetworkActionResult {
            event: "network-action-result",
            action: &command.action,
            success,
            message,
            request_id: command.request_id,
            password_required,
            advanced_required,
        },
        "network action result",
    );
}

#[derive(Debug)]
pub(crate) struct ActionError {
    message: String,
    password_required: bool,
    advanced_required: bool,
}

impl ActionError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            password_required: false,
            advanced_required: false,
        }
    }

    fn password(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            password_required: true,
            advanced_required: false,
        }
    }

    fn advanced(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            password_required: false,
            advanced_required: true,
        }
    }
}

struct SystemConnection {
    resource: JoinHandle<()>,
    connection: Arc<SyncConnection>,
}

impl Drop for SystemConnection {
    fn drop(&mut self) {
        self.resource.abort();
    }
}

fn connect_system() -> Result<SystemConnection, String> {
    let (resource, connection) =
        dbus_tokio::connection::new_system_sync().map_err(|error| error.to_string())?;

    let handle = tokio::spawn(async move {
        let error = resource.await;
        eprintln!("NetworkManager D-Bus connection stopped: {error}");
    });

    Ok(SystemConnection {
        resource: handle,
        connection,
    })
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

fn property_i64(properties: &PropMap, name: &str) -> Option<i64> {
    let value = property(properties, name)?;
    value
        .as_i64()
        .or_else(|| value.as_u64().and_then(|number| i64::try_from(number).ok()))
}

fn property_string(properties: &PropMap, name: &str) -> Option<String> {
    property(properties, name)?.as_str().map(str::to_string)
}

fn property_bytes(properties: &PropMap, name: &str) -> Option<Vec<u8>> {
    property(properties, name)?
        .as_iter()?
        .map(|value| value.as_u64().and_then(|number| u8::try_from(number).ok()))
        .collect()
}

fn property_paths(properties: &PropMap, name: &str) -> Vec<DbusPath<'static>> {
    property(properties, name)
        .and_then(RefArg::as_iter)
        .map(|values| {
            values
                .filter_map(|value| value.as_str())
                .filter_map(|path| DbusPath::new(path.to_string()).ok())
                .collect()
        })
        .unwrap_or_default()
}

fn property_path(properties: &PropMap, name: &str) -> Option<DbusPath<'static>> {
    let path = property_string(properties, name)?;
    DbusPath::new(path).ok()
}

fn ssid_text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

fn connectivity_name(value: u64) -> &'static str {
    match value {
        1 => "none",
        2 => "portal",
        3 => "limited",
        4 => "full",
        _ => "unknown",
    }
}

fn wifi_mode_name(value: u64) -> &'static str {
    match value {
        1 => "adhoc",
        2 => "infrastructure",
        3 => "hotspot",
        4 => "mesh",
        _ => "unknown",
    }
}

fn portal_url(properties: &PropMap) -> String {
    property_string(properties, "ConnectivityCheckUri")
        .filter(|value| value.starts_with("http://") || value.starts_with("https://"))
        .unwrap_or_else(|| PORTAL_FALLBACK_URL.to_string())
}

fn device_state_name(value: u64) -> &'static str {
    match value {
        10 => "unmanaged",
        20 => "unavailable",
        30 => "disconnected",
        40 => "prepare",
        50 => "config",
        60 => "need-auth",
        70 => "ip-config",
        80 => "ip-check",
        90 => "secondaries",
        100 => "activated",
        110 => "deactivating",
        120 => "failed",
        _ => "unknown",
    }
}

fn normalize_security_mode(value: &str) -> String {
    match value.trim() {
        "" | "none" => "open".to_string(),
        "wpa-none" | "wpa-psk" => "wpa-psk".to_string(),
        "sae" => "sae".to_string(),
        "owe" => "owe".to_string(),
        "wpa-eap" => "wpa-eap".to_string(),
        "wpa-eap-suite-b-192" => "wpa-eap-suite-b-192".to_string(),
        other => other.to_string(),
    }
}

fn security_from_flags(flags: u64, wpa: u64, rsn: u64) -> SecurityInfo {
    let combined = wpa | rsn;

    if combined & AP_KEY_MGMT_SUITE_B_192 != 0 {
        SecurityInfo {
            mode: "wpa-eap-suite-b-192",
            label: "WPA3 Enterprise",
            enterprise: true,
            supported: false,
            advanced: true,
        }
    } else if combined & AP_KEY_MGMT_802_1X != 0 {
        SecurityInfo {
            mode: "wpa-eap",
            label: "WPA2/WPA3 Enterprise",
            enterprise: true,
            supported: false,
            advanced: true,
        }
    } else if rsn & AP_KEY_MGMT_SAE != 0 && combined & AP_KEY_MGMT_PSK != 0 {
        SecurityInfo {
            mode: "wpa-psk",
            label: "WPA2/WPA3",
            enterprise: false,
            supported: true,
            advanced: false,
        }
    } else if rsn & AP_KEY_MGMT_SAE != 0 {
        SecurityInfo {
            mode: "sae",
            label: "WPA3",
            enterprise: false,
            supported: true,
            advanced: false,
        }
    } else if rsn & (AP_KEY_MGMT_OWE | AP_KEY_MGMT_OWE_TM) != 0 {
        SecurityInfo {
            mode: "owe",
            label: "OWE",
            enterprise: false,
            supported: true,
            advanced: false,
        }
    } else if combined & AP_KEY_MGMT_PSK != 0 || combined != 0 {
        SecurityInfo {
            mode: "wpa-psk",
            label: if rsn != 0 { "WPA2/WPA3" } else { "WPA" },
            enterprise: false,
            supported: true,
            advanced: false,
        }
    } else if flags & AP_PRIVACY != 0 {
        SecurityInfo {
            mode: "wep",
            label: "WEP",
            enterprise: false,
            supported: false,
            advanced: false,
        }
    } else {
        SecurityInfo {
            mode: "open",
            label: "Open",
            enterprise: false,
            supported: true,
            advanced: false,
        }
    }
}

fn profile_security(mode: &str) -> SecurityInfo {
    match normalize_security_mode(mode).as_str() {
        "open" => security_from_flags(0, 0, 0),
        "owe" => security_from_flags(0, 0, AP_KEY_MGMT_OWE),
        "sae" => security_from_flags(0, 0, AP_KEY_MGMT_SAE),
        "wpa-psk" => security_from_flags(0, 0, AP_KEY_MGMT_PSK),
        "wpa-eap" => security_from_flags(0, 0, AP_KEY_MGMT_802_1X),
        "wpa-eap-suite-b-192" => security_from_flags(0, 0, AP_KEY_MGMT_SUITE_B_192),
        _ => SecurityInfo {
            mode: "unsupported",
            label: "Unsupported",
            enterprise: false,
            supported: false,
            advanced: false,
        },
    }
}

fn best_profile<'a>(
    profiles: &'a [WifiProfile],
    ssid: &str,
    iface: &str,
    security_mode: &str,
) -> Option<&'a WifiProfile> {
    profiles
        .iter()
        .filter(|profile| {
            profile.ssid == ssid
                && profile.security_mode == security_mode
                && (profile.interface_name.is_empty() || profile.interface_name == iface)
        })
        .max_by_key(|profile| {
            (
                profile.interface_name == iface,
                profile.autoconnect,
                profile.autoconnect_priority,
            )
        })
}

async fn read_profiles(connection: Arc<SyncConnection>) -> Result<Vec<WifiProfile>, dbus::Error> {
    let settings = Proxy::new(
        NM_DESTINATION,
        NM_SETTINGS_PATH,
        DBUS_TIMEOUT,
        connection.clone(),
    );
    let (paths,): (Vec<DbusPath<'static>>,) = settings
        .method_call(NM_SETTINGS_INTERFACE, "ListConnections", ())
        .await?;
    let mut profiles = Vec::new();

    for path in paths {
        let proxy = Proxy::new(NM_DESTINATION, path, DBUS_TIMEOUT, connection.clone());
        let result: Result<(HashMap<String, PropMap>,), dbus::Error> = proxy
            .method_call(NM_SETTINGS_CONNECTION_INTERFACE, "GetSettings", ())
            .await;
        let Ok((settings,)) = result else {
            continue;
        };
        let Some(connection_settings) = settings.get("connection") else {
            continue;
        };
        if property_string(connection_settings, "type").as_deref() != Some("802-11-wireless") {
            continue;
        }
        let Some(wireless) = settings.get("802-11-wireless") else {
            continue;
        };
        if property_string(wireless, "mode").as_deref() == Some("ap") {
            continue;
        }
        let ssid = property_bytes(wireless, "ssid")
            .map(|bytes| ssid_text(&bytes))
            .unwrap_or_default();
        if ssid.is_empty() {
            continue;
        }
        let security_mode = settings
            .get("802-11-wireless-security")
            .map(|security| {
                let key_management = property_string(security, "key-mgmt").unwrap_or_default();
                if key_management.trim() == "none" {
                    "wep".to_string()
                } else {
                    normalize_security_mode(&key_management)
                }
            })
            .unwrap_or_else(|| "open".to_string());

        profiles.push(WifiProfile {
            ssid,
            uuid: property_string(connection_settings, "uuid").unwrap_or_default(),
            id: property_string(connection_settings, "id").unwrap_or_default(),
            autoconnect: property_bool(connection_settings, "autoconnect").unwrap_or(true),
            autoconnect_priority: property_i64(connection_settings, "autoconnect-priority")
                .unwrap_or_default()
                .clamp(-999, 999) as i32,
            interface_name: property_string(connection_settings, "interface-name")
                .unwrap_or_default(),
            security_mode,
            hidden: property_bool(wireless, "hidden").unwrap_or(false),
        });
    }

    profiles.sort_by(|left, right| left.ssid.cmp(&right.ssid).then(left.uuid.cmp(&right.uuid)));
    Ok(profiles)
}

async fn ip4_details(
    connection: Arc<SyncConnection>,
    path: Option<DbusPath<'static>>,
) -> (String, String) {
    let Some(path) = path.filter(|path| &path[..] != "/") else {
        return (String::new(), String::new());
    };
    let proxy = Proxy::new(NM_DESTINATION, path, DBUS_TIMEOUT, connection);
    let addresses: Vec<PropMap> = proxy
        .get(NM_IP4_INTERFACE, "AddressData")
        .await
        .unwrap_or_default();
    let address = addresses
        .first()
        .and_then(|value| property_string(value, "address"))
        .unwrap_or_default();
    let gateway: String = proxy
        .get(NM_IP4_INTERFACE, "Gateway")
        .await
        .unwrap_or_default();
    (address, gateway)
}

async fn read_primary(
    connection: Arc<SyncConnection>,
    path: Option<DbusPath<'static>>,
    connectivity: &str,
) -> PrimaryConnection {
    let Some(path) = path.filter(|path| &path[..] != "/") else {
        return PrimaryConnection {
            connectivity: connectivity.to_string(),
            ..PrimaryConnection::default()
        };
    };
    let properties: PropMap =
        match Proxy::new(NM_DESTINATION, path, DBUS_TIMEOUT, connection.clone())
            .get_all(NM_ACTIVE_INTERFACE)
            .await
        {
            Ok(properties) => properties,
            Err(_) => {
                return PrimaryConnection {
                    connectivity: connectivity.to_string(),
                    ..PrimaryConnection::default()
                };
            }
        };

    let mut devices = Vec::new();
    for device_path in property_paths(&properties, "Devices") {
        let iface: Result<String, dbus::Error> = Proxy::new(
            NM_DESTINATION,
            device_path,
            DBUS_TIMEOUT,
            connection.clone(),
        )
        .get(NM_DEVICE_INTERFACE, "Interface")
        .await;
        if let Ok(iface) = iface
            && !iface.is_empty()
        {
            devices.push(iface);
        }
    }
    PrimaryConnection {
        connected: true,
        id: property_string(&properties, "Id").unwrap_or_default(),
        uuid: property_string(&properties, "Uuid").unwrap_or_default(),
        kind: property_string(&properties, "Type").unwrap_or_default(),
        devices,
        connectivity: connectivity.to_string(),
    }
}

async fn read_access_point(
    connection: Arc<SyncConnection>,
    path: DbusPath<'static>,
    active_path: Option<&DbusPath<'static>>,
    iface: &str,
    profiles: &[WifiProfile],
) -> Option<AccessPoint> {
    let properties: PropMap = Proxy::new(NM_DESTINATION, path.clone(), DBUS_TIMEOUT, connection)
        .get_all(NM_AP_INTERFACE)
        .await
        .ok()?;
    let ssid = property_bytes(&properties, "Ssid")
        .map(|bytes| ssid_text(&bytes))
        .unwrap_or_default();
    if ssid.is_empty() {
        return None;
    }
    let security = security_from_flags(
        property_u64(&properties, "Flags").unwrap_or_default(),
        property_u64(&properties, "WpaFlags").unwrap_or_default(),
        property_u64(&properties, "RsnFlags").unwrap_or_default(),
    );
    let profile = best_profile(profiles, &ssid, iface, security.mode);

    Some(AccessPoint {
        ssid,
        strength: property_u64(&properties, "Strength")
            .unwrap_or_default()
            .min(100) as u8,
        security: security.label.to_string(),
        security_mode: security.mode.to_string(),
        active: active_path == Some(&path),
        saved: profile.is_some(),
        saved_uuid: profile.map(|value| value.uuid.clone()).unwrap_or_default(),
        autoconnect: profile.map(|value| value.autoconnect).unwrap_or(false),
        autoconnect_priority: profile
            .map(|value| value.autoconnect_priority)
            .unwrap_or_default(),
        last_seen: property_i64(&properties, "LastSeen").unwrap_or(-1) as i32,
        bssid: property_string(&properties, "HwAddress").unwrap_or_default(),
        frequency: property_u64(&properties, "Frequency").unwrap_or_default() as u32,
        enterprise: security.enterprise,
        supported: security.supported,
        advanced: security.advanced,
    })
}

fn merge_access_points(mut points: Vec<AccessPoint>) -> Vec<AccessPoint> {
    let mut merged: Vec<AccessPoint> = Vec::new();

    for point in points.drain(..) {
        if let Some(existing) = merged.iter_mut().find(|existing| {
            existing.ssid == point.ssid && existing.security_mode == point.security_mode
        }) {
            if point.active || point.strength > existing.strength {
                *existing = point;
            }
        } else {
            merged.push(point);
        }
    }

    merged.sort_by(|left, right| {
        right
            .active
            .cmp(&left.active)
            .then(right.strength.cmp(&left.strength))
            .then(left.ssid.cmp(&right.ssid))
    });
    merged
}

fn remove_stale_access_points(points: &mut Vec<AccessPoint>, last_scan_ms: i64) {
    if last_scan_ms < 0 {
        return;
    }
    let last_scan_seconds = last_scan_ms / 1000;
    points.retain(|point| {
        point.active
            || point.last_seen < 0
            || last_scan_seconds.saturating_sub(i64::from(point.last_seen))
                <= AP_STALE_AFTER_SECONDS
    });
}

async fn read_wifi_adapter(
    connection: Arc<SyncConnection>,
    path: DbusPath<'static>,
    device: &PropMap,
    profiles: &[WifiProfile],
) -> WifiAdapter {
    let iface = property_string(device, "Interface").unwrap_or_default();
    let wireless: PropMap = Proxy::new(NM_DESTINATION, path, DBUS_TIMEOUT, connection.clone())
        .get_all(NM_WIFI_INTERFACE)
        .await
        .unwrap_or_default();
    let last_scan_ms = property_i64(&wireless, "LastScan").unwrap_or(-1);
    let mode_value = property_u64(&wireless, "Mode").unwrap_or_default();
    let active_path = property_path(&wireless, "ActiveAccessPoint").filter(|path| &path[..] != "/");
    let mut access_points = Vec::new();

    for access_point_path in property_paths(&wireless, "AccessPoints") {
        if let Some(access_point) = read_access_point(
            connection.clone(),
            access_point_path,
            active_path.as_ref(),
            &iface,
            profiles,
        )
        .await
        {
            access_points.push(access_point);
        }
    }
    remove_stale_access_points(&mut access_points, last_scan_ms);
    let access_points = merge_access_points(access_points);
    let active = access_points.iter().find(|point| point.active);
    let (ip_address, gateway) = ip4_details(connection, property_path(device, "Ip4Config")).await;

    WifiAdapter {
        kind: "wifi",
        iface,
        ip_address,
        gateway,
        state: device_state_name(property_u64(device, "State").unwrap_or_default()).to_string(),
        active_ssid: active.map(|point| point.ssid.clone()).unwrap_or_default(),
        active_strength: active.map(|point| point.strength).unwrap_or_default(),
        bitrate: property_u64(&wireless, "Bitrate").unwrap_or_default() as u32,
        last_scan_ms,
        scan_busy: false,
        mode: wifi_mode_name(mode_value).to_string(),
        hotspot_active: mode_value == 3,
        hotspot_supported: property_u64(&wireless, "WirelessCapabilities")
            .is_some_and(|capabilities| capabilities & WIFI_CAP_AP != 0),
        access_points,
    }
}

async fn read_ethernet_adapter(
    connection: Arc<SyncConnection>,
    path: DbusPath<'static>,
    device: &PropMap,
) -> EthernetAdapter {
    let wired: PropMap = Proxy::new(NM_DESTINATION, path, DBUS_TIMEOUT, connection.clone())
        .get_all(NM_WIRED_INTERFACE)
        .await
        .unwrap_or_default();
    let (ip_address, gateway) = ip4_details(connection, property_path(device, "Ip4Config")).await;

    EthernetAdapter {
        kind: "ethernet",
        iface: property_string(device, "Interface").unwrap_or_default(),
        ip_address,
        gateway,
        state: device_state_name(property_u64(device, "State").unwrap_or_default()).to_string(),
        carrier: property_bool(&wired, "Carrier").unwrap_or(false),
        speed: property_u64(&wired, "Speed").unwrap_or_default() as u32,
    }
}

fn saved_networks(profiles: &[WifiProfile]) -> Vec<SavedNetwork> {
    profiles
        .iter()
        .map(|profile| {
            let security = profile_security(&profile.security_mode);
            SavedNetwork {
                ssid: profile.ssid.clone(),
                uuid: profile.uuid.clone(),
                id: profile.id.clone(),
                autoconnect: profile.autoconnect,
                autoconnect_priority: profile.autoconnect_priority,
                interface_name: profile.interface_name.clone(),
                security_mode: security.mode.to_string(),
                security: security.label.to_string(),
                hidden: profile.hidden,
                enterprise: security.enterprise,
                supported: security.supported,
                advanced: security.advanced,
            }
        })
        .collect()
}

async fn read_state(connection: Arc<SyncConnection>) -> Result<NetworkState, dbus::Error> {
    let root = Proxy::new(NM_DESTINATION, NM_PATH, DBUS_TIMEOUT, connection.clone());
    let root_properties: PropMap = root.get_all(NM_INTERFACE).await?;
    let connectivity =
        connectivity_name(property_u64(&root_properties, "Connectivity").unwrap_or_default())
            .to_string();
    let profiles = read_profiles(connection.clone()).await.unwrap_or_default();
    let (device_paths,): (Vec<DbusPath<'static>>,) =
        root.method_call(NM_INTERFACE, "GetDevices", ()).await?;
    let mut wifi = Vec::new();
    let mut ethernet = Vec::new();

    for path in device_paths {
        let device: PropMap = match Proxy::new(
            NM_DESTINATION,
            path.clone(),
            DBUS_TIMEOUT,
            connection.clone(),
        )
        .get_all(NM_DEVICE_INTERFACE)
        .await
        {
            Ok(properties) => properties,
            Err(_) => continue,
        };
        if property_bool(&device, "Managed") == Some(false) {
            continue;
        }

        match property_u64(&device, "DeviceType") {
            Some(1) => {
                ethernet.push(read_ethernet_adapter(connection.clone(), path, &device).await)
            }
            Some(2) => {
                wifi.push(read_wifi_adapter(connection.clone(), path, &device, &profiles).await)
            }
            _ => {}
        }
    }
    wifi.sort_by(|left, right| left.iface.cmp(&right.iface));
    ethernet.sort_by(|left, right| left.iface.cmp(&right.iface));
    let primary = read_primary(
        connection,
        property_path(&root_properties, "PrimaryConnection"),
        &connectivity,
    )
    .await;

    Ok(NetworkState {
        event: "network-state",
        service_available: true,
        nm_running: true,
        version: property_string(&root_properties, "Version").unwrap_or_default(),
        simulated: false,
        wifi_enabled: property_bool(&root_properties, "WirelessEnabled").unwrap_or(false),
        wifi_hardware_enabled: property_bool(&root_properties, "WirelessHardwareEnabled")
            .unwrap_or(false),
        connectivity,
        portal_url: portal_url(&root_properties),
        primary,
        wifi,
        ethernet,
        saved_networks: saved_networks(&profiles),
        advanced_editor_available: executable_exists("nmtui"),
    })
}

fn send_state(state: &NetworkState) -> bool {
    send_json(state, "network state")
}

fn send_if_changed(last_state: &mut Option<NetworkState>, state: NetworkState) -> bool {
    if last_state.as_ref() == Some(&state) {
        return false;
    }
    if !send_state(&state) {
        return false;
    }
    *last_state = Some(state);
    true
}

async fn monitor_connection(
    connection: Arc<SyncConnection>,
    last_state: &mut Option<NetworkState>,
) -> Result<(), String> {
    let state = read_state(connection.clone())
        .await
        .map_err(|error| error.to_string())?;
    send_if_changed(last_state, state);

    let rule = MatchRule::new()
        .with_type(MessageType::Signal)
        .with_sender(NM_DESTINATION)
        .with_namespaced_path(NM_PATH);
    let (_match_handle, events) = connection
        .add_match(rule)
        .await
        .map_err(|error| error.to_string())?
        .msg_stream();
    futures_util::pin_mut!(events);
    let mut health_check = interval(HEALTH_CHECK_INTERVAL);
    health_check.set_missed_tick_behavior(MissedTickBehavior::Delay);
    health_check.tick().await;

    loop {
        tokio::select! {
            event = events.next() => {
                if event.is_none() {
                    return Err("NetworkManager event stream ended".to_string());
                }
                sleep(EVENT_DEBOUNCE).await;
                while matches!(
                    tokio::time::timeout(Duration::from_millis(1), events.next()).await,
                    Ok(Some(_))
                ) {}
            }
            _ = health_check.tick() => {}
        }

        let state = read_state(connection.clone())
            .await
            .map_err(|error| error.to_string())?;
        send_if_changed(last_state, state);
    }
}

pub(crate) async fn run_monitor() {
    let mut last_state = None;
    let mut retry_delay = INITIAL_RETRY_DELAY;

    loop {
        match connect_system() {
            Ok(system) => {
                retry_delay = INITIAL_RETRY_DELAY;
                match monitor_connection(system.connection.clone(), &mut last_state).await {
                    Ok(()) => {}
                    Err(error) => {
                        if send_if_changed(&mut last_state, NetworkState::unavailable()) {
                            eprintln!("Network monitoring stopped: {error}");
                        }
                    }
                }
            }
            Err(error) => {
                if send_if_changed(&mut last_state, NetworkState::unavailable()) {
                    eprintln!("NetworkManager is unavailable: {error}");
                }
            }
        }

        sleep(retry_delay).await;
        retry_delay = retry_delay.saturating_mul(2).min(MAX_RETRY_DELAY);
    }
}

pub(crate) async fn send_real_state() {
    let state = match connect_system() {
        Ok(system) => read_state(system.connection.clone())
            .await
            .unwrap_or_else(|_| NetworkState::unavailable()),
        Err(_) => NetworkState::unavailable(),
    };
    send_state(&state);
}

fn executable_exists(program: &str) -> bool {
    env::var_os("PATH")
        .is_some_and(|paths| env::split_paths(&paths).any(|path| path.join(program).is_file()))
}

fn command_error(program: &str, output: &Output) -> String {
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let message = if !stderr.is_empty() { stderr } else { stdout };
    if message.is_empty() {
        format!("{program} exited with {}", output.status)
    } else {
        message.chars().take(400).collect()
    }
}

fn output_with_timeout(program: &str, arguments: &[String]) -> io::Result<Output> {
    let mut child = Command::new(program)
        .args(arguments)
        .env("LC_ALL", "C")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let deadline = Instant::now() + NMCLI_TIMEOUT;

    loop {
        if child.try_wait()?.is_some() {
            return child.wait_with_output();
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                format!("{program} timed out"),
            ));
        }
        thread::sleep(COMMAND_POLL_INTERVAL);
    }
}

async fn run_nmcli(arguments: Vec<String>) -> Result<Output, ActionError> {
    tokio::task::spawn_blocking(move || output_with_timeout("nmcli", &arguments))
        .await
        .map_err(|error| ActionError::new(error.to_string()))?
        .map_err(|error| ActionError::new(format!("nmcli: {error}")))
}

async fn successful_nmcli(arguments: Vec<String>) -> Result<String, ActionError> {
    let output = run_nmcli(arguments).await?;
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    } else {
        Err(ActionError::new(command_error("nmcli", &output)))
    }
}

fn validate_iface(value: Option<&str>) -> Result<String, ActionError> {
    let value = value.unwrap_or_default().trim();
    if value.is_empty()
        || value.len() > 64
        || !value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "._:-".contains(character))
    {
        return Err(ActionError::new("Invalid network interface"));
    }
    Ok(value.to_string())
}

fn validate_uuid(value: Option<&str>) -> Result<String, ActionError> {
    let value = value.unwrap_or_default().trim();
    if value.is_empty()
        || value.len() > 64
        || !value
            .chars()
            .all(|character| character.is_ascii_hexdigit() || character == '-')
    {
        return Err(ActionError::new("Invalid connection UUID"));
    }
    Ok(value.to_string())
}

fn validate_ssid(value: Option<&str>) -> Result<String, ActionError> {
    let value = value.unwrap_or_default();
    if value.is_empty() || value.len() > 32 || value.contains('\0') {
        return Err(ActionError::new("Wi-Fi name must contain 1 to 32 bytes"));
    }
    Ok(value.to_string())
}

fn validate_password(mode: &str, password: &str) -> Result<(), ActionError> {
    if mode == "open" || mode == "owe" {
        return Ok(());
    }
    if mode == "wpa-psk" {
        let valid_text = (8..=63).contains(&password.len());
        let valid_hex =
            password.len() == 64 && password.chars().all(|value| value.is_ascii_hexdigit());
        if !valid_text && !valid_hex {
            return Err(ActionError::password(
                "Wi-Fi password must be 8–63 characters, or 64 hexadecimal characters",
            ));
        }
    } else if mode == "sae" && password.is_empty() {
        return Err(ActionError::password("Wi-Fi password is required"));
    }
    Ok(())
}

fn authentication_failed(message: &str) -> bool {
    let message = message.to_ascii_lowercase();
    [
        "secrets were required",
        "no secrets",
        "authentication",
        "wrong password",
        "invalid password",
        "802-11-wireless-security.psk",
    ]
    .iter()
    .any(|needle| message.contains(needle))
}

fn classify_saved_activation_error(mode: &str, password: &str, error: ActionError) -> ActionError {
    if password.is_empty()
        && matches!(mode, "wpa-psk" | "sae")
        && authentication_failed(&error.message)
    {
        ActionError::password(error.message)
    } else {
        error
    }
}

fn runtime_directory() -> PathBuf {
    env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .filter(|path| path.is_dir())
        .unwrap_or_else(env::temp_dir)
}

fn hotspot_previous_path(iface: &str) -> PathBuf {
    runtime_directory().join(format!("redcore-hotspot-{iface}.previous"))
}

fn save_hotspot_session(iface: &str, hotspot_uuid: &str, previous_uuid: &str) -> io::Result<()> {
    let path = hotspot_previous_path(iface);
    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)?;
    writeln!(file, "{hotspot_uuid}")?;
    writeln!(file, "{previous_uuid}")
}

fn load_hotspot_session(iface: &str) -> (String, String) {
    let path = hotspot_previous_path(iface);
    let content = fs::read_to_string(path).unwrap_or_default();
    let mut lines = content.lines();
    let valid_uuid = |value: &str| {
        let value = value.trim();
        if validate_uuid(Some(value)).is_ok() {
            value.to_string()
        } else {
            String::new()
        }
    };
    (
        valid_uuid(lines.next().unwrap_or_default()),
        valid_uuid(lines.next().unwrap_or_default()),
    )
}

fn clear_hotspot_session(iface: &str) {
    let _ = fs::remove_file(hotspot_previous_path(iface));
}

struct SecretFile(PathBuf);

impl SecretFile {
    fn create(password: &str) -> Result<Self, ActionError> {
        let counter = SECRET_COUNTER.fetch_add(1, Ordering::Relaxed);
        let path = runtime_directory().join(format!(
            "redcore-wifi-{}-{counter}.secret",
            std::process::id()
        ));
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
            .map_err(|error| {
                ActionError::new(format!("Could not create password file: {error}"))
            })?;
        writeln!(file, "802-11-wireless-security.psk:{password}")
            .map_err(|error| ActionError::new(format!("Could not write password file: {error}")))?;
        Ok(Self(path))
    }
}

impl Drop for SecretFile {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

async fn activate(uuid: &str, iface: &str, password: &str) -> Result<(), ActionError> {
    let secret = if password.is_empty() {
        None
    } else {
        Some(SecretFile::create(password)?)
    };
    let mut arguments = vec![
        "--wait".to_string(),
        "22".to_string(),
        "connection".to_string(),
        "up".to_string(),
        "uuid".to_string(),
        uuid.to_string(),
        "ifname".to_string(),
        iface.to_string(),
    ];
    if let Some(secret) = &secret {
        arguments.extend([
            "passwd-file".to_string(),
            secret.0.to_string_lossy().into_owned(),
        ]);
    }
    successful_nmcli(arguments).await.map(|_| ())
}

async fn active_uuid(iface: &str) -> String {
    successful_nmcli(vec![
        "-g".to_string(),
        "GENERAL.CON-UUID".to_string(),
        "device".to_string(),
        "show".to_string(),
        iface.to_string(),
    ])
    .await
    .ok()
    .and_then(|value| value.lines().next().map(str::trim).map(str::to_string))
    .filter(|value| !value.is_empty() && value != "--")
    .unwrap_or_default()
}

fn scan_markers(state: &NetworkState) -> HashMap<String, i64> {
    state
        .wifi
        .iter()
        .map(|adapter| (adapter.iface.clone(), adapter.last_scan_ms))
        .collect()
}

fn scan_finished(
    before: &HashMap<String, i64>,
    after: &HashMap<String, i64>,
    iface: Option<&str>,
) -> bool {
    let changed = |name: &str, value: &i64| {
        *value >= 0 && before.get(name).is_none_or(|previous| value > previous)
    };
    match iface {
        Some(iface) => after.get(iface).is_some_and(|value| changed(iface, value)),
        None => after.iter().any(|(name, value)| changed(name, value)),
    }
}

async fn request_wifi_scan(iface: Option<&str>) -> Result<String, ActionError> {
    let system = connect_system().map_err(ActionError::new)?;
    let before = read_state(system.connection.clone())
        .await
        .map(|state| scan_markers(&state))
        .map_err(|error| ActionError::new(error.to_string()))?;
    let mut arguments = vec![
        "device".to_string(),
        "wifi".to_string(),
        "rescan".to_string(),
    ];
    if let Some(iface) = iface {
        arguments.extend(["ifname".to_string(), iface.to_string()]);
    }
    successful_nmcli(arguments).await?;

    let deadline = Instant::now() + Duration::from_secs(12);
    while Instant::now() < deadline {
        sleep(Duration::from_millis(250)).await;
        if let Ok(state) = read_state(system.connection.clone()).await
            && scan_finished(&before, &scan_markers(&state), iface)
        {
            return Ok("Wi-Fi scan completed".to_string());
        }
    }
    Ok("Wi-Fi scan requested; results may still be updating".to_string())
}

async fn create_profile(
    ssid: &str,
    mode: &str,
    hidden: bool,
    autoconnect: bool,
    priority: i32,
) -> Result<String, ActionError> {
    let name = format!(
        "redcore-{}-{}",
        std::process::id(),
        SECRET_COUNTER.fetch_add(1, Ordering::Relaxed)
    );
    let mut arguments = vec![
        "--wait".to_string(),
        "10".to_string(),
        "connection".to_string(),
        "add".to_string(),
        "type".to_string(),
        "wifi".to_string(),
        "con-name".to_string(),
        name.clone(),
        "ssid".to_string(),
        ssid.to_string(),
        "connection.autoconnect".to_string(),
        if autoconnect { "yes" } else { "no" }.to_string(),
        "connection.autoconnect-priority".to_string(),
        priority.clamp(-999, 999).to_string(),
    ];
    if hidden {
        arguments.extend(["802-11-wireless.hidden".to_string(), "yes".to_string()]);
    }
    if matches!(mode, "wpa-psk" | "sae" | "owe") {
        arguments.extend([
            "802-11-wireless-security.key-mgmt".to_string(),
            mode.to_string(),
        ]);
    }
    successful_nmcli(arguments).await?;
    let uuid = successful_nmcli(vec![
        "-g".to_string(),
        "connection.uuid".to_string(),
        "connection".to_string(),
        "show".to_string(),
        "id".to_string(),
        name.clone(),
    ])
    .await;
    match uuid {
        Ok(value) if !value.is_empty() => Ok(value.lines().next().unwrap_or_default().to_string()),
        Ok(_) | Err(_) => {
            let _ = successful_nmcli(vec![
                "connection".to_string(),
                "delete".to_string(),
                "id".to_string(),
                name,
            ])
            .await;
            Err(ActionError::new("Could not read the new Wi-Fi profile"))
        }
    }
}

async fn create_hotspot_profile(iface: &str, ssid: &str) -> Result<String, ActionError> {
    let name = format!(
        "{HOTSPOT_PROFILE_PREFIX} temporary {}-{}",
        std::process::id(),
        SECRET_COUNTER.fetch_add(1, Ordering::Relaxed)
    );
    successful_nmcli(vec![
        "--wait".to_string(),
        "10".to_string(),
        "connection".to_string(),
        "add".to_string(),
        "type".to_string(),
        "wifi".to_string(),
        "ifname".to_string(),
        iface.to_string(),
        "con-name".to_string(),
        name.clone(),
        "ssid".to_string(),
        ssid.to_string(),
        "802-11-wireless.mode".to_string(),
        "ap".to_string(),
        "802-11-wireless-security.key-mgmt".to_string(),
        "wpa-psk".to_string(),
        "ipv4.method".to_string(),
        "shared".to_string(),
        "ipv6.method".to_string(),
        "disabled".to_string(),
        "connection.autoconnect".to_string(),
        "no".to_string(),
    ])
    .await?;
    let uuid = successful_nmcli(vec![
        "-g".to_string(),
        "connection.uuid".to_string(),
        "connection".to_string(),
        "show".to_string(),
        "id".to_string(),
        name.clone(),
    ])
    .await;
    let uuid = match uuid {
        Ok(value) if !value.trim().is_empty() => {
            value.lines().next().unwrap_or_default().trim().to_string()
        }
        Ok(_) | Err(_) => {
            let _ = successful_nmcli(vec![
                "connection".to_string(),
                "delete".to_string(),
                "id".to_string(),
                name,
            ])
            .await;
            return Err(ActionError::new("Could not read the new hotspot profile"));
        }
    };
    if let Err(error) = successful_nmcli(vec![
        "connection".to_string(),
        "modify".to_string(),
        "uuid".to_string(),
        uuid.clone(),
        "connection.id".to_string(),
        format!("{HOTSPOT_PROFILE_PREFIX} · {ssid}"),
    ])
    .await
    {
        let _ = successful_nmcli(vec![
            "connection".to_string(),
            "delete".to_string(),
            "uuid".to_string(),
            uuid,
        ])
        .await;
        return Err(error);
    }
    Ok(uuid)
}

async fn hotspot_capable(iface: &str) -> Result<bool, ActionError> {
    let system = connect_system().map_err(ActionError::new)?;
    let state = read_state(system.connection.clone())
        .await
        .map_err(|error| ActionError::new(error.to_string()))?;
    Ok(state
        .wifi
        .iter()
        .find(|adapter| adapter.iface == iface)
        .is_some_and(|adapter| adapter.hotspot_supported))
}

async fn start_hotspot(command: &DaemonCommand) -> Result<String, ActionError> {
    let iface = validate_iface(command.device.as_deref())?;
    let ssid = validate_ssid(command.ssid.as_deref())?;
    let password = command.password.as_deref().unwrap_or_default();
    validate_password("wpa-psk", password)?;
    if !hotspot_capable(&iface).await? {
        return Err(ActionError::new(
            "This Wi-Fi adapter does not support hotspot mode",
        ));
    }

    let previous_uuid = active_uuid(&iface).await;
    let uuid = create_hotspot_profile(&iface, &ssid).await?;
    if let Err(error) = activate(&uuid, &iface, password).await {
        let _ = successful_nmcli(vec![
            "connection".to_string(),
            "delete".to_string(),
            "uuid".to_string(),
            uuid,
        ])
        .await;
        if !previous_uuid.is_empty() {
            let _ = activate(&previous_uuid, &iface, "").await;
        }
        return Err(error);
    }
    let _ = save_hotspot_session(&iface, &uuid, &previous_uuid);
    Ok(format!("Hotspot {ssid} started"))
}

async fn connection_mode(uuid: &str) -> Result<String, ActionError> {
    let values = successful_nmcli(vec![
        "-g".to_string(),
        "802-11-wireless.mode".to_string(),
        "connection".to_string(),
        "show".to_string(),
        "uuid".to_string(),
        uuid.to_string(),
    ])
    .await?;
    Ok(values.lines().next().unwrap_or_default().trim().to_string())
}

async fn stop_hotspot(command: &DaemonCommand) -> Result<String, ActionError> {
    let iface = validate_iface(command.device.as_deref())?;
    let uuid = active_uuid(&iface).await;
    if uuid.is_empty() {
        return Err(ActionError::new("No active hotspot was found"));
    }
    let mode = connection_mode(&uuid).await?;
    if mode != "ap" {
        return Err(ActionError::new(
            "The selected Wi-Fi adapter is not running a hotspot",
        ));
    }

    let (owned_uuid, previous_uuid) = load_hotspot_session(&iface);
    successful_nmcli(vec![
        "--wait".to_string(),
        "12".to_string(),
        "connection".to_string(),
        "down".to_string(),
        "uuid".to_string(),
        uuid.clone(),
    ])
    .await?;
    if owned_uuid == uuid {
        let _ = successful_nmcli(vec![
            "connection".to_string(),
            "delete".to_string(),
            "uuid".to_string(),
            uuid,
        ])
        .await;
    }

    clear_hotspot_session(&iface);
    if !previous_uuid.is_empty() && activate(&previous_uuid, &iface, "").await.is_err() {
        return Ok("Hotspot stopped; the previous Wi-Fi network could not reconnect".to_string());
    }
    Ok("Hotspot stopped".to_string())
}

async fn connect_network(command: &DaemonCommand) -> Result<String, ActionError> {
    let iface = validate_iface(command.device.as_deref())?;
    let ssid = validate_ssid(command.ssid.as_deref())?;
    let mode = normalize_security_mode(command.security_mode.as_deref().unwrap_or("open"));
    if matches!(mode.as_str(), "wpa-eap" | "wpa-eap-suite-b-192") {
        return Err(ActionError::advanced(
            "Enterprise Wi-Fi requires the advanced NetworkManager editor",
        ));
    }
    if mode == "wep" {
        return Err(ActionError::new(
            "WEP is insecure and is not supported by Red Core",
        ));
    }
    if !matches!(mode.as_str(), "open" | "owe" | "wpa-psk" | "sae") {
        return Err(ActionError::new("Unsupported Wi-Fi security mode"));
    }
    let password = command.password.as_deref().unwrap_or_default();

    if let Some(uuid) = command
        .saved_uuid
        .as_deref()
        .filter(|value| !value.is_empty())
    {
        let uuid = validate_uuid(Some(uuid))?;
        if !password.is_empty() {
            validate_password(&mode, password)?;
        }
        activate(&uuid, &iface, password)
            .await
            .map_err(|error| classify_saved_activation_error(&mode, password, error))?;
        return Ok(format!("Connected to {ssid}"));
    }

    validate_password(&mode, password)?;

    let autoconnect = command.autoconnect.unwrap_or(true);
    let priority = command
        .autoconnect_priority
        .unwrap_or_default()
        .clamp(-999, 999);
    let previous_uuid = active_uuid(&iface).await;
    let uuid = create_profile(
        &ssid,
        &mode,
        command.hidden.unwrap_or(false),
        autoconnect,
        priority,
    )
    .await?;
    if let Err(error) = activate(&uuid, &iface, password).await {
        let _ = successful_nmcli(vec![
            "connection".to_string(),
            "delete".to_string(),
            "uuid".to_string(),
            uuid,
        ])
        .await;
        if !previous_uuid.is_empty() {
            let _ = activate(&previous_uuid, &iface, "").await;
        }
        return Err(error);
    }
    let _ = successful_nmcli(vec![
        "connection".to_string(),
        "modify".to_string(),
        "uuid".to_string(),
        uuid,
        "connection.id".to_string(),
        ssid.clone(),
    ])
    .await;
    Ok(format!("Connected to {ssid}"))
}

fn open_advanced_editor() -> Result<String, ActionError> {
    let (terminal, prefix): (&str, &[&str]) = if executable_exists("foot") {
        ("foot", &["-e"])
    } else if executable_exists("kitty") {
        ("kitty", &[])
    } else if executable_exists("alacritty") {
        ("alacritty", &["-e"])
    } else {
        return Err(ActionError::new("No supported terminal was found"));
    };
    if !executable_exists("nmtui") {
        return Err(ActionError::new("nmtui is not installed"));
    }
    let mut command = Command::new(terminal);
    command.args(prefix).arg("nmtui");
    spawn_reaped(command, "nmtui")?;
    Ok("Advanced NetworkManager editor opened".to_string())
}

fn spawn_reaped(mut command: Command, description: &str) -> Result<(), ActionError> {
    let mut child = command
        .spawn()
        .map_err(|error| ActionError::new(format!("Could not start {description}: {error}")))?;
    let description = description.to_string();
    thread::Builder::new()
        .name(format!("redcore-{description}-wait"))
        .spawn(move || {
            let _ = child.wait();
        })
        .map_err(|error| {
            ActionError::new(format!("Could not monitor {description}: {error}"))
        })?;
    Ok(())
}

async fn open_portal_login() -> Result<String, ActionError> {
    let system = connect_system().map_err(ActionError::new)?;
    let properties: PropMap = Proxy::new(
        NM_DESTINATION,
        NM_PATH,
        DBUS_TIMEOUT,
        system.connection.clone(),
    )
    .get_all(NM_INTERFACE)
    .await
    .map_err(|error| ActionError::new(error.to_string()))?;
    let url = portal_url(&properties);

    let mut command = if executable_exists("xdg-open") {
        let mut command = Command::new("xdg-open");
        command.arg(&url);
        command
    } else if executable_exists("gio") {
        let mut command = Command::new("gio");
        command.args(["open", &url]);
        command
    } else {
        return Err(ActionError::new("No browser launcher was found"));
    };
    command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    spawn_reaped(command, "network login page")?;
    Ok("Network login page opened".to_string())
}

pub(crate) async fn apply_command(command: &DaemonCommand) -> Result<String, ActionError> {
    match command.action.as_str() {
        "get-state" | "snapshot" => {
            send_real_state().await;
            Ok(String::new())
        }
        "wifi" => {
            let enabled = command.enabled.unwrap_or(true);
            successful_nmcli(vec![
                "radio".to_string(),
                "wifi".to_string(),
                if enabled { "on" } else { "off" }.to_string(),
            ])
            .await?;
            Ok(if enabled {
                "Wi-Fi enabled"
            } else {
                "Wi-Fi disabled"
            }
            .to_string())
        }
        "scan" => {
            let iface = validate_iface(command.device.as_deref())?;
            request_wifi_scan(Some(&iface)).await
        }
        "scan-all" => request_wifi_scan(None).await,
        "disconnect" => {
            let iface = validate_iface(command.device.as_deref())?;
            successful_nmcli(vec![
                "--wait".to_string(),
                "12".to_string(),
                "device".to_string(),
                "disconnect".to_string(),
                iface,
            ])
            .await?;
            Ok("Disconnected".to_string())
        }
        "ethernet-connect" => {
            let iface = validate_iface(command.device.as_deref())?;
            successful_nmcli(vec![
                "--wait".to_string(),
                "20".to_string(),
                "device".to_string(),
                "connect".to_string(),
                iface,
            ])
            .await?;
            Ok("Ethernet connected".to_string())
        }
        "forget" => {
            let uuid = validate_uuid(command.uuid.as_deref())?;
            successful_nmcli(vec![
                "--wait".to_string(),
                "10".to_string(),
                "connection".to_string(),
                "delete".to_string(),
                "uuid".to_string(),
                uuid,
            ])
            .await?;
            Ok("Network forgotten".to_string())
        }
        "autoconnect" => {
            let uuid = validate_uuid(command.uuid.as_deref())?;
            let enabled = command.enabled.unwrap_or(true);
            let mut arguments = vec![
                "--wait".to_string(),
                "10".to_string(),
                "connection".to_string(),
                "modify".to_string(),
                "uuid".to_string(),
                uuid,
                "connection.autoconnect".to_string(),
                if enabled { "yes" } else { "no" }.to_string(),
            ];
            if let Some(priority) = command.autoconnect_priority {
                arguments.extend([
                    "connection.autoconnect-priority".to_string(),
                    priority.clamp(-999, 999).to_string(),
                ]);
            }
            successful_nmcli(arguments).await?;
            Ok(if enabled {
                "Auto-connect enabled"
            } else {
                "Auto-connect disabled"
            }
            .to_string())
        }
        "connect" => connect_network(command).await,
        "hotspot-start" => start_hotspot(command).await,
        "hotspot-stop" => stop_hotspot(command).await,
        "open-portal" => open_portal_login().await,
        "open-advanced" => open_advanced_editor(),
        _ => Err(ActionError::new("Unsupported network action")),
    }
}

pub(crate) struct NetworkSimulator {
    state: NetworkState,
}

impl NetworkSimulator {
    pub(crate) fn new() -> Self {
        Self {
            state: simulated_state(false),
        }
    }

    pub(crate) fn send_state(&self) {
        send_state(&self.state);
    }

    pub(crate) fn apply(&mut self, command: &DaemonCommand) -> Result<String, ActionError> {
        match command.action.as_str() {
            "get-state" | "snapshot" | "scan" | "scan-all" | "open-portal" => {}
            "wifi" => {
                let enabled = command.enabled.unwrap_or(true);

                if enabled {
                    let ethernet_primary =
                        self.state.primary.connected && self.state.primary.kind == "802-3-ethernet";
                    self.state = simulated_state(ethernet_primary);
                } else {
                    self.state.wifi_enabled = false;
                    for adapter in &mut self.state.wifi {
                        adapter.state = "unavailable".to_string();
                        adapter.active_ssid.clear();
                        adapter.active_strength = 0;
                        adapter.ip_address.clear();
                        adapter.gateway.clear();
                        adapter.bitrate = 0;
                        for access_point in &mut adapter.access_points {
                            access_point.active = false;
                        }
                    }

                    if self.state.primary.kind == "802-11-wireless" {
                        self.state.primary = PrimaryConnection::default();
                    }
                }
            }
            "set-ethernet-primary" => {
                let enabled = command.enabled.unwrap_or(true);
                self.state = simulated_state(enabled);
            }
            "ethernet-connect" => {
                self.state = simulated_state(true);
            }
            "connect" => {
                let ssid = validate_ssid(command.ssid.as_deref())?;
                let iface = validate_iface(command.device.as_deref())?;
                let adapter = self
                    .state
                    .wifi
                    .iter_mut()
                    .find(|adapter| adapter.iface == iface)
                    .ok_or_else(|| ActionError::new("Wi-Fi adapter not found"))?;
                for point in &mut adapter.access_points {
                    point.active = point.ssid == ssid;
                }
                adapter.active_ssid = ssid.clone();
                adapter.state = "activated".to_string();
                adapter.mode = "infrastructure".to_string();
                adapter.hotspot_active = false;
                self.state.primary = PrimaryConnection {
                    connected: true,
                    id: ssid,
                    uuid: "simulated-wifi".to_string(),
                    kind: "802-11-wireless".to_string(),
                    devices: vec![iface],
                    connectivity: "full".to_string(),
                };
            }
            "hotspot-start" => {
                let ssid = validate_ssid(command.ssid.as_deref())?;
                let password = command.password.as_deref().unwrap_or_default();
                validate_password("wpa-psk", password)?;
                let iface = validate_iface(command.device.as_deref())?;
                let adapter = self
                    .state
                    .wifi
                    .iter_mut()
                    .find(|adapter| adapter.iface == iface)
                    .ok_or_else(|| ActionError::new("Wi-Fi adapter not found"))?;
                if !adapter.hotspot_supported {
                    return Err(ActionError::new(
                        "This Wi-Fi adapter does not support hotspot mode",
                    ));
                }
                adapter.mode = "hotspot".to_string();
                adapter.hotspot_active = true;
                adapter.state = "activated".to_string();
                adapter.active_ssid = ssid.clone();
                adapter.ip_address = "10.42.0.1".to_string();
                for point in &mut adapter.access_points {
                    point.active = false;
                }
                self.state.primary = PrimaryConnection {
                    connected: true,
                    id: format!("{HOTSPOT_PROFILE_PREFIX} · {ssid}"),
                    uuid: "simulated-hotspot".to_string(),
                    kind: "802-11-wireless".to_string(),
                    devices: vec![iface],
                    connectivity: "full".to_string(),
                };
            }
            "hotspot-stop" => {
                let iface = validate_iface(command.device.as_deref())?;
                let adapter = self
                    .state
                    .wifi
                    .iter()
                    .find(|adapter| adapter.iface == iface)
                    .ok_or_else(|| ActionError::new("Wi-Fi adapter not found"))?;
                if !adapter.hotspot_active {
                    return Err(ActionError::new("No active hotspot was found"));
                }
                self.state = simulated_state(false);
            }
            "disconnect" => {
                self.state.primary = PrimaryConnection::default();
            }
            "forget" | "autoconnect" => {}
            _ => return Err(ActionError::new("Unsupported simulated network action")),
        }
        Ok(String::new())
    }
}

fn simulated_state(ethernet_primary: bool) -> NetworkState {
    let wifi = vec![
        WifiAdapter {
            kind: "wifi",
            iface: "wlan0".to_string(),
            ip_address: "192.168.1.40".to_string(),
            gateway: "192.168.1.1".to_string(),
            state: "activated".to_string(),
            active_ssid: "Red Core Home".to_string(),
            active_strength: 78,
            bitrate: 866_000,
            last_scan_ms: 1000,
            scan_busy: false,
            mode: "infrastructure".to_string(),
            hotspot_active: false,
            hotspot_supported: true,
            access_points: vec![
                AccessPoint {
                    ssid: "Red Core Home".to_string(),
                    strength: 78,
                    security: "WPA2/WPA3".to_string(),
                    security_mode: "wpa-psk".to_string(),
                    active: !ethernet_primary,
                    saved: true,
                    saved_uuid: "00000000-0000-0000-0000-000000000001".to_string(),
                    autoconnect: true,
                    autoconnect_priority: 10,
                    last_seen: 1,
                    bssid: "02:00:00:00:00:01".to_string(),
                    frequency: 5180,
                    enterprise: false,
                    supported: true,
                    advanced: false,
                },
                AccessPoint {
                    ssid: "Office Enterprise".to_string(),
                    strength: 61,
                    security: "WPA2/WPA3 Enterprise".to_string(),
                    security_mode: "wpa-eap".to_string(),
                    active: false,
                    saved: false,
                    saved_uuid: String::new(),
                    autoconnect: false,
                    autoconnect_priority: 0,
                    last_seen: 1,
                    bssid: "02:00:00:00:00:02".to_string(),
                    frequency: 2412,
                    enterprise: true,
                    supported: false,
                    advanced: true,
                },
            ],
        },
        WifiAdapter {
            kind: "wifi",
            iface: "wlan1".to_string(),
            state: "disconnected".to_string(),
            ..WifiAdapter::default()
        },
    ];
    let ethernet = vec![EthernetAdapter {
        kind: "ethernet",
        iface: "enp4s0".to_string(),
        ip_address: "192.168.1.20".to_string(),
        gateway: "192.168.1.1".to_string(),
        state: if ethernet_primary {
            "activated"
        } else {
            "disconnected"
        }
        .to_string(),
        carrier: ethernet_primary,
        speed: 1000,
    }];
    let primary = if ethernet_primary {
        PrimaryConnection {
            connected: true,
            id: "Wired connection 1".to_string(),
            uuid: "00000000-0000-0000-0000-000000000002".to_string(),
            kind: "802-3-ethernet".to_string(),
            devices: vec!["enp4s0".to_string()],
            connectivity: "full".to_string(),
        }
    } else {
        PrimaryConnection {
            connected: true,
            id: "Red Core Home".to_string(),
            uuid: "00000000-0000-0000-0000-000000000001".to_string(),
            kind: "802-11-wireless".to_string(),
            devices: vec!["wlan0".to_string()],
            connectivity: "full".to_string(),
        }
    };
    let profiles = vec![WifiProfile {
        ssid: "Red Core Home".to_string(),
        uuid: "00000000-0000-0000-0000-000000000001".to_string(),
        id: "Red Core Home".to_string(),
        autoconnect: true,
        autoconnect_priority: 10,
        interface_name: String::new(),
        security_mode: "wpa-psk".to_string(),
        hidden: false,
    }];

    NetworkState {
        event: "network-state",
        service_available: true,
        nm_running: true,
        version: "simulation".to_string(),
        simulated: true,
        wifi_enabled: true,
        wifi_hardware_enabled: true,
        connectivity: "full".to_string(),
        portal_url: PORTAL_FALLBACK_URL.to_string(),
        primary,
        wifi,
        ethernet,
        saved_networks: saved_networks(&profiles),
        advanced_editor_available: true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_personal_enterprise_owe_and_wep_security() {
        assert_eq!(security_from_flags(0, 0, AP_KEY_MGMT_PSK).mode, "wpa-psk");
        assert_eq!(
            security_from_flags(0, 0, AP_KEY_MGMT_PSK | AP_KEY_MGMT_SAE).mode,
            "wpa-psk"
        );
        assert_eq!(security_from_flags(0, 0, AP_KEY_MGMT_SAE).mode, "sae");
        assert_eq!(security_from_flags(0, 0, AP_KEY_MGMT_OWE).mode, "owe");
        assert_eq!(
            security_from_flags(0, 0, AP_KEY_MGMT_802_1X).mode,
            "wpa-eap"
        );
        assert_eq!(security_from_flags(AP_PRIVACY, 0, 0).mode, "wep");
        assert_eq!(security_from_flags(0, 0, 0).mode, "open");
    }

    #[test]
    fn exact_adapter_profile_wins_over_portable_profile() {
        let profiles = vec![
            WifiProfile {
                ssid: "Home".to_string(),
                uuid: "portable".to_string(),
                id: "Home".to_string(),
                autoconnect: true,
                autoconnect_priority: 99,
                interface_name: String::new(),
                security_mode: "wpa-psk".to_string(),
                hidden: false,
            },
            WifiProfile {
                ssid: "Home".to_string(),
                uuid: "bound".to_string(),
                id: "Home".to_string(),
                autoconnect: true,
                autoconnect_priority: 0,
                interface_name: "wlan1".to_string(),
                security_mode: "wpa-psk".to_string(),
                hidden: false,
            },
        ];

        assert_eq!(
            best_profile(&profiles, "Home", "wlan1", "wpa-psk")
                .map(|profile| profile.uuid.as_str()),
            Some("bound")
        );
    }

    #[test]
    fn access_points_are_grouped_by_ssid_and_security() {
        let point = |strength, mode: &str| AccessPoint {
            ssid: "Same".to_string(),
            strength,
            security_mode: mode.to_string(),
            ..AccessPoint::default()
        };
        let merged = merge_access_points(vec![
            point(20, "wpa-psk"),
            point(80, "wpa-psk"),
            point(70, "open"),
        ]);
        assert_eq!(merged.len(), 2);
        assert!(merged.iter().any(|point| point.strength == 80));
    }

    #[test]
    fn ethernet_primary_replaces_wifi_and_wifi_returns() {
        let ethernet = simulated_state(true);
        let wifi = simulated_state(false);
        assert_eq!(ethernet.primary.kind, "802-3-ethernet");
        assert_eq!(ethernet.primary.devices, vec!["enp4s0"]);
        assert_eq!(wifi.primary.kind, "802-11-wireless");
        assert_eq!(wifi.primary.devices, vec!["wlan0"]);
    }

    #[test]
    fn simulation_covers_multiple_wifi_adapters_and_saved_profiles() {
        let state = simulated_state(false);
        assert_eq!(state.wifi.len(), 2);
        assert_eq!(state.saved_networks.len(), 1);
        assert!(state.wifi_hardware_enabled);
    }

    #[test]
    fn passwords_are_validated_without_logging_them() {
        assert!(validate_password("wpa-psk", "short").is_err());
        assert!(validate_password("wpa-psk", "validpass").is_ok());
        assert!(validate_password("wpa-psk", &"a".repeat(64)).is_ok());
        assert!(validate_password("owe", "").is_ok());
    }

    #[test]
    fn password_prompt_is_only_used_for_authentication_failures() {
        let auth = classify_saved_activation_error(
            "wpa-psk",
            "",
            ActionError::new("Secrets were required, but not provided"),
        );
        let missing = classify_saved_activation_error(
            "wpa-psk",
            "",
            ActionError::new("The Wi-Fi network could not be found"),
        );
        assert!(auth.password_required);
        assert!(!missing.password_required);
    }

    #[test]
    fn stale_access_points_are_removed_but_active_point_is_kept() {
        let mut points = vec![
            AccessPoint {
                ssid: "Fresh".to_string(),
                last_seen: 995,
                ..AccessPoint::default()
            },
            AccessPoint {
                ssid: "Old".to_string(),
                last_seen: 700,
                ..AccessPoint::default()
            },
            AccessPoint {
                ssid: "Active".to_string(),
                last_seen: 700,
                active: true,
                ..AccessPoint::default()
            },
        ];
        remove_stale_access_points(&mut points, 1_000_000);
        assert_eq!(points.len(), 2);
        assert!(points.iter().any(|point| point.ssid == "Fresh"));
        assert!(points.iter().any(|point| point.ssid == "Active"));
    }

    #[test]
    fn scan_completion_is_tracked_per_adapter() {
        let before = HashMap::from([("wlan0".to_string(), 1000), ("wlan1".to_string(), 2000)]);
        let after = HashMap::from([("wlan0".to_string(), 1000), ("wlan1".to_string(), 2500)]);
        assert!(!scan_finished(&before, &after, Some("wlan0")));
        assert!(scan_finished(&before, &after, Some("wlan1")));
        assert!(scan_finished(&before, &after, None));
    }

    #[test]
    fn simulation_starts_and_stops_hotspot() {
        let mut simulator = NetworkSimulator::new();
        let start: DaemonCommand = serde_json::from_value(serde_json::json!({
            "module": "network",
            "action": "hotspot-start",
            "device": "wlan0",
            "ssid": "Red Core Share",
            "password": "safe-passphrase"
        }))
        .unwrap();
        let stop: DaemonCommand = serde_json::from_value(serde_json::json!({
            "module": "network",
            "action": "hotspot-stop",
            "device": "wlan0"
        }))
        .unwrap();

        simulator.apply(&start).unwrap();
        assert!(simulator.state.wifi[0].hotspot_active);
        assert_eq!(simulator.state.wifi[0].active_ssid, "Red Core Share");
        simulator.apply(&stop).unwrap();
        assert!(!simulator.state.wifi[0].hotspot_active);
        assert_eq!(simulator.state.wifi[0].active_ssid, "Red Core Home");
    }

    #[test]
    fn autoconnect_priority_is_clamped() {
        assert_eq!(1200_i32.clamp(-999, 999), 999);
        assert_eq!((-1200_i32).clamp(-999, 999), -999);
    }

    #[test]
    fn simulation_turns_wifi_off_and_restores_autoconnection() {
        let mut simulator = NetworkSimulator::new();
        let off: DaemonCommand = serde_json::from_value(serde_json::json!({
            "module": "network",
            "action": "wifi",
            "enabled": false
        }))
        .unwrap();
        let on: DaemonCommand = serde_json::from_value(serde_json::json!({
            "module": "network",
            "action": "wifi",
            "enabled": true
        }))
        .unwrap();

        simulator.apply(&off).unwrap();
        assert!(!simulator.state.wifi_enabled);
        assert!(!simulator.state.primary.connected);
        assert!(
            simulator
                .state
                .wifi
                .iter()
                .all(|adapter| adapter.active_ssid.is_empty())
        );

        simulator.apply(&on).unwrap();
        assert!(simulator.state.wifi_enabled);
        assert_eq!(simulator.state.primary.kind, "802-11-wireless");
        assert_eq!(simulator.state.wifi[0].active_ssid, "Red Core Home");
    }

    #[test]
    fn unavailable_state_keeps_network_contract() {
        let state = serde_json::to_value(NetworkState::unavailable()).unwrap();
        assert_eq!(state["event"], "network-state");
        assert_eq!(state["serviceAvailable"], false);
        assert!(state["wifi"].as_array().unwrap().is_empty());
        assert!(state["ethernet"].as_array().unwrap().is_empty());
    }
}
