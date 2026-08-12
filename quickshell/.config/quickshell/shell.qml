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
                    text: "CPU --%"
                    color: "#cdd6f4"
                    font.pixelSize: 13
                }

                Text {
                    text: "RAM --%"
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
                text: "WiFi"
                color: "#cdd6f4"
                font.pixelSize: 13
            }

            Text {
                text: "Vol --%"
                color: "#cdd6f4"
                font.pixelSize: 13
            }

            // Battery will be dynamic later.
            // It will only appear on devices that actually have one.

            Rectangle {
                width: 1
                height: 22
                color: "#45475a"
                anchors.verticalCenter: parent.verticalCenter
            }

            Text {
                text: Qt.formatDateTime(clock.date, "dd/MM")
                color: "#cdd6f4"
                font.pixelSize: 13
            }

            Text {
                text: Qt.formatDateTime(clock.date, "HH:mm")
                color: "#cdd6f4"
                font.pixelSize: 13
            }

            Rectangle {
                width: 1
                height: 22
                color: "#45475a"
                anchors.verticalCenter: parent.verticalCenter
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
