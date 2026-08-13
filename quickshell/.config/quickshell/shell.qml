import Quickshell
import Quickshell.Io
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

            // Media player placeholder
            Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8

                Text {
                    text: "▶"
                    color: "#89b4fa"
                    font.pixelSize: 13
                }

                Text {
                    text: "No media"
                    color: "#cdd6f4"
                    font.pixelSize: 13
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

            Text {
                text: "Vol --%"
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
}
