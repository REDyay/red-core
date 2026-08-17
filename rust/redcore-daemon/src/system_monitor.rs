use serde::Serialize;
use serde_json::Value;
use std::collections::HashSet;
use std::fs;
use std::io::{self, BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;
use std::time::{Duration, Instant};
use tokio::time::{MissedTickBehavior, interval, sleep};

const SAMPLE_INTERVAL: Duration = Duration::from_secs(1);
const COMMAND_TIMEOUT: Duration = Duration::from_secs(2);
const COMMAND_POLL_INTERVAL: Duration = Duration::from_millis(20);
const HARDWARE_EVENT_DEBOUNCE: Duration = Duration::from_millis(350);
const UDEV_RETRY_INTERVAL: Duration = Duration::from_secs(60);

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NetworkSample {
    interface: String,
    #[serde(rename = "type")]
    kind: String,
    download: u64,
    upload: u64,
}

impl NetworkSample {
    fn unavailable() -> Self {
        Self {
            interface: String::new(),
            kind: "none".to_string(),
            download: 0,
            upload: 0,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SystemMetrics {
    cpu: u8,
    cpu_temp: Option<i32>,
    ram: u8,
    gpu_name: String,
    gpu_vendor: String,
    gpu_usage: Option<u8>,
    network: NetworkSample,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SystemMonitorEvent<'a> {
    event: &'static str,
    service_available: bool,
    #[serde(flatten)]
    metrics: &'a SystemMetrics,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct CpuTicks {
    total: u64,
    idle: u64,
}

fn read_text(path: impl AsRef<Path>) -> Option<String> {
    fs::read_to_string(path)
        .ok()
        .map(|value| value.trim().to_string())
}

fn read_u64(path: impl AsRef<Path>) -> Option<u64> {
    read_text(path)?.parse().ok()
}

fn read_i64(path: impl AsRef<Path>) -> Option<i64> {
    read_text(path)?.parse().ok()
}

fn parse_cpu_stat(value: &str) -> Option<CpuTicks> {
    let first = value.lines().next()?;
    let mut fields = first.split_whitespace();

    if fields.next()? != "cpu" {
        return None;
    }

    let mut values: Vec<u64> = fields
        .take(8)
        .map(str::parse)
        .collect::<Result<_, _>>()
        .ok()?;
    values.resize(8, 0);

    Some(CpuTicks {
        total: values.iter().sum(),
        idle: values[3].saturating_add(values[4]),
    })
}

fn read_cpu_stat() -> Option<CpuTicks> {
    parse_cpu_stat(&fs::read_to_string("/proc/stat").ok()?)
}

fn cpu_usage(previous: Option<CpuTicks>, current: Option<CpuTicks>) -> u8 {
    let (Some(previous), Some(current)) = (previous, current) else {
        return 0;
    };
    let total = current.total.saturating_sub(previous.total);
    let idle = current.idle.saturating_sub(previous.idle);

    if total == 0 {
        return 0;
    }

    let busy = total.saturating_sub(idle) as f64 * 100.0 / total as f64;
    busy.round().clamp(0.0, 100.0) as u8
}

fn parse_memory_usage(value: &str) -> u8 {
    let mut total = None;
    let mut available = None;

    for line in value.lines() {
        let mut fields = line.split_whitespace();

        match fields.next() {
            Some("MemTotal:") => total = fields.next().and_then(|item| item.parse::<u64>().ok()),
            Some("MemAvailable:") => {
                available = fields.next().and_then(|item| item.parse::<u64>().ok())
            }
            _ => {}
        }

        if total.is_some() && available.is_some() {
            break;
        }
    }

    let (Some(total), Some(available)) = (total, available) else {
        return 0;
    };

    if total == 0 {
        return 0;
    }

    let used = total.saturating_sub(available) as f64 * 100.0 / total as f64;
    used.round().clamp(0.0, 100.0) as u8
}

fn memory_usage() -> u8 {
    fs::read_to_string("/proc/meminfo")
        .map(|value| parse_memory_usage(&value))
        .unwrap_or(0)
}

fn directory_entries(path: &Path) -> Vec<PathBuf> {
    let mut entries = fs::read_dir(path)
        .ok()
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .collect::<Vec<_>>();
    entries.sort();
    entries
}

fn cpu_sensor_priority(driver: &str, label: &str) -> u8 {
    if label.contains("tdie")
        || label.contains("package id")
        || label.contains("cpu package")
        || label == "package"
    {
        0
    } else if label == "cpu" || matches!(driver, "cpu_thermal" | "x86_pkg_temp" | "soc_thermal") {
        1
    } else if label.contains("tctl") {
        5
    } else if label.contains("core") {
        10
    } else {
        50
    }
}

fn discover_cpu_temp_sensors_at(hwmon_root: &Path, thermal_root: &Path) -> Vec<PathBuf> {
    const CPU_DRIVERS: &[&str] = &[
        "coretemp",
        "k10temp",
        "zenpower",
        "cpu_thermal",
        "x86_pkg_temp",
        "soc_thermal",
    ];
    let mut candidates = Vec::new();

    for hwmon in directory_entries(hwmon_root) {
        let driver = read_text(hwmon.join("name"))
            .unwrap_or_default()
            .to_lowercase();

        if !CPU_DRIVERS.contains(&driver.as_str()) {
            continue;
        }

        let mut labelled = directory_entries(&hwmon)
            .into_iter()
            .filter_map(|path| {
                let name = path.file_name()?.to_str()?;

                if !name.starts_with("temp") || !name.ends_with("_input") {
                    return None;
                }

                let stem = name.strip_suffix("_input")?;
                let label = read_text(hwmon.join(format!("{stem}_label")))
                    .unwrap_or_default()
                    .to_lowercase();
                Some((cpu_sensor_priority(&driver, &label), path))
            })
            .collect::<Vec<_>>();
        labelled.sort_by_key(|item| item.0);

        if let Some(best) = labelled.first().map(|item| item.0) {
            candidates.extend(
                labelled
                    .into_iter()
                    .filter(|item| item.0 == best)
                    .map(|item| item.1),
            );
        }
    }

    if candidates.is_empty() {
        const ACCEPTED_ZONES: &[&str] = &[
            "x86_pkg_temp",
            "cpu-thermal",
            "cpu_thermal",
            "soc_thermal",
            "soc-thermal",
        ];

        for zone in directory_entries(thermal_root) {
            let kind = read_text(zone.join("type"))
                .unwrap_or_default()
                .to_lowercase();
            let temperature = zone.join("temp");

            if ACCEPTED_ZONES.contains(&kind.as_str()) && temperature.is_file() {
                candidates.push(temperature);
            }
        }
    }

    let mut seen = HashSet::new();
    candidates.retain(|path| seen.insert(path.clone()));
    candidates
}

fn discover_cpu_temp_sensors() -> Vec<PathBuf> {
    discover_cpu_temp_sensors_at(
        Path::new("/sys/class/hwmon"),
        Path::new("/sys/class/thermal"),
    )
}

fn normalized_temperature(value: i64) -> Option<f64> {
    let value = if value.unsigned_abs() > 1000 {
        value as f64 / 1000.0
    } else {
        value as f64
    };

    (-20.0..=150.0).contains(&value).then_some(value)
}

fn cpu_temperature(sensors: &[PathBuf]) -> Option<i32> {
    sensors
        .iter()
        .filter_map(read_i64)
        .filter_map(normalized_temperature)
        .max_by(f64::total_cmp)
        .map(|value| value.round() as i32)
}

fn default_ipv4_interface_from(value: &str) -> Option<String> {
    value
        .lines()
        .skip(1)
        .filter_map(|line| {
            let fields = line.split_whitespace().collect::<Vec<_>>();

            if fields.len() < 8 || fields[1] != "00000000" {
                return None;
            }

            let flags = u32::from_str_radix(fields[3], 16).ok()?;

            if flags & 0x1 == 0 {
                return None;
            }

            let metric = fields[6].parse::<u64>().ok()?;
            Some((metric, fields[0].to_string()))
        })
        .min_by_key(|item| item.0)
        .map(|item| item.1)
}

fn default_ipv4_interface() -> Option<String> {
    default_ipv4_interface_from(&fs::read_to_string("/proc/net/route").ok()?)
}

fn fallback_interface_at(root: &Path) -> Option<String> {
    let mut candidates = directory_entries(root)
        .into_iter()
        .filter_map(|path| {
            let interface = path.file_name()?.to_str()?.to_string();

            if interface == "lo" {
                return None;
            }

            let state = read_text(path.join("operstate")).unwrap_or_default();
            let carrier = read_u64(path.join("carrier")).unwrap_or(0);

            if state != "up" && carrier != 1 {
                return None;
            }

            let rank = if path.join("wireless").exists() {
                0
            } else if path.join("device").exists() {
                1
            } else {
                2
            };
            Some((rank, interface))
        })
        .collect::<Vec<_>>();
    candidates.sort();
    candidates.first().map(|item| item.1.clone())
}

fn active_interface() -> Option<String> {
    default_ipv4_interface().or_else(|| fallback_interface_at(Path::new("/sys/class/net")))
}

fn network_kind(interface: &str) -> String {
    if interface.is_empty() {
        "none".to_string()
    } else if Path::new("/sys/class/net")
        .join(interface)
        .join("wireless")
        .exists()
    {
        "wifi".to_string()
    } else {
        "ethernet".to_string()
    }
}

#[derive(Default)]
struct NetworkMonitor {
    interface: Option<String>,
    received: Option<u64>,
    transmitted: Option<u64>,
    sampled_at: Option<Instant>,
}

impl NetworkMonitor {
    fn sample(&mut self) -> NetworkSample {
        let Some(interface) = active_interface() else {
            *self = Self::default();
            return NetworkSample::unavailable();
        };
        let statistics = Path::new("/sys/class/net")
            .join(&interface)
            .join("statistics");
        let received = read_u64(statistics.join("rx_bytes"));
        let transmitted = read_u64(statistics.join("tx_bytes"));
        let sampled_at = Instant::now();
        let mut download = 0;
        let mut upload = 0;

        if self.interface.as_deref() == Some(interface.as_str()) {
            if let (Some(old), Some(new), Some(previous)) =
                (self.received, received, self.sampled_at)
            {
                let seconds = sampled_at.duration_since(previous).as_secs_f64();

                if seconds > 0.0 {
                    download = (new.saturating_sub(old) as f64 / seconds) as u64;
                }
            }

            if let (Some(old), Some(new), Some(previous)) =
                (self.transmitted, transmitted, self.sampled_at)
            {
                let seconds = sampled_at.duration_since(previous).as_secs_f64();

                if seconds > 0.0 {
                    upload = (new.saturating_sub(old) as f64 / seconds) as u64;
                }
            }
        }

        self.interface = Some(interface.clone());
        self.received = received;
        self.transmitted = transmitted;
        self.sampled_at = Some(sampled_at);

        NetworkSample {
            kind: network_kind(&interface),
            interface,
            download,
            upload,
        }
    }
}

#[derive(Clone, Debug)]
struct GpuDevice {
    vendor: String,
    device: PathBuf,
}

fn discover_drm_gpus_at(root: &Path) -> Vec<GpuDevice> {
    directory_entries(root)
        .into_iter()
        .filter_map(|card| {
            let card_name = card.file_name()?.to_str()?;
            let suffix = card_name.strip_prefix("card")?;

            if suffix.is_empty() || !suffix.chars().all(|character| character.is_ascii_digit()) {
                return None;
            }

            let device = card.join("device");
            let vendor_id = read_text(device.join("vendor"))?.to_lowercase();
            let vendor = match vendor_id.as_str() {
                "0x8086" => "intel",
                "0x1002" => "amd",
                "0x10de" => "nvidia",
                _ => return None,
            };

            Some(GpuDevice {
                vendor: vendor.to_string(),
                device,
            })
        })
        .collect()
}

fn discover_drm_gpus() -> Vec<GpuDevice> {
    discover_drm_gpus_at(Path::new("/sys/class/drm"))
}

fn output_with_timeout(program: &str, arguments: &[&str], timeout: Duration) -> io::Result<Output> {
    let mut child = Command::new(program)
        .args(arguments)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
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
                format!("{program} timed out"),
            ));
        }

        thread::sleep(COMMAND_POLL_INTERVAL);
    }
}

fn gpu_friendly_name(devices: &[GpuDevice]) -> String {
    if let Ok(output) = output_with_timeout("lspci", &[], COMMAND_TIMEOUT) {
        let names = String::from_utf8_lossy(&output.stdout)
            .lines()
            .filter(|line| {
                line.contains("VGA compatible controller")
                    || line.contains("3D controller")
                    || line.contains("Display controller")
            })
            .filter_map(|line| line.split_once(": ").map(|item| item.1.to_string()))
            .collect::<Vec<_>>();

        if !names.is_empty() {
            return names.join(" | ");
        }
    }

    let mut vendors = Vec::new();

    for device in devices {
        let mut characters = device.vendor.chars();
        let name = characters
            .next()
            .map(|first| first.to_uppercase().collect::<String>() + characters.as_str())
            .unwrap_or_default();

        if !vendors.contains(&name) {
            vendors.push(name);
        }
    }

    if vendors.is_empty() {
        "Unknown".to_string()
    } else {
        format!("{} GPU", vendors.join(" + "))
    }
}

fn store_latest(latest: &Arc<Mutex<Option<f64>>>, value: f64) {
    if value.is_finite() {
        *latest
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(value.clamp(0.0, 100.0));
    }
}

fn maximum_busy(value: &Value) -> Option<f64> {
    match value {
        Value::Object(values) => {
            let own = values.get("busy").and_then(Value::as_f64);
            values
                .values()
                .filter_map(maximum_busy)
                .chain(own)
                .max_by(f64::total_cmp)
        }
        Value::Array(values) => values
            .iter()
            .filter_map(maximum_busy)
            .max_by(f64::total_cmp),
        _ => None,
    }
}

fn read_intel_json_objects(mut reader: impl Read, latest: Arc<Mutex<Option<f64>>>) {
    let mut buffer = Vec::new();
    let mut depth = 0_u32;
    let mut in_string = false;
    let mut escaped = false;
    let mut byte = [0_u8; 1];

    while reader.read(&mut byte).ok() == Some(1) {
        let character = byte[0];

        if depth == 0 {
            if character == b'{' {
                buffer.clear();
                buffer.push(character);
                depth = 1;
                in_string = false;
                escaped = false;
            }
            continue;
        }

        buffer.push(character);

        if in_string {
            if escaped {
                escaped = false;
            } else if character == b'\\' {
                escaped = true;
            } else if character == b'"' {
                in_string = false;
            }
            continue;
        }

        match character {
            b'"' => in_string = true,
            b'{' => depth += 1,
            b'}' => {
                depth = depth.saturating_sub(1);

                if depth == 0 {
                    if let Ok(value) = serde_json::from_slice::<Value>(&buffer) {
                        let source = value.get("engines").unwrap_or(&value);

                        if let Some(busy) = maximum_busy(source) {
                            store_latest(&latest, busy);
                        }
                    }
                    buffer.clear();
                }
            }
            _ => {}
        }
    }
}

struct ProcessMetric {
    child: Child,
    latest: Arc<Mutex<Option<f64>>>,
}

impl ProcessMetric {
    fn intel() -> Option<Self> {
        let mut child = Command::new("intel_gpu_top")
            .args(["-J", "-s", "1000"])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .ok()?;
        let stdout = child.stdout.take()?;
        let latest = Arc::new(Mutex::new(None));
        let reader_latest = Arc::clone(&latest);
        thread::spawn(move || read_intel_json_objects(stdout, reader_latest));
        Some(Self { child, latest })
    }

    fn nvidia(index: u32) -> Option<Self> {
        let mut child = Command::new("nvidia-smi")
            .args([
                "-i",
                &index.to_string(),
                "--query-gpu=utilization.gpu",
                "--format=csv,noheader,nounits",
                "-l",
                "1",
            ])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .ok()?;
        let stdout = child.stdout.take()?;
        let latest = Arc::new(Mutex::new(None));
        let reader_latest = Arc::clone(&latest);
        thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if let Ok(value) = line.trim().parse::<f64>() {
                    store_latest(&reader_latest, value);
                }
            }
        });
        Some(Self { child, latest })
    }

    fn value(&mut self) -> Option<f64> {
        if self.child.try_wait().ok().flatten().is_some() {
            return None;
        }

        *self
            .latest
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

impl Drop for ProcessMetric {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

enum GpuMonitor {
    Amd(PathBuf),
    Intel(ProcessMetric),
    Nvidia(ProcessMetric),
}

impl GpuMonitor {
    fn vendor(&self) -> &'static str {
        match self {
            Self::Amd(_) => "amd",
            Self::Intel(_) => "intel",
            Self::Nvidia(_) => "nvidia",
        }
    }

    fn value(&mut self) -> Option<f64> {
        match self {
            Self::Amd(path) => read_i64(path).map(|value| (value as f64).clamp(0.0, 100.0)),
            Self::Intel(monitor) | Self::Nvidia(monitor) => monitor.value(),
        }
    }
}

fn nvidia_indices() -> Vec<u32> {
    output_with_timeout(
        "nvidia-smi",
        &["--query-gpu=index", "--format=csv,noheader,nounits"],
        COMMAND_TIMEOUT,
    )
    .ok()
    .map(|output| {
        String::from_utf8_lossy(&output.stdout)
            .lines()
            .filter_map(|line| line.trim().parse().ok())
            .collect()
    })
    .unwrap_or_default()
}

fn select_busiest(values: impl IntoIterator<Item = (String, Option<f64>)>) -> Option<(String, u8)> {
    values
        .into_iter()
        .filter_map(|(vendor, usage)| usage.map(|usage| (vendor, usage)))
        .max_by(|left, right| left.1.total_cmp(&right.1))
        .map(|(vendor, usage)| (vendor, usage.round().clamp(0.0, 100.0) as u8))
}

struct GpuManager {
    devices: Vec<GpuDevice>,
    name: String,
    monitors: Vec<GpuMonitor>,
}

impl GpuManager {
    fn new() -> Self {
        let mut manager = Self {
            devices: Vec::new(),
            name: "Unknown".to_string(),
            monitors: Vec::new(),
        };
        manager.rebuild();
        manager
    }

    fn rebuild(&mut self) {
        self.monitors.clear();
        self.devices = discover_drm_gpus();
        self.name = gpu_friendly_name(&self.devices);

        for device in &self.devices {
            if device.vendor == "amd" {
                self.monitors
                    .push(GpuMonitor::Amd(device.device.join("gpu_busy_percent")));
            }
        }

        if self.devices.iter().any(|device| device.vendor == "intel")
            && let Some(monitor) = ProcessMetric::intel()
        {
            self.monitors.push(GpuMonitor::Intel(monitor));
        }

        if self.devices.iter().any(|device| device.vendor == "nvidia") {
            for index in nvidia_indices() {
                if let Some(monitor) = ProcessMetric::nvidia(index) {
                    self.monitors.push(GpuMonitor::Nvidia(monitor));
                }
            }
        }
    }

    fn sample(&mut self) -> (String, Option<u8>) {
        let values = self
            .monitors
            .iter_mut()
            .map(|monitor| (monitor.vendor().to_string(), monitor.value()))
            .collect::<Vec<_>>();

        if let Some((vendor, usage)) = select_busiest(values) {
            (vendor, Some(usage))
        } else {
            (
                self.devices
                    .first()
                    .map(|device| device.vendor.clone())
                    .unwrap_or_else(|| "unknown".to_string()),
                None,
            )
        }
    }
}

struct UdevWatcher {
    child: Child,
    receiver: mpsc::Receiver<()>,
}

impl UdevWatcher {
    fn new() -> Option<Self> {
        let mut child = Command::new("udevadm")
            .args([
                "monitor",
                "--udev",
                "--subsystem-match=drm",
                "--subsystem-match=net",
                "--subsystem-match=hwmon",
                "--subsystem-match=thermal",
                "--subsystem-match=power_supply",
                "--subsystem-match=backlight",
            ])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .ok()?;
        let stdout = child.stdout.take()?;
        let (sender, receiver) = mpsc::channel();
        thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                if line.is_err() || sender.send(()).is_err() {
                    break;
                }
            }
        });
        Some(Self { child, receiver })
    }

    fn changed(&mut self) -> Option<bool> {
        match self.child.try_wait() {
            Ok(None) => {}
            Ok(Some(_)) | Err(_) => return None,
        }

        let mut changed = false;

        while self.receiver.try_recv().is_ok() {
            changed = true;
        }

        Some(changed)
    }
}

impl Drop for UdevWatcher {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

struct SystemMonitor {
    previous_cpu: Option<CpuTicks>,
    network: NetworkMonitor,
    sensors: Vec<PathBuf>,
    gpu: GpuManager,
    udev: Option<UdevWatcher>,
    watch_hardware: bool,
    next_udev_retry: Instant,
    refresh_deadline: Option<Instant>,
}

impl SystemMonitor {
    fn new(watch_hardware: bool) -> Self {
        Self {
            previous_cpu: read_cpu_stat(),
            network: NetworkMonitor::default(),
            sensors: discover_cpu_temp_sensors(),
            gpu: GpuManager::new(),
            udev: watch_hardware.then(UdevWatcher::new).flatten(),
            watch_hardware,
            next_udev_retry: Instant::now() + UDEV_RETRY_INTERVAL,
            refresh_deadline: None,
        }
    }

    fn refresh_hardware_if_needed(&mut self) {
        let now = Instant::now();

        if let Some(watcher) = &mut self.udev {
            match watcher.changed() {
                Some(true) => {
                    self.refresh_deadline = Some(now + HARDWARE_EVENT_DEBOUNCE);
                }
                Some(false) => {}
                None => {
                    self.udev = None;
                    self.next_udev_retry = now + UDEV_RETRY_INTERVAL;
                }
            }
        } else if self.watch_hardware && now >= self.next_udev_retry {
            self.udev = UdevWatcher::new();
            self.next_udev_retry = now + UDEV_RETRY_INTERVAL;
        }

        if self
            .refresh_deadline
            .is_some_and(|deadline| now >= deadline)
        {
            self.refresh_deadline = None;
            self.sensors = discover_cpu_temp_sensors();
            self.gpu.rebuild();
        }
    }

    fn sample(&mut self) -> SystemMetrics {
        self.refresh_hardware_if_needed();
        let current_cpu = read_cpu_stat();
        let cpu = cpu_usage(self.previous_cpu, current_cpu);
        self.previous_cpu = current_cpu;
        let (gpu_vendor, gpu_usage) = self.gpu.sample();

        SystemMetrics {
            cpu,
            cpu_temp: cpu_temperature(&self.sensors),
            ram: memory_usage(),
            gpu_name: self.gpu.name.clone(),
            gpu_vendor,
            gpu_usage,
            network: self.network.sample(),
        }
    }
}

fn send_event(metrics: &SystemMetrics) {
    let event = SystemMonitorEvent {
        event: "system-monitor-state",
        service_available: true,
        metrics,
    };

    if let Ok(value) = serde_json::to_string(&event) {
        println!("{value}");
    }
}

pub async fn run_monitor() {
    let mut monitor = SystemMonitor::new(true);
    let mut ticker = interval(SAMPLE_INTERVAL);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    ticker.tick().await;

    loop {
        ticker.tick().await;
        send_event(&monitor.sample());
    }
}

pub async fn run_legacy_stream(once: bool) {
    let mut monitor = SystemMonitor::new(!once);

    loop {
        sleep(SAMPLE_INTERVAL).await;

        if let Ok(value) = serde_json::to_string(&monitor.sample()) {
            println!("{value}");
        }

        if once {
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_cpu_usage() {
        let previous = parse_cpu_stat("cpu  100 10 40 800 20 5 5 0");
        let current = parse_cpu_stat("cpu  140 10 60 860 20 5 5 0");

        assert_eq!(cpu_usage(previous, current), 50);
    }

    #[test]
    fn invalid_cpu_delta_is_zero() {
        let value = CpuTicks { total: 10, idle: 5 };
        assert_eq!(cpu_usage(Some(value), Some(value)), 0);
        assert_eq!(cpu_usage(None, Some(value)), 0);
    }

    #[test]
    fn parses_memory_usage() {
        let value = "MemTotal:       1000 kB\nMemAvailable:    275 kB\n";
        assert_eq!(parse_memory_usage(value), 73);
    }

    #[test]
    fn chooses_lowest_metric_default_route() {
        let routes = "Iface Destination Gateway Flags RefCnt Use Metric Mask\n\
                      eth0 00000000 00000000 0001 0 0 600 00000000\n\
                      wlan0 00000000 00000000 0001 0 0 100 00000000\n";
        assert_eq!(
            default_ipv4_interface_from(routes).as_deref(),
            Some("wlan0")
        );
    }

    #[test]
    fn ignores_down_default_route() {
        let routes = "Iface Destination Gateway Flags RefCnt Use Metric Mask\n\
                      wlan0 00000000 00000000 0000 0 0 100 00000000\n";
        assert_eq!(default_ipv4_interface_from(routes), None);
    }

    #[test]
    fn normalizes_temperature_units() {
        assert_eq!(normalized_temperature(42), Some(42.0));
        assert_eq!(normalized_temperature(42_500), Some(42.5));
        assert_eq!(normalized_temperature(200_000), None);
    }

    #[test]
    fn extracts_nested_intel_busy_value() {
        let value = serde_json::json!({
            "engines": {
                "Render/3D": { "busy": 12.5 },
                "Video": { "busy": 48.0 }
            }
        });
        assert_eq!(maximum_busy(value.get("engines").unwrap()), Some(48.0));
    }

    #[test]
    fn hybrid_gpu_uses_busiest_real_value() {
        let selected = select_busiest([
            ("intel".to_string(), Some(12.0)),
            ("nvidia".to_string(), Some(68.4)),
            ("amd".to_string(), None),
        ]);
        assert_eq!(selected, Some(("nvidia".to_string(), 68)));
    }

    #[test]
    fn unavailable_gpu_is_not_fake_zero() {
        let selected = select_busiest([("intel".to_string(), None), ("nvidia".to_string(), None)]);
        assert_eq!(selected, None);
    }

    #[test]
    fn serializes_legacy_contract() {
        let metrics = SystemMetrics {
            cpu: 12,
            cpu_temp: Some(43),
            ram: 34,
            gpu_name: "Test GPU".to_string(),
            gpu_vendor: "intel".to_string(),
            gpu_usage: None,
            network: NetworkSample::unavailable(),
        };
        let value = serde_json::to_value(metrics).unwrap();

        assert_eq!(value["cpuTemp"], 43);
        assert_eq!(value["gpuUsage"], Value::Null);
        assert_eq!(value["network"]["type"], "none");
    }
}
