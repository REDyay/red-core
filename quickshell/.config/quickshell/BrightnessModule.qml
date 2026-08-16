import Quickshell
import QtQuick
import QtQuick.Layouts

Item {
    id: brightness

    // Functional layout; visual design is intentionally deferred.
    property var service: null
    property bool actionBusy: false
    property string actionMessage: ""
    property string activeAction: ""
    property string activeDisplay: ""
    property int activePercentage: 1
    property string queuedDisplay: ""
    property int queuedPercentage: 1
    property int queuedMaxValue: 100
    property string queuedBackend: ""
    property bool queuedFinal: false

    readonly property bool blockingBusy:
        brightness.actionBusy &&
        brightness.activeAction !==
            "preview-brightness"

    readonly property bool available:
        brightness.service !== null &&
        brightness.service.brightnessAvailable === true

    readonly property bool simulated:
        brightness.service !== null &&
        brightness.service.brightnessSimulated === true

    readonly property var displays:
        brightness.service !== null
        ? brightness.service.brightnessDisplays
        : []

    visible:
        brightness.simulated ||
        brightness.available

    implicitWidth: brightness.visible ? 48 : 0
    implicitHeight: 32
    width: implicitWidth
    height: implicitHeight


    function primaryPercentage() {
        if (brightness.displays.length === 0)
            return "SUN"

        return Number(
            brightness.displays[0].percentage || 0
        ) + "%"
    }


    function displayKindLabel(kind) {
        return kind === "internal"
            ? "Built-in display"
            : "External monitor"
    }


    function sendBrightnessCommand(command) {
        if (
            brightness.actionBusy ||
            brightness.service === null
        ) {
            return
        }

        brightness.actionBusy = true
        brightness.actionMessage = ""
        brightness.activeAction = String(
            command.action || ""
        )
        brightness.activeDisplay = String(
            command.display || ""
        )
        brightness.activePercentage = Number(
            command.percentage || 1
        )
        actionTimeout.restart()

        if (!brightness.service.sendCommand(command)) {
            actionTimeout.stop()
            brightness.actionBusy = false
            brightness.activeAction = ""
            brightness.activeDisplay = ""
            brightness.actionMessage =
                "Brightness service is unavailable"
        }
    }


    function scheduleQueuedBrightness() {
        if (
            brightness.actionBusy ||
            brightness.queuedDisplay === ""
        ) {
            return
        }

        liveUpdateTimer.interval =
            brightness.queuedFinal
            ? 1
            : (
                brightness.queuedBackend ===
                    "ddcutil"
                ? 180
                : 40
              )
        liveUpdateTimer.restart()
    }


    function queueLiveBrightness(
        display,
        percentage,
        maxValue,
        backend,
        finalValue
    ) {
        const displayId = String(display || "")
        const requested = Math.max(
            1,
            Math.min(100, Math.round(percentage))
        )

        if (displayId === "")
            return

        if (
            finalValue !== true &&
            brightness.actionBusy &&
            brightness.activeAction ===
                "preview-brightness" &&
            brightness.activeDisplay === displayId &&
            brightness.activePercentage === requested
        ) {
            return
        }

        brightness.queuedDisplay = displayId
        brightness.queuedPercentage = requested
        brightness.queuedMaxValue = Math.max(
            1,
            Number(maxValue || 100)
        )
        brightness.queuedBackend = String(
            backend || ""
        )
        brightness.queuedFinal =
            finalValue === true

        if (brightness.queuedFinal)
            liveUpdateTimer.stop()

        brightness.scheduleQueuedBrightness()
    }


    function flushQueuedBrightness() {
        if (
            brightness.actionBusy ||
            brightness.queuedDisplay === ""
        ) {
            return
        }

        const command = {
            "module": "brightness",
            "action":
                brightness.queuedFinal
                ? "set-brightness"
                : "preview-brightness",
            "display": brightness.queuedDisplay,
            "percentage":
                brightness.queuedPercentage,
            "maxValue":
                brightness.queuedMaxValue
        }

        brightness.queuedDisplay = ""
        brightness.queuedFinal = false
        brightness.sendBrightnessCommand(command)
    }


    function setBrightness(display, percentage) {
        brightness.sendBrightnessCommand({
            "module": "brightness",
            "action": "set-brightness",
            "display": String(display),
            "percentage": Math.max(
                1,
                Math.min(100, Math.round(percentage))
            )
        })
    }


    function stepBrightness(display, delta) {
        brightness.sendBrightnessCommand({
            "module": "brightness",
            "action": "step-brightness",
            "display": String(display),
            "delta": Number(delta)
        })
    }


    function simulationAction(action, display) {
        const command = {
            "module": "brightness",
            "action": action
        }

        if (String(display || "") !== "")
            command.display = String(display)

        brightness.sendBrightnessCommand(command)
    }


    onAvailableChanged: {
        if (
            !brightness.available &&
            !brightness.simulated &&
            brightness.service !== null
        ) {
            brightness.service.closePopup(
                "brightness"
            )
        }
    }


    Connections {
        target: brightness.service

        function onBrightnessActionResult(data) {
            const responseAction = String(
                data.action || ""
            )
            const succeeded =
                data.success === true

            // Match responses to the active command: a direct refresh can
            // still be finishing when the user starts dragging.
            if (
                !brightness.actionBusy ||
                responseAction !==
                    brightness.activeAction
            ) {
                if (!succeeded) {
                    brightness.actionMessage = String(
                        data.message ||
                        "Brightness action failed"
                    )
                }

                return
            }

            actionTimeout.stop()
            brightness.actionBusy = false
            brightness.activeAction = ""
            brightness.activeDisplay = ""
            brightness.actionMessage =
                succeeded
                ? ""
                : String(
                    data.message ||
                    "Brightness action failed"
                  )

            if (
                !succeeded &&
                !brightness.simulated
            ) {
                liveUpdateTimer.stop()
                brightness.queuedDisplay = ""
                brightness.queuedFinal = false
                brightness.service.sendCommand({
                    "module": "brightness",
                    "action": "refresh-brightness"
                })
                return
            }

            brightness.scheduleQueuedBrightness()
        }

        function onRunningChanged() {
            if (brightness.service.running)
                return

            actionTimeout.stop()
            liveUpdateTimer.stop()
            brightness.actionBusy = false
            brightness.activeAction = ""
            brightness.activeDisplay = ""
            brightness.queuedDisplay = ""
            brightness.queuedFinal = false
        }

        function onActivePopupChanged() {
            brightnessPopup.visible =
                brightness.service.activePopup ===
                    "brightness"

            if (
                brightnessPopup.visible &&
                !brightness.simulated
            ) {
                brightness.service.sendCommand({
                    "module": "brightness",
                    "action": "refresh-brightness"
                })
            }
        }
    }


    Rectangle {
        id: brightnessButton

        anchors.fill: parent
        radius: 10
        color: "#313244"

        Text {
            anchors.centerIn: parent
            text: brightness.primaryPercentage()
            color: "#f9e2af"
            font.pixelSize: 10
            font.bold: true
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor

            onClicked: {
                if (brightness.service !== null)
                    brightness.service
                        .togglePopup("brightness")
            }
        }
    }


    Timer {
        id: actionTimeout

        interval: 45000
        repeat: false

        onTriggered: {
            if (!brightness.actionBusy)
                return

            brightness.actionBusy = false
            brightness.activeAction = ""
            brightness.activeDisplay = ""
            brightness.queuedDisplay = ""
            brightness.queuedFinal = false
            brightness.actionMessage =
                "Brightness action timed out"
        }
    }


    Timer {
        id: liveUpdateTimer

        // Keep only the latest drag position while a hardware command is busy.
        interval: 180
        repeat: false

        onTriggered:
            brightness.flushQueuedBrightness()
    }


    PopupWindow {
        id: brightnessPopup

        visible: false
        grabFocus: true
        color: "transparent"

        implicitWidth: 400
        implicitHeight: 500

        onVisibleChanged: {
            if (
                !visible &&
                brightness.service !== null &&
                brightness.service.activePopup ===
                    "brightness"
            ) {
                brightness.service.closePopup(
                    "brightness"
                )
            }
        }

        anchor {
            item: brightnessButton
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
                        text: "Brightness"
                        color: "#cdd6f4"
                        font.pixelSize: 18
                        font.bold: true
                    }

                    Item {
                        Layout.fillWidth: true
                    }

                    Rectangle {
                        visible: brightness.simulated
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

                Text {
                    visible:
                        brightness.displays.length === 0
                    Layout.fillWidth: true
                    text: "No controllable display detected"
                    color: "#a6adc8"
                    font.pixelSize: 11
                    horizontalAlignment: Text.AlignHCenter
                }

                Repeater {
                    model: brightness.displays

                    delegate: Rectangle {
                        id: displayCard

                        required property var modelData

                        readonly property string displayId:
                            String(modelData.id || "")

                        property bool dragging: false
                        property real previewPercentage:
                            Number(modelData.percentage || 0)

                        readonly property real shownPercentage:
                            Math.max(
                                1,
                                Math.min(
                                    100,
                                    previewPercentage
                                )
                            )

                        function updatePreview(position) {
                            if (brightnessTrack.width <= 0)
                                return

                            const trackPosition =
                                position - brightnessTrack.x

                            previewPercentage = Math.round(
                                Math.max(
                                    0,
                                    Math.min(
                                        brightnessTrack.width,
                                        trackPosition
                                    )
                                ) * 100 /
                                brightnessTrack.width
                            )

                            previewPercentage = Math.max(
                                1,
                                previewPercentage
                            )
                        }

                        function queuePreview(finalValue) {
                            brightness.queueLiveBrightness(
                                displayId,
                                shownPercentage,
                                Number(
                                    modelData.maxValue || 100
                                ),
                                String(
                                    modelData.backend || ""
                                ),
                                finalValue
                            )
                        }

                        onModelDataChanged: {
                            if (!dragging) {
                                previewPercentage = Number(
                                    modelData.percentage || 0
                                )
                            }
                        }

                        Layout.fillWidth: true
                        implicitHeight: 150
                        radius: 12
                        color: "#28283d"
                        opacity:
                            brightness.blockingBusy
                            ? 0.6
                            : 1

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 12
                            spacing: 9

                            RowLayout {
                                Layout.fillWidth: true

                                ColumnLayout {
                                    spacing: 2

                                    Text {
                                        text: String(
                                            modelData.name ||
                                            "Display"
                                        )
                                        color: "#cdd6f4"
                                        font.pixelSize: 12
                                        font.bold: true
                                    }

                                    Text {
                                        text:
                                            brightness
                                                .displayKindLabel(
                                                    String(
                                                        modelData.kind ||
                                                        "external"
                                                    )
                                                )
                                        color: "#a6adc8"
                                        font.pixelSize: 9
                                    }
                                }

                                Item {
                                    Layout.fillWidth: true
                                }

                                Text {
                                    text:
                                        Math.round(
                                            displayCard
                                                .shownPercentage
                                        ) + "%"
                                    color: "#89b4fa"
                                    font.pixelSize: 14
                                    font.bold: true
                                }
                            }

                            Item {
                                Layout.fillWidth: true
                                implicitHeight: 30

                                Rectangle {
                                    id: brightnessTrack

                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.leftMargin: 10
                                    anchors.rightMargin: 10
                                    anchors.verticalCenter:
                                        parent.verticalCenter
                                    height: 12
                                    radius: 6
                                    color: "#45475a"

                                    Rectangle {
                                        width:
                                            parent.width *
                                            displayCard
                                                .shownPercentage /
                                            100
                                        height: parent.height
                                        radius: parent.radius
                                        color: "#89b4fa"
                                    }

                                    Rectangle {
                                        width: 20
                                        height: 20
                                        radius: 10
                                        x:
                                            parent.width *
                                            displayCard
                                                .shownPercentage /
                                            100 - width / 2
                                        anchors.verticalCenter:
                                            parent.verticalCenter
                                        color:
                                            displayCard.dragging
                                            ? "#b4d0ff"
                                            : "#cdd6f4"
                                        border.width: 2
                                        border.color: "#89b4fa"
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    enabled:
                                        !brightness.blockingBusy &&
                                        modelData.writable === true
                                    hoverEnabled: true
                                    preventStealing: true
                                    cursorShape:
                                        enabled
                                        ? Qt.PointingHandCursor
                                        : Qt.ArrowCursor

                                    onPressed: mouse => {
                                        displayCard.dragging = true
                                        displayCard.updatePreview(
                                            mouse.x
                                        )
                                        displayCard.queuePreview(
                                            false
                                        )
                                    }

                                    onPositionChanged: mouse => {
                                        if (!pressed)
                                            return

                                        displayCard.updatePreview(
                                            mouse.x
                                        )
                                        displayCard.queuePreview(
                                            false
                                        )
                                    }

                                    onReleased: mouse => {
                                        displayCard.updatePreview(
                                            mouse.x
                                        )
                                        displayCard.dragging = false
                                        displayCard.queuePreview(
                                            true
                                        )
                                    }

                                    onCanceled: {
                                        displayCard.dragging = false
                                        displayCard
                                            .previewPercentage =
                                            Number(
                                                modelData
                                                    .percentage || 0
                                            )
                                        displayCard.queuePreview(
                                            true
                                        )
                                    }
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8

                                Repeater {
                                    model: [-10, 10]

                                    delegate: Rectangle {
                                        required property int modelData

                                        Layout.fillWidth: true
                                        implicitHeight: 34
                                        radius: 9
                                        color: "#313147"

                                        Text {
                                            anchors.centerIn: parent
                                            text:
                                                modelData > 0
                                                ? "+10"
                                                : "-10"
                                            color: "#cdd6f4"
                                            font.pixelSize: 10
                                            font.bold: true
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            enabled:
                                                !brightness.actionBusy
                                            cursorShape:
                                                enabled
                                                ? Qt.PointingHandCursor
                                                : Qt.ArrowCursor

                                            onClicked: {
                                                brightness
                                                    .stepBrightness(
                                                        displayCard
                                                            .displayId,
                                                        modelData
                                                    )
                                            }
                                        }
                                    }
                                }

                                Rectangle {
                                    visible: brightness.simulated
                                    Layout.fillWidth: true
                                    implicitHeight: 34
                                    radius: 9
                                    color: "#3d3040"

                                    Text {
                                        anchors.centerIn: parent
                                        text: "Remove"
                                        color: "#f38ba8"
                                        font.pixelSize: 9
                                        font.bold: true
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        enabled:
                                            !brightness.actionBusy
                                        cursorShape:
                                            enabled
                                            ? Qt.PointingHandCursor
                                            : Qt.ArrowCursor

                                        onClicked: {
                                            brightness
                                                .simulationAction(
                                                    "remove-brightness-display",
                                                    modelData.id
                                                )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                RowLayout {
                    visible: brightness.simulated
                    Layout.fillWidth: true
                    spacing: 8

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 36
                        radius: 9
                        color: "#313147"

                        Text {
                            anchors.centerIn: parent
                            text: "Remove all"
                            color: "#cdd6f4"
                            font.pixelSize: 9
                            font.bold: true
                        }

                        MouseArea {
                            anchors.fill: parent
                            enabled:
                                !brightness.actionBusy &&
                                brightness.displays.length > 0
                            cursorShape:
                                enabled
                                ? Qt.PointingHandCursor
                                : Qt.ArrowCursor

                            onClicked: {
                                brightness.simulationAction(
                                    "remove-all-brightness-displays",
                                    ""
                                )
                            }
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 36
                        radius: 9
                        color: "#313147"

                        Text {
                            anchors.centerIn: parent
                            text: "Restore displays"
                            color: "#cdd6f4"
                            font.pixelSize: 9
                            font.bold: true
                        }

                        MouseArea {
                            anchors.fill: parent
                            enabled: !brightness.actionBusy
                            cursorShape:
                                enabled
                                ? Qt.PointingHandCursor
                                : Qt.ArrowCursor

                            onClicked: {
                                brightness.simulationAction(
                                    "reset-brightness-simulation",
                                    ""
                                )
                            }
                        }
                    }
                }

                Text {
                    visible:
                        brightness.actionMessage !== ""
                    Layout.fillWidth: true
                    text: brightness.actionMessage
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
