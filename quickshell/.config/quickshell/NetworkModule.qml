import Quickshell
import QtQuick
import QtQuick.Layouts

Item {
    id: network

    property var service: null
    property var popupCoordinator: null

    implicitWidth: 68
    implicitHeight: 32

    width: implicitWidth
    height: implicitHeight

    property bool keyboardInputActive:
        passwordPrompt || hiddenPrompt || hotspotPrompt

    property bool serviceReady: false
    property bool stateReceived: false
    property real serviceVersion: 0

    property var snapshot: ({})
    property var primary: ({})
    property var wifiAdapters: []
    property var ethernetAdapters: []
    property var savedNetworks: []

    property bool wifiEnabled: false
    property bool wifiHardwareEnabled: false
    property bool serviceAvailable: false
    property bool networkManagerRunning: false
    property bool simulated: false
    property string connectivity: "unknown"
    property string portalUrl: ""
    property bool advancedEditorAvailable: false
    property bool newConnectionAutoconnect: true

    property bool actionBusy: false
    property string actionMessage: ""
    property string pendingAction: ""
    property int pendingRequestId: 0
    property int requestCounter: 0
    property string scanningDevice: ""

    property var pendingNetwork: ({})

    property bool passwordPrompt: false
    property bool passwordVisible: false

    property bool hiddenPrompt: false
    property bool wifiDisablePrompt: false
    property bool hiddenPasswordVisible: false
    property string hiddenDevice: ""
    property string hiddenSecurityMode: "wpa-psk"

    property bool hotspotPrompt: false
    property bool hotspotStopMode: false
    property bool hotspotPasswordVisible: false
    property string hotspotDevice: ""


    readonly property string primaryKind: {
        const type =
            String(
                network.primary.type || ""
            )

        if (
            type === "802-3-ethernet" ||
            type === "ethernet"
        ) {
            return "ethernet"
        }

        if (
            type === "802-11-wireless" ||
            type === "wifi"
        ) {
            return "wifi"
        }

        return "none"
    }


    readonly property int primaryWifiStrength: {
        const adapter = network.primaryAdapter()
        return Number(adapter.activeStrength || 0)
    }


    function adapterByIface(
        list,
        iface
    ) {
        for (
            let i = 0;
            i < list.length;
            ++i
        ) {
            if (
                String(
                    list[i].iface || ""
                ) === iface
            ) {
                return list[i]
            }
        }

        return ({})
    }


    function primaryIface() {
        const devices =
            network.primary.devices || []

        return (
            devices.length > 0
            ? String(devices[0])
            : ""
        )
    }


    function primaryAdapter() {
        const iface =
            network.primaryIface()

        if (
            network.primaryKind ===
                "wifi"
        ) {
            return network.adapterByIface(
                network.wifiAdapters,
                iface
            )
        }

        if (
            network.primaryKind ===
                "ethernet"
        ) {
            return network.adapterByIface(
                network.ethernetAdapters,
                iface
            )
        }

        return ({})
    }


    function primaryName() {
        const adapter =
            network.primaryAdapter()

        if (
            network.primaryKind ===
                "wifi"
        ) {
            return (
                String(
                    adapter.activeSsid || ""
                ) !== ""
                ? String(
                    adapter.activeSsid
                )
                : String(
                    network.primary.id ||
                    "Wi-Fi"
                )
            )
        }

        if (
            network.primaryKind ===
                "ethernet"
        ) {
            return (
                "Ethernet" +
                (
                    network.primaryIface()
                    ? " · " +
                      network.primaryIface()
                    : ""
                )
            )
        }

        return "Disconnected"
    }


    function primaryIp() {
        const adapter =
            network.primaryAdapter()

        return String(
            adapter.ipAddress || ""
        )
    }


    function securityModeFor(
        security
    ) {
        const value =
            String(
                security || ""
            )
            .trim()
            .toUpperCase()

        if (
            value === "" ||
            value === "--" ||
            value === "OPEN"
        ) {
            return "open"
        }

        if (value === "OWE")
            return "owe"

        if (
            value.indexOf("ENTERPRISE") >= 0
        ) {
            return "wpa-eap"
        }

        if (value === "WEP")
            return "wep"

        if (
            value.indexOf(
                "WPA3"
            ) >= 0
        ) {
            return "sae"
        }

        if (
            value === "WPA" ||
            value === "WPA2" ||
            value === "WPA/WPA2"
        ) {
            return "wpa-psk"
        }

        return "unsupported"
    }


    function securitySupported(
        security
    ) {
        const mode = network.securityModeFor(security)
        return ["open", "owe", "wpa-psk", "sae"].indexOf(mode) >= 0
    }


    function securityNeedsPassword(
        security
    ) {
        const mode =
            network.securityModeFor(
                security
            )

        return (
            mode === "wpa-psk" ||
            mode === "sae"
        )
    }


    function sendCommand(
        data,
        isAction
    ) {
        if (network.service === null) {
            network.actionMessage =
                "Network service is not available"
            return false
        }

        if (isAction) {
            if (
                network.actionBusy
            ) {
                return false
            }

            network.actionBusy = true
            network.actionMessage = ""
            network.pendingAction = String(data.action || "")

            actionTimeout.interval =
                network.pendingAction === "wifi"
                ? 12000
                : network.pendingAction.indexOf("hotspot-") === 0
                ? 50000
                : 35000
            actionTimeout.restart()

            network.requestCounter += 1

            data.requestId =
                network.requestCounter

            network.pendingRequestId =
                network.requestCounter

            data.module = "network"

            if (!network.service.sendCommand(data)) {
                actionTimeout.stop()
                network.actionBusy = false
                network.pendingAction = ""
                network.pendingRequestId = 0
                network.actionMessage =
                    "Network service is not running"
                return false
            }

            return true
        }

        data.module = "network"

        if (!network.service.sendCommand(data)) {
            network.actionMessage =
                "Network service is not running"
            return false
        }

        return true
    }


    function refreshState() {
        network.sendCommand(
            {
                "action":
                    "snapshot"
            },
            false
        )
    }


    function scanAdapter(
        iface
    ) {
        network.scanningDevice = String(iface)

        if (!network.sendCommand(
            {
                "action":
                    "scan",

                "device":
                    iface
            },
            true
        )) {
            network.scanningDevice = ""
        }
    }


    function scanAll() {
        network.scanningDevice = "*"

        if (!network.sendCommand(
            {
                "action":
                    "scan-all"
            },
            true
        )) {
            network.scanningDevice = ""
        }
    }


    function scanInProgress(
        iface
    ) {
        return (
            network.actionBusy &&
            (
                network.pendingAction === "scan" ||
                network.pendingAction === "scan-all"
            ) &&
            (
                network.scanningDevice === "*" ||
                network.scanningDevice === String(iface)
            )
        )
    }


    function toggleWifi() {
        if (network.wifiEnabled) {
            network.wifiDisablePrompt = true
            return
        }

        network.setWifiEnabled(true)
    }


    function setWifiEnabled(
        enabled
    ) {
        network.sendCommand(
            {
                "action":
                    "wifi",

                "enabled":
                    enabled
            },
            true
        )
    }


    function disconnectDevice(
        iface
    ) {
        network.sendCommand(
            {
                "action":
                    "disconnect",

                "device":
                    iface
            },
            true
        )
    }


    function connectEthernet(
        iface
    ) {
        network.sendCommand(
            {
                "action": "ethernet-connect",
                "device": iface
            },
            true
        )
    }


    function openPortalLogin() {
        network.sendCommand(
            {
                "action": "open-portal"
            },
            true
        )
    }


    function openHotspot(
        adapterData
    ) {
        if (
            network.actionBusy ||
            adapterData.hotspotSupported !== true
        ) {
            return
        }

        network.hotspotDevice =
            String(adapterData.iface || "")
        network.hotspotStopMode =
            adapterData.hotspotActive === true
        network.hotspotPasswordVisible = false
        network.hotspotPrompt = true
        network.actionMessage = ""
        hotspotSsidInput.text = "Red Core Hotspot"
        hotspotPasswordInput.text = ""

        if (!network.hotspotStopMode) {
            Qt.callLater(
                function() {
                    hotspotSsidInput.forceActiveFocus()
                }
            )
        }
    }


    function submitHotspot() {
        if (
            network.actionBusy ||
            hotspotSsidInput.text.length === 0 ||
            hotspotPasswordInput.text.length < 8
        ) {
            return
        }

        const ssid = hotspotSsidInput.text
        const password = hotspotPasswordInput.text
        hotspotPasswordInput.text = ""

        network.sendCommand(
            {
                "action": "hotspot-start",
                "device": network.hotspotDevice,
                "ssid": ssid,
                "password": password
            },
            true
        )
    }


    function stopHotspot() {
        network.sendCommand(
            {
                "action": "hotspot-stop",
                "device": network.hotspotDevice
            },
            true
        )
    }


    function connectivityLabel() {
        if (network.primary.connected !== true)
            return "Disconnected"

        switch (network.connectivity) {
        case "portal":
            return "Sign-in required"
        case "limited":
            return "Limited connectivity"
        case "none":
            return "No internet"
        default:
            return "Primary connection"
        }
    }


    function setAutoconnect(
        networkData,
        enabled,
        priority
    ) {
        if (
            network.actionBusy ||
            !(networkData.savedUuid || networkData.uuid)
        ) {
            return
        }

        const data = {
            "action": "autoconnect",
            "uuid": networkData.savedUuid || networkData.uuid,
            "enabled": enabled
        }

        if (priority !== undefined)
            data.autoconnectPriority = Number(priority)

        network.sendCommand(data, true)
    }


    function adjustAutoconnectPriority(
        networkData,
        delta
    ) {
        const priority = Math.max(
            -999,
            Math.min(
                999,
                Number(networkData.autoconnectPriority || 0) + delta
            )
        )

        network.setAutoconnect(
            networkData,
            networkData.autoconnect !== false,
            priority
        )
    }


    function forgetNetwork(
        networkData
    ) {
        if (
            !(networkData.savedUuid || networkData.uuid)
        ) {
            return
        }

        network.sendCommand(
            {
                "action":
                    "forget",

                "uuid":
                networkData.savedUuid || networkData.uuid
            },
            true
        )
    }


    function openPassword(
        networkData
    ) {
        network.pendingNetwork =
            networkData

        network.passwordPrompt = true
        network.passwordVisible = false

        network.actionMessage = ""

        wifiPasswordInput.text = ""

        Qt.callLater(
            function() {
                wifiPasswordInput
                    .forceActiveFocus()
            }
        )
    }


    function openAdvancedNetworkEditor() {
        network.sendCommand(
            {
                "action": "open-advanced"
            },
            true
        )
    }


    function savedNetworksOutsideRange() {
        const visibleUuids = ({})

        for (let adapter of network.wifiAdapters) {
            for (let point of (adapter.accessPoints || [])) {
                const uuid = String(point.savedUuid || "")
                if (uuid !== "")
                    visibleUuids[uuid] = true
            }
        }

        return network.savedNetworks.filter(
            profile => visibleUuids[String(profile.uuid || "")] !== true
        )
    }


    function connectSavedProfile(profile) {
        const iface = String(
            profile.interfaceName ||
            (network.wifiAdapters.length > 0
             ? network.wifiAdapters[0].iface
             : "")
        )

        if (iface === "") {
            network.actionMessage = "No Wi-Fi adapter is available"
            return
        }

        network.connectNetwork(
            {
                "ssid": profile.ssid,
                "security": profile.security,
                "securityMode": profile.securityMode,
                "saved": true,
                "savedUuid": profile.uuid,
                "autoconnect": profile.autoconnect,
                "autoconnectPriority": profile.autoconnectPriority,
                "supported": profile.supported,
                "advanced": profile.advanced
            },
            iface
        )
    }


    function connectNetwork(
        networkData,
        iface
    ) {
        if (
            network.actionBusy ||
            networkData.active === true
        ) {
            return
        }

        const mode = String(
            networkData.securityMode ||
            network.securityModeFor(networkData.security)
        )

        if (
            networkData.supported === false ||
            ["open", "owe", "wpa-psk", "sae"].indexOf(mode) < 0
        ) {
            network.actionMessage =
                (networkData.advanced === true
                 ? "Use Advanced settings for: "
                 : "Unsupported security: ") +
                String(
                    networkData.security
                )

            return
        }

        const data = {
            "ssid":
                networkData.ssid || "",

            "security":
                networkData.security || "",

            "securityMode":
                mode,

            "device":
                iface,

            "savedUuid":
                networkData.savedUuid || "",

            "autoconnect":
                networkData.saved === true
                ? networkData.autoconnect !== false
                : network.newConnectionAutoconnect,

            "autoconnectPriority":
                Number(networkData.autoconnectPriority || 0)
        }

        network.pendingNetwork =
            data

        if (
            networkData.saved === true
        ) {
            data.action = "connect"
            data.password = ""

            network.sendCommand(
                data,
                true
            )

            return
        }

        if (
            network.securityNeedsPassword(
                networkData.security
            )
        ) {
            network.openPassword(
                data
            )

            return
        }

        data.action = "connect"
        data.password = ""

        network.sendCommand(
            data,
            true
        )
    }


    function submitPassword() {
        if (
            network.actionBusy ||
            wifiPasswordInput.text.length === 0
        ) {
            return
        }

        const data =
            network.pendingNetwork

        const password =
            wifiPasswordInput.text

        wifiPasswordInput.text = ""

        network.sendCommand(
            {
                "action":
                    "connect",

                "ssid":
                    data.ssid || "",

                "security":
                    data.security || "",

                "securityMode":
                    data.securityMode ||
                    network.securityModeFor(
                        data.security
                    ),

                "device":
                    data.device || "",

                "savedUuid":
                    data.savedUuid || "",

                "password":
                    password,

                "autoconnect":
                    data.autoconnect !== false,

                "autoconnectPriority":
                    Number(data.autoconnectPriority || 0)
            },
            true
        )
    }


    function openHidden(
        iface
    ) {
        if (network.actionBusy)
            return

        network.hiddenDevice =
            iface

        network.hiddenSecurityMode =
            "wpa-psk"

        network.hiddenPasswordVisible =
            false

        network.hiddenPrompt = true
        network.actionMessage = ""

        hiddenSsidInput.text = ""
        hiddenPasswordInput.text = ""

        Qt.callLater(
            function() {
                hiddenSsidInput
                    .forceActiveFocus()
            }
        )
    }


    function submitHidden() {
        const ssid =
            hiddenSsidInput.text

        const password =
            hiddenPasswordInput.text

        if (
            ssid === "" ||
            network.actionBusy
        ) {
            return
        }

        if (
            network.hiddenSecurityMode !== "open" &&
            network.hiddenSecurityMode !== "owe" &&
            password.length === 0
        ) {
            return
        }

        const security =
            network.hiddenSecurityMode ===
                "sae"
            ? "WPA3"
            : network.hiddenSecurityMode ===
                    "owe"
            ? "OWE"
            : (
                network.hiddenSecurityMode ===
                    "wpa-psk"
                ? "WPA2"
                : "Open"
              )

        network.pendingNetwork = {
            "ssid": ssid,
            "security": security,
            "securityMode":
                network.hiddenSecurityMode,
            "device":
                network.hiddenDevice,
            "savedUuid": "",
            "hidden": true
        }

        hiddenPasswordInput.text = ""

        network.sendCommand(
            {
                "action":
                    "connect",

                "ssid":
                    ssid,

                "security":
                    security,

                "securityMode":
                    network.hiddenSecurityMode,

                "device":
                    network.hiddenDevice,

                "savedUuid":
                    "",

                "password":
                    password,

                "hidden":
                    true,

                "autoconnect":
                    network.newConnectionAutoconnect,

                "autoconnectPriority":
                    0
            },
            true
        )
    }


    function applySnapshot(
        data
    ) {
        network.snapshot =
            data || ({})

        network.primary =
            data.primary || ({})

        network.wifiAdapters =
            Array.isArray(
                data.wifi
            )
            ? data.wifi
            : []

        network.ethernetAdapters =
            Array.isArray(
                data.ethernet
            )
            ? data.ethernet
            : []

        network.wifiEnabled =
            data.wifiEnabled === true

        network.wifiHardwareEnabled =
            data.wifiHardwareEnabled ===
                true

        network.savedNetworks =
            Array.isArray(data.savedNetworks)
            ? data.savedNetworks
            : []

        network.serviceAvailable =
            data.serviceAvailable === true

        network.networkManagerRunning =
            data.nmRunning === true

        network.simulated =
            data.simulated === true

        network.connectivity =
            String(data.connectivity || "unknown")

        network.portalUrl =
            String(data.portalUrl || "")

        network.advancedEditorAvailable =
            data.advancedEditorAvailable === true
    }


    function handleEvent(
        data
    ) {
        const event =
            String(
                data.event || ""
            )

        if (event === "network-state") {
            network.stateReceived = true
            network.serviceReady = data.serviceAvailable === true
            network.applySnapshot(data)

            return
        }

        if (
            event === "scan-timeout" ||
            (
                event === "scan-request" &&
                data.success === false &&
                data.busy !== true
            )
        ) {
            actionTimeout.stop()
            network.actionBusy = false
            network.pendingAction = ""
            network.pendingRequestId = 0
            network.scanningDevice = ""
            network.actionMessage =
                data.message ||
                "Wi-Fi scan failed"

            return
        }

        if (event === "network-action-result") {
            const resultRequestId = Number(data.requestId || 0)

            if (
                resultRequestId !== 0 &&
                network.pendingRequestId !== 0 &&
                resultRequestId !== network.pendingRequestId
            ) {
                return
            }

            actionTimeout.stop()
            network.actionBusy = false
            network.pendingAction = ""
            network.pendingRequestId = 0

            if (
                data.action === "scan" ||
                data.action === "scan-all"
            ) {
                network.scanningDevice = ""
            }

            network.actionMessage =
                data.message || ""

            if (
                data.action === "connect" &&
                data.success !== true &&
                data.passwordRequired === true
            ) {
                if (
                    !network.hiddenPrompt
                ) {
                    network.openPassword(
                        network.pendingNetwork
                    )
                }

                return
            }

            if (data.success === true) {
                if (data.action === "wifi")
                    network.wifiDisablePrompt = false

                network.passwordPrompt =
                    false

                network.hiddenPrompt =
                    false

                network.hotspotPrompt =
                    false

                network.hotspotStopMode =
                    false

                network.wifiDisablePrompt =
                    false

                network.passwordVisible =
                    false

                network.hiddenPasswordVisible =
                    false

                network.hotspotPasswordVisible =
                    false

                wifiPasswordInput.text = ""
                hiddenPasswordInput.text = ""
                hotspotSsidInput.text = ""
                hotspotPasswordInput.text = ""

                network.refreshState()
            }

            return
        }

        if (event === "error") {
            actionTimeout.stop()
            network.actionBusy = false
            network.pendingAction = ""
            network.pendingRequestId = 0
            network.scanningDevice = ""

            network.actionMessage =
                data.message ||
                "Network error"
        }
    }


    Component.onCompleted: network.refreshState()


    Timer {
        interval: 2000
        repeat: true
        running:
            network.service !== null &&
            network.service.running &&
            !network.stateReceived

        onTriggered:
            network.refreshState()
    }


    Timer {
        id: actionTimeout

        interval: 35000
        repeat: false

        onTriggered: {
            const action = network.pendingAction
            network.actionBusy = false
            network.pendingAction = ""
            network.pendingRequestId = 0
            network.scanningDevice = ""
            network.actionMessage =
                action === "wifi"
                ? "Wi-Fi action timed out; state was refreshed"
                : "Network action timed out"
            network.refreshState()
        }
    }


    Connections {
        target: network.service

        function onNetworkStateEvent(data) {
            network.handleEvent(data)
        }

        function onNetworkActionResult(data) {
            network.handleEvent(data)
        }

        function onRunningChanged() {
            if (!network.service.running) {
                actionTimeout.stop()
                network.stateReceived = false
                network.serviceReady = false
                network.serviceAvailable = false
                network.networkManagerRunning = false
                network.actionBusy = false
                network.pendingAction = ""
                network.pendingRequestId = 0
                network.scanningDevice = ""
                return
            }

            network.stateReceived = false
            network.refreshState()
        }
    }


    // ========================================================
    // BAR BUTTON
    // ========================================================

    Rectangle {
        id: networkButton

        anchors.fill: parent

        radius: 10
        color: "#313244"

        Canvas {
            id: networkStatusGlyph

            anchors.centerIn: parent
            width: 20
            height: 20

            property string kind:
                network.primaryKind

            property bool connected:
                network.primary.connected === true

            property int strength:
                network.primaryWifiStrength

            property bool wifiPresent:
                network.wifiAdapters.length > 0

            onKindChanged: requestPaint()
            onConnectedChanged: requestPaint()
            onStrengthChanged: requestPaint()
            onWifiPresentChanged: requestPaint()
            Component.onCompleted: requestPaint()

            onPaint: {
                const context = getContext("2d")
                context.reset()
                context.clearRect(0, 0, width, height)
                context.lineWidth = 1.8
                context.lineCap = "round"
                context.lineJoin = "round"
                context.strokeStyle = connected ? "#a6e3a1" : "#a6adc8"
                context.fillStyle = context.strokeStyle

                if (kind === "ethernet" && connected) {
                    context.strokeRect(3.5, 3.5, 13, 9)
                    context.beginPath()
                    context.moveTo(7, 16.5)
                    context.lineTo(13, 16.5)
                    context.moveTo(10, 12.5)
                    context.lineTo(10, 16.5)
                    context.stroke()
                    return
                }

                const arcCount = connected && kind === "wifi"
                    ? (strength >= 67 ? 3 : strength >= 34 ? 2 : 1)
                    : 3
                const radii = [3.5, 6.5, 9.5]

                for (let index = 0; index < arcCount; ++index) {
                    context.beginPath()
                    context.arc(10, 16, radii[index], Math.PI, Math.PI * 2)
                    context.stroke()
                }

                context.beginPath()
                context.arc(10, 16, 1.35, 0, Math.PI * 2)
                context.fill()

                if (!connected) {
                    context.strokeStyle = "#f38ba8"
                    context.lineWidth = 2
                    context.beginPath()
                    context.moveTo(4, 4)
                    context.lineTo(16, 16)
                    context.stroke()
                }
            }
        }

        MouseArea {
            anchors.fill: parent

            cursorShape:
                Qt.PointingHandCursor

            onClicked: {
                const opening =
                    network.popupCoordinator !== null
                    ? network.popupCoordinator
                        .activePopup !== "network"
                    : !networkPopup.visible

                if (
                    network.popupCoordinator !== null
                ) {
                    network.popupCoordinator
                        .togglePopup("network")
                } else {
                    networkPopup.visible = opening
                }

                if (opening) {
                    network.refreshState()

                    if (
                        network.wifiEnabled &&
                        network.wifiAdapters
                            .length > 0
                    ) {
                        network.scanAll()
                    }
                }
            }
        }
    }


    Connections {
        target: network.popupCoordinator

        function onActivePopupChanged() {
            networkPopup.visible =
                network.popupCoordinator
                    .activePopup === "network"
        }
    }


    // ========================================================
    // POPUP
    // ========================================================

    PopupWindow {
        id: networkPopup

        visible: false
        grabFocus: true

        color: "transparent"

        implicitWidth: 400
        implicitHeight: 560

        anchor {
            item: networkButton

            edges:
                Edges.Bottom |
                Edges.Right

            gravity:
                Edges.Bottom |
                Edges.Left

            adjustment:
                PopupAdjustment.All
        }

        onVisibleChanged: {
            if (!visible) {
                if (
                    network.popupCoordinator !== null &&
                    network.popupCoordinator
                        .activePopup === "network"
                ) {
                    network.popupCoordinator
                        .closePopup("network")
                }

                network.passwordPrompt =
                    false

                network.hiddenPrompt =
                    false

                network.hotspotPrompt =
                    false

                network.hotspotStopMode =
                    false

                network.passwordVisible =
                    false

                network.hiddenPasswordVisible =
                    false

                network.hotspotPasswordVisible =
                    false

                wifiPasswordInput.text = ""
                hiddenPasswordInput.text = ""
                hiddenSsidInput.text = ""
                hotspotPasswordInput.text = ""
                hotspotSsidInput.text = ""
            }
        }


        Rectangle {
            anchors.fill: parent

            radius: 16
            color: "#1e1e2e"

            border.width: 1
            border.color: "#45475a"


            Flickable {
                id: networkFlick

                anchors.fill: parent
                anchors.margins: 16

                clip: true

                contentWidth: width
                contentHeight:
                    contentColumn
                        .implicitHeight

                Column {
                    id: contentColumn

                    width:
                        networkFlick.width

                    spacing: 10


                    RowLayout {
                        width: parent.width
                        height: 34

                        Text {
                            text: "Network"

                            color: "#cdd6f4"
                            font.pixelSize: 17
                            font.bold: true
                        }

                        Item {
                            Layout.fillWidth: true
                        }

                        Rectangle {
                            width: 62
                            height: 28
                            radius: 8

                            color:
                                network.newConnectionAutoconnect
                                ? "#a6e3a1"
                                : "#313244"

                            Text {
                                anchors.centerIn: parent

                                text:
                                    network.newConnectionAutoconnect
                                    ? "New Auto"
                                    : "Manual"

                                color:
                                    network.newConnectionAutoconnect
                                    ? "#11111b"
                                    : "#a6adc8"

                                font.pixelSize: 8
                                font.bold: true
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor

                                onClicked: {
                                    network.newConnectionAutoconnect =
                                        !network.newConnectionAutoconnect
                                }
                            }
                        }

                        Rectangle {
                            width: 70
                            height: 28
                            radius: 8

                            color:
                                network.wifiEnabled
                                ? "#89b4fa"
                                : "#313244"

                            Text {
                                anchors.centerIn:
                                    parent

                                text:
                                    network.wifiEnabled
                                    ? "Wi-Fi On"
                                    : "Wi-Fi Off"

                                color:
                                    network.wifiEnabled
                                    ? "#11111b"
                                    : "#a6adc8"

                                font.pixelSize: 9
                                font.bold: true
                            }

                            MouseArea {
                                anchors.fill: parent

                                enabled:
                                    !network.actionBusy &&
                                    network.serviceReady &&
                                    (
                                        network.wifiEnabled ||
                                        network.wifiHardwareEnabled
                                    )

                                cursorShape:
                                    Qt.PointingHandCursor

                                onClicked:
                                    network.toggleWifi()
                            }
                        }

                        Rectangle {
                            visible:
                                network.wifiAdapters.length > 1

                            width: 72
                            height: 28
                            radius: 8
                            color: "#313244"

                            Text {
                                anchors.centerIn:
                                    parent

                                text:
                                    network.scanInProgress("") &&
                                    network.scanningDevice === "*"
                                    ? "Scanning..."
                                    : "Refresh all"
                                color: "#cdd6f4"
                                font.pixelSize: 8
                            }

                            MouseArea {
                                anchors.fill: parent

                                enabled:
                                    network.wifiEnabled &&
                                    !network.actionBusy

                                cursorShape:
                                    Qt.PointingHandCursor

                                onClicked:
                                    network.scanAll()
                            }
                        }
                    }


                    Rectangle {
                        visible:
                            network.wifiDisablePrompt

                        width: parent.width
                        height: 62
                        radius: 10
                        color: "#313244"

                        Text {
                            anchors {
                                left: parent.left
                                leftMargin: 10
                                verticalCenter: parent.verticalCenter
                            }

                            text: "Turn off Wi-Fi?"
                            color: "#f9e2af"
                            font.pixelSize: 10
                            font.bold: true
                        }

                        Row {
                            anchors {
                                right: parent.right
                                rightMargin: 8
                                verticalCenter: parent.verticalCenter
                            }

                            spacing: 6

                            Rectangle {
                                width: 54
                                height: 27
                                radius: 7
                                color: "#45475a"

                                Text {
                                    anchors.centerIn: parent
                                    text: "Cancel"
                                    color: "#cdd6f4"
                                    font.pixelSize: 8
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked:
                                        network.wifiDisablePrompt = false
                                }
                            }

                            Rectangle {
                                width: 62
                                height: 27
                                radius: 7
                                color: "#f38ba8"

                                Text {
                                    anchors.centerIn: parent
                                    text: "Turn Off"
                                    color: "#11111b"
                                    font.pixelSize: 8
                                    font.bold: true
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    enabled: !network.actionBusy
                                    cursorShape: Qt.PointingHandCursor

                                    onClicked:
                                        network.setWifiEnabled(false)
                                }
                            }
                        }
                    }


                    // -----------------------------------------
                    // PRIMARY CONNECTION
                    // -----------------------------------------

                    Rectangle {
                        width: parent.width
                        height: 88
                        radius: 10
                        color: "#252537"

                        Column {
                            anchors {
                                left: parent.left
                                right: parent.right
                                top: parent.top
                                margins: 10
                            }

                            spacing: 4

                            Text {
                                width: parent.width

                                text:
                                    network.primaryName()

                                elide:
                                    Text.ElideRight

                                color: "#cdd6f4"
                                font.pixelSize: 14
                                font.bold: true
                            }

                            Text {
                                text:
                                    network.connectivityLabel()

                                color:
                                    network.primary
                                        .connected ===
                                        true
                                    ? "#a6e3a1"
                                    : "#a6adc8"

                                font.pixelSize: 9
                            }

                            Text {
                                visible:
                                    network.primaryIp() !==
                                    ""

                                text:
                                    "IP " +
                                    network.primaryIp()

                                color: "#6c7086"
                                font.pixelSize: 9
                            }
                        }

                        Rectangle {
                            id: disconnectPrimaryButton

                            visible:
                                network.primary
                                    .connected ===
                                    true &&
                                network.primaryIface() !==
                                    "" &&
                                network.primaryAdapter().hotspotActive !== true

                            anchors {
                                right: parent.right
                                bottom: parent.bottom
                                margins: 8
                            }

                            width: 74
                            height: 25
                            radius: 7
                            color: "#313244"

                            Text {
                                anchors.centerIn:
                                    parent

                                text: "Disconnect"
                                color: "#cdd6f4"
                                font.pixelSize: 8
                            }

                            MouseArea {
                                anchors.fill: parent

                                enabled:
                                    !network.actionBusy

                                cursorShape:
                                    Qt.PointingHandCursor

                                onClicked: {
                                    network.disconnectDevice(
                                        network.primaryIface()
                                    )
                                }
                            }
                        }

                        Rectangle {
                            visible:
                                network.primary.connected === true &&
                                network.connectivity === "portal"

                            anchors {
                                right:
                                    disconnectPrimaryButton.visible
                                    ? disconnectPrimaryButton.left
                                    : parent.right
                                rightMargin:
                                    disconnectPrimaryButton.visible
                                    ? 6
                                    : 8
                                bottom: parent.bottom
                                bottomMargin: 8
                            }

                            width: 62
                            height: 25
                            radius: 7
                            color: "#f9e2af"

                            Text {
                                anchors.centerIn: parent
                                text: "Sign In"
                                color: "#11111b"
                                font.pixelSize: 8
                                font.bold: true
                            }

                            MouseArea {
                                anchors.fill: parent
                                enabled: !network.actionBusy
                                cursorShape: Qt.PointingHandCursor
                                onClicked: network.openPortalLogin()
                            }
                        }
                    }


                    // -----------------------------------------
                    // ETHERNET
                    // -----------------------------------------

                    Text {
                        visible:
                            network.ethernetAdapters
                                .length > 0

                        text: "Ethernet"

                        color: "#cdd6f4"
                        font.pixelSize: 12
                        font.bold: true
                    }

                    Repeater {
                        model:
                            network.ethernetAdapters

                        delegate: Rectangle {
                            required property var modelData

                            width:
                                contentColumn.width

                            height: 54
                            radius: 9

                            color:
                                network.primaryIface() ===
                                    modelData.iface
                                ? "#313244"
                                : "#252537"

                            RowLayout {
                                anchors.fill: parent
                                anchors.margins: 9

                                Column {
                                    Layout.fillWidth: true
                                    spacing: 2

                                    Text {
                                        text:
                                            String(
                                                modelData.iface
                                            )

                                        color: "#cdd6f4"
                                        font.pixelSize: 11
                                        font.bold: true
                                    }

                                    Text {
                                        text:
                                            modelData.carrier ===
                                                true
                                            ? (
                                                modelData.state ===
                                                    "activated"
                                                ? "Connected"
                                                : "Cable connected"
                                              )
                                            : "Cable unplugged"

                                        color:
                                            modelData.carrier ===
                                                true
                                            ? "#a6e3a1"
                                            : "#6c7086"

                                        font.pixelSize: 8
                                    }
                                }

                                Text {
                                    visible:
                                        modelData.ipAddress

                                    text:
                                        modelData.ipAddress

                                    color: "#a6adc8"
                                    font.pixelSize: 8
                                }

                                Rectangle {
                                    visible:
                                        modelData.carrier === true &&
                                        modelData.state !== "activated"

                                    width: 54
                                    height: 24
                                    radius: 7
                                    color: "#89b4fa"

                                    Text {
                                        anchors.centerIn: parent
                                        text: "Connect"
                                        color: "#11111b"
                                        font.pixelSize: 8
                                        font.bold: true
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        enabled: !network.actionBusy
                                        cursorShape: Qt.PointingHandCursor

                                        onClicked:
                                            network.connectEthernet(modelData.iface)
                                    }
                                }
                            }
                        }
                    }


                    // -----------------------------------------
                    // WIFI ADAPTERS
                    // -----------------------------------------

                    Text {
                        visible:
                            network.wifiAdapters
                                .length === 0

                        text:
                            !network.serviceAvailable
                            ? "NetworkManager is unavailable"
                            : !network.wifiHardwareEnabled
                            ? "No Wi-Fi adapter, or Wi-Fi is hardware-blocked"
                            : network.wifiEnabled
                            ? "No Wi-Fi adapter"
                            : "Wi-Fi is disabled"

                        color: "#6c7086"
                        font.pixelSize: 10
                    }


                    Repeater {
                        model:
                            network.wifiAdapters

                        delegate: Rectangle {
                            id: adapterCard

                            required property var modelData

                            width:
                                contentColumn.width

                            height:
                                adapterColumn
                                    .implicitHeight +
                                20

                            radius: 11

                            color: "#252537"

                            Column {
                                id: adapterColumn

                                anchors {
                                    left: parent.left
                                    right: parent.right
                                    top: parent.top
                                    margins: 10
                                }

                                spacing: 6


                                RowLayout {
                                    width: parent.width
                                    height: 28

                                    Column {
                                        Layout.fillWidth: true
                                        Layout.minimumWidth: 72
                                        clip: true
                                        spacing: 1

                                        Text {
                                            width: parent.width

                                            text:
                                                "Wi-Fi · " +
                                                String(
                                                    adapterCard
                                                        .modelData
                                                        .iface
                                                )

                                            color: "#cdd6f4"
                                            elide: Text.ElideRight
                                            font.pixelSize: 11
                                            font.bold: true
                                        }

                                        Text {
                                            width: parent.width

                                            text:
                                                adapterCard.modelData.hotspotActive === true
                                                ? "Hotspot · " + String(
                                                    adapterCard.modelData.activeSsid ||
                                                    "Active"
                                                  )
                                                : String(
                                                    adapterCard.modelData.activeSsid ||
                                                    "Disconnected"
                                                  )

                                            color:
                                                adapterCard
                                                    .modelData
                                                    .activeSsid
                                                ? "#a6e3a1"
                                                : "#6c7086"

                                            elide: Text.ElideRight
                                            font.pixelSize: 8
                                        }
                                    }


                                    Rectangle {
                                        visible:
                                            adapterCard.modelData.hotspotActive !== true

                                        width: 52
                                        height: 24
                                        radius: 7
                                        color: "#313244"

                                        Text {
                                            anchors.centerIn:
                                                parent

                                            text: "Hidden"
                                            color: "#cdd6f4"
                                            font.pixelSize: 8
                                        }

                                        MouseArea {
                                            anchors.fill:
                                                parent

                                            cursorShape:
                                                Qt.PointingHandCursor

                                            onClicked: {
                                                network.openHidden(
                                                    adapterCard
                                                        .modelData
                                                        .iface
                                                )
                                            }
                                        }
                                    }


                                    Rectangle {
                                        visible:
                                            adapterCard.modelData.hotspotSupported === true

                                        width: 58
                                        height: 24
                                        radius: 7

                                        color:
                                            adapterCard.modelData.hotspotActive === true
                                            ? "#a6e3a1"
                                            : "#313244"

                                        Text {
                                            anchors.centerIn: parent

                                            text:
                                                adapterCard.modelData.hotspotActive === true
                                                ? "Stop"
                                                : "Hotspot"

                                            color:
                                                adapterCard.modelData.hotspotActive === true
                                                ? "#11111b"
                                                : "#cdd6f4"

                                            font.pixelSize: 8
                                            font.bold:
                                                adapterCard.modelData.hotspotActive === true
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            enabled: !network.actionBusy
                                            cursorShape: Qt.PointingHandCursor

                                            onClicked:
                                                network.openHotspot(
                                                    adapterCard.modelData
                                                )
                                        }
                                    }


                                    Rectangle {
                                        visible:
                                            adapterCard.modelData.hotspotActive !== true

                                        width: 56
                                        height: 24
                                        radius: 7
                                        color: "#313244"

                                        Text {
                                            anchors.centerIn:
                                                parent

                                            text:
                                                network.scanInProgress(
                                                    adapterCard.modelData.iface
                                                )
                                                ? "Scan..."
                                                : "Refresh"

                                            color: "#cdd6f4"
                                            font.pixelSize: 8
                                        }

                                        MouseArea {
                                            anchors.fill:
                                                parent

                                            enabled:
                                                !network.actionBusy

                                            cursorShape:
                                                Qt.PointingHandCursor

                                            onClicked: {
                                                network.scanAdapter(
                                                    adapterCard
                                                        .modelData
                                                        .iface
                                                )
                                            }
                                        }
                                    }
                                }


                                Text {
                                    visible:
                                        adapterCard
                                            .modelData
                                            .ipAddress

                                    text:
                                        "IP " +
                                        String(
                                            adapterCard
                                                .modelData
                                                .ipAddress
                                        )

                                    color: "#6c7086"
                                    font.pixelSize: 8
                                }


                                Column {
                                    visible:
                                        adapterCard.modelData.hotspotActive !== true

                                    width: parent.width
                                    spacing: 3

                                    Repeater {
                                        model:
                                            adapterCard
                                                .modelData
                                                .accessPoints ||
                                            []

                                        delegate: Rectangle {
                                            id: apRow

                                            required property var modelData

                                            width:
                                                adapterColumn
                                                    .width

                                            height: 44
                                            radius: 8

                                            color:
                                                apRow
                                                    .modelData
                                                    .active
                                                ? "#313244"
                                                : "transparent"


                                            Column {
                                                anchors {
                                                    left: parent.left
                                                    verticalCenter:
                                                        parent
                                                        .verticalCenter

                                                    leftMargin: 8
                                                }

                                                width:
                                                    parent.width -
                                                    (
                                                        apRow
                                                            .modelData
                                                            .saved
                                                        ? (
                                                            forgetButton
                                                                .visible
                                                            ? 188
                                                            : 138
                                                          )
                                                        : 75
                                                    )

                                                spacing: 1

                                                Text {
                                                    width:
                                                        parent
                                                            .width

                                                    text:
                                                        String(
                                                            apRow
                                                                .modelData
                                                                .ssid
                                                        )

                                                    elide:
                                                        Text.ElideRight

                                                    color:
                                                        "#cdd6f4"

                                                    font.pixelSize:
                                                        10

                                                    font.bold:
                                                        apRow
                                                            .modelData
                                                            .active
                                                }

                                                Text {
                                                    text:
                                                        String(
                                                            apRow
                                                                .modelData
                                                                .security
                                                        ) +
                                                        (
                                                            network
                                                                .securitySupported(
                                                                    apRow
                                                                        .modelData
                                                                        .security
                                                                )
                                                            ? ""
                                                            : apRow.modelData.advanced === true
                                                            ? " · Advanced"
                                                            : " · Unsupported"
                                                        )

                                                    color:
                                                        network
                                                            .securitySupported(
                                                                apRow
                                                                    .modelData
                                                                    .security
                                                            )
                                                        ? "#6c7086"
                                                        : "#f9e2af"

                                                    font.pixelSize:
                                                        7
                                                }
                                            }


                                            Text {
                                                anchors {
                                                    right:
                                                        autoConnectButton
                                                            .visible
                                                        ? autoConnectButton
                                                            .left
                                                        : (
                                                            forgetButton
                                                                .visible
                                                            ? forgetButton
                                                                .left
                                                            : parent
                                                                .right
                                                          )

                                                    rightMargin: 7

                                                    verticalCenter:
                                                        parent
                                                        .verticalCenter
                                                }

                                                text:
                                                    apRow
                                                        .modelData
                                                        .active
                                                    ? "Connected"
                                                    : (
                                                        apRow
                                                            .modelData
                                                            .saved
                                                        ? "Saved"
                                                        : String(
                                                            apRow
                                                                .modelData
                                                                .strength
                                                        ) +
                                                          "%"
                                                      )

                                                color:
                                                    apRow
                                                        .modelData
                                                        .active
                                                    ? "#a6e3a1"
                                                    : "#a6adc8"

                                                font.pixelSize: 8
                                            }


                                            Rectangle {
                                                id: autoConnectButton

                                                visible:
                                                    apRow
                                                        .modelData
                                                        .saved

                                                anchors {
                                                    right:
                                                        forgetButton
                                                            .visible
                                                        ? forgetButton
                                                            .left
                                                        : parent
                                                            .right

                                                    rightMargin:
                                                        forgetButton
                                                            .visible
                                                        ? 6
                                                        : 0

                                                    verticalCenter:
                                                        parent
                                                        .verticalCenter
                                                }

                                                width: 58
                                                height: 23
                                                radius: 7

                                                color:
                                                    apRow
                                                        .modelData
                                                        .autoconnect
                                                    ? "#89b4fa"
                                                    : "#313244"

                                                Text {
                                                    anchors.centerIn:
                                                        parent

                                                    text:
                                                        apRow
                                                            .modelData
                                                            .autoconnect
                                                        ? "Auto On"
                                                        : "Auto Off"

                                                    color:
                                                        apRow
                                                            .modelData
                                                            .autoconnect
                                                        ? "#11111b"
                                                        : "#a6adc8"

                                                    font.pixelSize: 7
                                                    font.bold: true
                                                }

                                                MouseArea {
                                                    anchors.fill:
                                                        parent

                                                    enabled:
                                                        !network
                                                            .actionBusy

                                                    cursorShape:
                                                        Qt.PointingHandCursor

                                                    onClicked: {
                                                        network.setAutoconnect(
                                                            apRow
                                                                .modelData,

                                                            !apRow
                                                                .modelData
                                                                .autoconnect
                                                        )
                                                    }
                                                }
                                            }


                                            Rectangle {
                                                id: forgetButton

                                                visible:
                                                    apRow
                                                        .modelData
                                                        .saved &&
                                                    !apRow
                                                        .modelData
                                                        .active

                                                anchors {
                                                    right:
                                                        parent.right

                                                    verticalCenter:
                                                        parent
                                                        .verticalCenter
                                                }

                                                width: 42
                                                height: 23
                                                radius: 7
                                                color: "#313244"

                                                Text {
                                                    anchors.centerIn:
                                                        parent

                                                    text: "Forget"
                                                    color: "#f38ba8"
                                                    font.pixelSize: 7
                                                }

                                                MouseArea {
                                                    anchors.fill:
                                                        parent

                                                    enabled:
                                                        !network
                                                            .actionBusy

                                                    cursorShape:
                                                        Qt.PointingHandCursor

                                                    onClicked: {
                                                        network.forgetNetwork(
                                                            apRow
                                                                .modelData
                                                        )
                                                    }
                                                }
                                            }


                                            MouseArea {
                                                anchors {
                                                    left:
                                                        parent.left

                                                    top:
                                                        parent.top

                                                    bottom:
                                                        parent.bottom

                                                    right:
                                                        autoConnectButton
                                                            .visible
                                                        ? autoConnectButton
                                                            .left
                                                        : forgetButton
                                                            .visible
                                                        ? forgetButton.left
                                                        : parent.right

                                                    rightMargin:
                                                        autoConnectButton.visible ||
                                                        forgetButton.visible
                                                        ? 4
                                                        : 0
                                                }

                                                enabled:
                                                    !apRow
                                                        .modelData
                                                        .active &&
                                                    !network
                                                        .actionBusy &&
                                                    (
                                                        network
                                                        .securitySupported(
                                                            apRow
                                                                .modelData
                                                                .security
                                                        ) ||
                                                        apRow.modelData.advanced === true
                                                    )

                                                cursorShape:
                                                    enabled
                                                    ? Qt.PointingHandCursor
                                                    : Qt.ArrowCursor

                                                onClicked: {
                                                    if (apRow.modelData.advanced === true) {
                                                        network.openAdvancedNetworkEditor()
                                                    } else {
                                                        network.connectNetwork(
                                                            apRow.modelData,
                                                            adapterCard.modelData.iface
                                                        )
                                                    }
                                                }
                                            }
                                        }
                                    }


                                    Text {
                                        visible:
                                            (
                                                adapterCard
                                                    .modelData
                                                    .accessPoints ||
                                                []
                                            ).length === 0 &&
                                            !adapterCard
                                                .modelData
                                                .scanBusy

                                        text:
                                            "No nearby networks"

                                        color: "#6c7086"
                                        font.pixelSize: 9
                                    }
                                }
                            }
                        }
                    }


                    // Saved profiles that are hidden or currently out of range.
                    Text {
                        visible:
                            network.savedNetworksOutsideRange().length > 0

                        text: "Saved networks"
                        color: "#cdd6f4"
                        font.pixelSize: 12
                        font.bold: true
                    }

                    Repeater {
                        model:
                            network.savedNetworksOutsideRange()

                        delegate: Rectangle {
                            id: savedRow

                            required property var modelData

                            width: contentColumn.width
                            height: 50
                            radius: 9
                            color: "#252537"

                            Column {
                                anchors {
                                    left: parent.left
                                    leftMargin: 9
                                    verticalCenter: parent.verticalCenter
                                }

                                width: 128
                                spacing: 1

                                Text {
                                    width: parent.width
                                    text: String(savedRow.modelData.ssid || savedRow.modelData.id)
                                    elide: Text.ElideRight
                                    color: "#cdd6f4"
                                    font.pixelSize: 10
                                    font.bold: true
                                }

                                Text {
                                    text:
                                        String(savedRow.modelData.security || "") +
                                        (savedRow.modelData.hidden === true ? " · Hidden" : "")
                                    color: "#6c7086"
                                    font.pixelSize: 7
                                }
                            }

                            Row {
                                anchors {
                                    right: autoSaved.left
                                    rightMargin: 6
                                    verticalCenter: parent.verticalCenter
                                }
                                spacing: 3

                                Rectangle {
                                    width: 22
                                    height: 22
                                    radius: 6
                                    color: "#313244"

                                    Text {
                                        anchors.centerIn: parent
                                        text: "−"
                                        color: "#cdd6f4"
                                        font.pixelSize: 11
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        enabled: !network.actionBusy
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked:
                                            network.adjustAutoconnectPriority(
                                                savedRow.modelData,
                                                -1
                                            )
                                    }
                                }

                                Text {
                                    width: 24
                                    anchors.verticalCenter: parent.verticalCenter
                                    horizontalAlignment: Text.AlignHCenter
                                    text: Number(savedRow.modelData.autoconnectPriority || 0)
                                    color: "#a6adc8"
                                    font.pixelSize: 8
                                }

                                Rectangle {
                                    width: 22
                                    height: 22
                                    radius: 6
                                    color: "#313244"

                                    Text {
                                        anchors.centerIn: parent
                                        text: "+"
                                        color: "#cdd6f4"
                                        font.pixelSize: 10
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        enabled: !network.actionBusy
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked:
                                            network.adjustAutoconnectPriority(
                                                savedRow.modelData,
                                                1
                                            )
                                    }
                                }
                            }

                            Rectangle {
                                id: autoSaved

                                anchors {
                                    right: forgetSaved.left
                                    rightMargin: 6
                                    verticalCenter: parent.verticalCenter
                                }

                                width: 54
                                height: 24
                                radius: 7
                                color:
                                    savedRow.modelData.autoconnect
                                    ? "#89b4fa"
                                    : "#313244"

                                Text {
                                    anchors.centerIn: parent
                                    text:
                                        savedRow.modelData.autoconnect
                                        ? "Auto On"
                                        : "Auto Off"
                                    color:
                                        savedRow.modelData.autoconnect
                                        ? "#11111b"
                                        : "#a6adc8"
                                    font.pixelSize: 7
                                    font.bold: true
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    enabled: !network.actionBusy
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked:
                                        network.setAutoconnect(
                                            savedRow.modelData,
                                            !savedRow.modelData.autoconnect
                                        )
                                }
                            }

                            Rectangle {
                                id: forgetSaved

                                anchors {
                                    right: parent.right
                                    verticalCenter: parent.verticalCenter
                                }

                                width: 42
                                height: 24
                                radius: 7
                                color: "#313244"

                                Text {
                                    anchors.centerIn: parent
                                    text: "Forget"
                                    color: "#f38ba8"
                                    font.pixelSize: 7
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    enabled: !network.actionBusy
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked:
                                        network.forgetNetwork(savedRow.modelData)
                                }
                            }

                            MouseArea {
                                anchors {
                                    left: parent.left
                                    top: parent.top
                                    bottom: parent.bottom
                                }

                                width: 128

                                enabled: !network.actionBusy
                                cursorShape: Qt.PointingHandCursor

                                onClicked: {
                                    if (savedRow.modelData.advanced === true)
                                        network.openAdvancedNetworkEditor()
                                    else
                                        network.connectSavedProfile(savedRow.modelData)
                                }
                            }
                        }
                    }


                    Text {
                        width: parent.width

                        visible:
                            network.actionMessage !==
                            ""

                        text:
                            network.actionBusy
                            ? "Working..."
                            : network.actionMessage

                        wrapMode: Text.Wrap

                        color:
                            network.actionBusy
                            ? "#89b4fa"
                            : "#a6adc8"

                        font.pixelSize: 9
                    }


                    Item {
                        width: 1
                        height: 8
                    }
                }
            }


            // =================================================
            // HOTSPOT SETUP DIALOG
            // =================================================

            Rectangle {
                anchors.fill: parent
                anchors.margins: 10

                visible:
                    network.hotspotPrompt

                radius: 14
                color: "#181825"

                border.width: 1
                border.color: "#45475a"

                Column {
                    anchors {
                        left: parent.left
                        right: parent.right
                        top: parent.top
                        margins: 18
                    }

                    spacing: 14

                    Text {
                        text:
                            network.hotspotStopMode
                            ? "Stop Hotspot · " + network.hotspotDevice
                            : "Create Hotspot · " + network.hotspotDevice

                        color: "#cdd6f4"
                        font.pixelSize: 15
                        font.bold: true
                    }

                    Text {
                        width: parent.width

                        text:
                            network.hotspotStopMode
                            ? "Stopping the hotspot will reconnect the Wi-Fi network that was active before sharing."
                            : "Starting a hotspot disconnects this adapter from Wi-Fi. Internet is shared only when Ethernet or another adapter remains connected."

                        wrapMode: Text.Wrap
                        color: "#f9e2af"
                        font.pixelSize: 10
                    }

                    Rectangle {
                        visible:
                            !network.hotspotStopMode

                        width: parent.width
                        height: 40
                        radius: 9
                        color: "#313244"

                        TextInput {
                            id: hotspotSsidInput

                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12

                            maximumLength: 32
                            verticalAlignment: TextInput.AlignVCenter
                            color: "#cdd6f4"
                            font.pixelSize: 11
                        }

                        Text {
                            visible:
                                hotspotSsidInput.text === ""

                            anchors {
                                left: parent.left
                                leftMargin: 12
                                verticalCenter: parent.verticalCenter
                            }

                            text: "Hotspot name (SSID)"
                            color: "#6c7086"
                            font.pixelSize: 10
                        }
                    }

                    Rectangle {
                        visible:
                            !network.hotspotStopMode

                        width: parent.width
                        height: 40
                        radius: 9
                        color: "#313244"

                        TextInput {
                            id: hotspotPasswordInput

                            anchors {
                                left: parent.left
                                right: hotspotShow.left
                                top: parent.top
                                bottom: parent.bottom
                                leftMargin: 12
                            }

                            maximumLength: 63
                            verticalAlignment: TextInput.AlignVCenter

                            echoMode:
                                network.hotspotPasswordVisible
                                ? TextInput.Normal
                                : TextInput.Password

                            color: "#cdd6f4"
                            font.pixelSize: 11

                            Keys.onReturnPressed:
                                network.submitHotspot()
                        }

                        Text {
                            visible:
                                hotspotPasswordInput.text === ""

                            anchors {
                                left: parent.left
                                leftMargin: 12
                                verticalCenter: parent.verticalCenter
                            }

                            text: "Password · at least 8 characters"
                            color: "#6c7086"
                            font.pixelSize: 10
                        }

                        Rectangle {
                            id: hotspotShow

                            anchors.right: parent.right
                            width: 48
                            height: parent.height
                            color: "transparent"

                            Text {
                                anchors.centerIn: parent

                                text:
                                    network.hotspotPasswordVisible
                                    ? "Hide"
                                    : "Show"

                                color: "#a6adc8"
                                font.pixelSize: 8
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor

                                onClicked:
                                    network.hotspotPasswordVisible =
                                        !network.hotspotPasswordVisible
                            }
                        }
                    }

                    Text {
                        width: parent.width

                        visible:
                            network.actionMessage !== ""

                        text:
                            network.actionBusy
                            ? (
                                network.hotspotStopMode
                                ? "Stopping hotspot..."
                                : "Starting hotspot..."
                              )
                            : network.actionMessage

                        wrapMode: Text.Wrap
                        color:
                            network.actionBusy
                            ? "#89b4fa"
                            : "#f38ba8"
                        font.pixelSize: 9
                    }

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 12

                        Rectangle {
                            width: 92
                            height: 32
                            radius: 9
                            color: "#313244"

                            Text {
                                anchors.centerIn: parent
                                text: "Cancel"
                                color: "#cdd6f4"
                                font.pixelSize: 9
                            }

                            MouseArea {
                                anchors.fill: parent
                                enabled: !network.actionBusy
                                cursorShape: Qt.PointingHandCursor

                                onClicked: {
                                    hotspotSsidInput.text = ""
                                    hotspotPasswordInput.text = ""
                                    network.hotspotPrompt = false
                                    network.hotspotStopMode = false
                                    network.hotspotPasswordVisible = false
                                    network.actionMessage = ""
                                }
                            }
                        }

                        Rectangle {
                            width: 108
                            height: 32
                            radius: 9

                            color:
                                network.actionBusy ||
                                (
                                    !network.hotspotStopMode &&
                                    (
                                        hotspotSsidInput.text.length === 0 ||
                                        hotspotPasswordInput.text.length < 8
                                    )
                                )
                                ? "#45475a"
                                : network.hotspotStopMode
                                ? "#f38ba8"
                                : "#a6e3a1"

                            Text {
                                anchors.centerIn: parent

                                text:
                                    network.actionBusy
                                    ? "..."
                                    : network.hotspotStopMode
                                    ? "Stop Hotspot"
                                    : "Start Hotspot"

                                color:
                                    network.actionBusy
                                    ? "#a6adc8"
                                    : "#11111b"

                                font.pixelSize: 9
                                font.bold: true
                            }

                            MouseArea {
                                anchors.fill: parent

                                enabled:
                                    !network.actionBusy &&
                                    (
                                        network.hotspotStopMode ||
                                        (
                                            hotspotSsidInput.text.length > 0 &&
                                            hotspotPasswordInput.text.length >= 8
                                        )
                                    )

                                cursorShape:
                                    enabled
                                    ? Qt.PointingHandCursor
                                    : Qt.ArrowCursor

                                onClicked: {
                                    if (network.hotspotStopMode)
                                        network.stopHotspot()
                                    else
                                        network.submitHotspot()
                                }
                            }
                        }
                    }
                }
            }


            // =================================================
            // PASSWORD DIALOG
            // =================================================

            Rectangle {
                anchors.fill: parent
                anchors.margins: 10

                visible:
                    network.passwordPrompt

                radius: 14
                color: "#181825"

                border.width: 1
                border.color: "#45475a"


                Column {
                    anchors {
                        left: parent.left
                        right: parent.right
                        top: parent.top
                        margins: 18
                    }

                    spacing: 14


                    Text {
                        width: parent.width

                        text:
                            "Connect to " +
                            String(
                                network.pendingNetwork
                                    .ssid || ""
                            )

                        elide:
                            Text.ElideRight

                        color: "#cdd6f4"
                        font.pixelSize: 16
                        font.bold: true
                    }


                    Text {
                        text:
                            String(
                                network.pendingNetwork
                                    .security || ""
                            ) +
                            " · " +
                            String(
                                network.pendingNetwork
                                    .device || ""
                            )

                        color: "#a6adc8"
                        font.pixelSize: 9
                    }


                    Rectangle {
                        width: parent.width
                        height: 40
                        radius: 9
                        color: "#313244"

                        TextInput {
                            id: wifiPasswordInput

                            anchors {
                                left: parent.left
                                right: passwordShow.left
                                top: parent.top
                                bottom: parent.bottom

                                leftMargin: 12
                                rightMargin: 6
                            }

                            verticalAlignment:
                                TextInput.AlignVCenter

                            echoMode:
                                network.passwordVisible
                                ? TextInput.Normal
                                : TextInput.Password

                            color: "#cdd6f4"
                            font.pixelSize: 12

                            enabled:
                                !network.actionBusy

                            Keys.onReturnPressed:
                                network.submitPassword()
                        }

                        Text {
                            anchors {
                                left: parent.left
                                leftMargin: 12
                                verticalCenter:
                                    parent.verticalCenter
                            }

                            visible:
                                wifiPasswordInput.text ===
                                ""

                            text: "Password"
                            color: "#6c7086"
                            font.pixelSize: 10
                        }

                        Rectangle {
                            id: passwordShow

                            anchors {
                                right: parent.right
                                verticalCenter:
                                    parent.verticalCenter
                            }

                            width: 48
                            height: 38

                            color: "transparent"

                            Text {
                                anchors.centerIn: parent

                                text:
                                    network.passwordVisible
                                    ? "Hide"
                                    : "Show"

                                color: "#a6adc8"
                                font.pixelSize: 8
                            }

                            MouseArea {
                                anchors.fill: parent

                                cursorShape:
                                    Qt.PointingHandCursor

                                onClicked: {
                                    network.passwordVisible =
                                        !network.passwordVisible

                                    wifiPasswordInput
                                        .forceActiveFocus()
                                }
                            }
                        }
                    }


                    Text {
                        width: parent.width

                        visible:
                            network.actionMessage !==
                            ""

                        text:
                            network.actionBusy
                            ? "Connecting..."
                            : network.actionMessage

                        wrapMode: Text.Wrap

                        color:
                            network.actionBusy
                            ? "#89b4fa"
                            : "#f38ba8"

                        font.pixelSize: 9
                    }


                    Row {
                        anchors.horizontalCenter:
                            parent.horizontalCenter

                        spacing: 12

                        Rectangle {
                            width: 92
                            height: 32
                            radius: 9
                            color: "#313244"

                            Text {
                                anchors.centerIn: parent
                                text: "Cancel"
                                color: "#cdd6f4"
                                font.pixelSize: 9
                            }

                            MouseArea {
                                anchors.fill: parent

                                enabled:
                                    !network.actionBusy

                                cursorShape:
                                    Qt.PointingHandCursor

                                onClicked: {
                                    wifiPasswordInput.text =
                                        ""

                                    network.passwordPrompt =
                                        false

                                    network.passwordVisible =
                                        false

                                    network.actionMessage =
                                        ""
                                }
                            }
                        }


                        Rectangle {
                            width: 92
                            height: 32
                            radius: 9

                            color:
                                network.actionBusy ||
                                wifiPasswordInput
                                    .text.length === 0
                                ? "#45475a"
                                : "#89b4fa"

                            Text {
                                anchors.centerIn: parent

                                text:
                                    network.actionBusy
                                    ? "..."
                                    : "Connect"

                                color:
                                    network.actionBusy
                                    ? "#a6adc8"
                                    : "#11111b"

                                font.pixelSize: 9
                                font.bold: true
                            }

                            MouseArea {
                                anchors.fill: parent

                                enabled:
                                    !network.actionBusy &&
                                    wifiPasswordInput
                                        .text.length > 0

                                cursorShape:
                                    enabled
                                    ? Qt.PointingHandCursor
                                    : Qt.ArrowCursor

                                onClicked:
                                    network.submitPassword()
                            }
                        }
                    }
                }
            }


            // =================================================
            // HIDDEN NETWORK DIALOG
            // =================================================

            Rectangle {
                anchors.fill: parent
                anchors.margins: 10

                visible:
                    network.hiddenPrompt

                radius: 14
                color: "#181825"

                border.width: 1
                border.color: "#45475a"


                Column {
                    anchors {
                        left: parent.left
                        right: parent.right
                        top: parent.top
                        margins: 18
                    }

                    spacing: 14


                    Text {
                        text:
                            "Hidden network · " +
                            network.hiddenDevice

                        color: "#cdd6f4"
                        font.pixelSize: 15
                        font.bold: true
                    }


                    Rectangle {
                        width: parent.width
                        height: 40
                        radius: 9
                        color: "#313244"

                        TextInput {
                            id: hiddenSsidInput

                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12

                            verticalAlignment:
                                TextInput.AlignVCenter

                            color: "#cdd6f4"
                            font.pixelSize: 11
                        }

                        Text {
                            anchors {
                                left: parent.left
                                leftMargin: 12
                                verticalCenter:
                                    parent.verticalCenter
                            }

                            visible:
                                hiddenSsidInput.text === ""

                            text: "Network name (SSID)"
                            color: "#6c7086"
                            font.pixelSize: 10
                        }
                    }


                    Row {
                        spacing: 6

                        Repeater {
                            model: [
                                {
                                    "mode": "open",
                                    "label": "Open"
                                },
                                {
                                    "mode": "owe",
                                    "label": "OWE"
                                },
                                {
                                    "mode": "wpa-psk",
                                    "label": "WPA/WPA2"
                                },
                                {
                                    "mode": "sae",
                                    "label": "WPA3"
                                }
                            ]

                            delegate: Rectangle {
                                required property var modelData

                                width:
                                    modelData.mode ===
                                        "wpa-psk"
                                    ? 96
                                    : 60

                                height: 30
                                radius: 8

                                color:
                                    network
                                        .hiddenSecurityMode ===
                                        modelData.mode
                                    ? "#89b4fa"
                                    : "#313244"

                                Text {
                                    anchors.centerIn: parent

                                    text:
                                        parent.modelData
                                            .label

                                    color:
                                        network
                                            .hiddenSecurityMode ===
                                            parent.modelData
                                                .mode
                                        ? "#11111b"
                                        : "#cdd6f4"

                                    font.pixelSize: 8
                                    font.bold: true
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape:
                                        Qt.PointingHandCursor

                                    onClicked: {
                                        network.hiddenSecurityMode =
                                            parent.modelData
                                                .mode
                                    }
                                }
                            }
                        }
                    }


                    Rectangle {
                        visible:
                            network.hiddenSecurityMode !== "open" &&
                            network.hiddenSecurityMode !== "owe"

                        width: parent.width
                        height: 40
                        radius: 9
                        color: "#313244"

                        TextInput {
                            id: hiddenPasswordInput

                            anchors {
                                left: parent.left
                                right: hiddenShow.left
                                top: parent.top
                                bottom: parent.bottom
                                leftMargin: 12
                            }

                            verticalAlignment:
                                TextInput.AlignVCenter

                            echoMode:
                                network.hiddenPasswordVisible
                                ? TextInput.Normal
                                : TextInput.Password

                            color: "#cdd6f4"
                            font.pixelSize: 11

                            Keys.onReturnPressed:
                                network.submitHidden()
                        }

                        Text {
                            anchors {
                                left: parent.left
                                leftMargin: 12
                                verticalCenter:
                                    parent.verticalCenter
                            }

                            visible:
                                hiddenPasswordInput.text ===
                                ""

                            text: "Password"
                            color: "#6c7086"
                            font.pixelSize: 10
                        }

                        Rectangle {
                            id: hiddenShow

                            anchors.right: parent.right

                            width: 48
                            height: parent.height
                            color: "transparent"

                            Text {
                                anchors.centerIn: parent

                                text:
                                    network
                                        .hiddenPasswordVisible
                                    ? "Hide"
                                    : "Show"

                                color: "#a6adc8"
                                font.pixelSize: 8
                            }

                            MouseArea {
                                anchors.fill: parent

                                cursorShape:
                                    Qt.PointingHandCursor

                                onClicked: {
                                    network.hiddenPasswordVisible =
                                        !network.hiddenPasswordVisible
                                }
                            }
                        }
                    }


                    Text {
                        width: parent.width

                        visible:
                            network.actionMessage !==
                            ""

                        text:
                            network.actionBusy
                            ? "Connecting..."
                            : network.actionMessage

                        wrapMode: Text.Wrap

                        color:
                            network.actionBusy
                            ? "#89b4fa"
                            : "#f38ba8"

                        font.pixelSize: 9
                    }


                    Row {
                        anchors.horizontalCenter:
                            parent.horizontalCenter

                        spacing: 12

                        Rectangle {
                            width: 92
                            height: 32
                            radius: 9
                            color: "#313244"

                            Text {
                                anchors.centerIn: parent
                                text: "Cancel"
                                color: "#cdd6f4"
                                font.pixelSize: 9
                            }

                            MouseArea {
                                anchors.fill: parent

                                enabled:
                                    !network.actionBusy

                                cursorShape:
                                    Qt.PointingHandCursor

                                onClicked: {
                                    hiddenSsidInput.text =
                                        ""

                                    hiddenPasswordInput.text =
                                        ""

                                    network.hiddenPrompt =
                                        false

                                    network.actionMessage =
                                        ""
                                }
                            }
                        }


                        Rectangle {
                            width: 92
                            height: 32
                            radius: 9

                            color:
                                network.actionBusy ||
                                hiddenSsidInput
                                    .text.length === 0 ||
                                (
                                    network
                                        .hiddenSecurityMode !==
                                        "open" &&
                                    network
                                        .hiddenSecurityMode !==
                                        "owe" &&
                                    hiddenPasswordInput
                                        .text.length === 0
                                )
                                ? "#45475a"
                                : "#89b4fa"

                            Text {
                                anchors.centerIn: parent

                                text:
                                    network.actionBusy
                                    ? "..."
                                    : "Connect"

                                color:
                                    network.actionBusy
                                    ? "#a6adc8"
                                    : "#11111b"

                                font.pixelSize: 9
                                font.bold: true
                            }

                            MouseArea {
                                anchors.fill: parent

                                enabled:
                                    !network.actionBusy &&
                                    hiddenSsidInput
                                        .text.length > 0 &&
                                    (
                                        network
                                            .hiddenSecurityMode ===
                                            "open" ||
                                        network
                                            .hiddenSecurityMode ===
                                            "owe" ||
                                        hiddenPasswordInput
                                            .text.length > 0
                                    )

                                cursorShape:
                                    enabled
                                    ? Qt.PointingHandCursor
                                    : Qt.ArrowCursor

                                onClicked:
                                    network.submitHidden()
                            }
                        }
                    }
                }
            }
        }
    }
}
