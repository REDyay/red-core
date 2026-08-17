import Quickshell
import Quickshell.Io
import QtQuick

Item {
    id: service

    visible: false
    width: 0
    height: 0

    readonly property bool useBluetoothSimulation:
        true

    readonly property bool useBatterySimulation:
        true

    readonly property bool useBrightnessSimulation:
        false

    property int restartDelay: 1500
    property string activePopup: ""
    property string pendingPopup: ""

    readonly property int maximumRestartDelay:
        60000

    readonly property bool running:
        daemonProcess.running

    property bool bluetoothServiceAvailable: false
    property bool bluetoothSimulated: false
    property var bluetoothAdapters: []
    property var bluetoothDevices: []

    property bool batteryServiceAvailable: false
    property bool batteryAvailable: false
    property bool batterySimulated: false
    property string batterySource: "none"
    property int batteryCount: 0
    property int batteryPercentage: 0
    property bool batteryPercentageKnown: false
    property string batteryStatus: "unavailable"
    property var batteryTimeToEmptySeconds: null
    property var batteryTimeToFullSeconds: null
    property var batteryEnergyRateWatts: null
    property var batteryHealthPercentage: null
    property bool powerProfilesAvailable: false
    property string activePowerProfile: ""
    property var powerProfiles: []
    property string performanceDegraded: ""

    property bool brightnessServiceAvailable: false
    property bool brightnessAvailable: false
    property bool brightnessSimulated: false
    property bool brightnessctlAvailable: false
    property bool ddcutilAvailable: false
    property var brightnessDisplays: []

    // System metrics share this one Rust process with the hardware modules.
    property bool systemMonitorServiceAvailable: false
    property int systemMonitorCpuUsage: 0
    property var systemMonitorCpuTemp: null
    property int systemMonitorRamUsage: 0
    property string systemMonitorGpuName: "Unknown"
    property string systemMonitorGpuVendor: "unknown"
    property var systemMonitorGpuUsage: null
    property string systemMonitorNetworkInterface: ""
    property string systemMonitorNetworkType: "none"
    property int systemMonitorDownloadSpeed: 0
    property int systemMonitorUploadSpeed: 0

    // Niri workspace/window state is owned by the same Rust service.
    property bool workspacesServiceAvailable: false
    property bool workspacesAvailable: false
    property var workspaces: []
    property int activeWorkspace: -1
    property var workspaceWindows: []
    property var keyboardLayouts: []
    property int keyboardLayoutIndex: 0

    readonly property string daemonLauncher:
        "daemon=\"${REDCORE_DAEMON:-}\"; " +
        "if [ -z \"$daemon\" ] && [ -x \"$HOME/.local/lib/red-core/redcore-daemon\" ]; then " +
        "daemon=\"$HOME/.local/lib/red-core/redcore-daemon\"; fi; " +
        "if [ -z \"$daemon\" ]; then daemon=\"$(command -v redcore-daemon || true)\"; fi; " +
        "if [ -z \"$daemon\" ] && [ -x \"$HOME/red-core/rust/redcore-daemon/target/release/redcore-daemon\" ]; then " +
        "daemon=\"$HOME/red-core/rust/redcore-daemon/target/release/redcore-daemon\"; fi; " +
        "if [ -z \"$daemon\" ]; then " +
        "daemon=\"$HOME/red-core/rust/redcore-daemon/target/debug/redcore-daemon\"; fi; " +
        "if [ ! -x \"$daemon\" ]; then echo \"Red Core daemon not found: $daemon\" >&2; exit 127; fi; " +
        "exec \"$daemon\" \"$@\""

    readonly property var daemonArguments: {
        const arguments = []

        if (service.useBluetoothSimulation)
            arguments.push("--simulate-bluetooth")

        if (service.useBatterySimulation)
            arguments.push("--simulate-battery")

        if (service.useBrightnessSimulation)
            arguments.push("--simulate-brightness")

        return arguments
    }

    signal bluetoothActionResult(var data)
    signal batteryActionResult(var data)
    signal brightnessActionResult(var data)
    signal workspacesStateEvent(var data)
    signal workspacesActionResult(var data)
    signal appIconResult(var data)
    signal terminalAppsResult(var data)


    function sendCommand(data) {
        if (!daemonProcess.running)
            return false

        daemonProcess.write(
            JSON.stringify(data) + "\n"
        )

        return true
    }


    function togglePopup(name) {
        const popup = String(name || "")

        if (
            popup === "" ||
            service.activePopup === popup ||
            service.pendingPopup === popup
        ) {
            service.closePopup(popup)
            return
        }

        service.pendingPopup = popup
        service.activePopup = ""
        popupSwitchTimer.restart()
    }


    function closePopup(name) {
        const popup = String(name || "")

        if (
            popup === "" ||
            service.pendingPopup === popup
        ) {
            service.pendingPopup = ""
            popupSwitchTimer.stop()
        }

        if (
            popup === "" ||
            service.activePopup === popup
        ) {
            service.activePopup = ""
        }
    }


    function handleEvent(data) {
        const event = String(data.event || "")

        if (event === "bluetooth-state") {
            service.restartDelay = 1500
            service.bluetoothServiceAvailable =
                data.serviceAvailable === true
            service.bluetoothSimulated =
                data.simulated === true
            service.bluetoothAdapters =
                Array.isArray(data.adapters)
                ? data.adapters
                : []
            service.bluetoothDevices =
                Array.isArray(data.devices)
                ? data.devices
                : []
            return
        }

        if (event === "battery-state") {
            service.restartDelay = 1500
            service.batteryServiceAvailable =
                data.serviceAvailable === true
            service.batteryAvailable =
                data.available === true
            service.batterySimulated =
                data.simulated === true
            service.batterySource =
                String(data.source || "none")
            service.batteryCount =
                Number(data.batteryCount || 0)
            service.batteryPercentage =
                Number(data.percentage || 0)
            service.batteryPercentageKnown =
                data.percentageKnown === true
            service.batteryStatus =
                String(data.status || "unknown")
            service.batteryTimeToEmptySeconds =
                data.timeToEmptySeconds
            service.batteryTimeToFullSeconds =
                data.timeToFullSeconds
            service.batteryEnergyRateWatts =
                data.energyRateWatts
            service.batteryHealthPercentage =
                data.healthPercentage
            service.powerProfilesAvailable =
                data.powerProfilesAvailable === true
            service.activePowerProfile =
                String(data.activePowerProfile || "")
            service.powerProfiles =
                Array.isArray(data.powerProfiles)
                ? data.powerProfiles
                : []
            service.performanceDegraded =
                String(data.performanceDegraded || "")
            return
        }

        if (event === "brightness-state") {
            service.restartDelay = 1500
            service.brightnessServiceAvailable =
                data.serviceAvailable === true
            service.brightnessAvailable =
                data.available === true
            service.brightnessSimulated =
                data.simulated === true
            service.brightnessctlAvailable =
                data.brightnessctlAvailable === true
            service.ddcutilAvailable =
                data.ddcutilAvailable === true
            service.brightnessDisplays =
                Array.isArray(data.displays)
                ? data.displays
                : []
            return
        }

        if (event === "system-monitor-state") {
            service.restartDelay = 1500
            service.systemMonitorServiceAvailable =
                data.serviceAvailable === true
            service.systemMonitorCpuUsage =
                Number(data.cpu || 0)
            service.systemMonitorCpuTemp =
                data.cpuTemp === null ||
                data.cpuTemp === undefined
                ? null
                : Number(data.cpuTemp)
            service.systemMonitorRamUsage =
                Number(data.ram || 0)
            service.systemMonitorGpuName =
                String(data.gpuName || "Unknown")
            service.systemMonitorGpuVendor =
                String(data.gpuVendor || "unknown")
            service.systemMonitorGpuUsage =
                data.gpuUsage === null ||
                data.gpuUsage === undefined
                ? null
                : Number(data.gpuUsage)

            const network =
                data.network || ({})

            service.systemMonitorNetworkInterface =
                String(network.interface || "")
            service.systemMonitorNetworkType =
                String(network.type || "none")
            service.systemMonitorDownloadSpeed =
                Number(network.download || 0)
            service.systemMonitorUploadSpeed =
                Number(network.upload || 0)
            return
        }

        if (event === "workspaces-state") {
            service.restartDelay = 1500
            service.workspacesServiceAvailable =
                data.serviceAvailable === true
            service.workspacesAvailable =
                data.available === true
            service.workspaces =
                Array.isArray(data.workspaces)
                ? data.workspaces
                : []
            service.activeWorkspace =
                data.activeWorkspace === undefined ||
                data.activeWorkspace === null
                ? -1
                : Number(data.activeWorkspace)
            service.workspaceWindows =
                Array.isArray(data.windows)
                ? data.windows
                : []
            service.keyboardLayouts =
                Array.isArray(data.keyboardLayouts)
                ? data.keyboardLayouts
                : []
            service.keyboardLayoutIndex =
                Number(data.keyboardLayoutIndex || 0)
            service.workspacesStateEvent(data)
            return
        }

        if (event === "app-icon-result") {
            service.appIconResult(data)
            return
        }

        if (event === "terminal-apps-result") {
            service.terminalAppsResult(data)
            return
        }

        if (event === "bluetooth-action-result") {
            service.bluetoothActionResult(data)
            return
        }

        if (event === "battery-action-result")
            service.batteryActionResult(data)

        if (event === "brightness-action-result")
            service.brightnessActionResult(data)

        if (event === "workspaces-action-result")
            service.workspacesActionResult(data)
    }


    Component.onCompleted: {
        daemonProcess.running = true
    }


    // One shared backend process serves every Red Core system module.
    Process {
        id: daemonProcess

        command: [
            "bash",
            "-lc",
            service.daemonLauncher,
            "redcore-daemon"
        ].concat(service.daemonArguments)

        stdinEnabled: true

        stdout: SplitParser {
            onRead: line => {
                const value =
                    String(line || "").trim()

                if (value === "")
                    return

                try {
                    service.handleEvent(JSON.parse(value))
                } catch (error) {
                    console.warn(
                        "Red Core daemon data error:",
                        error
                    )
                }
            }
        }

        onRunningChanged: {
            if (running)
                return

            service.bluetoothServiceAvailable = false
            service.batteryServiceAvailable = false
            service.brightnessServiceAvailable = false
            service.brightnessAvailable = false
            service.brightnessSimulated = false
            service.brightnessDisplays = []
            service.systemMonitorServiceAvailable = false
            service.systemMonitorCpuUsage = 0
            service.systemMonitorCpuTemp = null
            service.systemMonitorRamUsage = 0
            service.systemMonitorGpuName = "Unknown"
            service.systemMonitorGpuVendor = "unknown"
            service.systemMonitorGpuUsage = null
            service.systemMonitorNetworkInterface = ""
            service.systemMonitorNetworkType = "none"
            service.systemMonitorDownloadSpeed = 0
            service.systemMonitorUploadSpeed = 0
            service.workspacesServiceAvailable = false
            service.workspacesAvailable = false
            service.workspaces = []
            service.activeWorkspace = -1
            service.workspaceWindows = []
            service.keyboardLayouts = []
            service.keyboardLayoutIndex = 0

            restartTimer.interval =
                service.restartDelay
            restartTimer.restart()

            service.restartDelay =
                Math.min(
                    service.restartDelay * 2,
                    service.maximumRestartDelay
                )
        }
    }


    Timer {
        id: popupSwitchTimer

        interval: 1
        repeat: false

        onTriggered: {
            const popup = service.pendingPopup
            service.pendingPopup = ""

            if (popup !== "")
                service.activePopup = popup
        }
    }


    Timer {
        id: restartTimer

        repeat: false

        onTriggered: {
            if (!daemonProcess.running)
                daemonProcess.running = true
        }
    }
}
