import Quickshell
import QtQuick
import QtQuick.Layouts

Item {
    id: battery

    // Functional layout; visual design is intentionally deferred.
    property var service: null
    property bool actionBusy: false
    property string actionMessage: ""

    readonly property bool available:
        battery.service !== null &&
        battery.service.batteryAvailable === true

    readonly property bool simulated:
        battery.service !== null &&
        battery.service.batterySimulated === true

    readonly property int percentage:
        battery.service !== null
        ? battery.service.batteryPercentage
        : 0

    readonly property bool percentageKnown:
        // Never present a missing hardware reading as a real 0% charge.
        battery.service !== null &&
        battery.service.batteryPercentageKnown ===
            true

    readonly property string status:
        battery.service !== null
        ? battery.service.batteryStatus
        : "unavailable"

    readonly property var powerProfiles:
        battery.service !== null
        ? battery.service.powerProfiles
        : []

    visible:
        battery.simulated ||
        battery.available

    implicitWidth: battery.visible ? 48 : 0
    implicitHeight: 32
    width: implicitWidth
    height: implicitHeight


    function statusLabel() {
        if (battery.status === "charging")
            return "Charging"

        if (battery.status === "discharging")
            return "On battery"

        if (battery.status === "full")
            return "Fully charged"

        if (battery.status === "empty")
            return "Empty"

        if (battery.status === "unavailable")
            return "No battery"

        return "Battery"
    }


    function profileLabel(profile) {
        if (profile === "power-saver")
            return "Power Saver"

        if (profile === "balanced")
            return "Balanced"

        if (profile === "performance")
            return "Performance"

        return String(profile || "")
    }


    function durationLabel(seconds) {
        const value = Number(seconds || 0)

        if (value <= 0)
            return "Not available"

        const hours = Math.floor(value / 3600)
        const minutes = Math.floor(
            (value % 3600) / 60
        )

        if (hours <= 0)
            return minutes + " min"

        return hours + " h " + minutes + " min"
    }


    function setPowerProfile(profile) {
        if (
            battery.actionBusy ||
            battery.service === null
        ) {
            return
        }

        battery.actionBusy = true
        battery.actionMessage = ""
        actionTimeout.restart()

        if (!battery.service.sendCommand({
            "module": "battery",
            "action": "set-power-profile",
            "profile": profile
        })) {
            actionTimeout.stop()
            battery.actionBusy = false
            battery.actionMessage =
                "Battery service is unavailable"
        }
    }


    function runSimulationAction(
        action,
        scenario
    ) {
        if (
            battery.actionBusy ||
            battery.service === null ||
            !battery.simulated
        ) {
            return
        }

        const command = {
            "module": "battery",
            "action": action
        }

        if (String(scenario || "") !== "")
            command.scenario = scenario

        battery.actionBusy = true
        battery.actionMessage = ""
        actionTimeout.restart()

        if (!battery.service.sendCommand(command)) {
            actionTimeout.stop()
            battery.actionBusy = false
            battery.actionMessage =
                "Battery service is unavailable"
        }
    }


    onAvailableChanged: {
        if (
            !battery.available &&
            !battery.simulated &&
            battery.service !== null
        ) {
            battery.service.closePopup("battery")
        }
    }


    Connections {
        target: battery.service

        function onBatteryActionResult(data) {
            actionTimeout.stop()
            battery.actionBusy = false
            battery.actionMessage =
                data.success === true
                ? ""
                : String(
                    data.message ||
                    "Battery action failed"
                  )
        }

        function onRunningChanged() {
            if (battery.service.running)
                return

            actionTimeout.stop()
            battery.actionBusy = false
        }

        function onActivePopupChanged() {
            batteryPopup.visible =
                battery.service.activePopup ===
                    "battery"
        }
    }


    Rectangle {
        id: batteryButton

        anchors.fill: parent
        radius: 10
        color: "#313244"

        Text {
            anchors.centerIn: parent

            text:
                battery.percentageKnown
                ? battery.percentage + "%"
                : "BAT"
            color:
                battery.percentageKnown &&
                battery.percentage <= 15
                ? "#f38ba8"
                : (
                    battery.status === "charging"
                    ? "#a6e3a1"
                    : "#cdd6f4"
                  )
            font.pixelSize: 10
            font.bold: true
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor

            onClicked: {
                if (battery.service !== null)
                    battery.service
                        .togglePopup("battery")
            }
        }
    }


    Timer {
        id: actionTimeout

        interval: 45000
        repeat: false

        onTriggered: {
            if (!battery.actionBusy)
                return

            battery.actionBusy = false
            battery.actionMessage =
                "Battery action timed out"
        }
    }


    PopupWindow {
        id: batteryPopup

        visible: false
        grabFocus: true

        onVisibleChanged: {
            if (
                !visible &&
                battery.service !== null &&
                battery.service.activePopup ===
                    "battery"
            ) {
                battery.service.closePopup(
                    "battery"
                )
            }
        }
        color: "transparent"

        implicitWidth: 380
        implicitHeight: 560

        anchor {
            item: batteryButton
            edges: Edges.Bottom | Edges.Right
            gravity: Edges.Bottom | Edges.Left
            adjustment: PopupAdjustment.Slide
        }

        Rectangle {
            anchors.fill: parent
            radius: 18
            color: "#1e1e2e"
            border.width: 1
            border.color: "#45475a"

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 16
                spacing: 12

                RowLayout {
                    Layout.fillWidth: true

                    Text {
                        text: "Battery"
                        color: "#cdd6f4"
                        font.pixelSize: 18
                        font.bold: true
                    }

                    Item {
                        Layout.fillWidth: true
                    }

                    Rectangle {
                        visible: battery.simulated
                        implicitWidth: 72
                        implicitHeight: 28
                        radius: 8
                        color: "#45475a"

                        Text {
                            anchors.centerIn: parent
                            text: "Simulation"
                            color: "#f9e2af"
                            font.pixelSize: 9
                            font.bold: true
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 110
                    radius: 12
                    color: "#28283d"

                    Column {
                        anchors.centerIn: parent
                        spacing: 5

                        Text {
                            anchors.horizontalCenter:
                                parent.horizontalCenter
                            text:
                                battery.percentageKnown
                                ? battery.percentage + "%"
                                : "--"
                            color: "#89b4fa"
                            font.pixelSize: 30
                            font.bold: true
                        }

                        Text {
                            anchors.horizontalCenter:
                                parent.horizontalCenter
                            text: battery.statusLabel()
                            color: "#bac2de"
                            font.pixelSize: 12
                        }
                    }
                }

                GridLayout {
                    Layout.fillWidth: true
                    columns: 2
                    columnSpacing: 10
                    rowSpacing: 8

                    Text {
                        text:
                            battery.status === "charging"
                            ? "Time to full"
                            : "Time remaining"
                        color: "#a6adc8"
                        font.pixelSize: 11
                    }

                    Text {
                        Layout.alignment: Qt.AlignRight
                        text: battery.durationLabel(
                            battery.status === "charging"
                            ? battery.service
                                .batteryTimeToFullSeconds
                            : battery.service
                                .batteryTimeToEmptySeconds
                        )
                        color: "#cdd6f4"
                        font.pixelSize: 11
                        font.bold: true
                    }

                    Text {
                        text: "Battery health"
                        color: "#a6adc8"
                        font.pixelSize: 11
                    }

                    Text {
                        Layout.alignment: Qt.AlignRight
                        text:
                            battery.service
                                .batteryHealthPercentage ===
                                null
                            ? "Not available"
                            : battery.service
                                .batteryHealthPercentage +
                                "%"
                        color: "#cdd6f4"
                        font.pixelSize: 11
                        font.bold: true
                    }
                }

                Text {
                    visible: battery.simulated
                    text: "Simulation controls"
                    color: "#bac2de"
                    font.pixelSize: 12
                    font.bold: true
                }

                GridLayout {
                    visible: battery.simulated
                    Layout.fillWidth: true
                    columns: 3
                    columnSpacing: 8
                    rowSpacing: 8

                    Repeater {
                        model:
                            battery.available
                            ? [
                                {
                                    "label": "Charging",
                                    "action": "set-battery-scenario",
                                    "scenario": "charging"
                                },
                                {
                                    "label": "Battery",
                                    "action": "set-battery-scenario",
                                    "scenario": "discharging"
                                },
                                {
                                    "label": "Low",
                                    "action": "set-battery-scenario",
                                    "scenario": "low"
                                },
                                {
                                    "label": "Full",
                                    "action": "set-battery-scenario",
                                    "scenario": "full"
                                },
                                {
                                    "label": "Remove",
                                    "action": "remove-battery",
                                    "scenario": ""
                                }
                              ]
                            : [
                                {
                                    "label": "Add battery",
                                    "action": "add-battery",
                                    "scenario": ""
                                }
                              ]

                        delegate: Rectangle {
                            required property var modelData

                            Layout.fillWidth: true
                            implicitHeight: 34
                            radius: 9
                            color: "#313147"
                            opacity:
                                battery.actionBusy
                                ? 0.55
                                : 1

                            Text {
                                anchors.centerIn: parent
                                text: String(
                                    modelData.label || ""
                                )
                                color: "#cdd6f4"
                                font.pixelSize: 9
                                font.bold: true
                            }

                            MouseArea {
                                anchors.fill: parent
                                enabled:
                                    !battery.actionBusy
                                cursorShape:
                                    enabled
                                    ? Qt.PointingHandCursor
                                    : Qt.ArrowCursor

                                onClicked: {
                                    battery
                                        .runSimulationAction(
                                            modelData.action,
                                            modelData.scenario
                                        )
                                }
                            }
                        }
                    }
                }

                Text {
                    text: "Power mode"
                    color: "#bac2de"
                    font.pixelSize: 12
                    font.bold: true
                }

                Repeater {
                    model: battery.powerProfiles

                    delegate: Rectangle {
                        required property string modelData

                        Layout.fillWidth: true
                        implicitHeight: 38
                        radius: 10
                        color:
                            battery.service
                                .activePowerProfile ===
                                modelData
                            ? "#89b4fa"
                            : "#313147"
                        opacity:
                            battery.actionBusy
                            ? 0.55
                            : 1

                        Text {
                            anchors.centerIn: parent
                            text:
                                battery.profileLabel(
                                    modelData
                                )
                            color:
                                battery.service
                                    .activePowerProfile ===
                                    modelData
                                ? "#11111b"
                                : "#cdd6f4"
                            font.pixelSize: 11
                            font.bold: true
                        }

                        MouseArea {
                            anchors.fill: parent
                            enabled:
                                !battery.actionBusy &&
                                battery.service
                                    .activePowerProfile !==
                                    modelData
                            cursorShape:
                                enabled
                                ? Qt.PointingHandCursor
                                : Qt.ArrowCursor

                            onClicked: {
                                battery.setPowerProfile(
                                    modelData
                                )
                            }
                        }
                    }
                }

                Text {
                    visible:
                        battery.service !== null &&
                        battery.service
                            .activePowerProfile ===
                            "performance" &&
                        battery.service
                            .performanceDegraded !== ""
                    Layout.fillWidth: true
                    text:
                        "Performance is limited: " +
                        battery.service
                            .performanceDegraded
                    color: "#f9e2af"
                    font.pixelSize: 10
                    wrapMode: Text.Wrap
                }

                Text {
                    visible:
                        battery.actionMessage !== ""
                    Layout.fillWidth: true
                    text: battery.actionMessage
                    color: "#f38ba8"
                    font.pixelSize: 10
                    wrapMode: Text.Wrap
                }

                Item {
                    Layout.fillHeight: true
                }
            }
        }
    }
}
