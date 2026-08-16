import Quickshell
import QtQuick
import QtQuick.Layouts

Item {
    id: bluetooth

    implicitWidth: 32
    implicitHeight: 32

    width: implicitWidth
    height: implicitHeight

    visible:
        bluetooth.simulated ||
        bluetooth.adapterAvailable

    property var service: null

    property bool actionBusy: false
    property string actionMessage: ""

    readonly property bool serviceAvailable:
        bluetooth.service !== null &&
        bluetooth.service
            .bluetoothServiceAvailable === true

    readonly property bool simulated:
        bluetooth.service !== null &&
        bluetooth.service.bluetoothSimulated === true

    readonly property var adapters:
        bluetooth.service !== null
        ? bluetooth.service.bluetoothAdapters
        : []

    readonly property var devices:
        bluetooth.service !== null
        ? bluetooth.service.bluetoothDevices
        : []

    readonly property bool adapterAvailable:
        bluetooth.adapters.length > 0

    readonly property bool adapterPowered: {
        for (
            let index = 0;
            index < bluetooth.adapters.length;
            ++index
        ) {
            if (
                bluetooth.adapters[index]
                    .powered === true
            ) {
                return true
            }
        }

        return false
    }

    readonly property bool deviceConnected: {
        for (
            let index = 0;
            index < bluetooth.devices.length;
            ++index
        ) {
            if (
                bluetooth.devices[index]
                    .connected === true
            ) {
                return true
            }
        }

        return false
    }


    function devicesForAdapter(
        adapterName
    ) {
        const result = []

        for (
            let index = 0;
            index < bluetooth.devices.length;
            ++index
        ) {
            const device =
                bluetooth.devices[index]

            if (
                String(
                    device.adapter || ""
                ) === adapterName
            ) {
                result.push(device)
            }
        }

        result.sort(
            function(first, second) {
                function rank(device) {
                    if (
                        device.connected ===
                            true
                    ) {
                        return 0
                    }

                    if (
                        device.paired === true
                    ) {
                        return 1
                    }

                    return 2
                }

                const rankDifference =
                    rank(first) -
                    rank(second)

                if (rankDifference !== 0) {
                    return rankDifference
                }

                return String(
                    first.name || ""
                ).localeCompare(
                    String(
                        second.name || ""
                    )
                )
            }
        )

        return result
    }


    function kindLabel(kind) {
        const value =
            String(kind || "")

        if (value === "headphones")
            return "HP"

        if (value === "phone")
            return "PH"

        if (value === "keyboard")
            return "KB"

        if (value === "speaker")
            return "SP"

        return "BT"
    }


    function deviceStatus(device) {
        if (device.connected === true)
            return "Connected"

        if (device.paired === true)
            return "Saved"

        return "Nearby"
    }


    function deviceStatusColor(device) {
        if (device.connected === true)
            return "#a6e3a1"

        if (device.paired === true)
            return "#89b4fa"

        return "#a6adc8"
    }


    function primaryActionLabel(device) {
        if (device.connected === true)
            return "Disconnect"

        if (device.paired === true)
            return "Connect"

        return "Pair"
    }


    function sendCommand(data) {
        if (
            bluetooth.actionBusy ||
            bluetooth.service === null ||
            !bluetooth.service.running
        ) {
            return false
        }

        bluetooth.actionBusy = true
        bluetooth.actionMessage = ""
        actionTimeout.restart()

        data.module = "bluetooth"

        if (!bluetooth.service.sendCommand(data)) {
            actionTimeout.stop()
            bluetooth.actionBusy = false
            bluetooth.actionMessage =
                "Bluetooth service is unavailable"
            return false
        }

        return true
    }


    function setPowered(
        adapter,
        powered
    ) {
        bluetooth.sendCommand({
            "action": "set-powered",
            "adapter": adapter,
            "powered": powered
        })
    }


    function setScan(
        adapter,
        enabled
    ) {
        bluetooth.sendCommand({
            "action": "scan",
            "adapter": adapter,
            "enabled": enabled
        })
    }


    function runPrimaryAction(device) {
        const action =
            device.connected === true
            ? "disconnect"
            : (
                device.paired === true
                ? "connect"
                : "pair"
              )

        bluetooth.sendCommand({
            "action": action,
            "adapter":
                device.adapter || "",
            "address":
                device.address || ""
        })
    }


    function forgetDevice(device) {
        bluetooth.sendCommand({
            "action": "forget",
            "adapter":
                device.adapter || "",
            "address":
                device.address || ""
        })
    }


    onAdapterAvailableChanged: {
        if (
            !bluetooth.simulated &&
            !bluetooth.adapterAvailable
        ) {
            if (bluetooth.service !== null)
                bluetooth.service.closePopup("bluetooth")
        }
    }


    Connections {
        target: bluetooth.service

        function onBluetoothActionResult(data) {
            actionTimeout.stop()
            bluetooth.actionBusy = false

            bluetooth.actionMessage =
                data.success === true
                ? ""
                : String(
                    data.message ||
                    "Bluetooth action failed"
                  )
        }

        function onRunningChanged() {
            if (bluetooth.service.running)
                return

            actionTimeout.stop()
            bluetooth.actionBusy = false
        }

        function onActivePopupChanged() {
            bluetoothPopup.visible =
                bluetooth.service.activePopup ===
                    "bluetooth"
        }
    }


    Rectangle {
        id: bluetoothButton

        anchors.fill: parent

        radius: 10
        color: "#313244"

        Text {
            anchors.centerIn: parent

            text: "BT"

            color:
                bluetooth.deviceConnected
                ? "#a6e3a1"
                : (
                    bluetooth.adapterPowered
                    ? "#89b4fa"
                    : "#a6adc8"
                  )

            font.pixelSize: 11
            font.bold: true
        }

        MouseArea {
            anchors.fill: parent

            cursorShape:
                Qt.PointingHandCursor

            onClicked: {
                if (bluetooth.service !== null)
                    bluetooth.service
                        .togglePopup("bluetooth")
            }
        }
    }


    Timer {
        id: actionTimeout

        interval: 45000
        repeat: false

        onTriggered: {
            if (!bluetooth.actionBusy)
                return

            bluetooth.actionBusy = false
            bluetooth.actionMessage =
                "Bluetooth action timed out"
        }
    }


    PopupWindow {
        id: bluetoothPopup

        visible: false
        grabFocus: true

        onVisibleChanged: {
            if (
                !visible &&
                bluetooth.service !== null &&
                bluetooth.service.activePopup ===
                    "bluetooth"
            ) {
                bluetooth.service.closePopup(
                    "bluetooth"
                )
            }
        }

        color: "transparent"

        implicitWidth: 400
        implicitHeight: 560

        anchor {
            item: bluetoothButton

            edges:
                Edges.Bottom |
                Edges.Right

            gravity:
                Edges.Bottom |
                Edges.Left

            adjustment:
                PopupAdjustment.All
        }


        Rectangle {
            anchors.fill: parent

            radius: 16
            color: "#1e1e2e"

            border.width: 1
            border.color: "#45475a"


            Flickable {
                id: bluetoothFlick

                anchors.fill: parent
                anchors.margins: 16

                clip: true

                contentWidth: width
                contentHeight:
                    bluetoothContent
                        .implicitHeight


                Column {
                    id: bluetoothContent

                    width:
                        bluetoothFlick.width

                    spacing: 10


                    RowLayout {
                        width: parent.width
                        height: 34

                        Text {
                            text: "Bluetooth"

                            color: "#cdd6f4"
                            font.pixelSize: 17
                            font.bold: true
                        }

                        Item {
                            Layout.fillWidth: true
                        }

                        Rectangle {
                            visible:
                                bluetooth.simulated

                            width: 72
                            height: 25
                            radius: 7

                            color: "#45475a"

                            Text {
                                anchors.centerIn:
                                    parent

                                text: "Simulation"
                                color: "#f9e2af"
                                font.pixelSize: 8
                                font.bold: true
                            }
                        }
                    }


                    Rectangle {
                        visible:
                            bluetooth.adapters
                                .length === 0

                        width: parent.width
                        height: 120
                        radius: 10

                        color: "#252537"

                        Column {
                            anchors.centerIn: parent
                            spacing: 8

                            Text {
                                anchors.horizontalCenter:
                                    parent.horizontalCenter

                                text:
                                    "No Bluetooth adapter"

                                color: "#cdd6f4"
                                font.pixelSize: 13
                                font.bold: true
                            }

                            Text {
                                anchors.horizontalCenter:
                                    parent.horizontalCenter

                                text:
                                    bluetooth.simulated
                                    ? "The simulated adapter was removed"
                                    : "Connect a Bluetooth adapter"

                                color: "#6c7086"
                                font.pixelSize: 9
                            }

                            Rectangle {
                                visible:
                                    bluetooth.simulated

                                anchors.horizontalCenter:
                                    parent.horizontalCenter

                                width: 96
                                height: 26
                                radius: 7

                                color: "#313244"

                                Text {
                                    anchors.centerIn:
                                        parent

                                    text: "Add adapter"
                                    color: "#cdd6f4"
                                    font.pixelSize: 8
                                }

                                MouseArea {
                                    anchors.fill: parent

                                    enabled:
                                        !bluetooth.actionBusy

                                    cursorShape:
                                        Qt.PointingHandCursor

                                    onClicked: {
                                        bluetooth.sendCommand({
                                            "action":
                                                "add-adapter"
                                        })
                                    }
                                }
                            }
                        }
                    }


                    Repeater {
                        model:
                            bluetooth.adapters

                        delegate: Column {
                            id: adapterSection

                            required property var modelData

                            property var adapterData:
                                modelData

                            width:
                                bluetoothContent.width

                            spacing: 8


                            Rectangle {
                                width: parent.width
                                height: 74
                                radius: 10

                                color: "#252537"

                                Column {
                                    anchors {
                                        left: parent.left
                                        verticalCenter:
                                            parent.verticalCenter
                                        leftMargin: 12
                                    }

                                    spacing: 3

                                    Text {
                                        text:
                                            adapterSection
                                                .adapterData
                                                .alias ||
                                            "Bluetooth Adapter"

                                        color: "#cdd6f4"
                                        font.pixelSize: 13
                                        font.bold: true
                                    }

                                    Text {
                                        text:
                                            adapterSection
                                                .adapterData
                                                .name ||
                                            ""

                                        color: "#6c7086"
                                        font.pixelSize: 9
                                    }
                                }


                                Row {
                                    anchors {
                                        right: parent.right
                                        verticalCenter:
                                            parent.verticalCenter
                                        rightMargin: 10
                                    }

                                    spacing: 6


                                    Rectangle {
                                        width: 62
                                        height: 27
                                        radius: 7

                                        color:
                                            adapterSection
                                                .adapterData
                                                .powered ===
                                                true
                                            ? "#89b4fa"
                                            : "#313244"

                                        Text {
                                            anchors.centerIn:
                                                parent

                                            text:
                                                adapterSection
                                                    .adapterData
                                                    .powered ===
                                                    true
                                                ? "On"
                                                : "Off"

                                            color:
                                                adapterSection
                                                    .adapterData
                                                    .powered ===
                                                    true
                                                ? "#11111b"
                                                : "#a6adc8"

                                            font.pixelSize: 9
                                            font.bold: true
                                        }

                                        MouseArea {
                                            anchors.fill:
                                                parent

                                            enabled:
                                                !bluetooth
                                                    .actionBusy

                                            cursorShape:
                                                Qt.PointingHandCursor

                                            onClicked: {
                                                bluetooth.setPowered(
                                                    String(
                                                        adapterSection
                                                            .adapterData
                                                            .name ||
                                                        ""
                                                    ),
                                                    adapterSection
                                                        .adapterData
                                                        .powered !==
                                                        true
                                                )
                                            }
                                        }
                                    }


                                    Rectangle {
                                        width: 62
                                        height: 27
                                        radius: 7

                                        color:
                                            adapterSection
                                                .adapterData
                                                .discovering ===
                                                true
                                            ? "#a6e3a1"
                                            : "#313244"

                                        Text {
                                            anchors.centerIn:
                                                parent

                                            text:
                                                adapterSection
                                                    .adapterData
                                                    .discovering ===
                                                    true
                                                ? "Scanning"
                                                : "Scan"

                                            color:
                                                adapterSection
                                                    .adapterData
                                                    .discovering ===
                                                    true
                                                ? "#11111b"
                                                : "#cdd6f4"

                                            font.pixelSize: 8
                                            font.bold: true
                                        }

                                        MouseArea {
                                            anchors.fill:
                                                parent

                                            enabled:
                                                !bluetooth
                                                    .actionBusy &&
                                                adapterSection
                                                    .adapterData
                                                    .powered ===
                                                    true

                                            cursorShape:
                                                Qt.PointingHandCursor

                                            onClicked: {
                                                bluetooth.setScan(
                                                    String(
                                                        adapterSection
                                                            .adapterData
                                                            .name ||
                                                        ""
                                                    ),
                                                    adapterSection
                                                        .adapterData
                                                        .discovering !==
                                                        true
                                                )
                                            }
                                        }
                                    }
                                }
                            }


                            Text {
                                text: "Devices"

                                color: "#a6adc8"
                                font.pixelSize: 10
                                font.bold: true
                            }


                            Rectangle {
                                visible:
                                    bluetooth
                                        .devicesForAdapter(
                                            String(
                                                adapterSection
                                                    .adapterData
                                                    .name ||
                                                ""
                                            )
                                        )
                                        .length === 0

                                width: parent.width
                                height: 58
                                radius: 9

                                color: "#252537"

                                Text {
                                    anchors.centerIn:
                                        parent

                                    text:
                                        adapterSection
                                            .adapterData
                                            .powered ===
                                            true
                                        ? "Press Scan to find devices"
                                        : "Turn Bluetooth on"

                                    color: "#6c7086"
                                    font.pixelSize: 9
                                }
                            }


                            Repeater {
                                model:
                                    bluetooth
                                        .devicesForAdapter(
                                            String(
                                                adapterSection
                                                    .adapterData
                                                    .name ||
                                                ""
                                            )
                                        )

                                delegate: Rectangle {
                                    id: deviceCard

                                    required property var modelData

                                    property var deviceData:
                                        modelData

                                    width:
                                        adapterSection.width

                                    height: 72
                                    radius: 9

                                    color: "#252537"


                                    Rectangle {
                                        anchors {
                                            left: parent.left
                                            verticalCenter:
                                                parent.verticalCenter
                                            leftMargin: 10
                                        }

                                        width: 34
                                        height: 34
                                        radius: 9

                                        color: "#313244"

                                        Text {
                                            anchors.centerIn:
                                                parent

                                            text:
                                                bluetooth
                                                    .kindLabel(
                                                        deviceCard
                                                            .deviceData
                                                            .kind
                                                    )

                                            color: "#89b4fa"
                                            font.pixelSize: 9
                                            font.bold: true
                                        }
                                    }


                                    Column {
                                        anchors {
                                            left: parent.left
                                            verticalCenter:
                                                parent.verticalCenter
                                            leftMargin: 54
                                        }

                                        width: 142
                                        spacing: 4

                                        Text {
                                            width: parent.width

                                            text:
                                                deviceCard
                                                    .deviceData
                                                    .name ||
                                                "Bluetooth Device"

                                            elide:
                                                Text.ElideRight

                                            color: "#cdd6f4"
                                            font.pixelSize: 11
                                            font.bold: true
                                        }

                                        Text {
                                            text:
                                                bluetooth
                                                    .deviceStatus(
                                                        deviceCard
                                                            .deviceData
                                                    )

                                            color:
                                                bluetooth
                                                    .deviceStatusColor(
                                                        deviceCard
                                                            .deviceData
                                                    )

                                            font.pixelSize: 8
                                        }
                                    }


                                    Row {
                                        anchors {
                                            right: parent.right
                                            verticalCenter:
                                                parent.verticalCenter
                                            rightMargin: 8
                                        }

                                        spacing: 5


                                        Rectangle {
                                            width: 72
                                            height: 26
                                            radius: 7

                                            color:
                                                deviceCard
                                                    .deviceData
                                                    .connected ===
                                                    true
                                                ? "#45475a"
                                                : "#89b4fa"

                                            Text {
                                                anchors.centerIn:
                                                    parent

                                                text:
                                                    bluetooth
                                                        .primaryActionLabel(
                                                            deviceCard
                                                                .deviceData
                                                        )

                                                color:
                                                    deviceCard
                                                        .deviceData
                                                        .connected ===
                                                        true
                                                    ? "#cdd6f4"
                                                    : "#11111b"

                                                font.pixelSize: 8
                                                font.bold: true
                                            }

                                            MouseArea {
                                                anchors.fill:
                                                    parent

                                                enabled:
                                                    !bluetooth
                                                        .actionBusy &&
                                                    adapterSection
                                                        .adapterData
                                                        .powered ===
                                                        true

                                                cursorShape:
                                                    Qt.PointingHandCursor

                                                onClicked: {
                                                    bluetooth
                                                        .runPrimaryAction(
                                                            deviceCard
                                                                .deviceData
                                                        )
                                                }
                                            }
                                        }


                                        Rectangle {
                                            visible:
                                                deviceCard
                                                    .deviceData
                                                    .paired ===
                                                    true

                                            width: 48
                                            height: 26
                                            radius: 7

                                            color: "#313244"

                                            Text {
                                                anchors.centerIn:
                                                    parent

                                                text: "Forget"
                                                color: "#f38ba8"
                                                font.pixelSize: 8
                                            }

                                            MouseArea {
                                                anchors.fill:
                                                    parent

                                                enabled:
                                                    !bluetooth
                                                        .actionBusy

                                                cursorShape:
                                                    Qt.PointingHandCursor

                                                onClicked: {
                                                    bluetooth
                                                        .forgetDevice(
                                                            deviceCard
                                                                .deviceData
                                                        )
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }


                    Rectangle {
                        visible:
                            bluetooth.actionBusy ||
                            bluetooth.actionMessage !==
                                ""

                        width: parent.width
                        height: 42
                        radius: 9

                        color: "#252537"

                        Text {
                            anchors.centerIn: parent

                            text:
                                bluetooth.actionBusy
                                ? "Working..."
                                : bluetooth.actionMessage

                            color:
                                bluetooth.actionBusy
                                ? "#f9e2af"
                                : "#f38ba8"

                            font.pixelSize: 9
                        }
                    }


                    Rectangle {
                        visible:
                            bluetooth.simulated

                        width: parent.width
                        height: 28
                        radius: 8

                        color: "#252537"

                        Text {
                            anchors.centerIn: parent

                            text:
                                "Test data only · no real hardware actions"

                            color: "#6c7086"
                            font.pixelSize: 8
                        }
                    }
                }
            }
        }
    }
}
