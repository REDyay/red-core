pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Services.Pipewire
import QtQuick

Item {
    id: audioModule

    property var service: null
    property bool outputsExpanded: false
    property bool inputsExpanded: false

    implicitWidth: 64
    implicitHeight: 32
    width: implicitWidth
    height: implicitHeight

    readonly property var outputNodes:
        audioModule.filteredNodes(true)

    readonly property var inputNodes:
        audioModule.filteredNodes(false)

    readonly property var defaultOutput:
        Pipewire.defaultAudioSink

    readonly property var defaultInput:
        Pipewire.defaultAudioSource

    readonly property bool defaultOutputReady:
        audioModule.defaultOutput !== null &&
        audioModule.defaultOutput !== undefined &&
        audioModule.defaultOutput.audio !== null &&
        audioModule.defaultOutput.audio !== undefined

    readonly property real defaultOutputVolume:
        audioModule.defaultOutputReady
        ? Math.max(
            0,
            Math.min(
                1,
                Number(audioModule.defaultOutput.audio.volume)
            )
          )
        : 0

    readonly property bool defaultOutputMuted:
        audioModule.defaultOutputReady &&
        audioModule.defaultOutput.audio.muted


    function hasType(node, nodeType) {
        if (node === null || node === undefined)
            return false

        const value = Number(node.type)
        const wanted = Number(nodeType)

        return (
            wanted !== 0 &&
            (value & wanted) === wanted
        )
    }


    function propertyText(node, name) {
        if (
            node === null ||
            node === undefined ||
            node.properties === null ||
            node.properties === undefined
        ) {
            return ""
        }

        return String(node.properties[name] || "")
    }


    function isMonitorSource(node) {
        const nodeName = String(node.name || "")
            .toLowerCase()
        const description = String(
            node.description || ""
        ).toLowerCase()
        const deviceClass = audioModule.propertyText(
            node,
            "device.class"
        ).toLowerCase()
        const mediaClass = audioModule.propertyText(
            node,
            "media.class"
        ).toLowerCase()

        return (
            deviceClass === "monitor" ||
            mediaClass.indexOf("monitor") >= 0 ||
            nodeName.endsWith(".monitor") ||
            description.startsWith("monitor of ")
        )
    }


    function filteredNodes(outputs) {
        const values = Pipewire.nodes.values || []
        const result = []

        for (let index = 0; index < values.length; ++index) {
            const node = values[index]

            if (
                node === null ||
                node === undefined ||
                node.isStream === true
            ) {
                continue
            }

            const matches = outputs
                ? audioModule.hasType(
                    node,
                    PwNodeType.AudioSink
                  )
                : audioModule.hasType(
                    node,
                    PwNodeType.AudioSource
                  )

            if (!matches)
                continue

            if (
                !outputs &&
                audioModule.isMonitorSource(node)
            ) {
                continue
            }

            result.push(node)
        }

        result.sort(function(first, second) {
            return audioModule.nodeLabel(first)
                .localeCompare(
                    audioModule.nodeLabel(second)
                )
        })

        return result
    }


    function trackedNodes() {
        const combined = audioModule.outputNodes
            .concat(audioModule.inputNodes)
        const result = []
        const ids = ({})

        for (
            let index = 0;
            index < combined.length;
            ++index
        ) {
            const node = combined[index]

            if (node === null || node === undefined)
                continue

            const key = String(node.id)

            if (ids[key] === true)
                continue

            ids[key] = true
            result.push(node)
        }

        return result
    }


    function nodeLabel(node) {
        if (node === null || node === undefined)
            return "Unavailable"

        const description = String(
            node.description || ""
        ).trim()
        const nickname = String(
            node.nickname || ""
        ).trim()
        const name = String(node.name || "").trim()

        if (description !== "")
            return description

        if (nickname !== "")
            return nickname

        return name !== "" ? name : "Audio device"
    }


    function nodeDetail(node) {
        if (node === null || node === undefined)
            return ""

        const label = audioModule.nodeLabel(node)
        const nickname = String(
            node.nickname || ""
        ).trim()
        const deviceName = audioModule.propertyText(
            node,
            "device.product.name"
        ).trim()

        if (nickname !== "" && nickname !== label)
            return nickname

        if (deviceName !== "" && deviceName !== label)
            return deviceName

        return String(node.name || "")
    }


    function sameNode(first, second) {
        return (
            first !== null &&
            first !== undefined &&
            second !== null &&
            second !== undefined &&
            Number(first.id) === Number(second.id)
        )
    }


    function nodesToShow(outputs) {
        const nodes = outputs
            ? audioModule.outputNodes
            : audioModule.inputNodes
        const expanded = outputs
            ? audioModule.outputsExpanded
            : audioModule.inputsExpanded
        const selected = outputs
            ? audioModule.defaultOutput
            : audioModule.defaultInput

        if (expanded)
            return nodes

        for (let index = 0; index < nodes.length; ++index) {
            if (audioModule.sameNode(nodes[index], selected))
                return [nodes[index]]
        }

        return nodes.length > 0 ? [nodes[0]] : []
    }


    function listedDefault(outputs) {
        const nodes = outputs
            ? audioModule.outputNodes
            : audioModule.inputNodes
        const selected = outputs
            ? audioModule.defaultOutput
            : audioModule.defaultInput

        for (let index = 0; index < nodes.length; ++index) {
            if (audioModule.sameNode(nodes[index], selected))
                return nodes[index]
        }

        return nodes.length > 0 ? nodes[0] : null
    }


    function selectDefault(node, output) {
        if (node === null || node === undefined)
            return

        if (output) {
            Pipewire.preferredDefaultAudioSink = node
            audioModule.outputsExpanded = false
        } else {
            Pipewire.preferredDefaultAudioSource = node
            audioModule.inputsExpanded = false
        }
    }


    function setVolume(node, value) {
        if (
            node === null ||
            node === undefined ||
            node.audio === null ||
            node.audio === undefined
        ) {
            return
        }

        const safeValue = Math.max(
            0,
            Math.min(1, Number(value))
        )

        node.audio.volume = safeValue

        if (node.audio.muted && safeValue > 0)
            node.audio.muted = false
    }


    function stepDefaultOutput(delta) {
        const node = audioModule.defaultOutput

        if (
            node === null ||
            node === undefined ||
            node.audio === null ||
            node.audio === undefined
        ) {
            return
        }

        audioModule.setVolume(
            node,
            Number(node.audio.volume) + Number(delta)
        )
    }


    function toggleDefaultOutputMute() {
        if (!audioModule.defaultOutputReady)
            return

        audioModule.defaultOutput.audio.muted =
            !audioModule.defaultOutput.audio.muted
    }


    PwObjectTracker {
        objects: audioModule.trackedNodes()
    }


    component DeviceCard: Rectangle {
        id: deviceCard

        required property var deviceNode
        required property bool outputDevice

        readonly property var selectedNode:
            outputDevice
            ? audioModule.defaultOutput
            : audioModule.defaultInput

        readonly property bool selected:
            audioModule.sameNode(
                deviceNode,
                selectedNode
            )

        readonly property bool controllable:
            deviceNode !== null &&
            deviceNode !== undefined &&
            deviceNode.audio !== null &&
            deviceNode.audio !== undefined

        property bool dragging: false
        property real previewVolume: 0

        readonly property real shownVolume:
            dragging
            ? previewVolume
            : (
                controllable
                ? Math.max(
                    0,
                    Math.min(
                        1,
                        Number(deviceNode.audio.volume)
                    )
                  )
                : 0
              )

        function previewAt(position) {
            if (volumeTrack.width <= 0)
                return

            const localPosition =
                position - volumeTrack.x

            previewVolume = Math.max(
                0,
                Math.min(
                    1,
                    localPosition / volumeTrack.width
                )
            )

            audioModule.setVolume(
                deviceNode,
                previewVolume
            )
        }

        width: parent !== null ? parent.width : 0
        height: 112
        radius: 11
        color: selected ? "#2d3348" : "#28283d"
        border.width: selected ? 1 : 0
        border.color: "#89b4fa"

        Column {
            anchors.fill: parent
            anchors.margins: 11
            spacing: 8

            Row {
                width: parent.width
                height: 28
                spacing: 8

                Item {
                    width: parent.width - 70
                    height: parent.height

                    Column {
                        anchors.fill: parent
                        spacing: 2

                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            text: audioModule.nodeLabel(
                                deviceCard.deviceNode
                            )
                            color: "#cdd6f4"
                            font.pixelSize: 11
                            font.bold: true
                        }

                        Text {
                            width: parent.width
                            elide: Text.ElideMiddle
                            text: audioModule.nodeDetail(
                                deviceCard.deviceNode
                            )
                            color: "#7f849c"
                            font.pixelSize: 8
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor

                        onClicked: {
                            audioModule.selectDefault(
                                deviceCard.deviceNode,
                                deviceCard.outputDevice
                            )
                        }
                    }
                }

                Rectangle {
                    width: 62
                    height: 26
                    radius: 7
                    color: deviceCard.selected
                        ? "#89b4fa"
                        : "#313244"

                    Text {
                        anchors.centerIn: parent
                        text: deviceCard.selected
                            ? "Default"
                            : "Use"
                        color: deviceCard.selected
                            ? "#11111b"
                            : "#cdd6f4"
                        font.pixelSize: 8
                        font.bold: true
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor

                        onClicked: {
                            audioModule.selectDefault(
                                deviceCard.deviceNode,
                                deviceCard.outputDevice
                            )
                        }
                    }
                }
            }

            Row {
                width: parent.width
                height: 42
                spacing: 8

                Rectangle {
                    width: 42
                    height: 30
                    anchors.verticalCenter: parent.verticalCenter
                    radius: 8
                    color:
                        deviceCard.controllable &&
                        deviceCard.deviceNode.audio.muted
                        ? "#f38ba8"
                        : "#313244"

                    Text {
                        anchors.centerIn: parent
                        text: deviceCard.outputDevice
                            ? "SPK"
                            : "MIC"
                        color:
                            deviceCard.controllable &&
                            deviceCard.deviceNode.audio.muted
                            ? "#11111b"
                            : "#cdd6f4"
                        font.pixelSize: 8
                        font.bold: true
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: deviceCard.controllable
                        cursorShape: enabled
                            ? Qt.PointingHandCursor
                            : Qt.ArrowCursor

                        onClicked: {
                            deviceCard.deviceNode.audio.muted =
                                !deviceCard.deviceNode.audio.muted
                        }
                    }
                }

                Item {
                    width: parent.width - 96
                    height: parent.height

                    Rectangle {
                        id: volumeTrack

                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: 9
                        anchors.rightMargin: 9
                        anchors.verticalCenter: parent.verticalCenter
                        height: 10
                        radius: 5
                        color: "#45475a"

                        Rectangle {
                            width:
                                parent.width *
                                deviceCard.shownVolume
                            height: parent.height
                            radius: parent.radius
                            color: deviceCard.outputDevice
                                ? "#89b4fa"
                                : "#a6e3a1"
                        }

                        Rectangle {
                            width: 18
                            height: 18
                            radius: 9
                            x: Math.max(
                                -width / 2,
                                Math.min(
                                    parent.width - width / 2,
                                    parent.width *
                                        deviceCard.shownVolume -
                                        width / 2
                                )
                            )
                            anchors.verticalCenter:
                                parent.verticalCenter
                            color: deviceCard.dragging
                                ? "#ffffff"
                                : "#cdd6f4"
                            border.width: 2
                            border.color: deviceCard.outputDevice
                                ? "#89b4fa"
                                : "#a6e3a1"
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: deviceCard.controllable
                        preventStealing: true
                        cursorShape: enabled
                            ? Qt.PointingHandCursor
                            : Qt.ArrowCursor

                        onPressed: mouse => {
                            deviceCard.dragging = true
                            deviceCard.previewAt(mouse.x)
                        }

                        onPositionChanged: mouse => {
                            if (pressed)
                                deviceCard.previewAt(mouse.x)
                        }

                        onReleased: mouse => {
                            deviceCard.previewAt(mouse.x)
                            deviceCard.dragging = false
                        }

                        onCanceled:
                            deviceCard.dragging = false

                        onWheel: wheel => {
                            const direction =
                                wheel.angleDelta.y >= 0
                                ? 0.03
                                : -0.03
                            audioModule.setVolume(
                                deviceCard.deviceNode,
                                deviceCard.shownVolume + direction
                            )
                        }
                    }
                }

                Text {
                    width: 38
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    text: deviceCard.controllable
                        ? Math.round(
                            deviceCard.shownVolume * 100
                          ) + "%"
                        : "--%"
                    color: "#cdd6f4"
                    font.pixelSize: 10
                    font.bold: true
                }
            }
        }
    }


    Rectangle {
        id: audioButton

        anchors.fill: parent
        radius: 10
        color: "#313244"

        Text {
            anchors.centerIn: parent

            text: {
                const node = audioModule.defaultOutput

                if (
                    node === null ||
                    node === undefined ||
                    node.audio === null ||
                    node.audio === undefined
                ) {
                    return "--%"
                }

                if (node.audio.muted)
                    return "Muted"

                return Math.round(
                    Math.max(
                        0,
                        Math.min(
                            1,
                            Number(node.audio.volume)
                        )
                    ) * 100
                ) + "%"
            }

            color:
                audioModule.defaultOutput !== null &&
                audioModule.defaultOutput !== undefined &&
                audioModule.defaultOutput.audio !== null &&
                audioModule.defaultOutput.audio !== undefined &&
                audioModule.defaultOutput.audio.muted
                ? "#f38ba8"
                : "#cdd6f4"
            font.pixelSize: 12
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor

            onClicked: {
                if (audioModule.service !== null) {
                    audioModule.service.togglePopup("audio")
                } else {
                    audioPopup.visible = !audioPopup.visible
                }
            }

            onWheel: wheel => {
                audioModule.stepDefaultOutput(
                    wheel.angleDelta.y >= 0
                    ? 0.03
                    : -0.03
                )
            }
        }
    }


    Connections {
        target: audioModule.service

        function onActivePopupChanged() {
            audioPopup.visible =
                audioModule.service.activePopup === "audio"
        }
    }


    PopupWindow {
        id: audioPopup

        visible: false
        grabFocus: true
        color: "transparent"

        implicitWidth: 420
        implicitHeight: 560

        anchor {
            item: audioButton
            edges: Edges.Bottom | Edges.Right
            gravity: Edges.Bottom | Edges.Left
            adjustment: PopupAdjustment.All
        }

        onVisibleChanged: {
            if (!visible) {
                audioModule.outputsExpanded = false
                audioModule.inputsExpanded = false

                if (
                    audioModule.service !== null &&
                    audioModule.service.activePopup === "audio"
                ) {
                    audioModule.service.closePopup("audio")
                }
            }
        }

        Rectangle {
            anchors.fill: parent
            radius: 16
            color: "#1e1e2e"
            border.width: 1
            border.color: "#45475a"

            Flickable {
                id: audioFlick

                anchors.fill: parent
                anchors.margins: 16
                clip: true
                contentWidth: width
                contentHeight: audioContent.implicitHeight

                Column {
                    id: audioContent

                    width: audioFlick.width
                    spacing: 12

                    Text {
                        text: "Sound"
                        color: "#cdd6f4"
                        font.pixelSize: 18
                        font.bold: true
                    }

                    Rectangle {
                        width: parent.width
                        height: outputContent.implicitHeight + 22
                        radius: 12
                        color: "#252537"

                        Column {
                            id: outputContent

                            anchors {
                                left: parent.left
                                right: parent.right
                                top: parent.top
                                margins: 11
                            }
                            spacing: 9

                            Row {
                                width: parent.width
                                height: 34
                                spacing: 8

                                Rectangle {
                                    width: 38
                                    height: 30
                                    radius: 8
                                    color: audioModule.outputsExpanded
                                        ? "#89b4fa"
                                        : "#313244"

                                    Text {
                                        anchors.centerIn: parent
                                        text: "SPK"
                                        color: audioModule.outputsExpanded
                                            ? "#11111b"
                                            : "#cdd6f4"
                                        font.pixelSize: 8
                                        font.bold: true
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        enabled:
                                            audioModule.outputNodes.length > 0
                                        cursorShape: enabled
                                            ? Qt.PointingHandCursor
                                            : Qt.ArrowCursor

                                        onClicked: {
                                            audioModule.outputsExpanded =
                                                !audioModule.outputsExpanded
                                            audioModule.inputsExpanded = false
                                        }
                                    }
                                }

                                Item {
                                    width: parent.width - 80
                                    height: parent.height

                                    Column {
                                        anchors.fill: parent
                                        spacing: 2

                                        Text {
                                            text: "Output"
                                            color: "#cdd6f4"
                                            font.pixelSize: 12
                                            font.bold: true
                                        }

                                        Text {
                                            width: parent.width
                                            elide: Text.ElideRight
                                            text: audioModule.defaultOutput !== null
                                                ? audioModule.nodeLabel(
                                                    audioModule.defaultOutput
                                                  )
                                                : "No output detected"
                                            color: "#a6adc8"
                                            font.pixelSize: 9
                                        }
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        enabled:
                                            audioModule.outputNodes.length > 0
                                        cursorShape: enabled
                                            ? Qt.PointingHandCursor
                                            : Qt.ArrowCursor

                                        onClicked: {
                                            audioModule.outputsExpanded =
                                                !audioModule.outputsExpanded
                                            audioModule.inputsExpanded = false
                                        }
                                    }
                                }

                                Text {
                                    width: 26
                                    anchors.verticalCenter: parent.verticalCenter
                                    horizontalAlignment: Text.AlignHCenter
                                    text: audioModule.outputsExpanded
                                        ? "▴"
                                        : "▾"
                                    color: "#a6adc8"
                                    font.pixelSize: 12

                                    MouseArea {
                                        anchors.fill: parent
                                        enabled:
                                            audioModule.outputNodes.length > 0
                                        cursorShape: enabled
                                            ? Qt.PointingHandCursor
                                            : Qt.ArrowCursor

                                        onClicked: {
                                            audioModule.outputsExpanded =
                                                !audioModule.outputsExpanded
                                            audioModule.inputsExpanded = false
                                        }
                                    }
                                }
                            }

                            Repeater {
                                model: audioModule.nodesToShow(true)

                                delegate: DeviceCard {
                                    required property var modelData

                                    deviceNode: modelData
                                    outputDevice: true
                                }
                            }

                            Text {
                                visible:
                                    audioModule.outputNodes.length === 0
                                width: parent.width
                                text: "No audio output is available"
                                color: "#7f849c"
                                font.pixelSize: 10
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }
                    }

                    Rectangle {
                        visible:
                            audioModule.inputNodes.length > 0
                        width: parent.width
                        height: visible
                            ? inputContent.implicitHeight + 22
                            : 0
                        radius: 12
                        color: "#252537"

                        Column {
                            id: inputContent

                            anchors {
                                left: parent.left
                                right: parent.right
                                top: parent.top
                                margins: 11
                            }
                            spacing: 9

                            Row {
                                width: parent.width
                                height: 34
                                spacing: 8

                                Rectangle {
                                    width: 38
                                    height: 30
                                    radius: 8
                                    color: audioModule.inputsExpanded
                                        ? "#a6e3a1"
                                        : "#313244"

                                    Text {
                                        anchors.centerIn: parent
                                        text: "MIC"
                                        color: audioModule.inputsExpanded
                                            ? "#11111b"
                                            : "#cdd6f4"
                                        font.pixelSize: 8
                                        font.bold: true
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        enabled:
                                            audioModule.inputNodes.length > 0
                                        cursorShape: enabled
                                            ? Qt.PointingHandCursor
                                            : Qt.ArrowCursor

                                        onClicked: {
                                            audioModule.inputsExpanded =
                                                !audioModule.inputsExpanded
                                            audioModule.outputsExpanded = false
                                        }
                                    }
                                }

                                Item {
                                    width: parent.width - 80
                                    height: parent.height

                                    Column {
                                        anchors.fill: parent
                                        spacing: 2

                                        Text {
                                            text: "Microphone"
                                            color: "#cdd6f4"
                                            font.pixelSize: 12
                                            font.bold: true
                                        }

                                        Text {
                                            width: parent.width
                                            elide: Text.ElideRight
                                            text: audioModule.listedDefault(
                                                false
                                            ) !== null
                                                ? audioModule.nodeLabel(
                                                    audioModule.listedDefault(
                                                        false
                                                    )
                                                  )
                                                : "No microphone detected"
                                            color: "#a6adc8"
                                            font.pixelSize: 9
                                        }
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        enabled:
                                            audioModule.inputNodes.length > 0
                                        cursorShape: enabled
                                            ? Qt.PointingHandCursor
                                            : Qt.ArrowCursor

                                        onClicked: {
                                            audioModule.inputsExpanded =
                                                !audioModule.inputsExpanded
                                            audioModule.outputsExpanded = false
                                        }
                                    }
                                }

                                Text {
                                    width: 26
                                    anchors.verticalCenter: parent.verticalCenter
                                    horizontalAlignment: Text.AlignHCenter
                                    text: audioModule.inputsExpanded
                                        ? "▴"
                                        : "▾"
                                    color: "#a6adc8"
                                    font.pixelSize: 12

                                    MouseArea {
                                        anchors.fill: parent
                                        enabled:
                                            audioModule.inputNodes.length > 0
                                        cursorShape: enabled
                                            ? Qt.PointingHandCursor
                                            : Qt.ArrowCursor

                                        onClicked: {
                                            audioModule.inputsExpanded =
                                                !audioModule.inputsExpanded
                                            audioModule.outputsExpanded = false
                                        }
                                    }
                                }
                            }

                            Repeater {
                                model: audioModule.nodesToShow(false)

                                delegate: DeviceCard {
                                    required property var modelData

                                    deviceNode: modelData
                                    outputDevice: false
                                }
                            }
                        }
                    }

                    Text {
                        width: parent.width
                        text:
                            "Devices update automatically through PipeWire"
                        color: "#6c7086"
                        font.pixelSize: 9
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
            }
        }
    }
}
