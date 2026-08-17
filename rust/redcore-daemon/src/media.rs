use crate::{DaemonCommand, send_json};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::Duration;

const VALID_MODES: [&str; 4] = ["normal", "track", "playlist", "shuffle"];
const AUDIO_EXTENSIONS: &[&str] = &[
    "aac", "ac3", "aif", "aifc", "aiff", "alac", "amr", "ape", "au", "caf", "dff", "dsf", "dts",
    "flac", "m4a", "m4b", "mid", "midi", "mka", "mp3", "mpc", "oga", "ogg", "opus", "ra", "snd",
    "spx", "tak", "tta", "wav", "wma", "wv",
];
const SOCKET_RETRIES: usize = 12;
const POSITION_RETRIES: usize = 60;
const RETRY_DELAY: Duration = Duration::from_millis(50);
const IPC_TIMEOUT: Duration = Duration::from_secs(2);
const MAX_IPC_MESSAGES_PER_COMMAND: usize = 256;
static PLAYLIST_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MediaCommandPayload {
    pub(crate) uri: Option<String>,
    pub(crate) title: Option<String>,
    pub(crate) artist: Option<String>,
    pub(crate) art: Option<String>,
    pub(crate) position: Option<f64>,
    pub(crate) mode: Option<String>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
struct StoredMediaState {
    #[serde(default)]
    uri: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    artist: String,
    #[serde(default)]
    art: String,
    #[serde(default)]
    position: f64,
    #[serde(default = "default_mode")]
    mode: String,
}

impl Default for StoredMediaState {
    fn default() -> Self {
        Self {
            uri: String::new(),
            title: String::new(),
            artist: String::new(),
            art: String::new(),
            position: 0.0,
            mode: default_mode(),
        }
    }
}

impl StoredMediaState {
    fn normalize(mut self) -> Self {
        self.position = valid_position(self.position);
        self.mode = normalize_mode(&self.mode);
        self
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct LocalMediaStateEvent<'a> {
    event: &'static str,
    service_available: bool,
    uri: &'a str,
    title: &'a str,
    artist: &'a str,
    art: &'a str,
    position: f64,
    mode: &'a str,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct MediaActionResult<'a> {
    event: &'static str,
    action: &'a str,
    success: bool,
    message: Option<String>,
}

fn default_mode() -> String {
    "normal".to_string()
}

fn normalize_mode(mode: &str) -> String {
    if VALID_MODES.contains(&mode) {
        mode.to_string()
    } else {
        default_mode()
    }
}

fn valid_position(position: f64) -> f64 {
    if position.is_finite() && position > 0.0 {
        position
    } else {
        0.0
    }
}

fn state_directory() -> Result<PathBuf, String> {
    if let Some(directory) = env::var_os("XDG_STATE_HOME") {
        return Ok(PathBuf::from(directory).join("red-core"));
    }

    env::var_os("HOME")
        .map(PathBuf::from)
        .map(|home| home.join(".local/state/red-core"))
        .ok_or_else(|| "HOME and XDG_STATE_HOME are unavailable".to_string())
}

fn state_path() -> Result<PathBuf, String> {
    Ok(state_directory()?.join("local-media.json"))
}

fn ensure_private_directory(path: &Path) -> Result<(), String> {
    fs::create_dir_all(path)
        .map_err(|error| format!("could not create {}: {error}", path.display()))?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
        .map_err(|error| format!("could not protect {}: {error}", path.display()))
}

fn load_state_from(path: &Path) -> Result<StoredMediaState, String> {
    let text = match fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            return Ok(StoredMediaState::default());
        }
        Err(error) => return Err(format!("could not read {}: {error}", path.display())),
    };

    serde_json::from_str::<StoredMediaState>(&text)
        .map(StoredMediaState::normalize)
        .map_err(|error| format!("could not parse {}: {error}", path.display()))
}

fn load_state() -> StoredMediaState {
    let path = match state_path() {
        Ok(path) => path,
        Err(error) => {
            eprintln!("Local Media state is unavailable: {error}");
            return StoredMediaState::default();
        }
    };

    match load_state_from(&path) {
        Ok(state) => state,
        Err(error) => {
            eprintln!("Local Media state was reset in memory: {error}");
            StoredMediaState::default()
        }
    }
}

fn save_state_to(path: &Path, state: &StoredMediaState) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| "Local Media state path has no parent".to_string())?;
    ensure_private_directory(parent)?;

    let temporary = path.with_extension(format!("json.tmp.{}", std::process::id()));
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&temporary)
            .map_err(|error| format!("could not create {}: {error}", temporary.display()))?;
        serde_json::to_writer_pretty(&mut file, state)
            .map_err(|error| format!("could not serialize Local Media state: {error}"))?;
        file.write_all(b"\n")
            .and_then(|_| file.sync_all())
            .map_err(|error| format!("could not flush {}: {error}", temporary.display()))?;
        fs::rename(&temporary, path)
            .map_err(|error| format!("could not replace {}: {error}", path.display()))
    })();

    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn save_state(state: &StoredMediaState) -> Result<(), String> {
    save_state_to(&state_path()?, state)
}

fn send_state_value(state: &StoredMediaState) {
    send_json(
        &LocalMediaStateEvent {
            event: "media-local-state",
            service_available: true,
            uri: &state.uri,
            title: &state.title,
            artist: &state.artist,
            art: &state.art,
            position: state.position,
            mode: &state.mode,
        },
        "Local Media state",
    );
}

pub(crate) fn send_state() {
    send_state_value(&load_state());
}

fn send_action_result(action: &str, result: Result<(), String>) {
    let (success, message) = match result {
        Ok(()) => (true, None),
        Err(message) => (false, Some(message)),
    };
    send_json(
        &MediaActionResult {
            event: "media-action-result",
            action,
            success,
            message,
        },
        "Media action result",
    );
}

fn payload_state(payload: &MediaCommandPayload) -> Result<StoredMediaState, String> {
    let uri = payload.uri.clone().unwrap_or_default();
    if uri.is_empty() || !uri.starts_with("file://") {
        return Err("Local Media state requires a file:// URI".to_string());
    }

    Ok(StoredMediaState {
        uri,
        title: payload.title.clone().unwrap_or_default(),
        artist: payload.artist.clone().unwrap_or_default(),
        art: payload.art.clone().unwrap_or_default(),
        position: valid_position(payload.position.unwrap_or(0.0)),
        mode: normalize_mode(payload.mode.as_deref().unwrap_or("normal")),
    })
}

fn command_exists(program: &str) -> bool {
    let Some(path) = env::var_os("PATH") else {
        return false;
    };

    env::split_paths(&path)
        .map(|directory| directory.join(program))
        .any(|candidate| candidate.is_file())
}

fn percent_decode(value: &str) -> Result<String, String> {
    let bytes = value.as_bytes();
    let mut result = Vec::with_capacity(bytes.len());
    let mut index = 0;

    while index < bytes.len() {
        if bytes[index] != b'%' {
            result.push(bytes[index]);
            index += 1;
            continue;
        }

        if index + 2 >= bytes.len() {
            return Err("invalid percent escape in file URI".to_string());
        }
        let hex = std::str::from_utf8(&bytes[index + 1..index + 3])
            .map_err(|_| "invalid percent escape in file URI".to_string())?;
        let byte = u8::from_str_radix(hex, 16)
            .map_err(|_| "invalid percent escape in file URI".to_string())?;
        if byte == 0 {
            return Err("file URI contains a null byte".to_string());
        }
        result.push(byte);
        index += 3;
    }

    String::from_utf8(result).map_err(|_| "file URI is not valid UTF-8".to_string())
}

fn input_path(input: &str) -> Result<PathBuf, String> {
    let value = if let Some(uri) = input.strip_prefix("file://") {
        let uri = uri.strip_prefix("localhost").unwrap_or(uri);
        percent_decode(uri)?
    } else if let Some(relative) = input.strip_prefix("~/") {
        let home = env::var_os("HOME").ok_or_else(|| "HOME is unavailable".to_string())?;
        PathBuf::from(home)
            .join(relative)
            .to_string_lossy()
            .to_string()
    } else {
        input.to_string()
    };

    let path = PathBuf::from(value);
    let path = if path.is_absolute() {
        path
    } else {
        env::current_dir()
            .map_err(|error| error.to_string())?
            .join(path)
    };
    let canonical = path
        .canonicalize()
        .map_err(|error| format!("audio file was not found: {}: {error}", path.display()))?;

    if !canonical.is_file() {
        return Err(format!("audio file was not found: {}", canonical.display()));
    }
    Ok(canonical)
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

fn is_audio_file(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .map(str::to_lowercase)
        .is_some_and(|extension| AUDIO_EXTENSIONS.contains(&extension.as_str()))
}

fn directory_playlist(current: &Path) -> Result<(Vec<PathBuf>, usize), String> {
    let directory = current
        .parent()
        .ok_or_else(|| "audio file has no parent directory".to_string())?;
    let mut files = fs::read_dir(directory)
        .map_err(|error| format!("could not read {}: {error}", directory.display()))?
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.is_file() && is_audio_file(path))
        .filter_map(|path| path.canonicalize().ok())
        .collect::<Vec<_>>();

    files.sort_by(|left, right| {
        left.file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .to_lowercase()
            .cmp(
                &right
                    .file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .to_lowercase(),
            )
    });

    if !files.iter().any(|path| path == current) {
        files.insert(0, current.to_path_buf());
    }
    let index = files.iter().position(|path| path == current).unwrap_or(0);
    Ok((files, index))
}

fn write_playlist(path: &Path, files: &[PathBuf]) -> Result<(), String> {
    let mut contents = String::new();
    for file in files {
        contents.push_str(&file_uri(file));
        contents.push('\n');
    }

    let temporary = path.with_extension(format!("m3u.tmp.{}", std::process::id()));
    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&temporary)
        .map_err(|error| format!("could not write {}: {error}", temporary.display()))?;
    file.write_all(contents.as_bytes())
        .and_then(|_| file.sync_all())
        .map_err(|error| format!("could not write {}: {error}", temporary.display()))?;
    fs::rename(&temporary, path)
        .map_err(|error| format!("could not replace {}: {error}", path.display()))
}

struct TemporaryPlaylist {
    path: PathBuf,
}

impl TemporaryPlaylist {
    fn create(directory: &Path, files: &[PathBuf]) -> Result<Self, String> {
        let sequence = PLAYLIST_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let path = directory.join(format!(
            "local-playlist-{}-{sequence}.m3u",
            std::process::id()
        ));
        write_playlist(&path, files)?;
        Ok(Self { path })
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TemporaryPlaylist {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

fn exchange_mpv_commands<R: BufRead, W: Write>(
    reader: &mut R,
    writer: &mut W,
    commands: &[Value],
) -> io::Result<()> {
    let mut response_line = String::new();

    for (index, command) in commands.iter().enumerate() {
        let request_id = (index + 1) as u64;
        let request = json!({
            "command": command,
            "request_id": request_id,
        });
        serde_json::to_writer(&mut *writer, &request)?;
        writer.write_all(b"\n")?;
        writer.flush()?;

        let mut received_reply = false;
        for _ in 0..MAX_IPC_MESSAGES_PER_COMMAND {
            response_line.clear();
            if reader.read_line(&mut response_line)? == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "mpv closed the IPC connection before replying",
                ));
            }

            let response: Value = serde_json::from_str(&response_line).map_err(|error| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("mpv returned invalid JSON: {error}"),
                )
            })?;
            if response.get("request_id").and_then(Value::as_u64) != Some(request_id) {
                // Playback events can arrive between command responses.
                continue;
            }

            let status = response
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("missing error status");
            if status != "success" {
                return Err(io::Error::other(format!(
                    "mpv rejected command {request_id}: {status}"
                )));
            }
            received_reply = true;
            break;
        }
        if !received_reply {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("mpv sent too many events before answering command {request_id}"),
            ));
        }
    }
    Ok(())
}

fn send_mpv_commands(socket: &Path, commands: &[Value]) -> io::Result<()> {
    let mut stream = UnixStream::connect(socket)?;
    stream.set_write_timeout(Some(IPC_TIMEOUT))?;
    stream.set_read_timeout(Some(IPC_TIMEOUT))?;
    let mut reader = BufReader::new(stream.try_clone()?);
    exchange_mpv_commands(&mut reader, &mut stream, commands)
}

fn mode_commands(mode: &str) -> Vec<Value> {
    let (loop_file, loop_playlist) = match mode {
        "track" => ("inf", "no"),
        "playlist" | "shuffle" => ("no", "inf"),
        _ => ("no", "no"),
    };
    let mut commands = vec![
        json!(["set_property", "loop-file", loop_file]),
        json!(["set_property", "loop-playlist", loop_playlist]),
    ];
    commands.push(if mode == "shuffle" {
        json!(["playlist-shuffle"])
    } else {
        json!(["playlist-unshuffle"])
    });
    commands
}

fn try_existing_player(socket: &Path, playlist: &Path, index: usize, mode: &str) -> bool {
    let mut commands = vec![
        json!(["loadlist", playlist.to_string_lossy(), "replace"]),
        json!(["playlist-play-index", index]),
    ];
    commands.extend(mode_commands(mode));

    for _ in 0..SOCKET_RETRIES {
        if socket.exists() && send_mpv_commands(socket, &commands).is_ok() {
            return true;
        }
        thread::sleep(RETRY_DELAY);
    }
    false
}

fn try_lock(file: &File) -> Result<bool, String> {
    // SAFETY: flock only reads the valid file descriptor and does not retain it.
    let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if result == 0 {
        return Ok(true);
    }

    let error = io::Error::last_os_error();
    if error.kind() == io::ErrorKind::WouldBlock {
        Ok(false)
    } else {
        Err(format!("could not lock Local Media session: {error}"))
    }
}

fn mpv_options(socket: &Path, playlist: &Path, index: usize, mode: &str) -> Vec<String> {
    let mut options = vec![
        "--no-terminal".to_string(),
        format!("--input-ipc-server={}", socket.display()),
        format!("--playlist={}", playlist.display()),
        format!("--playlist-start={index}"),
        "--loop-file=no".to_string(),
        "--loop-playlist=no".to_string(),
    ];

    match mode {
        "track" => options.push("--loop-file=inf".to_string()),
        "playlist" => options.push("--loop-playlist=inf".to_string()),
        "shuffle" => {
            options.push("--shuffle".to_string());
            options.push("--loop-playlist=inf".to_string());
        }
        _ => {}
    }
    options
}

fn restore_position(socket: &Path, position: f64) {
    let position = valid_position(position);
    if position <= 0.0 {
        return;
    }
    let command = json!(["set_property", "time-pos", position]);
    for _ in 0..POSITION_RETRIES {
        if socket.exists() && send_mpv_commands(socket, std::slice::from_ref(&command)).is_ok() {
            return;
        }
        thread::sleep(RETRY_DELAY);
    }
    eprintln!("Could not restore Local Media position");
}

fn play_local_path(path: PathBuf, mode: String, position: f64) -> Result<(), String> {
    if !command_exists("mpv") {
        return Err("mpv is not installed".to_string());
    }

    let directory = state_directory()?;
    ensure_private_directory(&directory)?;
    let socket = directory.join("mpv.sock");
    let lock_path = directory.join("local-player.lock");
    let (files, index) = directory_playlist(&path)?;
    // Every open request owns its playlist until mpv has finished using it.
    // This prevents rapid or concurrent file opens from overwriting each other.
    let playlist = TemporaryPlaylist::create(&directory, &files)?;

    if try_existing_player(&socket, playlist.path(), index, &mode) {
        return Ok(());
    }

    let lock = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .mode(0o600)
        .open(&lock_path)
        .map_err(|error| format!("could not open {}: {error}", lock_path.display()))?;

    if !try_lock(&lock)? {
        if try_existing_player(&socket, playlist.path(), index, &mode) {
            return Ok(());
        }
        eprintln!("Red Core Local Media session is already starting");
        return Ok(());
    }

    if try_existing_player(&socket, playlist.path(), index, &mode) {
        return Ok(());
    }

    match fs::remove_file(&socket) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(format!("could not remove stale socket: {error}")),
    }

    let mut child = Command::new("mpv")
        .args(mpv_options(&socket, playlist.path(), index, &mode))
        .stdin(Stdio::null())
        .spawn()
        .map_err(|error| format!("could not start mpv: {error}"))?;

    restore_position(&socket, position);
    let status = child
        .wait()
        .map_err(|error| format!("could not wait for mpv: {error}"))?;
    let _ = fs::remove_file(&socket);

    if status.success() {
        Ok(())
    } else {
        Err(format!("mpv exited with {status}"))
    }
}

fn detached_start(payload: &MediaCommandPayload) -> Result<(), String> {
    let input = payload
        .uri
        .as_deref()
        .ok_or_else(|| "Missing Local Media URI".to_string())?;
    let path = input_path(input)?;
    if !command_exists("mpv") {
        return Err("mpv is not installed".to_string());
    }
    let mode = payload
        .mode
        .as_deref()
        .map(normalize_mode)
        .unwrap_or_else(|| load_state().mode);
    let position = valid_position(payload.position.unwrap_or(0.0));

    thread::Builder::new()
        .name("redcore-local-media".to_string())
        .spawn(move || {
            if let Err(error) = play_local_path(path, mode, position) {
                eprintln!("Local Media playback stopped: {error}");
            }
        })
        .map(|_| ())
        .map_err(|error| format!("could not create Local Media task: {error}"))
}

pub(crate) fn apply_command(command: &DaemonCommand) {
    let result = match command.action.as_str() {
        "get-local-state" => {
            send_state();
            Ok(())
        }
        "save-local-state" => command
            .media
            .as_ref()
            .ok_or_else(|| "Missing Media payload".to_string())
            .and_then(payload_state)
            .and_then(|state| {
                save_state(&state)?;
                send_state_value(&state);
                Ok(())
            }),
        "start-local-media" => command
            .media
            .as_ref()
            .ok_or_else(|| "Missing Media payload".to_string())
            .and_then(detached_start),
        _ => Err(format!("Unknown Media action: {}", command.action)),
    };
    send_action_result(&command.action, result);
}

pub(crate) fn run_cli(arguments: &[String]) -> Result<(), String> {
    let input = arguments
        .first()
        .ok_or_else(|| "missing audio file".to_string())?;
    let path = input_path(input)?;
    let saved = load_state();
    let mode = arguments
        .get(1)
        .map(|mode| normalize_mode(mode))
        .unwrap_or(saved.mode);
    let position = arguments
        .get(2)
        .and_then(|position| position.parse::<f64>().ok())
        .map(valid_position)
        .unwrap_or(0.0);
    play_local_path(path, mode, position)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temporary_directory(name: &str) -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = env::temp_dir().join(format!(
            "redcore-media-{name}-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir_all(&path).unwrap();
        path
    }

    #[test]
    fn invalid_mode_and_position_are_normalized() {
        let state = StoredMediaState {
            position: f64::NAN,
            mode: "unexpected".to_string(),
            ..StoredMediaState::default()
        }
        .normalize();

        assert_eq!(state.position, 0.0);
        assert_eq!(state.mode, "normal");
    }

    #[test]
    fn old_state_contract_loads_and_normalizes() {
        let directory = temporary_directory("state");
        let path = directory.join("local-media.json");
        fs::write(
            &path,
            r#"{"uri":"file:///music/a.mp3","title":"A","position":7.5,"mode":"track"}"#,
        )
        .unwrap();

        let state = load_state_from(&path).unwrap();
        assert_eq!(state.uri, "file:///music/a.mp3");
        assert_eq!(state.title, "A");
        assert_eq!(state.position, 7.5);
        assert_eq!(state.mode, "track");
        assert_eq!(state.artist, "");
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn state_save_is_atomic_and_round_trips() {
        let directory = temporary_directory("save");
        let path = directory.join("local-media.json");
        let expected = StoredMediaState {
            uri: "file:///music/red%20core.flac".to_string(),
            title: "Red Core".to_string(),
            artist: "Artist".to_string(),
            art: "file:///cover.png".to_string(),
            position: 21.25,
            mode: "playlist".to_string(),
        };

        save_state_to(&path, &expected).unwrap();
        assert_eq!(load_state_from(&path).unwrap(), expected);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn percent_decoder_handles_spaces_and_rejects_invalid_input() {
        assert_eq!(
            percent_decode("/music/Red%20Core.mp3").unwrap(),
            "/music/Red Core.mp3"
        );
        assert!(percent_decode("/music/%ZZ.mp3").is_err());
        assert!(percent_decode("/music/%00.mp3").is_err());
    }

    #[test]
    fn playlist_filters_audio_and_sorts_case_insensitively() {
        let directory = temporary_directory("playlist");
        let first = directory.join("A.flac");
        let current = directory.join("b.MP3");
        fs::write(&first, b"").unwrap();
        fs::write(&current, b"").unwrap();
        fs::write(directory.join("notes.txt"), b"").unwrap();

        let current = current.canonicalize().unwrap();
        let (files, index) = directory_playlist(&current).unwrap();
        assert_eq!(files.len(), 2);
        assert_eq!(files[0].file_name().unwrap(), "A.flac");
        assert_eq!(index, 1);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn expanded_audio_extensions_are_included() {
        for name in [
            "track.AIFF",
            "track.ape",
            "track.mka",
            "track.dsf",
            "track.wv",
            "track.midi",
        ] {
            assert!(is_audio_file(Path::new(name)), "{name} was not recognized");
        }
        assert!(!is_audio_file(Path::new("video.mp4")));
    }

    #[test]
    fn temporary_playlists_are_unique_and_removed_on_drop() {
        let directory = temporary_directory("temporary-playlist");
        let audio = directory.join("track.mp3");
        fs::write(&audio, b"").unwrap();

        let (first_path, second_path) = {
            let first =
                TemporaryPlaylist::create(&directory, std::slice::from_ref(&audio)).unwrap();
            let second =
                TemporaryPlaylist::create(&directory, std::slice::from_ref(&audio)).unwrap();
            assert_ne!(first.path(), second.path());
            assert!(first.path().is_file());
            assert!(second.path().is_file());
            (first.path().to_path_buf(), second.path().to_path_buf())
        };

        assert!(!first_path.exists());
        assert!(!second_path.exists());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn mpv_ipc_ignores_events_and_validates_success_replies() {
        let responses = concat!(
            "{\"event\":\"start-file\"}\n",
            "{\"error\":\"success\",\"request_id\":1}\n",
            "{\"error\":\"success\",\"request_id\":2}\n"
        );
        let mut reader = Cursor::new(responses.as_bytes());
        let mut requests = Vec::new();
        exchange_mpv_commands(
            &mut reader,
            &mut requests,
            &[
                json!(["get_property", "pause"]),
                json!(["set_property", "pause", true]),
            ],
        )
        .unwrap();

        let requests = String::from_utf8(requests).unwrap();
        let requests = requests.lines().collect::<Vec<_>>();
        assert_eq!(requests.len(), 2);
        assert_eq!(
            serde_json::from_str::<Value>(requests[0]).unwrap()["request_id"],
            1
        );
        assert_eq!(
            serde_json::from_str::<Value>(requests[1]).unwrap()["request_id"],
            2
        );
    }

    #[test]
    fn mpv_ipc_reports_rejected_commands() {
        let mut reader =
            Cursor::new(b"{\"error\":\"invalid parameter\",\"request_id\":1}\n".as_slice());
        let mut requests = Vec::new();
        let error = exchange_mpv_commands(&mut reader, &mut requests, &[json!(["bad-command"])])
            .unwrap_err();
        assert!(error.to_string().contains("invalid parameter"));
    }

    #[test]
    fn file_uri_encodes_non_path_characters() {
        assert_eq!(
            file_uri(Path::new("/tmp/Red Core/a#b.mp3")),
            "file:///tmp/Red%20Core/a%23b.mp3"
        );
    }

    #[test]
    fn mode_commands_reset_old_mode_before_applying_new_one() {
        let normal = mode_commands("normal");
        let shuffle = mode_commands("shuffle");

        assert_eq!(normal[0], json!(["set_property", "loop-file", "no"]));
        assert_eq!(normal[2], json!(["playlist-unshuffle"]));
        assert_eq!(shuffle[1], json!(["set_property", "loop-playlist", "inf"]));
        assert_eq!(shuffle[2], json!(["playlist-shuffle"]));
    }
}
