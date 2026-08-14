import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import QtQuick

PanelWindow {
    id: root

    anchors {
        top: true
    }

    implicitWidth: 1180
    implicitHeight: 48
    color: "transparent"

    property var workspaces: []
    property int activeWorkspace: -1

    // Last actually used media player.
    // We keep its metadata even if the player disappears.
    property var activePlayer: null

    // Current/last visible MPRIS media.
    property string lastPlayerDbusName: ""
    property string lastMediaTitle: ""
    property string lastMediaArtist: ""
    property string lastMediaArt: ""
    property string lastMediaUri: ""

    // Persistent LOCAL music session.
    // Online players must NEVER overwrite these.
    property string lastLocalUri: ""
    property string lastLocalTitle: ""
    property string lastLocalArtist: ""
    property string lastLocalArt: ""
    property real lastLocalPosition: 0
    property string localPlaybackMode: "normal"

    // Empty = automatic player selection.
    property string pinnedPlayerDbusName: ""

    // Used to detect the actual Paused -> Playing transition.
    property var playerPlayingSnapshot: ({})

    // Keep the current MPRIS source stable during short
    // track transitions, especially browser media sessions.
    property string mediaTransitionDbusName: ""
    property double mediaTransitionUntil: 0

    // Local queue information.
    property int localQueueCount: 0
    property string localQueueCurrent: ""
    property string localQueueNext: ""

    function currentPlaybackMode() {
        const player = root.activePlayer

        if (player !== null) {
            if (
                player.shuffleSupported &&
                player.shuffle
            ) {
                return "shuffle"
            }

            if (player.loopSupported) {
                if (player.loopState === MprisLoopState.Track)
                    return "track"

                if (player.loopState === MprisLoopState.Playlist)
                    return "playlist"
            }

            return "normal"
        }

        return root.localPlaybackMode
    }

    function playbackModeIcon() {
        const mode = root.currentPlaybackMode()

        if (mode === "track")
            return "↻1"

        if (mode === "playlist")
            return "↻"

        if (mode === "shuffle")
            return "⇄"

        return "▶"
    }

    function applyPlaybackMode(mode) {
        const player = root.activePlayer

        // Store this as Local Music preference only when we are
        // controlling Local Music or there is no live player.
        if (
            player === null ||
            root.playerIsLocal(player)
        ) {
            root.localPlaybackMode = mode
        }

        // No live MPRIS player:
        // keep the mode as the preferred mode for local fallback.
        if (player === null)
            return

        // Always disable shuffle first when leaving shuffle mode.
        if (
            player.shuffleSupported &&
            mode !== "shuffle"
        ) {
            player.shuffle = false
        }

        if (mode === "normal") {
            if (player.loopSupported)
                player.loopState = MprisLoopState.None

            return
        }

        if (mode === "track") {
            if (player.loopSupported)
                player.loopState = MprisLoopState.Track

            return
        }

        if (mode === "playlist") {
            if (player.loopSupported)
                player.loopState = MprisLoopState.Playlist

            return
        }

        if (mode === "shuffle") {
            if (player.loopSupported)
                player.loopState = MprisLoopState.Playlist

            if (player.shuffleSupported)
                player.shuffle = true
        }
    }

    function nextPlaybackMode() {
        const player = root.activePlayer
        const current = root.currentPlaybackMode()

        let modes = ["normal"]

        if (
            player === null ||
            player.loopSupported
        ) {
            modes.push("track")
            modes.push("playlist")
        }

        if (
            player === null ||
            player.shuffleSupported
        ) {
            modes.push("shuffle")
        }

        let index = modes.indexOf(current)

        if (index < 0)
            index = 0

        const next =
            modes[(index + 1) % modes.length]

        root.applyPlaybackMode(next)
    }

    function localPlaybackModeLabel() {
        return root.currentPlaybackMode()
    }

    property int cpuUsage: 0
    property var cpuTemp: null
    property int ramUsage: 0

    property var gpuUsage: null
    property string gpuVendor: "unknown"

    property string networkType: "none"
    property string networkInterface: ""
    property int downloadSpeed: 0
    property int uploadSpeed: 0

    function formatSpeed(bytes) {
        if (bytes >= 1024 * 1024)
            return (bytes / 1024 / 1024).toFixed(1) + "M"

        if (bytes >= 1024)
            return (bytes / 1024).toFixed(1) + "K"

        return bytes + "B"
    }

    function formatTime(seconds) {
        if (!seconds || seconds < 0)
            return "0:00"

        const total = Math.floor(seconds)
        const minutes = Math.floor(total / 60)
        const secs = total % 60

        return minutes + ":" + (secs < 10 ? "0" : "") + secs
    }

    // =========================
    // MEDIA PLAYER TRACKING
    // =========================

    function playerUri(player) {
        if (player === null)
            return ""

        try {
            const metadata = player.metadata

            if (
                metadata !== null &&
                metadata !== undefined
            ) {
                const uri = metadata["xesam:url"]

                if (
                    uri !== undefined &&
                    uri !== null
                ) {
                    return String(uri)
                }
            }
        } catch (error) {
        }

        return ""
    }

    function playerIsLocal(player) {
        const uri = root.playerUri(player)

        return (
            uri !== "" &&
            uri.startsWith("file://")
        )
    }

    function findPlayer(dbusName) {
        if (dbusName === "")
            return null

        const players = Mpris.players.values

        for (let i = 0; i < players.length; i++) {
            if (players[i].dbusName === dbusName)
                return players[i]
        }

        return null
    }

    function playerUsable(player) {
        if (player === null)
            return false

        return (
            player.isPlaying ||
            player.canTogglePlaying ||
            player.canPlay ||
            player.trackTitle !== ""
        )
    }

    function pauseOtherPlayers(exceptDbusName) {
        const players = Mpris.players.values

        for (let i = 0; i < players.length; i++) {
            const player = players[i]

            if (
                player.dbusName === exceptDbusName ||
                !player.isPlaying
            ) {
                continue
            }

            try {
                if (player.canPause) {
                    player.pause()
                } else if (player.canControl) {
                    player.stop()
                }
            } catch (error) {
                console.log(
                    "Could not silence media source:",
                    player.dbusName,
                    error
                )
            }
        }
    }

    function bestLocalPlayer() {
        const players = Mpris.players.values
        let fallback = null

        // Prefer the Local player that is really playing.
        for (let i = 0; i < players.length; i++) {
            const player = players[i]

            if (!root.playerIsLocal(player))
                continue

            if (player.isPlaying)
                return player

            if (
                root.activePlayer !== null &&
                player.dbusName === root.activePlayer.dbusName
            ) {
                fallback = player
            } else if (fallback === null) {
                fallback = player
            }
        }

        return fallback
    }

    function activateMediaPlayer(player) {
        if (player === null)
            return

        // Red Core uses exclusive playback:
        // selecting one source pauses every other source.
        root.pauseOtherPlayers(player.dbusName)

        root.pinnedPlayerDbusName =
            player.dbusName

        root.rememberPlayer(player)

        if (
            !player.isPlaying &&
            player.canPlay
        ) {
            player.play()
        }
    }

    function logicalMediaSources() {
        const players = Mpris.players.values
        let sources = []

        // All file:// MPRIS players represent ONE logical
        // Red Core Local Music source.
        const local =
            root.bestLocalPlayer()

        if (local !== null)
            sources.push(local)

        for (let i = 0; i < players.length; i++) {
            const player = players[i]

            if (!root.playerUsable(player))
                continue

            if (root.playerIsLocal(player))
                continue

            sources.push(player)
        }

        return sources
    }

    function livePlayerCount() {
        const players = Mpris.players.values
        let count = 0

        for (let i = 0; i < players.length; i++) {
            if (root.playerUsable(players[i]))
                count++
        }

        return count
    }

    function rememberPlayer(player) {
        if (player === null)
            return

        root.mediaTransitionDbusName = ""
        root.mediaTransitionUntil = 0

        root.activePlayer = player
        root.lastPlayerDbusName =
            player.dbusName || ""

        root.lastMediaTitle =
            player.trackTitle ||
            player.identity ||
            ""

        root.lastMediaArtist =
            player.trackArtist ||
            player.identity ||
            ""

        root.lastMediaArt =
            player.trackArtUrl || ""

        const uri = root.playerUri(player)

        if (uri !== "")
            root.lastMediaUri = uri

        // Online players must NEVER overwrite Local Music.
        if (uri.startsWith("file://")) {
            const trackChanged =
                uri !== root.lastLocalUri

            root.lastLocalUri = uri

            root.lastLocalTitle =
                player.trackTitle ||
                root.lastLocalTitle

            root.lastLocalArtist =
                player.trackArtist ||
                root.lastLocalArtist

            root.lastLocalArt =
                player.trackArtUrl ||
                root.lastLocalArt

            if (trackChanged) {
                root.lastLocalPosition = 0
            } else if (player.positionSupported) {
                let position =
                    Math.max(
                        0,
                        player.position
                    )

                if (
                    player.lengthSupported &&
                    player.length > 0 &&
                    position >=
                        Math.max(
                            0,
                            player.length - 2.5
                        )
                ) {
                    position = 0
                }

                root.lastLocalPosition =
                    position
            }
        }
    }

    function resumeLocalSession() {
        // If a Local MPRIS session already exists,
        // reuse it instead of starting another mpv.
        const local =
            root.bestLocalPlayer()

        if (local !== null) {
            root.activateMediaPlayer(local)
            return
        }

        if (root.lastLocalUri === "")
            return

        // No live local player:
        // pause online media before starting Local Music.
        root.pauseOtherPlayers("")

        root.pinnedPlayerDbusName = ""

        if (!resumeLocalMedia.running) {
            resumeLocalMedia.command = [
                "redcore-local-media",
                root.lastLocalUri,
                root.localPlaybackMode,
                String(root.lastLocalPosition)
            ]

            resumeLocalMedia.running = true
        }
    }

    function toggleOrResumeMedia() {
        if (root.activePlayer !== null) {
            const live =
                root.findPlayer(
                    root.activePlayer.dbusName
                )

            if (
                live !== null &&
                live.canTogglePlaying
            ) {
                // When resuming this source, first pause
                // any other source that may be playing.
                if (!live.isPlaying) {
                    root.pauseOtherPlayers(
                        live.dbusName
                    )
                }

                live.togglePlaying()
                return
            }
        }

        root.resumeLocalSession()
    }

    function mediaSourceLabel() {
        if (root.activePlayer !== null) {
            if (
                root.playerIsLocal(
                    root.activePlayer
                )
            ) {
                return "Local"
            }

            return (
                root.activePlayer.identity ||
                "Media"
            )
        }

        if (root.lastLocalUri !== "")
            return "Local"

        return "No media"
    }

    function cycleMediaPlayer() {
        const sources =
            root.logicalMediaSources()

        if (sources.length === 0)
            return

        if (sources.length === 1) {
            root.activateMediaPlayer(
                sources[0]
            )
            return
        }

        let currentIndex = -1

        for (let i = 0; i < sources.length; i++) {
            if (root.activePlayer === null)
                break

            const currentLocal =
                root.playerIsLocal(
                    root.activePlayer
                )

            const candidateLocal =
                root.playerIsLocal(
                    sources[i]
                )

            if (
                currentLocal &&
                candidateLocal
            ) {
                currentIndex = i
                break
            }

            if (
                !currentLocal &&
                sources[i].dbusName ===
                root.activePlayer.dbusName
            ) {
                currentIndex = i
                break
            }
        }

        const nextIndex =
            (currentIndex + 1) %
            sources.length

        root.activateMediaPlayer(
            sources[nextIndex]
        )
    }

    function saveLocalMediaState() {
        if (
            root.activePlayer !== null &&
            root.playerIsLocal(
                root.activePlayer
            )
        ) {
            const uri =
                root.playerUri(
                    root.activePlayer
                )

            if (uri.startsWith("file://")) {
                const trackChanged =
                    uri !== root.lastLocalUri

                root.lastLocalUri = uri

                root.lastLocalTitle =
                    root.activePlayer.trackTitle ||
                    root.lastLocalTitle

                root.lastLocalArtist =
                    root.activePlayer.trackArtist ||
                    root.lastLocalArtist

                root.lastLocalArt =
                    root.activePlayer.trackArtUrl ||
                    root.lastLocalArt

                if (trackChanged) {
                    root.lastLocalPosition = 0
                } else if (
                    root.activePlayer.positionSupported
                ) {
                    let position =
                        Math.max(
                            0,
                            root.activePlayer.position
                        )

                    if (
                        root.activePlayer.lengthSupported &&
                        root.activePlayer.length > 0 &&
                        position >=
                            Math.max(
                                0,
                                root.activePlayer.length -
                                2.5
                            )
                    ) {
                        position = 0
                    }

                    root.lastLocalPosition =
                        position
                }
            }
        }

        if (
            root.lastLocalUri === "" ||
            localStateSave.running
        ) {
            return
        }

        localStateSave.command = [
            "redcore-media-state",
            "save",
            root.lastLocalUri,
            root.lastLocalTitle,
            root.lastLocalArtist,
            root.lastLocalArt,
            String(root.lastLocalPosition),
            root.localPlaybackMode
        ]

        localStateSave.running = true
    }

    Process {
        id: resumeLocalMedia
    }

    // Load Local Music state once when Quickshell starts.
    Process {
        id: localStateLoad

        running: true
        command: [
            "redcore-media-state",
            "get"
        ]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const data =
                        JSON.parse(this.text)

                    root.lastLocalUri =
                        data.uri || ""

                    root.lastLocalTitle =
                        data.title || ""

                    root.lastLocalArtist =
                        data.artist || ""

                    root.lastLocalArt =
                        data.art || ""

                    root.lastLocalPosition =
                        Number(data.position || 0)

                    const mode =
                        data.mode || "normal"

                    if (
                        mode === "normal" ||
                        mode === "track" ||
                        mode === "playlist" ||
                        mode === "shuffle"
                    ) {
                        root.localPlaybackMode =
                            mode
                    }

                    // Display remembered local music
                    // without automatically starting it.
                    if (
                        root.activePlayer === null &&
                        root.lastLocalUri !== ""
                    ) {
                        root.lastMediaUri =
                            root.lastLocalUri

                        root.lastMediaTitle =
                            root.lastLocalTitle

                        root.lastMediaArtist =
                            root.lastLocalArtist

                        root.lastMediaArt =
                            root.lastLocalArt
                    }
                } catch (error) {
                    console.log(
                        "Could not load Local Media state:",
                        error
                    )
                }
            }
        }
    }

    Process {
        id: localStateSave
    }

    Process {
        id: localQueueRead

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const data =
                        JSON.parse(this.text)

                    root.localQueueCount =
                        Number(
                            data.count || 0
                        )

                    root.localQueueCurrent =
                        data.current || ""

                    root.localQueueNext =
                        data.next || ""

                } catch (error) {
                    root.localQueueCount = 0
                    root.localQueueCurrent = ""
                    root.localQueueNext = ""
                }
            }
        }
    }

    Timer {
        interval: 1000

        running:
            mediaPopup.visible &&
            root.activePlayer !== null &&
            root.playerIsLocal(
                root.activePlayer
            )

        repeat: true
        triggeredOnStart: true

        onTriggered: {
            if (
                root.activePlayer === null ||
                !root.playerIsLocal(
                    root.activePlayer
                )
            ) {
                root.localQueueCount = 0
                return
            }

            if (!localQueueRead.running) {
                localQueueRead.command = [
                    "redcore-local-queue",
                    root.playerUri(
                        root.activePlayer
                    )
                ]

                localQueueRead.running = true
            }
        }
    }

    // Persist Local position without constantly writing to disk.
    Timer {
        interval: 5000
        running: true
        repeat: true

        onTriggered: {
            root.saveLocalMediaState()
        }
    }

    Timer {
        id: mediaPlayerTracker

        interval: 350
        running: true
        repeat: true
        triggeredOnStart: true

        onTriggered: {
            const players =
                Mpris.players.values

            const previous =
                root.playerPlayingSnapshot || ({})

            let snapshot = ({})
            let playing = []
            let started = []

            for (
                let i = 0;
                i < players.length;
                i++
            ) {
                const player = players[i]

                const name =
                    player.dbusName || ""

                const nowPlaying =
                    player.isPlaying

                snapshot[name] =
                    nowPlaying

                if (nowPlaying) {
                    playing.push(player)

                    // This source actually changed
                    // Paused/Stopped -> Playing.
                    if (previous[name] !== true) {
                        started.push(player)
                    }
                }
            }

            root.playerPlayingSnapshot =
                snapshot

            // ---------------------------------
            // A source has just started.
            // The newest started source wins.
            // ---------------------------------
            if (started.length > 0) {
                let chosen =
                    started[
                        started.length - 1
                    ]

                // If multiple appeared in the same
                // tick, prefer the one different
                // from the previous active source.
                if (
                    started.length > 1 &&
                    root.activePlayer !== null
                ) {
                    for (
                        let i = started.length - 1;
                        i >= 0;
                        i--
                    ) {
                        if (
                            started[i].dbusName !==
                            root.activePlayer.dbusName
                        ) {
                            chosen = started[i]
                            break
                        }
                    }
                }

                root.pauseOtherPlayers(
                    chosen.dbusName
                )

                root.pinnedPlayerDbusName =
                    chosen.dbusName

                root.rememberPlayer(chosen)
                return
            }

            // ---------------------------------
            // Something is already playing.
            // Keep active/pinned player if possible.
            // ---------------------------------
            if (playing.length > 0) {
                let chosen = null

                if (
                    root.pinnedPlayerDbusName !== ""
                ) {
                    for (
                        let i = 0;
                        i < playing.length;
                        i++
                    ) {
                        if (
                            playing[i].dbusName ===
                            root.pinnedPlayerDbusName
                        ) {
                            chosen = playing[i]
                            break
                        }
                    }
                }

                if (
                    chosen === null &&
                    root.activePlayer !== null
                ) {
                    for (
                        let i = 0;
                        i < playing.length;
                        i++
                    ) {
                        if (
                            playing[i].dbusName ===
                            root.activePlayer.dbusName
                        ) {
                            chosen = playing[i]
                            break
                        }
                    }
                }

                if (chosen === null)
                    chosen = playing[0]

                if (playing.length > 1) {
                    root.pauseOtherPlayers(
                        chosen.dbusName
                    )
                }

                root.rememberPlayer(chosen)
                return
            }

            // ---------------------------------
            // Nothing playing: selected session.
            //
            // Browsers may briefly expose an empty/stopped
            // MPRIS state while changing tracks.
            // Do NOT jump to Local immediately.
            // ---------------------------------
            if (
                root.pinnedPlayerDbusName !== ""
            ) {
                const pinned =
                    root.findPlayer(
                        root.pinnedPlayerDbusName
                    )

                if (pinned !== null) {
                    if (
                        root.playerUsable(pinned)
                    ) {
                        root.rememberPlayer(pinned)
                        return
                    }

                    const now = Date.now()

                    if (
                        root.mediaTransitionDbusName !==
                        pinned.dbusName
                    ) {
                        root.mediaTransitionDbusName =
                            pinned.dbusName

                        root.mediaTransitionUntil =
                            now + 2500
                    }

                    if (
                        now <
                        root.mediaTransitionUntil
                    ) {
                        // Keep the same source selected.
                        // We intentionally do NOT call
                        // rememberPlayer here because its
                        // metadata may be temporarily empty.
                        root.activePlayer = pinned
                        return
                    }
                }

                root.mediaTransitionDbusName = ""
                root.mediaTransitionUntil = 0
                root.pinnedPlayerDbusName = ""
            }

            // ---------------------------------
            // Last paused session.
            // ---------------------------------
            const remembered =
                root.findPlayer(
                    root.lastPlayerDbusName
                )

            if (
                remembered !== null &&
                root.playerUsable(remembered)
            ) {
                root.rememberPlayer(remembered)
                return
            }

            // ---------------------------------
            // Any valid paused MPRIS session.
            // ---------------------------------
            for (
                let i = 0;
                i < players.length;
                i++
            ) {
                if (
                    root.playerUsable(players[i])
                ) {
                    root.rememberPlayer(
                        players[i]
                    )
                    return
                }
            }

            // ---------------------------------
            // Nothing live: persistent Local fallback.
            // ---------------------------------
            root.activePlayer = null

            if (root.lastLocalUri !== "") {
                root.lastMediaUri =
                    root.lastLocalUri

                root.lastMediaTitle =
                    root.lastLocalTitle

                root.lastMediaArtist =
                    root.lastLocalArtist

                root.lastMediaArt =
                    root.lastLocalArt
            }
        }
    }

    // =========================
    // NIRI WORKSPACES
    // =========================

    Process {
        id: niriEvents
        running: true
        command: ["niri", "msg", "--json", "event-stream"]

        stdout: SplitParser {
            onRead: line => {
                try {
                    const event = JSON.parse(line)

                    if (event.WorkspacesChanged) {
                        const list = event.WorkspacesChanged.workspaces

                        list.sort((a, b) => a.idx - b.idx)
                        root.workspaces = list

                        for (const workspace of list) {
                            if (workspace.is_focused) {
                                root.activeWorkspace = workspace.id
                            }
                        }
                    }

                    if (
                        event.WorkspaceActivated &&
                        event.WorkspaceActivated.focused
                    ) {
                        root.activeWorkspace =
                            event.WorkspaceActivated.id
                    }

                } catch (error) {
                    console.log("Niri event parse error:", error)
                }
            }
        }
    }

    Process {
        id: workspaceSwitch
    }

    // =========================
    // SYSTEM INFO
    // =========================

    Process {
        id: systemInfoProcess

        command: ["redcore-system-info"]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const data = JSON.parse(text)

                    root.cpuUsage = data.cpu
                    root.cpuTemp = data.cpuTemp
                    root.ramUsage = data.ram

                    root.gpuUsage = data.gpuUsage
                    root.gpuVendor = data.gpuVendor

                    root.networkInterface =
                        data.network.interface

                    root.networkType =
                        data.network.type

                    root.downloadSpeed =
                        data.network.download

                    root.uploadSpeed =
                        data.network.upload

                } catch (error) {
                    console.log(
                        "System info parse error:",
                        error
                    )
                }
            }
        }
    }

    Timer {
        interval: 2000
        running: true
        repeat: true
        triggeredOnStart: true

        onTriggered: {
            if (!systemInfoProcess.running) {
                systemInfoProcess.running = true
            }
        }
    }

    // =========================
    // PIPEWIRE AUDIO
    // =========================

    PwObjectTracker {
        objects: [Pipewire.defaultAudioSink]
    }

    property var audioSink: Pipewire.defaultAudioSink

    function changeVolume(delta) {
        if (
            root.audioSink === null ||
            root.audioSink.audio === null
        )
            return

        let value = root.audioSink.audio.volume + delta

        if (value < 0)
            value = 0

        if (value > 1)
            value = 1

        root.audioSink.audio.volume = value

        if (
            root.audioSink.audio.muted &&
            value > 0
        ) {
            root.audioSink.audio.muted = false
        }
    }

    // =========================
    // CLOCK
    // =========================

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    // =========================
    // MAIN BAR
    // =========================

    Rectangle {
        anchors.fill: parent

        color: "#1e1e2e"
        radius: 16

        // =====================
        // LEFT SIDE
        // =====================

        Row {
            anchors {
                left: parent.left
                leftMargin: 14
                verticalCenter: parent.verticalCenter
            }

            spacing: 16

            // Red Core / Start button
            Rectangle {
                width: 36
                height: 32
                radius: 10
                color: "#313244"

                Text {
                    anchors.centerIn: parent
                    text: "★"
                    color: "#89b4fa"
                    font.pixelSize: 17
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor

                    onClicked: {
                        console.log("Red Core menu")
                    }
                }
            }

            // System monitor
            Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8

                Text {
                    text:
                        "CPU " +
                        root.cpuUsage +
                        "%" +
                        (
                            root.cpuTemp !== null
                            ? " " + root.cpuTemp + "°"
                            : ""
                        )

                    color: "#cdd6f4"
                    font.pixelSize: 13
                }

                Text {
                    text:
                        "RAM " +
                        root.ramUsage +
                        "%"

                    color: "#cdd6f4"
                    font.pixelSize: 13
                }
                Text {
                   visible: root.gpuUsage !== null

                   text:
                       "GPU " +
                        root.gpuUsage +
                        "%"

                   color: "#cdd6f4"
                   font.pixelSize: 13
                       }
                Text {
                    text:
                        "↓" +
                        root.formatSpeed(
                            root.downloadSpeed
                        ) +
                        " ↑" +
                        root.formatSpeed(
                            root.uploadSpeed
                        )

                    color: "#cdd6f4"
                    font.pixelSize: 13
                }
            }

            // Separator
            Rectangle {
                width: 1
                height: 22
                color: "#45475a"
                anchors.verticalCenter: parent.verticalCenter
            }

            // Media player
            Item {
                id: mediaButton

                width: 230
                height: 32

                Row {
                    anchors.centerIn: parent
                    spacing: 6

                    // Previous
                    Rectangle {
                        width: 26
                        height: 26
                        radius: 8
                        color: "#313244"

                        opacity:
                            root.activePlayer !== null &&
                            root.activePlayer.canGoPrevious
                            ? 1.0
                            : 0.35

                        Text {
                            anchors.centerIn: parent
                            text: "◀"
                            color: "#cdd6f4"
                            font.pixelSize: 11
                        }

                        MouseArea {
                            anchors.fill: parent

                            cursorShape:
                                root.activePlayer !== null &&
                                root.activePlayer.canGoPrevious
                                ? Qt.PointingHandCursor
                                : Qt.ArrowCursor

                            onClicked: {
                                if (
                                    root.activePlayer !== null &&
                                    root.activePlayer.canGoPrevious
                                ) {
                                    root.activePlayer.previous()
                                }
                            }
                        }
                    }

                    // Play / Pause
                    Rectangle {
                        width: 30
                        height: 28
                        radius: 8
                        color: "#89b4fa"

                        Text {
                            anchors.centerIn: parent

                            text:
                                root.activePlayer !== null &&
                                root.activePlayer.isPlaying
                                ? "Ⅱ"
                                : "▶"

                            color: "#11111b"
                            font.pixelSize: 12
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor

                            onClicked: {
                                root.toggleOrResumeMedia()
                            }
                        }
                    }

                    // Next
                    Rectangle {
                        width: 26
                        height: 26
                        radius: 8
                        color: "#313244"

                        opacity:
                            root.activePlayer !== null &&
                            root.activePlayer.canGoNext
                            ? 1.0
                            : 0.35

                        Text {
                            anchors.centerIn: parent
                            text: "▶"
                            color: "#cdd6f4"
                            font.pixelSize: 11
                        }

                        MouseArea {
                            anchors.fill: parent

                            cursorShape:
                                root.activePlayer !== null &&
                                root.activePlayer.canGoNext
                                ? Qt.PointingHandCursor
                                : Qt.ArrowCursor

                            onClicked: {
                                if (
                                    root.activePlayer !== null &&
                                    root.activePlayer.canGoNext
                                ) {
                                    root.activePlayer.next()
                                }
                            }
                        }
                    }

                    // Track title - click opens popup
                    Item {
                        width: 130
                        height: 30

                        Text {
                            anchors {
                                left: parent.left
                                right: parent.right
                                verticalCenter: parent.verticalCenter
                            }

                            elide: Text.ElideRight

                            text:
                                root.activePlayer !== null
                                ? (
                                    root.activePlayer.trackTitle
                                    || root.activePlayer.identity
                                    || "Media"
                                  )
                                : (
                                    root.lastMediaTitle !== ""
                                    ? root.lastMediaTitle
                                    : "No media"
                                  )

                            color: "#cdd6f4"
                            font.pixelSize: 13
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor

                            onClicked: {
                                if (
                                    root.activePlayer === null &&
                                    root.lastMediaTitle === ""
                                ) {
                                    return
                                }

                                const opening = !mediaPopup.visible

                                if (
                                    opening &&
                                    root.activePlayer !== null &&
                                    root.activePlayer.positionSupported
                                ) {
                                    root.activePlayer.positionChanged()
                                }

                                mediaPopup.visible = opening
                            }
                        }
                    }
                }
            }
        }

        // =====================
        // TRUE CENTER
        // WORKSPACES
        // =====================

        Row {
            anchors.centerIn: parent
            spacing: 10

            Repeater {
                model: root.workspaces

                Rectangle {
                    required property var modelData

                    width: 32
                    height: 32
                    radius: 10

                    color:
                        root.activeWorkspace === modelData.id
                        ? "#89b4fa"
                        : "#313244"

                    Text {
                        anchors.centerIn: parent
                        text: modelData.idx

                        color:
                            root.activeWorkspace === modelData.id
                            ? "#11111b"
                            : "#cdd6f4"

                        font.pixelSize: 13
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor

                        onClicked: {
                            workspaceSwitch.command = [
                                "niri",
                                "msg",
                                "action",
                                "focus-workspace",
                                String(modelData.idx)
                            ]

                            workspaceSwitch.running = true
                        }
                    }
                }
            }
        }

        // =====================
        // RIGHT SIDE
        // =====================

        Row {
            anchors {
                right: parent.right
                rightMargin: 14
                verticalCenter: parent.verticalCenter
            }

            spacing: 14

            Text {
                text:
                    root.networkType === "ethernet"
                    ? "Ethernet"
                    : root.networkType === "wifi"
                    ? "WiFi"
                    : "Offline"

                color: "#cdd6f4"
                font.pixelSize: 13
            }

            Rectangle {
                width: 64
                height: 32
                radius: 10
                color: "#313244"

                Text {
                    anchors.centerIn: parent

                    text:
                        root.audioSink !== null &&
                        root.audioSink.audio !== null
                        ? (
                            root.audioSink.audio.muted
                            ? "Muted"
                            : Math.round(
                                root.audioSink.audio.volume * 100
                              ) + "%"
                          )
                        : "--%"

                    color: "#cdd6f4"
                    font.pixelSize: 13
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor

                    onClicked: {
                        if (
                            root.audioSink !== null &&
                            root.audioSink.audio !== null
                        ) {
                            root.audioSink.audio.muted =
                                !root.audioSink.audio.muted
                        }
                    }
                }
            }

            Rectangle {
                width: 1
                height: 22
                color: "#45475a"
                anchors.verticalCenter:
                    parent.verticalCenter
            }

            Text {
                text:
                    Qt.formatDateTime(
                        clock.date,
                        "dd/MM"
                    )

                color: "#cdd6f4"
                font.pixelSize: 13
            }

            Text {
                text:
                    Qt.formatDateTime(
                        clock.date,
                        "HH:mm"
                    )

                color: "#cdd6f4"
                font.pixelSize: 13
            }

            Rectangle {
                width: 1
                height: 22
                color: "#45475a"
                anchors.verticalCenter:
                    parent.verticalCenter
            }

            // Power button
            Rectangle {
                width: 32
                height: 32
                radius: 10
                color: "#313244"

                Text {
                    anchors.centerIn: parent
                    text: "⏻"
                    color: "#f38ba8"
                    font.pixelSize: 16
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor

                    onClicked: {
                        console.log("Power menu")
                    }
                }
            }
        }
    }

    // =========================
    // MEDIA POPUP
    // =========================

    PopupWindow {
        id: mediaPopup

        visible: false
        grabFocus: true
        color: "transparent"

        implicitWidth: 360
        implicitHeight: 340

        anchor {
            item: mediaButton
            edges: Edges.Bottom | Edges.Left
            gravity: Edges.Bottom | Edges.Right
            adjustment: PopupAdjustment.All
        }

        Rectangle {
            anchors.fill: parent

            radius: 16
            color: "#1e1e2e"
            border.width: 1
            border.color: "#45475a"

            Column {
                anchors {
                    fill: parent
                    margins: 16
                }

                spacing: 14

                // Track information
                Row {
                    spacing: 14

                    Rectangle {
                        width: 82
                        height: 82
                        radius: 12
                        color: "#313244"
                        clip: true

                        Image {
                            anchors.fill: parent

                            source:
                                root.activePlayer !== null &&
                                root.activePlayer.trackArtUrl !== ""
                                ? root.activePlayer.trackArtUrl
                                : root.lastMediaArt

                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true

                            visible:
                                root.activePlayer !== null &&
                                root.activePlayer.trackArtUrl !== ""
                        }

                        Text {
                            anchors.centerIn: parent

                            visible:
                                (
                                    root.activePlayer === null ||
                                    root.activePlayer.trackArtUrl === ""
                                ) &&
                                root.lastMediaArt === ""

                            text: "♪"
                            color: "#89b4fa"
                            font.pixelSize: 30
                        }
                    }

                    Item {
                        width: 230
                        height: 82

                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width
                            spacing: 7

                            Text {
                                width: parent.width
                                elide: Text.ElideRight

                                text:
                                    root.activePlayer !== null
                                    ? (
                                        root.activePlayer.trackTitle
                                        || root.lastMediaTitle
                                        || "Unknown title"
                                    )
                                    : (
                                        root.lastMediaTitle !== ""
                                        ? root.lastMediaTitle
                                        : "No media"
                                    )

                                color: "#cdd6f4"
                                font.pixelSize: 16
                            }

                            Text {
                                width: parent.width
                                elide: Text.ElideRight

                                text:
                                    root.activePlayer !== null
                                    ? (
                                        root.activePlayer.trackArtist
                                        || root.lastMediaArtist
                                        || root.activePlayer.identity
                                        || ""
                                    )
                                    : root.lastMediaArtist

                                color: "#a6adc8"
                                font.pixelSize: 12
                            }
                        }
                    }
                }

                // Previous / Play-Pause / Next
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 16

                    Rectangle {
                        width: 42
                        height: 34
                        radius: 10
                        color: "#313244"

                        opacity:
                            root.activePlayer !== null &&
                            root.activePlayer.canGoPrevious
                            ? 1.0
                            : 0.35

                        Text {
                            anchors.centerIn: parent
                            text: "◀"
                            color: "#cdd6f4"
                            font.pixelSize: 15
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor

                            onClicked: {
                                if (
                                    root.activePlayer !== null &&
                                    root.activePlayer.canGoPrevious
                                ) {
                                    root.activePlayer.previous()
                                }
                            }
                        }
                    }

                    Rectangle {
                        width: 52
                        height: 34
                        radius: 10
                        color: "#89b4fa"

                        Text {
                            anchors.centerIn: parent

                            text:
                                root.activePlayer !== null &&
                                root.activePlayer.isPlaying
                                ? "Ⅱ"
                                : "▶"

                            color: "#11111b"
                            font.pixelSize: 16
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor

                            onClicked: {
                                root.toggleOrResumeMedia()
                            }
                        }
                    }

                    Rectangle {
                        width: 42
                        height: 34
                        radius: 10
                        color: "#313244"

                        opacity:
                            root.activePlayer !== null &&
                            root.activePlayer.canGoNext
                            ? 1.0
                            : 0.35

                        Text {
                            anchors.centerIn: parent
                            text: "▶"
                            color: "#cdd6f4"
                            font.pixelSize: 15
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor

                            onClicked: {
                                if (
                                    root.activePlayer !== null &&
                                    root.activePlayer.canGoNext
                                ) {
                                    root.activePlayer.next()
                                }
                            }
                        }
                    }
                }

                // Progress / Seek
                Column {
                    width: parent.width
                    spacing: 6

                    Item {
                        id: seekArea

                        width: parent.width
                        height: 14

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter

                            width: parent.width
                            height: 5
                            radius: 3
                            color: "#313244"

                            Rectangle {
                                height: parent.height
                                radius: 3
                                color: "#89b4fa"

                                width:
                                    root.activePlayer !== null &&
                                    root.activePlayer.lengthSupported &&
                                    root.activePlayer.length > 0
                                    ? parent.width *
                                      Math.max(
                                          0,
                                          Math.min(
                                              1,
                                              root.activePlayer.position /
                                              root.activePlayer.length
                                          )
                                      )
                                    : 0
                            }
                        }

                        Rectangle {
                            width: 10
                            height: 10
                            radius: 5
                            color: "#89b4fa"

                            visible:
                                root.activePlayer !== null &&
                                root.activePlayer.lengthSupported &&
                                root.activePlayer.length > 0

                            x:
                                visible
                                ? Math.max(
                                    0,
                                    Math.min(
                                        seekArea.width - width,
                                        (
                                            root.activePlayer.position /
                                            root.activePlayer.length
                                        ) * seekArea.width - width / 2
                                    )
                                  )
                                : 0

                            anchors.verticalCenter: parent.verticalCenter
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape:
                                root.activePlayer !== null &&
                                root.activePlayer.canSeek &&
                                root.activePlayer.positionSupported
                                ? Qt.PointingHandCursor
                                : Qt.ArrowCursor

                            function seekTo(mouseX) {
                                if (
                                    root.activePlayer === null ||
                                    !root.activePlayer.canSeek ||
                                    !root.activePlayer.positionSupported ||
                                    !root.activePlayer.lengthSupported ||
                                    root.activePlayer.length <= 0
                                ) {
                                    return
                                }

                                let ratio = mouseX / width

                                if (ratio < 0)
                                    ratio = 0

                                if (ratio > 1)
                                    ratio = 1

                                root.activePlayer.position =
                                    ratio * root.activePlayer.length
                            }

                            onPressed: mouse => {
                                seekTo(mouse.x)
                            }

                            onPositionChanged: mouse => {
                                if (pressed)
                                    seekTo(mouse.x)
                            }
                        }
                    }

                    Row {
                        width: parent.width

                        Text {
                            width: parent.width / 2

                            text:
                                root.activePlayer !== null &&
                                root.activePlayer.positionSupported
                                ? root.formatTime(
                                    root.activePlayer.position
                                  )
                                : "0:00"

                            color: "#a6adc8"
                            font.pixelSize: 11
                        }

                        Text {
                            width: parent.width / 2
                            horizontalAlignment: Text.AlignRight

                            text:
                                root.activePlayer !== null &&
                                root.activePlayer.lengthSupported
                                ? root.formatTime(
                                    root.activePlayer.length
                                  )
                                : "--:--"

                            color: "#a6adc8"
                            font.pixelSize: 11
                        }
                    }
                }

                // Media source / player selector
                Row {
                    anchors.horizontalCenter:
                        parent.horizontalCenter

                    spacing: 8

                    Rectangle {
                        width: 185
                        height: 28
                        radius: 9
                        color: "#313244"

                        Text {
                            anchors {
                                left: parent.left
                                right: parent.right
                                verticalCenter:
                                    parent.verticalCenter
                                leftMargin: 10
                                rightMargin: 10
                            }

                            elide: Text.ElideRight

                            text:
                                "Source: " +
                                root.mediaSourceLabel()

                            color: "#cdd6f4"
                            font.pixelSize: 11
                        }

                        MouseArea {
                            anchors.fill: parent

                            cursorShape:
                                root.logicalMediaSources().length > 1
                                ? Qt.PointingHandCursor
                                : Qt.ArrowCursor

                            onClicked: {
                                if (
                                    root.logicalMediaSources().length > 1
                                ) {
                                    root.cycleMediaPlayer()
                                }
                            }
                        }
                    }

                    Rectangle {
                        width: 60
                        height: 28
                        radius: 9
                        color: "#313244"

                        visible:
                            root.lastLocalUri !== "" &&
                            (
                                root.activePlayer === null ||
                                !root.playerIsLocal(
                                    root.activePlayer
                                )
                            )

                        Text {
                            anchors.centerIn: parent
                            text: "Local"
                            color: "#cdd6f4"
                            font.pixelSize: 11
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape:
                                Qt.PointingHandCursor

                            onClicked: {
                                root.resumeLocalSession()
                            }
                        }
                    }
                }

                // Local playback mode
                Rectangle {
                    width: 44
                    height: 30
                    radius: 9
                    anchors.horizontalCenter: parent.horizontalCenter
                    color: "#313244"

                    visible:
                        root.activePlayer !== null
                        ? (
                            root.activePlayer.loopSupported ||
                            root.activePlayer.shuffleSupported
                          )
                        : root.lastLocalUri !== ""

                    Text {
                        anchors.centerIn: parent
                        text: root.playbackModeIcon()
                        color: "#cdd6f4"
                        font.pixelSize: 12
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor

                        onClicked: {
                            root.nextPlaybackMode()
                        }
                    }
                }

                // System volume
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 12

                    Rectangle {
                        width: 38
                        height: 30
                        radius: 9
                        color: "#313244"

                        Text {
                            anchors.centerIn: parent
                            text: "−"
                            color: "#cdd6f4"
                            font.pixelSize: 17
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor

                            onClicked: {
                                root.changeVolume(-0.05)
                            }
                        }
                    }

                    Rectangle {
                        width: 84
                        height: 30
                        radius: 9
                        color: "#313244"

                        Text {
                            anchors.centerIn: parent

                            text:
                                root.audioSink !== null &&
                                root.audioSink.audio !== null
                                ? (
                                    root.audioSink.audio.muted
                                    ? "Muted"
                                    : Math.round(
                                        root.audioSink.audio.volume * 100
                                      ) + "%"
                                  )
                                : "--%"

                            color: "#cdd6f4"
                            font.pixelSize: 12
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor

                            onClicked: {
                                if (
                                    root.audioSink !== null &&
                                    root.audioSink.audio !== null
                                ) {
                                    root.audioSink.audio.muted =
                                        !root.audioSink.audio.muted
                                }
                            }
                        }
                    }

                    Rectangle {
                        width: 38
                        height: 30
                        radius: 9
                        color: "#313244"

                        Text {
                            anchors.centerIn: parent
                            text: "+"
                            color: "#cdd6f4"
                            font.pixelSize: 17
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor

                            onClicked: {
                                root.changeVolume(0.05)
                            }
                        }
                    }
                }
            }
        }

        FrameAnimation {
            running:
                mediaPopup.visible &&
                root.activePlayer !== null &&
                root.activePlayer.isPlaying

            onTriggered: {
                if (
                    root.activePlayer !== null &&
                    root.activePlayer.positionSupported
                ) {
                    root.activePlayer.positionChanged()
                }
            }
        }
    }

}
