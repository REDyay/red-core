import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import QtQuick
import QtQuick.Layouts

Item {
    id: network

    implicitWidth: 68
    implicitHeight: 32

    width: implicitWidth
    height: implicitHeight

    property bool keyboardInputActive:
        passwordPrompt || hiddenPrompt

    property bool serviceReady: false
    property real serviceVersion: 0

    property var snapshot: ({})
    property var primary: ({})
    property var wifiAdapters: []
    property var ethernetAdapters: []

    property bool wifiEnabled: false
    property bool wifiHardwareEnabled: false

    property bool actionBusy: false
    property string actionMessage: ""
    property string actionPayload: ""

    property int requestCounter: 0

    property var pendingNetwork: ({})

    property bool passwordPrompt: false
    property bool passwordVisible: false

    property bool hiddenPrompt: false
    property bool hiddenPasswordVisible: false
    property string hiddenDevice: ""
    property string hiddenSecurityMode: "wpa-psk"


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


    readonly property string statusIconName:
        network.primary.connected === true &&
        network.primaryKind === "ethernet"
        ? "network-wired-symbolic"
        : network.primary.connected === true &&
          network.primaryKind === "wifi"
        ? "network-wireless-signal-excellent-symbolic"
        : network.wifiAdapters.length > 0
        ? "network-wireless-offline-symbolic"
        : "network-offline-symbolic"


    readonly property string statusIcon:
        Quickshell.iconPath(
            network.statusIconName,
            true
        )


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
        return (
            network.securityModeFor(
                security
            ) !== "unsupported"
        )
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
        if (isAction) {
            if (
                network.actionBusy ||
                actionProcess.running
            ) {
                return false
            }

            network.actionBusy = true
            network.actionMessage = ""

            network.requestCounter += 1

            data.requestId =
                network.requestCounter

            network.actionPayload =
                JSON.stringify(data)

            actionProcess.running =
                true

            return true
        }

        if (!serviceProcess.running) {
            network.actionMessage =
                "Network service is not running"

            return false
        }

        serviceProcess.write(
            JSON.stringify(data) +
            "\n"
        )

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
        network.sendCommand(
            {
                "action":
                    "scan",

                "device":
                    iface
            },
            false
        )
    }


    function scanAll() {
        network.sendCommand(
            {
                "action":
                    "scan-all"
            },
            false
        )
    }


    function toggleWifi() {
        network.sendCommand(
            {
                "action":
                    "wifi",

                "enabled":
                    !network.wifiEnabled
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


    function forgetNetwork(
        networkData
    ) {
        if (
            !networkData.savedUuid
        ) {
            return
        }

        network.sendCommand(
            {
                "action":
                    "forget",

                "uuid":
                    networkData.savedUuid
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

        const mode =
            network.securityModeFor(
                networkData.security
            )

        if (
            mode === "unsupported"
        ) {
            network.actionMessage =
                "Unsupported security: " +
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
                networkData.savedUuid || ""
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
                    password
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
            hiddenSsidInput.text.trim()

        const password =
            hiddenPasswordInput.text

        if (
            ssid === "" ||
            network.actionBusy
        ) {
            return
        }

        if (
            network.hiddenSecurityMode !==
                "open" &&
            password.length === 0
        ) {
            return
        }

        const security =
            network.hiddenSecurityMode ===
                "sae"
            ? "WPA3"
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
                    true
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
    }


    function handleEvent(
        data
    ) {
        const event =
            String(
                data.event || ""
            )

        if (event === "ready") {
            network.serviceReady = true

            network.serviceVersion =
                Number(
                    data.version || 0
                )

            return
        }

        if (event === "snapshot") {
            network.serviceReady = true

            network.applySnapshot(
                data.data || ({})
            )

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
            network.actionMessage =
                data.message ||
                "Wi-Fi scan failed"

            return
        }

        if (event === "action-result") {
            network.actionBusy = false

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
                network.passwordPrompt =
                    false

                network.hiddenPrompt =
                    false

                network.passwordVisible =
                    false

                network.hiddenPasswordVisible =
                    false

                wifiPasswordInput.text = ""
                hiddenPasswordInput.text = ""

                network.refreshState()
            }

            return
        }

        if (event === "error") {
            if (
                data.action !== "scan" &&
                data.action !== "scan-all"
            ) {
                network.actionBusy =
                    false
            }

            network.actionMessage =
                data.message ||
                "Network error"
        }
    }


    Component.onCompleted: {
        serviceProcess.running = true
    }


    // ========================================================
    // BAR BUTTON
    // ========================================================

    Rectangle {
        id: networkButton

        anchors.fill: parent

        radius: 10
        color: "#313244"

        IconImage {
            anchors.centerIn: parent
            implicitSize: 18

            source:
                network.statusIcon

            visible:
                network.statusIcon !== ""
        }

        Text {
            anchors.centerIn: parent

            visible:
                network.statusIcon === ""

            text:
                network.primaryKind ===
                    "ethernet"
                ? "ETH"
                : (
                    network.primaryKind ===
                        "wifi"
                    ? "WiFi"
                    : "×"
                  )

            color:
                network.primary.connected ===
                    true
                ? "#a6e3a1"
                : "#a6adc8"

            font.pixelSize: 10
            font.bold: true
        }

        MouseArea {
            anchors.fill: parent

            cursorShape:
                Qt.PointingHandCursor

            onClicked: {
                networkPopup.visible =
                    !networkPopup.visible

                if (
                    networkPopup.visible
                ) {
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


    // ========================================================
    // NETWORK ACTION PROCESS
    //
    // Write operations are intentionally isolated from the
    // persistent libnm monitoring/scan service.
    // ========================================================

    Process {
        id: actionProcess

        command: [
            "redcore-network-action"
        ]

        stdinEnabled: true

        stdout: SplitParser {
            onRead: line => {
                const value =
                    String(
                        line || ""
                    ).trim()

                if (value === "")
                    return

                try {
                    network.handleEvent(
                        JSON.parse(
                            value
                        )
                    )

                } catch (error) {
                    network.actionBusy =
                        false

                    network.actionMessage =
                        "Network action parse error"
                }
            }
        }

        onStarted: {
            actionProcess.write(
                network.actionPayload +
                "\n"
            )

            network.actionPayload = ""
        }

        onRunningChanged: {
            if (
                !running &&
                network.actionBusy
            ) {
                actionProcessGuard.restart()
            }
        }
    }


    Timer {
        id: actionProcessGuard

        interval: 150
        repeat: false

        onTriggered: {
            if (network.actionBusy) {
                network.actionBusy = false

                network.actionMessage =
                    "Network action ended unexpectedly"
            }
        }
    }


    // ========================================================
    // PERSISTENT LIBNM SERVICE
    // ========================================================

    Process {
        id: serviceProcess

        command: [
            "redcore-network-service-v2"
        ]

        stdinEnabled: true

        stdout: SplitParser {
            onRead: line => {
                const value =
                    String(line || "")
                    .trim()

                if (value === "")
                    return

                try {
                    network.handleEvent(
                        JSON.parse(
                            value
                        )
                    )
                } catch (error) {
                    console.log(
                        "Network V2 JSON error:",
                        error
                    )
                }
            }
        }

        onRunningChanged: {
            if (!running) {
                network.serviceReady =
                    false

                network.actionBusy =
                    false

                serviceRestart.restart()
            }
        }
    }


    Timer {
        id: serviceRestart

        interval: 1500
        repeat: false

        onTriggered: {
            if (!serviceProcess.running)
                serviceProcess.running = true
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
                network.passwordPrompt =
                    false

                network.hiddenPrompt =
                    false

                network.passwordVisible =
                    false

                network.hiddenPasswordVisible =
                    false

                wifiPasswordInput.text = ""
                hiddenPasswordInput.text = ""
                hiddenSsidInput.text = ""
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
                                    !network.actionBusy

                                cursorShape:
                                    Qt.PointingHandCursor

                                onClicked:
                                    network.toggleWifi()
                            }
                        }

                        Rectangle {
                            width: 72
                            height: 28
                            radius: 8
                            color: "#313244"

                            Text {
                                anchors.centerIn:
                                    parent

                                text: "Refresh all"
                                color: "#cdd6f4"
                                font.pixelSize: 8
                            }

                            MouseArea {
                                anchors.fill: parent

                                enabled:
                                    network.wifiEnabled

                                cursorShape:
                                    Qt.PointingHandCursor

                                onClicked:
                                    network.scanAll()
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
                                    network.primary
                                        .connected ===
                                        true
                                    ? "Primary connection"
                                    : "Disconnected"

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
                            visible:
                                network.primary
                                    .connected ===
                                    true &&
                                network.primaryIface() !==
                                    ""

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
                            network.wifiEnabled
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
                                        spacing: 1

                                        Text {
                                            text:
                                                "Wi-Fi · " +
                                                String(
                                                    adapterCard
                                                        .modelData
                                                        .iface
                                                )

                                            color: "#cdd6f4"
                                            font.pixelSize: 11
                                            font.bold: true
                                        }

                                        Text {
                                            text:
                                                String(
                                                    adapterCard
                                                        .modelData
                                                        .activeSsid ||
                                                    "Disconnected"
                                                )

                                            color:
                                                adapterCard
                                                    .modelData
                                                    .activeSsid
                                                ? "#a6e3a1"
                                                : "#6c7086"

                                            font.pixelSize: 8
                                        }
                                    }


                                    Rectangle {
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
                                        width: 56
                                        height: 24
                                        radius: 7
                                        color: "#313244"

                                        Text {
                                            anchors.centerIn:
                                                parent

                                            text:
                                                adapterCard
                                                    .modelData
                                                    .scanBusy
                                                ? "..."
                                                : "Refresh"

                                            color: "#cdd6f4"
                                            font.pixelSize: 8
                                        }

                                        MouseArea {
                                            anchors.fill:
                                                parent

                                            enabled:
                                                !adapterCard
                                                    .modelData
                                                    .scanBusy

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
                                                        forgetButton
                                                            .visible
                                                        ? 130
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
                                                        forgetButton
                                                            .visible
                                                        ? forgetButton
                                                            .left
                                                        : parent
                                                            .right

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
                                                        forgetButton
                                                            .visible
                                                        ? forgetButton
                                                            .left
                                                        : parent
                                                            .right

                                                    rightMargin:
                                                        forgetButton
                                                            .visible
                                                        ? 4
                                                        : 0
                                                }

                                                enabled:
                                                    !apRow
                                                        .modelData
                                                        .active &&
                                                    !network
                                                        .actionBusy &&
                                                    network
                                                        .securitySupported(
                                                            apRow
                                                                .modelData
                                                                .security
                                                        )

                                                cursorShape:
                                                    enabled
                                                    ? Qt.PointingHandCursor
                                                    : Qt.ArrowCursor

                                                onClicked: {
                                                    network.connectNetwork(
                                                        apRow
                                                            .modelData,

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
                                    ? 104
                                    : 72

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
                            network.hiddenSecurityMode !==
                            "open"

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
                                    .text.trim() === "" ||
                                (
                                    network
                                        .hiddenSecurityMode !==
                                        "open" &&
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
                                        .text.trim() !== "" &&
                                    (
                                        network
                                            .hiddenSecurityMode ===
                                            "open" ||
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
