import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import QtQuick

PanelWindow {
    id: root

    anchors {
        top: true
    }

    // Adaptive bar width.
    //
    // The larger side is mirrored mathematically so that
    // workspaceSection always stays in the TRUE center.
    //
    // 14px outer margin + 16px safety gap on each side.
    implicitWidth:
        Math.ceil(
            workspaceSection.implicitWidth +
            2 * Math.max(
                leftSection.implicitWidth,
                rightSection.implicitWidth
            ) +
            60
        )

    implicitHeight: 48
    color: "transparent"

    // Normally Red Core must never steal keyboard focus.
    // Enable it only while an interactive popup needs typing.
    focusable:
        networkModule.keyboardInputActive

    property var workspaces: []
    property int activeWorkspace: -1

    // Keyboard layout state from Niri.
    property var keyboardLayouts: []
    property int keyboardLayoutIndex: 0

    RedCoreService {
        id: redCoreService
    }

    function keyboardLayoutLabel() {
        if (
            root.keyboardLayoutIndex < 0 ||
            root.keyboardLayoutIndex >=
                root.keyboardLayouts.length
        ) {
            return "--"
        }

        const name =
            String(
                root.keyboardLayouts[
                    root.keyboardLayoutIndex
                ] || ""
            ).toLowerCase()

        if (name.indexOf("french") !== -1)
            return "FR"

        if (name.indexOf("arabic") !== -1)
            return "AR"

        // Generic fallback for future layouts.
        return String(
            root.keyboardLayouts[
                root.keyboardLayoutIndex
            ] || "--"
        )
        .slice(0, 2)
        .toUpperCase()
    }

    // Number of workspace buttons shown at once.
    // Later this can become a Control Center setting.
    property int visibleWorkspaceCount: 5

    function visibleWorkspaces() {
        const all =
            root.workspaces || []

        const count =
            root.visibleWorkspaceCount

        if (all.length <= count)
            return all

        let activeIndex = -1

        for (
            let i = 0;
            i < all.length;
            i++
        ) {
            if (
                all[i].id ===
                root.activeWorkspace
            ) {
                activeIndex = i
                break
            }
        }

        // Fallback to the beginning if active workspace
        // has not been resolved yet.
        if (activeIndex < 0)
            activeIndex = 0

        const half =
            Math.floor(count / 2)

        let start =
            activeIndex - half

        if (start < 0)
            start = 0

        const maxStart =
            all.length - count

        if (start > maxStart)
            start = maxStart

        return all.slice(
            start,
            start + count
        )
    }

    // Niri windows used by the workspace app indicators.
    property var niriWindows: []

    // Generic application icon cache.
    // app_id -> resolved image URI.
    property var appIconCache: ({})
    property var pendingAppIcons: ({})

    // window id -> TUI app detected inside a terminal.
    // Empty string means: use terminal's own app_id.
    property var terminalAppCache: ({})

    // Tracks whether a terminal window has received at least
    // one valid foreground-app scan.
    //
    // Until then we always use the terminal's own app_id,
    // preventing stale TUI icons from flashing on new windows.
    property var terminalAppReady: ({})

    // Window id -> first-seen timestamp.
    // A brand-new terminal must show its REAL terminal icon
    // while its shell/startup processes are still settling.
    property var windowFirstSeen: ({})

    function windowStartupGuardActive(window) {
        if (
            window === null ||
            window === undefined
        ) {
            return false
        }

        const id = String(window.id)
        const born = root.windowFirstSeen[id]

        if (
            born === undefined ||
            born === null
        ) {
            return false
        }

        return (
            Date.now() - Number(born)
        ) < 400
    }

    function effectiveWindowAppId(window) {
        if (
            window === null ||
            window === undefined
        ) {
            return ""
        }

        const windowId =
            String(window.id)

        // A new terminal may briefly spawn shell/prompt
        // helper processes. Never allow those to become the
        // displayed application icon.
        if (
            root.windowStartupGuardActive(window)
        ) {
            return String(
                window.app_id || ""
            )
        }

        const ready =
            root.terminalAppReady[windowId] ===
            true

        if (ready) {
            const detected =
                root.terminalAppCache[windowId]

            if (
                detected !== undefined &&
                detected !== null &&
                String(detected) !== ""
            ) {
                const detectedId =
                    String(detected)

                // A CLI process must have a REAL resolved icon
                // before it may replace the terminal icon.
                //
                // This prevents pacman/makepkg/yay/build tools
                // and other commands from displaying unrelated
                // application icons.
                const resolved =
                    root.appIconCache[detectedId]

                // IMPORTANT:
                // effectiveWindowAppId() is used inside a QML
                // binding and MUST stay completely side-effect free.
                //
                // The Terminal scanner resolves detected application
                // icons separately when an event arrives.
                if (
                    resolved !== undefined &&
                    resolved !== null &&
                    String(resolved) !== ""
                ) {
                    return detectedId
                }
            }
        }

        // New/unchecked terminal windows immediately use
        // their real terminal app icon.
        return String(
            window.app_id || ""
        )
    }

    function appsForWorkspace(workspaceId) {
        const windows = []
        const apps = []
        const seen = ({})

        // First collect all windows from this workspace.
        for (
            let i = 0;
            i < root.niriWindows.length;
            i++
        ) {
            const window =
                root.niriWindows[i]

            if (
                window.workspace_id === workspaceId
            ) {
                windows.push(window)
            }
        }

        // Match Niri's real visual order.
        //
        // pos_in_scrolling_layout is typically:
        // [column, tile]
        //
        // Sort by column first, then tile position.
        windows.sort(
            function(a, b) {
                const aPos =
                    a.layout &&
                    a.layout.pos_in_scrolling_layout
                    ? a.layout.pos_in_scrolling_layout
                    : null

                const bPos =
                    b.layout &&
                    b.layout.pos_in_scrolling_layout
                    ? b.layout.pos_in_scrolling_layout
                    : null

                const aColumn =
                    aPos && aPos.length > 0
                    ? Number(aPos[0])
                    : Number.MAX_SAFE_INTEGER

                const bColumn =
                    bPos && bPos.length > 0
                    ? Number(bPos[0])
                    : Number.MAX_SAFE_INTEGER

                if (aColumn !== bColumn)
                    return aColumn - bColumn

                const aTile =
                    aPos && aPos.length > 1
                    ? Number(aPos[1])
                    : Number.MAX_SAFE_INTEGER

                const bTile =
                    bPos && bPos.length > 1
                    ? Number(bPos[1])
                    : Number.MAX_SAFE_INTEGER

                if (aTile !== bTile)
                    return aTile - bTile

                // Stable deterministic fallback.
                return Number(a.id || 0) -
                       Number(b.id || 0)
            }
        )

        // Only after sorting do we remove duplicate app ids.
        //
        // This means if multiple windows belong to the same app,
        // the icon represents the first visible occurrence of that
        // app in Niri's layout.
        for (
            let i = 0;
            i < windows.length;
            i++
        ) {
            const window =
                windows[i]

            const appId =
                root.effectiveWindowAppId(
                    window
                )

            if (
                appId === "" ||
                seen[appId] === true
            ) {
                continue
            }

            seen[appId] = true

            apps.push({
                "app_id": appId,
                "title": window.title || ""
            })
        }

        return apps
    }

    function desktopIconName(appId) {
        if (!appId)
            return ""

        try {
            const entry =
                DesktopEntries.heuristicLookup(
                    appId
                )

            if (
                entry !== null &&
                entry.icon !== ""
            ) {
                return entry.icon
            }
        } catch (error) {
        }

        return ""
    }

    function requestAppIcon(appId) {
        if (!appId)
            return

        // Already resolved, including an intentional
        // empty fallback result.
        if (
            root.appIconCache[appId] !==
            undefined
        ) {
            return
        }

        // This exact app is already being resolved.
        if (
            root.pendingAppIcons[appId] ===
            true
        ) {
            return
        }

        const iconName =
            root.desktopIconName(appId)

        // First try Quickshell / Qt icon theme.
        // check=true prevents the purple missing texture.
        if (iconName !== "") {
            const themed =
                Quickshell.iconPath(
                    iconName,
                    true
                )

            if (themed !== "") {
                let cache =
                    Object.assign(
                        {},
                        root.appIconCache
                    )

                cache[appId] = themed
                root.appIconCache = cache
                return
            }
        }

        // IMPORTANT:
        // If the shared resolver is already working,
        // do NOT mark this app as pending yet.
        //
        // Once the current lookup finishes,
        // processNextAppIcon() will pick this one.
        if (appIconResolver.running)
            return

        let pending =
            Object.assign(
                {},
                root.pendingAppIcons
            )

        pending[appId] = true
        root.pendingAppIcons = pending

        root.appIconResolverAppId =
            appId

        root.appIconResolverIconName =
            iconName

        appIconResolver.command = [
            "redcore-app-icon",
            appId,
            iconName
        ]

        appIconResolver.running = true
    }

    function processNextAppIcon() {
        if (appIconResolver.running)
            return

        const seen = ({})

        for (
            let i = 0;
            i < root.niriWindows.length;
            i++
        ) {
            const appId =
                String(
                    root.niriWindows[i].app_id ||
                    ""
                )

            if (
                appId === "" ||
                seen[appId] === true
            ) {
                continue
            }

            seen[appId] = true

            if (
                root.appIconCache[appId] ===
                    undefined &&
                root.pendingAppIcons[appId] !==
                    true
            ) {
                root.requestAppIcon(appId)

                if (appIconResolver.running)
                    return
            }
        }
    }

    function iconForApp(appId) {
        if (!appId)
            return ""

        const cached =
            root.appIconCache[appId]

        if (
            cached === undefined ||
            cached === null
        ) {
            return ""
        }

        return String(cached)
    }

    function windowsForWorkspace(workspaceId) {
        const result = []

        for (let i = 0; i < root.niriWindows.length; i++) {
            const window = root.niriWindows[i]

            if (window.workspace_id === workspaceId)
                result.push(window)
        }

        return result
    }

    function updateNiriWindow(window) {
        if (
            window === null ||
            window === undefined
        ) {
            return
        }

        let list = root.niriWindows.slice()
        let found = false

        for (let i = 0; i < list.length; i++) {
            if (list[i].id === window.id) {
                list[i] = window
                found = true
                break
            }
        }

        if (!found)
            list.push(window)

        root.niriWindows = list
    }

    function removeNiriWindow(windowId) {
        let list = []

        for (let i = 0; i < root.niriWindows.length; i++) {
            if (root.niriWindows[i].id !== windowId)
                list.push(root.niriWindows[i])
        }

        root.niriWindows = list
    }

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

    // Compact media state:
    // playing -> expanded immediately
    // paused/stopped -> remain expanded for 60 seconds
    // idle -> music icon only
    property bool mediaExpanded: false

    // On Red Core startup, Media always begins compact.
    // It expands only after a real playback event occurs.
    property bool mediaStartupReady: false

    function updateMediaBarState() {
        const player = root.activePlayer

        // Startup state is always compact.
        // The first actual playback change enables normal behavior.
        if (!root.mediaStartupReady) {
            root.mediaExpanded = false
            return
        }

        if (
            player !== null &&
            player.isPlaying
        ) {
            mediaCollapseTimer.stop()
            root.mediaExpanded = true
            return
        }

        // If the media bar was visible and playback stopped,
        // keep it available for 60 seconds.
        if (root.mediaExpanded) {
            mediaCollapseTimer.restart()
            return
        }

        // No active playback on startup.
        root.mediaExpanded = false
    }

    Timer {
        id: mediaCollapseTimer

        interval: 60000
        repeat: false

        onTriggered: {
            const player = root.activePlayer

            if (
                player === null ||
                !player.isPlaying
            ) {
                root.mediaExpanded = false
            }
        }
    }

    // activePlayer itself can change when switching
    // Local / Brave / Spotify / etc.
    Connections {
        target: root

        function onActivePlayerChanged() {
            Qt.callLater(
                root.updateMediaBarState
            )
        }
    }

    // Playback state changed on the current player.
    Connections {
        target: root.activePlayer
        ignoreUnknownSignals: true

        function onIsPlayingChanged() {
            root.mediaStartupReady = true
            root.updateMediaBarState()
        }

        function onPlaybackStateChanged() {
            root.mediaStartupReady = true
            root.updateMediaBarState()
        }
    }

    // Empty = automatic player selection.
    property string pinnedPlayerDbusName: ""

    // If a state write is already running, remember that
    // another save is needed instead of losing the update.
    property bool localStateSavePending: false

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

    function chooseMediaPlayer(preferredPlayer) {
        const players = Mpris.players.values

        // ----------------------------------------------------
        // 1. A player has just started playback.
        //    It wins immediately and silences the others.
        // ----------------------------------------------------
        if (
            preferredPlayer !== null &&
            preferredPlayer !== undefined &&
            preferredPlayer.isPlaying
        ) {
            root.pauseOtherPlayers(
                preferredPlayer.dbusName
            )

            root.pinnedPlayerDbusName =
                preferredPlayer.dbusName

            root.rememberPlayer(
                preferredPlayer
            )

            return
        }

        // ----------------------------------------------------
        // 2. Keep selected player if it is currently playing.
        // ----------------------------------------------------
        if (
            root.pinnedPlayerDbusName !== ""
        ) {
            const pinned =
                root.findPlayer(
                    root.pinnedPlayerDbusName
                )

            if (
                pinned !== null &&
                pinned.isPlaying
            ) {
                root.rememberPlayer(pinned)
                return
            }
        }

        // ----------------------------------------------------
        // 3. Find any player actually playing.
        // ----------------------------------------------------
        for (
            let i = 0;
            i < players.length;
            i++
        ) {
            if (players[i].isPlaying) {
                root.pauseOtherPlayers(
                    players[i].dbusName
                )

                root.pinnedPlayerDbusName =
                    players[i].dbusName

                root.rememberPlayer(
                    players[i]
                )

                return
            }
        }

        // ----------------------------------------------------
        // 4. Keep pinned paused/stopped session.
        // ----------------------------------------------------
        if (
            root.pinnedPlayerDbusName !== ""
        ) {
            const pinned =
                root.findPlayer(
                    root.pinnedPlayerDbusName
                )

            if (
                pinned !== null &&
                root.playerUsable(pinned)
            ) {
                root.rememberPlayer(pinned)
                return
            }

            root.pinnedPlayerDbusName = ""
        }

        // ----------------------------------------------------
        // 5. Keep last-used session if still available.
        // ----------------------------------------------------
        const remembered =
            root.findPlayer(
                root.lastPlayerDbusName
            )

        if (
            remembered !== null &&
            root.playerUsable(remembered)
        ) {
            root.rememberPlayer(
                remembered
            )
            return
        }

        // ----------------------------------------------------
        // 6. Any usable paused MPRIS session.
        // ----------------------------------------------------
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

        // ----------------------------------------------------
        // 7. Nothing live.
        //    Keep Local metadata as fallback only.
        // ----------------------------------------------------
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

    function handleMediaPlaybackEvent(player) {
        if (
            player === null ||
            player === undefined
        ) {
            root.chooseMediaPlayer(null)
            return
        }

        // Playing source becomes active immediately.
        if (player.isPlaying) {
            root.chooseMediaPlayer(player)
        } else {
            // Save Local position immediately on Pause/Stop.
            if (
                root.playerIsLocal(player)
            ) {
                root.rememberPlayer(player)
                root.saveLocalMediaState()
            }

            root.chooseMediaPlayer(null)
        }

        root.updateMediaBarState()
    }

    function handleMediaTrackEvent(player) {
        if (
            player === null ||
            player === undefined
        ) {
            return
        }

        root.rememberPlayer(player)

        if (
            root.playerIsLocal(player)
        ) {
            // New track = important persistent state change.
            root.saveLocalMediaState()
        }

        if (player.isPlaying) {
            root.chooseMediaPlayer(player)
        }
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
            root.lastLocalUri === ""
        ) {
            return
        }

        if (localStateSave.running) {
            root.localStateSavePending = true
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

        onExited: {
            if (
                root.localStateSavePending
            ) {
                root.localStateSavePending =
                    false

                Qt.callLater(
                    root.saveLocalMediaState
                )
            }
        }
    }


    // Crash/power-loss protection for Local Music.
    //
    // This timer is completely stopped unless a LOCAL track
    // is actually playing. One state checkpoint per minute.
    Timer {
        id: localMediaCheckpoint

        interval: 60000
        repeat: true

        running:
            root.activePlayer !== null &&
            root.playerIsLocal(
                root.activePlayer
            ) &&
            root.activePlayer.isPlaying

        onTriggered: {
            root.saveLocalMediaState()
        }
    }

    // =========================
    // EVENT-DRIVEN MPRIS
    // =========================

    Instantiator {
        id: mediaPlayerObservers

        model: Mpris.players

        delegate: Scope {
            required property var modelData

            property var player:
                modelData

            Component.onCompleted: {
                Qt.callLater(
                    function() {
                        root.chooseMediaPlayer(
                            player.isPlaying
                            ? player
                            : null
                        )
                    }
                )
            }

            Component.onDestruction: {
                root.chooseMediaPlayer(
                    null
                )
            }

            Connections {
                target: player
                ignoreUnknownSignals: true

                function onPlaybackStateChanged() {
                    root.handleMediaPlaybackEvent(
                        player
                    )
                }

                function onTrackChanged() {
                    // trackChanged happens before all friendly
                    // metadata helpers are guaranteed settled.
                    // Wait one event-loop turn.
                    Qt.callLater(
                        function() {
                            root.handleMediaTrackEvent(
                                player
                            )
                        }
                    )
                }

                function onPostTrackChanged() {
                    // Some players update artwork/metadata late.
                    if (
                        root.activePlayer !== null &&
                        root.activePlayer.dbusName ===
                            player.dbusName
                    ) {
                        root.rememberPlayer(
                            player
                        )
                    }
                }
            }
        }
    }

    // =========================
    // NIRI WORKSPACES
    // =========================

    property string appIconResolverAppId: ""
    property string appIconResolverIconName: ""

    Process {
        id: appIconResolver

        stdout: StdioCollector {
            onStreamFinished: {
                const appId =
                    root.appIconResolverAppId

                const result =
                    this.text.trim()

                if (appId !== "") {
                    let cache =
                        Object.assign(
                            {},
                            root.appIconCache
                        )

                    cache[appId] = result
                    root.appIconCache = cache

                    let pending =
                        Object.assign(
                            {},
                            root.pendingAppIcons
                        )

                    delete pending[appId]

                    root.pendingAppIcons =
                        pending
                }
            }
        }

        onExited: {
            root.appIconResolverAppId = ""
            root.appIconResolverIconName = ""

            // Wait until running has become false,
            // then resolve the next application.
            Qt.callLater(
                root.processNextAppIcon
            )
        }
    }

    // Terminal foreground application scanner.
    //
    // Niri tracks windows immediately through event-stream.
    // This small scan only handles the application running
    // INSIDE terminal windows, because a TUI may change
    // without generating a Niri window event.
    function scanTerminalAppsNow() {
        if (terminalAppScanner.running)
            return

        terminalAppScanner.command = [
            "redcore-terminal-scan",
            JSON.stringify(
                root.niriWindows
            )
        ]

        terminalAppScanner.running = true
    }

    property int terminalEventPid: 0

    IpcHandler {
        target: "redcoreTerminal"

        function changed(pid: int): void {
            root.terminalEventPid = pid

            // preexec happens just before the child process
            // starts. A tiny one-shot delay lets /proc settle.
            terminalEventScanDelay.restart()
        }
    }

    Timer {
        id: terminalEventScanDelay

        interval: 40
        repeat: false
        running: false

        onTriggered: {
            root.scanTerminalAppsNow()
        }
    }

    Process {
        id: terminalAppScanner

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const result =
                        JSON.parse(this.text)

                    if (
                        result !== null &&
                        typeof result === "object"
                    ) {
                        root.terminalAppCache =
                            result

                        let ready =
                            Object.assign(
                                {},
                                root.terminalAppReady
                            )

                        for (
                            const windowId
                            in result
                        ) {
                            ready[windowId] = true

                            const appId =
                                String(
                                    result[windowId] ||
                                    ""
                                )

                            if (appId !== "") {
                                root.requestAppIcon(
                                    appId
                                )
                            }
                        }

                        root.terminalAppReady =
                            ready
                    }
                } catch (error) {
                    console.log(
                        "Terminal scan parse error:",
                        error
                    )
                }
            }
        }
    }


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

                    // Keyboard layouts full snapshot/config change.
                    if (event.KeyboardLayoutsChanged) {
                        const wrapper =
                            event.KeyboardLayoutsChanged

                        const data =
                            wrapper.keyboard_layouts || {}

                        root.keyboardLayouts =
                            data.names || []

                        if (
                            data.current_idx !== undefined
                        ) {
                            root.keyboardLayoutIndex =
                                data.current_idx
                        }
                    }

                    // Active keyboard layout changed.
                    if (event.KeyboardLayoutSwitched) {
                        const data =
                            event.KeyboardLayoutSwitched

                        if (
                            data.idx !== undefined
                        ) {
                            root.keyboardLayoutIndex =
                                data.idx
                        }
                    }

                    // Full window snapshot.
                    if (event.WindowsChanged) {
                        root.niriWindows =
                            event.WindowsChanged.windows || []

                        Qt.callLater(
                            root.processNextAppIcon
                        )

                        Qt.callLater(
                            root.scanTerminalAppsNow
                        )
                    }

                    // Opened window, changed title/app-id,
                    // or moved between workspaces.
                    if (event.WindowOpenedOrChanged) {
                        const window =
                            event.WindowOpenedOrChanged.window

                        const windowId =
                            String(window.id)

                        if (
                            root.windowFirstSeen[windowId] ===
                            undefined
                        ) {
                            let firstSeen =
                                Object.assign(
                                    {},
                                    root.windowFirstSeen
                                )

                            firstSeen[windowId] =
                                Date.now()

                            root.windowFirstSeen =
                                firstSeen
                        }

                        root.updateNiriWindow(
                            window
                        )

                        // Never allow an old terminal foreground
                        // application result to leak into a new
                        // or changed Niri window state.
                        let ready =
                            Object.assign(
                                {},
                                root.terminalAppReady
                            )

                        ready[windowId] = false
                        root.terminalAppReady = ready

                        // A terminal title/process may have changed.
                        // Scan immediately.
                        Qt.callLater(
                            root.scanTerminalAppsNow
                        )
                        if (
                            window !== null &&
                            window !== undefined
                        ) {
                            root.requestAppIcon(
                                String(
                                    window.app_id || ""
                                )
                            )
                        }
                    }

                    // Window positions/layout changed inside Niri.
                    //
                    // This is separate from WindowOpenedOrChanged:
                    // moving columns left/right may only update layout.
                    if (event.WindowLayoutsChanged) {
                        const payload =
                            event.WindowLayoutsChanged

                        const changes =
                            payload.changes ||
                            payload.layouts ||
                            payload.windows ||
                            payload

                        let list =
                            root.niriWindows.slice()

                        function applyLayout(
                            windowId,
                            layout
                        ) {
                            for (
                                let i = 0;
                                i < list.length;
                                i++
                            ) {
                                if (
                                    String(list[i].id) !==
                                    String(windowId)
                                ) {
                                    continue
                                }

                                const updated =
                                    Object.assign(
                                        {},
                                        list[i]
                                    )

                                updated.layout =
                                    layout

                                list[i] =
                                    updated

                                return
                            }
                        }

                        if (
                            Array.isArray(changes)
                        ) {
                            for (
                                let i = 0;
                                i < changes.length;
                                i++
                            ) {
                                const item =
                                    changes[i]

                                if (
                                    item === null ||
                                    item === undefined
                                ) {
                                    continue
                                }

                                if (
                                    item.id !== undefined &&
                                    item.layout !== undefined
                                ) {
                                    applyLayout(
                                        item.id,
                                        item.layout
                                    )
                                    continue
                                }

                                if (
                                    Array.isArray(item) &&
                                    item.length >= 2
                                ) {
                                    applyLayout(
                                        item[0],
                                        item[1]
                                    )
                                }
                            }

                        } else if (
                            changes !== null &&
                            typeof changes === "object"
                        ) {
                            for (
                                const id in changes
                            ) {
                                const value =
                                    changes[id]

                                if (
                                    value &&
                                    value.layout !== undefined
                                ) {
                                    applyLayout(
                                        id,
                                        value.layout
                                    )
                                } else {
                                    applyLayout(
                                        id,
                                        value
                                    )
                                }
                            }
                        }

                        // Important:
                        // assign a NEW array so QML bindings such as
                        // workspaceApps are reevaluated immediately.
                        root.niriWindows =
                            list
                    }

                    // Closed window.
                    if (event.WindowClosed) {
                        const id =
                            String(
                                event.WindowClosed.id
                            )

                        root.removeNiriWindow(
                            event.WindowClosed.id
                        )

                        let terminalCache =
                            Object.assign(
                                {},
                                root.terminalAppCache
                            )

                        delete terminalCache[id]

                        root.terminalAppCache =
                            terminalCache

                        let ready =
                            Object.assign(
                                {},
                                root.terminalAppReady
                            )

                        delete ready[id]

                        root.terminalAppReady =
                            ready

                        let firstSeen =
                            Object.assign(
                                {},
                                root.windowFirstSeen
                            )

                        delete firstSeen[id]

                        root.windowFirstSeen =
                            firstSeen
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

    Process {
        id: keyboardLayoutSwitch
    }

    // =========================
    // SYSTEM INFO
    // =========================

    // One persistent monitor process.
    // Hardware detection happens once in the backend,
    // then real measurements are streamed every second.
    Process {
        id: systemInfoProcess

        running: true

        command: [
            "redcore-system-monitor"
        ]

        stdout: SplitParser {
            onRead: line => {
                try {
                    const data =
                        JSON.parse(line)

                    root.cpuUsage =
                        data.cpu

                    root.cpuTemp =
                        data.cpuTemp

                    root.ramUsage =
                        data.ram

                    root.gpuUsage =
                        data.gpuUsage

                    root.gpuVendor =
                        data.gpuVendor

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
                        "System monitor parse error:",
                        error
                    )
                }
            }
        }

        // If the backend crashes unexpectedly,
        // retry once after a short delay.
        onRunningChanged: {
            if (!running) {
                systemMonitorRestart.restart()
            }
        }
    }

    Timer {
        id: systemMonitorRestart

        interval: 2000
        repeat: false

        onTriggered: {
            if (!systemInfoProcess.running) {
                systemInfoProcess.running =
                    true
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

    // NetworkManager state.

    // Nearby Wi-Fi networks.
    // Updated only when requested, never continuously.

    // Wi-Fi connection UI.





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
            id: leftSection

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
            //
            // Reserve a stable area for changing numeric values.
            // CPU/GPU/network updates must never resize the whole bar.
            Row {
                width: 330
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

                width:
                    root.mediaExpanded
                    ? 230
                    : 32

                height: 32

                // Compact idle state.
                Rectangle {
                    anchors.fill: parent

                    radius: 9
                    color: "#313244"

                    visible:
                        !root.mediaExpanded

                    Text {
                        anchors.centerIn: parent
                        text: "♪"
                        color: "#89b4fa"
                        font.pixelSize: 16
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape:
                            Qt.PointingHandCursor

                        onClicked: {
                            // If remembered media exists,
                            // opening the popup still works
                            // from compact mode.
                            if (
                                root.activePlayer !== null ||
                                root.lastMediaTitle !== ""
                            ) {
                                mediaPopup.visible =
                                    !mediaPopup.visible
                            }
                        }
                    }
                }

                Row {
                    anchors.centerIn: parent
                    spacing: 6

                    visible:
                        root.mediaExpanded

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
            id: workspaceSection

            anchors.centerIn: parent
            spacing: 10

            Repeater {
                model:
                    root.visibleWorkspaces()

                Rectangle {
                    id: workspaceItem

                    required property var modelData

                    property var workspaceApps:
                        root.appsForWorkspace(
                            modelData.id
                        )

                    property int shownApps:
                        Math.min(
                            3,
                            workspaceApps.length
                        )

                    property int hiddenApps:
                        Math.max(
                            0,
                            workspaceApps.length - 3
                        )

                    width:
                        workspaceApps.length === 0
                        ? 32
                        : (
                            36 +
                            shownApps * 20 +
                            (
                                hiddenApps > 0
                                ? 26
                                : 0
                            )
                          )

                    height: 32
                    radius: 10

                    color:
                        root.activeWorkspace ===
                        modelData.id
                        ? "#89b4fa"
                        : "#313244"

                    Row {
                        anchors.centerIn: parent
                        spacing: 5

                        Text {
                            width: 18

                            anchors.verticalCenter:
                                parent.verticalCenter

                            horizontalAlignment:
                                Text.AlignHCenter

                            text:
                                workspaceItem.modelData.idx

                            color:
                                root.activeWorkspace ===
                                workspaceItem.modelData.id
                                ? "#11111b"
                                : "#cdd6f4"

                            font.pixelSize: 13
                        }

                        Repeater {
                            model:
                                workspaceItem.workspaceApps
                                    .slice(
                                        0,
                                        3
                                    )

                            Item {
                                id: appIconItem

                                required property var modelData

                                property string appId:
                                    String(
                                        modelData.app_id ||
                                        ""
                                    )

                                property string resolvedIcon:
                                    root.iconForApp(
                                        appIconItem.appId
                                    )

                                width: 18
                                height: 22

                                Component.onCompleted: {
                                    root.requestAppIcon(
                                        appIconItem.appId
                                    )
                                }

                                onAppIdChanged: {
                                    root.requestAppIcon(
                                        appIconItem.appId
                                    )
                                }

                                IconImage {
                                    anchors.centerIn: parent

                                    implicitSize: 16

                                    source:
                                        appIconItem.resolvedIcon

                                    visible:
                                        appIconItem.resolvedIcon !== ""
                                }

                                Text {
                                    anchors.centerIn: parent

                                    visible:
                                        appIconItem.resolvedIcon === ""

                                    text:
                                        appIconItem.appId !== ""
                                        ? appIconItem.appId
                                            .charAt(0)
                                            .toUpperCase()
                                        : "?"

                                    color:
                                        root.activeWorkspace ===
                                        workspaceItem.modelData.id
                                        ? "#11111b"
                                        : "#cdd6f4"

                                    font.pixelSize: 10
                                    font.bold: true
                                }
                            }
                        }

                        Text {
                            visible:
                                workspaceItem.hiddenApps > 0

                            anchors.verticalCenter:
                                parent.verticalCenter

                            text:
                                "+" +
                                workspaceItem.hiddenApps

                            color:
                                root.activeWorkspace ===
                                workspaceItem.modelData.id
                                ? "#11111b"
                                : "#cdd6f4"

                            font.pixelSize: 10
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape:
                            Qt.PointingHandCursor

                        onClicked: {
                            workspaceSwitch.command = [
                                "niri",
                                "msg",
                                "action",
                                "focus-workspace",
                                String(
                                    workspaceItem.modelData.idx
                                )
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
            id: rightSection

            anchors {
                right: parent.right
                rightMargin: 14
                verticalCenter: parent.verticalCenter
            }

            spacing: 10

            // ---------------------
            // Alerts
            // ---------------------
            Rectangle {
                width: 32
                height: 32
                radius: 10
                color: "#313244"

                Text {
                    anchors.centerIn: parent
                    text: "!"
                    color: "#cdd6f4"
                    font.pixelSize: 13
                    font.bold: true
                }
            }

            // ---------------------
            // Audio
            // ---------------------
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

            // ---------------------
            // Keyboard layout
            // ---------------------
            Rectangle {
                width: 38
                height: 32
                radius: 10
                color: "#313244"

                Text {
                    anchors.centerIn: parent

                    text:
                        root.keyboardLayoutLabel()

                    color: "#cdd6f4"
                    font.pixelSize: 12
                    font.bold: true
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor

                    onClicked: {
                        if (
                            !keyboardLayoutSwitch.running
                        ) {
                            keyboardLayoutSwitch.command = [
                                "niri",
                                "msg",
                                "action",
                                "switch-layout",
                                "next"
                            ]

                            keyboardLayoutSwitch.running =
                                true
                        }
                    }
                }
            }

            // ---------------------
            // Network
            // ---------------------
            NetworkModule {
                id: networkModule
                popupCoordinator: redCoreService
            }

            // ---------------------
            // Bluetooth
            // ---------------------
            BluetoothModule {
                id: bluetoothModule
                service: redCoreService
            }

            // ---------------------
            // Battery
            // ---------------------
            BatteryModule {
                id: batteryModule
                service: redCoreService
            }

            // ---------------------
            // Brightness (functional layout; design later)
            // ---------------------
            BrightnessModule {
                id: brightnessModule
                service: redCoreService
            }

            // ---------------------
            // Weather + Date/Time
            // ---------------------
            Rectangle {
                height: 32
                width: weatherTimeRow.implicitWidth + 20
                radius: 10
                color: "#313244"

                Row {
                    id: weatherTimeRow

                    anchors.centerIn: parent
                    spacing: 8

                    // Weather placeholder
                    Text {
                        text: "--°"
                        color: "#cdd6f4"
                        font.pixelSize: 12
                    }

                    Text {
                        text:
                            Qt.formatDateTime(
                                clock.date,
                                "dd/MM"
                            )

                        color: "#cdd6f4"
                        font.pixelSize: 12
                    }

                    Text {
                        text:
                            Qt.formatDateTime(
                                clock.date,
                                "HH:mm"
                            )

                        color: "#cdd6f4"
                        font.pixelSize: 12
                    }
                }
            }

            // ---------------------
            // Power
            // ---------------------
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

                            onReleased: {
                                if (
                                    root.activePlayer !== null &&
                                    root.playerIsLocal(
                                        root.activePlayer
                                    )
                                ) {
                                    root.saveLocalMediaState()
                                }
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
