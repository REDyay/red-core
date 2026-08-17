pragma ComponentBehavior: Bound

import Quickshell
import QtQuick

Item {
    id: powerModule

    property var service: null

    property string pendingAction: ""
    property bool actionBusy: false
    property string actionMessage: ""
    property int requestCounter: 0
    property int pendingRequestId: 0

    readonly property var powerActions: [
        {
            "action": "lock",
            "title": "Lock",
            "description": "Lock this session",
            "symbol": "▣"
        },
        {
            "action": "suspend",
            "title": "Sleep",
            "description": "Suspend to memory",
            "symbol": "☾"
        },
        {
            "action": "reboot",
            "title": "Restart",
            "description": "Restart the computer",
            "symbol": "↻"
        },
        {
            "action": "power-off",
            "title": "Power Off",
            "description": "Shut down the computer",
            "symbol": "⏻"
        }
    ]

    implicitWidth: 32
    implicitHeight: 32
    width: implicitWidth
    height: implicitHeight


    function actionAvailable(action) {
        if (powerModule.service === null)
            return false

        switch (action) {
        case "lock":
            return powerModule.service.lockAvailable
        case "suspend":
            return powerModule.service.suspendAvailable
        case "reboot":
            return powerModule.service.rebootAvailable
        case "power-off":
            return powerModule.service.powerOffAvailable
        default:
            return false
        }
    }


    function actionTitle(action) {
        switch (action) {
        case "lock":
            return "Lock"
        case "suspend":
            return "Sleep"
        case "reboot":
            return "Restart"
        case "power-off":
            return "Power Off"
        default:
            return "Power action"
        }
    }


    function confirmationText(action) {
        switch (action) {
        case "suspend":
            return "Put this computer to sleep?"
        case "reboot":
            return "Restart this computer now?"
        case "power-off":
            return "Power off this computer now?"
        default:
            return "Continue with this action?"
        }
    }


    function unavailableMessage(action) {
        if (action === "lock")
            return "Install swaylock to enable screen locking"

        if (action === "suspend")
            return "Sleep is not supported by this device"

        return "This power action is unavailable"
    }


    function refreshState() {
        if (powerModule.service === null)
            return

        powerModule.service.sendCommand({
            "module": "power",
            "action": "get-state"
        })
    }


    function selectAction(action) {
        if (
            powerModule.actionBusy ||
            action === undefined ||
            action === null
        ) {
            return
        }

        const requested = String(action)

        if (!powerModule.actionAvailable(requested)) {
            powerModule.actionMessage =
                powerModule.unavailableMessage(requested)
            return
        }

        powerModule.actionMessage = ""

        if (requested === "lock") {
            powerModule.executeAction(requested)
            return
        }

        powerModule.pendingAction = requested
    }


    function executeAction(action) {
        if (
            powerModule.service === null ||
            powerModule.actionBusy ||
            !powerModule.actionAvailable(action)
        ) {
            return
        }

        powerModule.requestCounter += 1
        powerModule.pendingRequestId =
            powerModule.requestCounter
        powerModule.actionBusy = true
        powerModule.actionMessage =
            "Requesting " +
            powerModule.actionTitle(action) + "…"

        const sent = powerModule.service.sendCommand({
            "module": "power",
            "action": action,
            "requestId": powerModule.pendingRequestId
        })

        if (!sent) {
            powerModule.actionBusy = false
            powerModule.pendingRequestId = 0
            powerModule.actionMessage =
                "Red Core service is unavailable"
        }
    }


    function handleActionResult(data) {
        const responseId = Number(data.requestId || 0)

        if (
            powerModule.pendingRequestId > 0 &&
            responseId > 0 &&
            responseId !== powerModule.pendingRequestId
        ) {
            return
        }

        powerModule.actionBusy = false
        powerModule.pendingRequestId = 0

        if (data.success === true) {
            powerModule.pendingAction = ""
            powerModule.actionMessage = ""

            if (powerModule.service !== null) {
                powerModule.service.closePopup("power")
            } else {
                powerPopup.visible = false
            }

            return
        }

        powerModule.actionMessage = String(
            data.message || "Power action failed"
        )
    }


    Component.onCompleted: {
        Qt.callLater(function() {
            powerModule.refreshState()
        })
    }


    Rectangle {
        id: powerButton

        anchors.fill: parent
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
                if (powerModule.service !== null) {
                    powerModule.service.togglePopup("power")
                } else {
                    powerPopup.visible = !powerPopup.visible
                }
            }
        }
    }


    Connections {
        target: powerModule.service

        function onActivePopupChanged() {
            powerPopup.visible =
                powerModule.service.activePopup === "power"

            if (powerPopup.visible) {
                powerModule.pendingAction = ""
                powerModule.actionMessage = ""
                powerModule.refreshState()
            }
        }

        function onPowerActionResult(data) {
            powerModule.handleActionResult(data)
        }
    }


    PopupWindow {
        id: powerPopup

        visible: false
        grabFocus: true
        color: "transparent"
        implicitWidth: 370
        implicitHeight: 326

        anchor {
            item: powerButton
            edges: Edges.Bottom | Edges.Right
            gravity: Edges.Bottom | Edges.Left
            adjustment: PopupAdjustment.All
        }

        onVisibleChanged: {
            if (visible)
                return

            powerModule.pendingAction = ""
            powerModule.actionMessage = ""

            if (
                powerModule.service !== null &&
                powerModule.service.activePopup === "power"
            ) {
                powerModule.service.closePopup("power")
            }
        }

        Rectangle {
            anchors.fill: parent
            radius: 16
            color: "#1e1e2e"
            border.width: 1
            border.color: "#45475a"

            Column {
                anchors.fill: parent
                anchors.margins: 16
                spacing: 12

                Row {
                    width: parent.width
                    height: 34

                    Column {
                        width: parent.width
                        spacing: 2

                        Text {
                            width: parent.width
                            text: "Power"
                            color: "#cdd6f4"
                            font.pixelSize: 17
                            font.bold: true
                        }

                        Text {
                            width: parent.width
                            text:
                                powerModule.service !== null &&
                                powerModule.service.powerServiceAvailable
                                ? "System controls are ready"
                                : "Power service is unavailable"
                            color:
                                powerModule.service !== null &&
                                powerModule.service.powerServiceAvailable
                                ? "#a6e3a1"
                                : "#f9e2af"
                            font.pixelSize: 8
                        }
                    }
                }

                Item {
                    width: parent.width
                    height: 218

                    Grid {
                        visible: powerModule.pendingAction === ""
                        width: parent.width
                        columns: 2
                        columnSpacing: 10
                        rowSpacing: 10

                        Repeater {
                            model: powerModule.powerActions

                            delegate: Rectangle {
                                id: powerActionCard

                                required property var modelData

                                readonly property bool available:
                                    powerModule.actionAvailable(
                                        String(modelData.action)
                                    )

                                width: 164
                                height: 98
                                radius: 11
                                color:
                                    modelData.action === "power-off"
                                    ? "#342637"
                                    : "#28283d"
                                opacity: available ? 1 : 0.48
                                border.width:
                                    modelData.action === "power-off"
                                    ? 1
                                    : 0
                                border.color: "#f38ba8"

                                Column {
                                    anchors.centerIn: parent
                                    width: parent.width - 20
                                    spacing: 5

                                    Text {
                                        anchors.horizontalCenter:
                                            parent.horizontalCenter
                                        text: String(
                                            powerActionCard
                                                .modelData.symbol
                                        )
                                        color:
                                            powerActionCard.modelData
                                                .action === "power-off"
                                            ? "#f38ba8"
                                            : "#89b4fa"
                                        font.pixelSize: 22
                                    }

                                    Text {
                                        anchors.horizontalCenter:
                                            parent.horizontalCenter
                                        text: String(
                                            powerActionCard
                                                .modelData.title
                                        )
                                        color: "#cdd6f4"
                                        font.pixelSize: 11
                                        font.bold: true
                                    }

                                    Text {
                                        width: parent.width
                                        horizontalAlignment:
                                            Text.AlignHCenter
                                        text:
                                            powerActionCard.available
                                            ? String(
                                                powerActionCard
                                                    .modelData
                                                    .description
                                              )
                                            : powerModule
                                                  .unavailableMessage(
                                                      String(
                                                          powerActionCard
                                                              .modelData
                                                              .action
                                                      )
                                                  )
                                        elide: Text.ElideRight
                                        color: "#7f849c"
                                        font.pixelSize: 8
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    enabled: !powerModule.actionBusy
                                    cursorShape: Qt.PointingHandCursor

                                    onClicked: {
                                        powerModule.selectAction(
                                            String(
                                                powerActionCard
                                                    .modelData.action
                                            )
                                        )
                                    }
                                }
                            }
                        }
                    }

                    Column {
                        visible: powerModule.pendingAction !== ""
                        anchors.centerIn: parent
                        width: parent.width
                        spacing: 16

                        Text {
                            anchors.horizontalCenter:
                                parent.horizontalCenter
                            text:
                                powerModule.pendingAction ===
                                    "power-off"
                                ? "⏻"
                                : (
                                    powerModule.pendingAction ===
                                        "reboot"
                                    ? "↻"
                                    : "☾"
                                  )
                            color:
                                powerModule.pendingAction ===
                                    "power-off"
                                ? "#f38ba8"
                                : "#89b4fa"
                            font.pixelSize: 34
                        }

                        Text {
                            width: parent.width
                            horizontalAlignment:
                                Text.AlignHCenter
                            text:
                                powerModule.confirmationText(
                                    powerModule.pendingAction
                                )
                            color: "#cdd6f4"
                            font.pixelSize: 14
                            font.bold: true
                        }

                        Text {
                            width: parent.width
                            horizontalAlignment:
                                Text.AlignHCenter
                            text:
                                powerModule.pendingAction === "suspend"
                                ? "Your session stays open while the computer sleeps."
                                : "Save your work before continuing."
                            color: "#a6adc8"
                            font.pixelSize: 9
                        }

                        Row {
                            anchors.horizontalCenter:
                                parent.horizontalCenter
                            spacing: 10

                            Rectangle {
                                width: 100
                                height: 34
                                radius: 9
                                color: "#313244"
                                opacity:
                                    powerModule.actionBusy ? 0.5 : 1

                                Text {
                                    anchors.centerIn: parent
                                    text: "Cancel"
                                    color: "#cdd6f4"
                                    font.pixelSize: 9
                                    font.bold: true
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    enabled: !powerModule.actionBusy
                                    cursorShape: enabled
                                        ? Qt.PointingHandCursor
                                        : Qt.ArrowCursor

                                    onClicked: {
                                        powerModule.pendingAction = ""
                                        powerModule.actionMessage = ""
                                    }
                                }
                            }

                            Rectangle {
                                width: 112
                                height: 34
                                radius: 9
                                color:
                                    powerModule.pendingAction ===
                                        "power-off"
                                    ? "#f38ba8"
                                    : "#89b4fa"
                                opacity:
                                    powerModule.actionBusy ? 0.6 : 1

                                Text {
                                    anchors.centerIn: parent
                                    text:
                                        powerModule.actionBusy
                                        ? "Please wait…"
                                        : "Confirm"
                                    color: "#11111b"
                                    font.pixelSize: 9
                                    font.bold: true
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    enabled: !powerModule.actionBusy
                                    cursorShape: enabled
                                        ? Qt.PointingHandCursor
                                        : Qt.ArrowCursor

                                    onClicked: {
                                        powerModule.executeAction(
                                            powerModule.pendingAction
                                        )
                                    }
                                }
                            }
                        }
                    }
                }

                Text {
                    visible: powerModule.actionMessage !== ""
                    width: parent.width
                    height: visible ? 18 : 0
                    horizontalAlignment: Text.AlignHCenter
                    text: powerModule.actionMessage
                    elide: Text.ElideRight
                    color:
                        powerModule.actionMessage.indexOf(
                            "unavailable"
                        ) >= 0 ||
                        powerModule.actionMessage.indexOf(
                            "not supported"
                        ) >= 0 ||
                        powerModule.actionMessage.indexOf(
                            "Install"
                        ) >= 0
                        ? "#f9e2af"
                        : "#a6adc8"
                    font.pixelSize: 8
                }

                Text {
                    visible:
                        powerModule.actionMessage === "" &&
                        powerModule.service !== null &&
                        !powerModule.service.lockAvailable
                    width: parent.width
                    height: visible ? 18 : 0
                    horizontalAlignment: Text.AlignHCenter
                    text: "Screen lock needs swaylock"
                    color: "#7f849c"
                    font.pixelSize: 8
                }
            }
        }
    }
}
