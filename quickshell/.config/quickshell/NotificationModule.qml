pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Services.Notifications
import Quickshell.Widgets
import QtQuick

Item {
    id: notificationModule

    property var service: null
    property alias doNotDisturb:
        persistentNotificationState.doNotDisturb
    property var toastNotifications: []
    property var unreadNotifications: ({})

    readonly property var receivedTimes:
        notificationModule.parseReceivedTimes(
            persistentNotificationState.receivedTimesJson
        )

    readonly property int maximumHistory: 100
    readonly property int maximumToasts: 3

    readonly property var historyNotifications:
        notificationModule.historyValues()

    readonly property int unreadCount:
        Object.keys(
            notificationModule.unreadNotifications
        ).length

    readonly property bool criticalUnread:
        notificationModule.hasCriticalUnread()

    implicitWidth: 32
    implicitHeight: 32
    width: implicitWidth
    height: implicitHeight


    PersistentProperties {
        id: persistentNotificationState

        reloadableId: "red-core-notifications"

        property bool doNotDisturb: false
        property string receivedTimesJson: "{}"
    }


    function notificationKey(notification) {
        if (
            notification === null ||
            notification === undefined
        ) {
            return ""
        }

        return String(notification.id)
    }


    function parseReceivedTimes(serialized) {
        try {
            const parsed = JSON.parse(
                String(serialized || "{}")
            )

            if (
                parsed !== null &&
                typeof parsed === "object" &&
                !Array.isArray(parsed)
            ) {
                return parsed
            }
        } catch (error) {
            console.warn(
                "Red Core notifications reset invalid timestamps"
            )
        }

        return ({})
    }


    function saveReceivedTimes(times) {
        persistentNotificationState.receivedTimesJson =
            JSON.stringify(times || ({}))
    }


    function urgencyColor(notification) {
        if (
            notification !== null &&
            notification !== undefined &&
            notification.urgency ===
                NotificationUrgency.Critical
        ) {
            return "#f38ba8"
        }

        if (
            notification !== null &&
            notification !== undefined &&
            notification.urgency ===
                NotificationUrgency.Low
        ) {
            return "#a6adc8"
        }

        return "#89b4fa"
    }


    function urgencyLabel(notification) {
        if (
            notification !== null &&
            notification !== undefined &&
            notification.urgency ===
                NotificationUrgency.Critical
        ) {
            return "Critical"
        }

        if (
            notification !== null &&
            notification !== undefined &&
            notification.urgency ===
                NotificationUrgency.Low
        ) {
            return "Low"
        }

        return "Normal"
    }


    function notificationTitle(notification) {
        const summary = String(
            notification.summary || ""
        ).trim()

        if (summary !== "")
            return summary

        const appName = String(
            notification.appName || ""
        ).trim()

        return appName !== ""
            ? appName
            : "Notification"
    }


    function notificationApp(notification) {
        const appName = String(
            notification.appName || ""
        ).trim()

        if (appName !== "")
            return appName

        const desktopEntry = String(
            notification.desktopEntry || ""
        ).trim()

        return desktopEntry !== ""
            ? desktopEntry
            : "Application"
    }


    function normalizedImageSource(source) {
        const value = String(source || "").trim()

        if (value === "")
            return ""

        if (value.startsWith("/"))
            return "file://" + value

        if (
            value.indexOf(":") >= 0 ||
            value.startsWith("qrc/")
        ) {
            return value
        }

        return Quickshell.iconPath(value, true)
    }


    function notificationImage(notification) {
        const image = notificationModule
            .normalizedImageSource(
                notification.image
            )

        if (image !== "")
            return image

        return notificationModule
            .normalizedImageSource(
                notification.appIcon
            )
    }


    function notificationInitial(notification) {
        const value = notificationModule
            .notificationApp(notification)

        return value !== ""
            ? value.charAt(0).toUpperCase()
            : "!"
    }


    function recordReceivedTime(notification) {
        const key = notificationModule
            .notificationKey(notification)

        if (key === "")
            return

        const times = Object.assign(
            {},
            notificationModule.receivedTimes
        )

        if (
            notification.lastGeneration === true &&
            Number(times[key] || 0) > 0
        ) {
            return
        }

        times[key] = Date.now()
        notificationModule.saveReceivedTimes(times)
    }


    function receivedTime(notification) {
        const key = notificationModule
            .notificationKey(notification)

        return Number(
            notificationModule.receivedTimes[key] || 0
        )
    }


    function formattedReceivedTime(notification) {
        const milliseconds =
            notificationModule.receivedTime(notification)

        if (milliseconds <= 0)
            return ""

        const received = new Date(milliseconds)
        const now = new Date()
        const sameDay =
            received.getFullYear() === now.getFullYear() &&
            received.getMonth() === now.getMonth() &&
            received.getDate() === now.getDate()

        return sameDay
            ? Qt.formatDateTime(received, "HH:mm")
            : Qt.formatDateTime(received, "dd/MM HH:mm")
    }


    function cleanupReceivedTimes() {
        const values =
            notificationServer
                .trackedNotifications.values || []
        const active = ({})

        for (let index = 0; index < values.length; ++index) {
            active[
                notificationModule.notificationKey(
                    values[index]
                )
            ] = true
        }

        const current = notificationModule.receivedTimes
        const keys = Object.keys(current)
        const cleaned = ({})

        for (let index = 0; index < keys.length; ++index) {
            if (active[keys[index]] === true)
                cleaned[keys[index]] = current[keys[index]]
        }

        notificationModule.saveReceivedTimes(cleaned)
    }


    function progressValue(notification) {
        if (
            notification === null ||
            notification === undefined ||
            notification.hints === null ||
            notification.hints === undefined
        ) {
            return -1
        }

        const hints = notification.hints
        const candidates = [
            hints["value"],
            hints["x-kde-progress-value"],
            hints["percentage"]
        ]

        for (
            let index = 0;
            index < candidates.length;
            ++index
        ) {
            const candidate = candidates[index]

            if (
                candidate === null ||
                candidate === undefined ||
                typeof candidate === "boolean"
            ) {
                continue
            }

            const value = Number(candidate)

            if (Number.isFinite(value)) {
                return Math.max(
                    0,
                    Math.min(100, value)
                )
            }
        }

        return -1
    }


    function historyValues() {
        const values =
            notificationServer
                .trackedNotifications.values || []
        const result = []

        for (
            let index = values.length - 1;
            index >= 0;
            --index
        ) {
            const notification = values[index]

            if (
                notification !== null &&
                notification !== undefined &&
                notification.transient !== true
            ) {
                result.push(notification)
            }
        }

        return result
    }


    function markUnread(notification) {
        if (
            notification === null ||
            notification === undefined ||
            notification.transient === true ||
            notification.lastGeneration === true
        ) {
            return
        }

        const key = notificationModule
            .notificationKey(notification)

        if (key === "")
            return

        const unread = Object.assign(
            {},
            notificationModule.unreadNotifications
        )

        unread[key] = notification
        notificationModule.unreadNotifications = unread
    }


    function removeUnread(notification) {
        const key = notificationModule
            .notificationKey(notification)
        const unread = Object.assign(
            {},
            notificationModule.unreadNotifications
        )

        if (
            key !== "" &&
            unread[key] === notification
        ) {
            delete unread[key]
            notificationModule.unreadNotifications = unread
        }
    }


    function markAllRead() {
        notificationModule.unreadNotifications = ({})
    }


    function hasCriticalUnread() {
        const unread =
            notificationModule.unreadNotifications
        const keys = Object.keys(unread)

        for (let index = 0; index < keys.length; ++index) {
            const notification = unread[keys[index]]

            if (
                notification !== null &&
                notification !== undefined &&
                notification.urgency ===
                    NotificationUrgency.Critical
            ) {
                return true
            }
        }

        return false
    }


    function sameNotification(first, second) {
        return first === second
    }


    function removeToast(notification) {
        const current =
            notificationModule.toastNotifications
        const result = []

        for (let index = 0; index < current.length; ++index) {
            if (
                !notificationModule.sameNotification(
                    current[index],
                    notification
                )
            ) {
                result.push(current[index])
            }
        }

        if (result.length !== current.length)
            notificationModule.toastNotifications = result
    }


    function expireTransient(notification) {
        if (
            notification !== null &&
            notification !== undefined &&
            notification.transient === true &&
            notification.tracked === true
        ) {
            notification.expire()
        }
    }


    function hideToast(notification) {
        notificationModule.removeToast(notification)
        notificationModule.expireTransient(notification)
    }


    function addToast(notification) {
        const current =
            notificationModule.toastNotifications
        const result = []

        // A replacement notification uses the same server id. Keep only
        // the newest generation in the toast stack.
        for (let index = 0; index < current.length; ++index) {
            if (
                notificationModule.notificationKey(
                    current[index]
                ) !== notificationModule.notificationKey(
                    notification
                )
            ) {
                result.push(current[index])
            }
        }

        result.push(notification)

        while (
            result.length >
                notificationModule.maximumToasts
        ) {
            const removed = result.shift()
            notificationModule.expireTransient(removed)
        }

        notificationModule.toastNotifications = result
    }


    function timeoutMilliseconds(notification) {
        const requested = Number(
            notification.expireTimeout
        )

        // The desktop notification specification uses zero for an
        // explicitly persistent notification.
        if (requested === 0)
            return 0

        if (requested > 0) {
            return Math.max(
                1500,
                Math.min(60000, requested * 1000)
            )
        }

        if (
            notification.urgency ===
                NotificationUrgency.Critical
        ) {
            return 8000
        }

        if (
            notification.urgency ===
                NotificationUrgency.Low
        ) {
            return 3500
        }

        return 5000
    }


    function receiveNotification(notification) {
        notification.tracked = true
        notificationModule.recordReceivedTime(notification)

        if (notification.lastGeneration === true) {
            if (notification.transient === true)
                notification.expire()

            return
        }

        notificationModule.markUnread(notification)

        const critical =
            notification.urgency ===
                NotificationUrgency.Critical

        if (
            notificationModule.doNotDisturb &&
            !critical
        ) {
            notificationModule.expireTransient(
                notification
            )
        } else {
            notificationModule.addToast(notification)
        }

        Qt.callLater(function() {
            notificationModule.trimHistory()
        })
    }


    function notificationClosed(notification) {
        notificationModule.removeToast(notification)
        notificationModule.removeUnread(notification)

        Qt.callLater(function() {
            notificationModule.cleanupReceivedTimes()
        })
    }


    function dismissNotification(notification) {
        if (
            notification === null ||
            notification === undefined
        ) {
            return
        }

        notificationModule.removeToast(notification)
        notificationModule.removeUnread(notification)

        if (notification.tracked === true)
            notification.dismiss()
    }


    function clearAll() {
        const values = (
            notificationServer
                .trackedNotifications.values || []
        ).slice()

        notificationModule.toastNotifications = []
        notificationModule.markAllRead()

        for (let index = 0; index < values.length; ++index) {
            if (values[index].tracked === true)
                values[index].dismiss()
        }
    }


    function trimHistory() {
        const values = notificationModule
            .historyValues()

        while (
            values.length >
                notificationModule.maximumHistory
        ) {
            const oldest = values.pop()
            notificationModule.dismissNotification(oldest)
        }
    }


    function setDoNotDisturb(enabled) {
        const requested = enabled === true

        if (
            requested ===
                notificationModule.doNotDisturb
        ) {
            return
        }

        notificationModule.doNotDisturb = requested

        if (!requested)
            return

        const current =
            notificationModule.toastNotifications.slice()
        const keep = []

        for (let index = 0; index < current.length; ++index) {
            const notification = current[index]

            if (
                notification.urgency ===
                    NotificationUrgency.Critical
            ) {
                keep.push(notification)
            } else {
                notificationModule.expireTransient(
                    notification
                )
            }
        }

        notificationModule.toastNotifications = keep
    }


    function invokeAction(notification, action) {
        if (
            notification === null ||
            notification === undefined ||
            action === null ||
            action === undefined
        ) {
            return
        }

        action.invoke()
        notificationModule.removeToast(notification)
    }


    NotificationServer {
        id: notificationServer

        keepOnReload: true
        persistenceSupported: true
        bodySupported: true
        bodyMarkupSupported: false
        bodyHyperlinksSupported: false
        bodyImagesSupported: false
        actionsSupported: true
        actionIconsSupported: false
        imageSupported: true
        inlineReplySupported: false
        extraHints: [
            "value",
            "x-kde-progress-value",
            "percentage"
        ]

        onNotification: notification => {
            notificationModule.receiveNotification(
                notification
            )
        }
    }


    // Track remote closes and replacements even when the history popup is
    // not visible, without polling the notification model.
    Repeater {
        model: notificationServer.trackedNotifications

        delegate: Item {
            id: trackedNotification

            required property var modelData

            width: 0
            height: 0
            visible: false

            Connections {
                target: trackedNotification.modelData

                function onClosed(reason) {
                    notificationModule.notificationClosed(
                        trackedNotification.modelData
                    )
                }
            }
        }
    }


    component ToastCard: Rectangle {
        id: toastCard

        required property var notification

        readonly property string imageSource:
            notificationModule.notificationImage(
                toastCard.notification
            )

        readonly property real progress:
            notificationModule.progressValue(
                toastCard.notification
            )

        width: parent !== null ? parent.width : 360
        height: Math.max(
            100,
            toastContent.implicitHeight + 22
        )
        radius: 13
        color: "#1e1e2e"
        border.width: 1
        border.color:
            notificationModule.urgencyColor(
                toastCard.notification
            )

        Rectangle {
            width: 4
            anchors {
                left: parent.left
                top: parent.top
                bottom: parent.bottom
                margins: 6
            }
            radius: 2
            color:
                notificationModule.urgencyColor(
                    toastCard.notification
                )
        }

        Column {
            id: toastContent

            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
                margins: 11
                leftMargin: 17
            }
            spacing: 8

            Row {
                width: parent.width
                height: 42
                spacing: 9

                Rectangle {
                    width: 40
                    height: 40
                    radius: 10
                    color: "#313244"
                    clip: true

                    IconImage {
                        anchors.centerIn: parent
                        implicitSize: 28
                        source: toastCard.imageSource
                        visible: toastCard.imageSource !== ""
                    }

                    Text {
                        anchors.centerIn: parent
                        visible: toastCard.imageSource === ""
                        text:
                            notificationModule
                                .notificationInitial(
                                    toastCard.notification
                                )
                        color: "#89b4fa"
                        font.pixelSize: 14
                        font.bold: true
                    }
                }

                Column {
                    width: parent.width - 84
                    spacing: 3

                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        text:
                            notificationModule.notificationApp(
                                toastCard.notification
                            ) + (
                                notificationModule
                                    .formattedReceivedTime(
                                        toastCard.notification
                                    ) !== ""
                                ? " · " +
                                  notificationModule
                                    .formattedReceivedTime(
                                        toastCard.notification
                                    )
                                : ""
                              )
                        color: "#a6adc8"
                        font.pixelSize: 9
                    }

                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        text:
                            notificationModule
                                .notificationTitle(
                                    toastCard.notification
                                )
                        textFormat: Text.PlainText
                        color: "#cdd6f4"
                        font.pixelSize: 12
                        font.bold: true
                    }
                }

                Rectangle {
                    width: 26
                    height: 26
                    radius: 7
                    color: "#313244"

                    Text {
                        anchors.centerIn: parent
                        text: "×"
                        color: "#a6adc8"
                        font.pixelSize: 14
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor

                        onClicked: {
                            notificationModule
                                .dismissNotification(
                                    toastCard.notification
                                )
                        }
                    }
                }
            }

            Text {
                visible:
                    String(
                        toastCard.notification.body || ""
                    ).trim() !== ""
                width: parent.width
                text: String(
                    toastCard.notification.body || ""
                )
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
                color: "#bac2de"
                font.pixelSize: 10
            }

            Column {
                visible: toastCard.progress >= 0
                width: parent.width
                spacing: 4

                Row {
                    width: parent.width

                    Text {
                        width: parent.width / 2
                        text: "Progress"
                        color: "#a6adc8"
                        font.pixelSize: 8
                    }

                    Text {
                        width: parent.width / 2
                        horizontalAlignment: Text.AlignRight
                        text:
                            Math.round(
                                toastCard.progress
                            ) + "%"
                        color: "#cdd6f4"
                        font.pixelSize: 8
                        font.bold: true
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 6
                    radius: 3
                    color: "#45475a"

                    Rectangle {
                        width:
                            parent.width *
                            toastCard.progress / 100
                        height: parent.height
                        radius: parent.radius
                        color:
                            notificationModule.urgencyColor(
                                toastCard.notification
                            )
                    }
                }
            }

            Flow {
                visible:
                    toastCard.notification.actions.length > 0
                width: parent.width
                spacing: 6

                Repeater {
                    model: toastCard.notification.actions

                    delegate: Rectangle {
                        id: toastAction

                        required property var modelData

                        width: Math.min(
                            120,
                            toastActionText.implicitWidth + 20
                        )
                        height: 28
                        radius: 7
                        color: "#313244"

                        Text {
                            id: toastActionText

                            anchors.centerIn: parent
                            width: Math.min(
                                implicitWidth,
                                parent.width - 12
                            )
                            elide: Text.ElideRight
                            text: String(
                                toastAction.modelData.text ||
                                "Action"
                            )
                            color: "#89b4fa"
                            font.pixelSize: 9
                            font.bold: true
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor

                            onClicked: {
                                notificationModule.invokeAction(
                                    toastCard.notification,
                                    toastAction.modelData
                                )
                            }
                        }
                    }
                }
            }
        }

        Timer {
            interval: Math.max(
                1,
                notificationModule
                    .timeoutMilliseconds(
                        toastCard.notification
                    )
            )
            running:
                notificationModule
                    .timeoutMilliseconds(
                        toastCard.notification
                    ) > 0
            repeat: false

            onTriggered: {
                notificationModule.hideToast(
                    toastCard.notification
                )
            }
        }

        Connections {
            target: toastCard.notification

            function onClosed(reason) {
                notificationModule.removeToast(
                    toastCard.notification
                )
            }
        }
    }


    component HistoryCard: Rectangle {
        id: historyCard

        required property var notification

        property bool expanded: false

        readonly property string imageSource:
            notificationModule.notificationImage(
                historyCard.notification
            )

        readonly property real progress:
            notificationModule.progressValue(
                historyCard.notification
            )

        width: parent !== null ? parent.width : 0
        height: Math.max(
            92,
            historyCardContent.implicitHeight + 20
        )
        radius: 11
        color: "#28283d"

        Rectangle {
            width: 3
            anchors {
                left: parent.left
                top: parent.top
                bottom: parent.bottom
                margins: 6
            }
            radius: 2
            color:
                notificationModule.urgencyColor(
                    historyCard.notification
                )
        }

        Column {
            id: historyCardContent

            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
                margins: 10
                leftMargin: 16
            }
            spacing: 7

            Row {
                width: parent.width
                height: 42
                spacing: 9

                Rectangle {
                    width: 40
                    height: 40
                    radius: 10
                    color: "#313244"
                    clip: true

                    IconImage {
                        anchors.centerIn: parent
                        implicitSize: 28
                        source: historyCard.imageSource
                        visible:
                            historyCard.imageSource !== ""
                    }

                    Text {
                        anchors.centerIn: parent
                        visible:
                            historyCard.imageSource === ""
                        text:
                            notificationModule
                                .notificationInitial(
                                    historyCard.notification
                                )
                        color: "#89b4fa"
                        font.pixelSize: 14
                        font.bold: true
                    }
                }

                Column {
                    width: parent.width - 84
                    spacing: 3

                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        text:
                            notificationModule.notificationApp(
                                historyCard.notification
                            ) + " · " +
                            notificationModule.urgencyLabel(
                                historyCard.notification
                            ) + (
                                notificationModule
                                    .formattedReceivedTime(
                                        historyCard.notification
                                    ) !== ""
                                ? " · " +
                                  notificationModule
                                    .formattedReceivedTime(
                                        historyCard.notification
                                    )
                                : ""
                              )
                        color: "#a6adc8"
                        font.pixelSize: 9
                    }

                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        text:
                            notificationModule
                                .notificationTitle(
                                    historyCard.notification
                                )
                        textFormat: Text.PlainText
                        color: "#cdd6f4"
                        font.pixelSize: 11
                        font.bold: true
                    }
                }

                Rectangle {
                    width: 26
                    height: 26
                    radius: 7
                    color: "#313244"

                    Text {
                        anchors.centerIn: parent
                        text: "×"
                        color: "#a6adc8"
                        font.pixelSize: 14
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor

                        onClicked: {
                            notificationModule
                                .dismissNotification(
                                    historyCard.notification
                                )
                        }
                    }
                }
            }

            Text {
                id: historyBodyText

                visible:
                    String(
                        historyCard.notification.body || ""
                    ).trim() !== ""
                width: parent.width
                text: String(
                    historyCard.notification.body || ""
                )
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                maximumLineCount:
                    historyCard.expanded ? 40 : 4
                elide:
                    historyCard.expanded
                    ? Text.ElideNone
                    : Text.ElideRight
                color: "#bac2de"
                font.pixelSize: 10
            }

            Rectangle {
                visible:
                    historyBodyText.truncated ||
                    historyCard.expanded
                width: 76
                height: visible ? 24 : 0
                radius: 7
                color: "#313244"

                Text {
                    anchors.centerIn: parent
                    text:
                        historyCard.expanded
                        ? "Show less"
                        : "Show more"
                    color: "#89b4fa"
                    font.pixelSize: 8
                    font.bold: true
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor

                    onClicked: {
                        historyCard.expanded =
                            !historyCard.expanded
                    }
                }
            }

            Column {
                visible: historyCard.progress >= 0
                width: parent.width
                spacing: 4

                Row {
                    width: parent.width

                    Text {
                        width: parent.width / 2
                        text: "Progress"
                        color: "#a6adc8"
                        font.pixelSize: 8
                    }

                    Text {
                        width: parent.width / 2
                        horizontalAlignment: Text.AlignRight
                        text:
                            Math.round(
                                historyCard.progress
                            ) + "%"
                        color: "#cdd6f4"
                        font.pixelSize: 8
                        font.bold: true
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 6
                    radius: 3
                    color: "#45475a"

                    Rectangle {
                        width:
                            parent.width *
                            historyCard.progress / 100
                        height: parent.height
                        radius: parent.radius
                        color:
                            notificationModule.urgencyColor(
                                historyCard.notification
                            )
                    }
                }
            }

            Flow {
                visible:
                    historyCard.notification.actions.length > 0
                width: parent.width
                spacing: 6

                Repeater {
                    model: historyCard.notification.actions

                    delegate: Rectangle {
                        id: historyAction

                        required property var modelData

                        width: Math.min(
                            120,
                            historyActionText.implicitWidth + 20
                        )
                        height: 28
                        radius: 7
                        color: "#313244"

                        Text {
                            id: historyActionText

                            anchors.centerIn: parent
                            width: Math.min(
                                implicitWidth,
                                parent.width - 12
                            )
                            elide: Text.ElideRight
                            text: String(
                                historyAction.modelData.text ||
                                "Action"
                            )
                            color: "#89b4fa"
                            font.pixelSize: 9
                            font.bold: true
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor

                            onClicked: {
                                notificationModule.invokeAction(
                                    historyCard.notification,
                                    historyAction.modelData
                                )
                            }
                        }
                    }
                }
            }
        }
    }


    Rectangle {
        id: notificationButton

        anchors.fill: parent
        radius: 10
        color:
            notificationModule.criticalUnread
            ? "#f38ba8"
            : (
                notificationModule.unreadCount > 0
                ? "#89b4fa"
                : "#313244"
              )

        Text {
            anchors.centerIn: parent
            text:
                notificationModule.unreadCount > 99
                ? "99+"
                : (
                    notificationModule.unreadCount > 0
                    ? String(notificationModule.unreadCount)
                    : (
                        notificationModule.doNotDisturb
                        ? "Z"
                        : "!"
                      )
                  )
            color:
                notificationModule.unreadCount > 0
                ? "#11111b"
                : (
                    notificationModule.doNotDisturb
                    ? "#f9e2af"
                    : "#cdd6f4"
                  )
            font.pixelSize:
                notificationModule.unreadCount > 99
                ? 8
                : 12
            font.bold: true
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor

            onClicked: {
                if (notificationModule.service !== null) {
                    notificationModule.service.togglePopup(
                        "notifications"
                    )
                } else {
                    notificationsPopup.visible =
                        !notificationsPopup.visible
                }
            }
        }
    }


    Connections {
        target: notificationModule.service

        function onActivePopupChanged() {
            notificationsPopup.visible =
                notificationModule.service.activePopup ===
                    "notifications"

            if (notificationsPopup.visible)
                notificationModule.markAllRead()
        }
    }


    PanelWindow {
        id: toastWindow

        visible:
            notificationModule.toastNotifications.length > 0
        color: "transparent"
        focusable: false
        aboveWindows: true
        exclusiveZone: 0

        implicitWidth: 360
        implicitHeight: Math.max(
            1,
            toastColumn.implicitHeight
        )

        anchors {
            top: true
            right: true
        }

        margins {
            top: 58
            right: 14
        }

        Column {
            id: toastColumn

            width: toastWindow.width
            spacing: 10

            Repeater {
                model:
                    notificationModule.toastNotifications

                delegate: ToastCard {
                    required property var modelData

                    notification: modelData
                }
            }
        }
    }


    PopupWindow {
        id: notificationsPopup

        visible: false
        grabFocus: true
        color: "transparent"

        implicitWidth: 420
        implicitHeight: 560

        anchor {
            item: notificationButton
            edges: Edges.Bottom | Edges.Right
            gravity: Edges.Bottom | Edges.Left
            adjustment: PopupAdjustment.All
        }

        onVisibleChanged: {
            if (visible) {
                notificationModule.markAllRead()
                return
            }

            if (
                notificationModule.service !== null &&
                notificationModule.service.activePopup ===
                    "notifications"
            ) {
                notificationModule.service.closePopup(
                    "notifications"
                )
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
                spacing: 10

                Row {
                    width: parent.width
                    height: 34
                    spacing: 8

                    Text {
                        width: parent.width - 154
                        anchors.verticalCenter:
                            parent.verticalCenter
                        text: "Notifications"
                        color: "#cdd6f4"
                        font.pixelSize: 17
                        font.bold: true
                    }

                    Rectangle {
                        width: 82
                        height: 28
                        anchors.verticalCenter:
                            parent.verticalCenter
                        radius: 8
                        color:
                            notificationModule.doNotDisturb
                            ? "#f9e2af"
                            : "#313244"

                        Text {
                            anchors.centerIn: parent
                            text:
                                notificationModule.doNotDisturb
                                ? "DND On"
                                : "DND Off"
                            color:
                                notificationModule.doNotDisturb
                                ? "#11111b"
                                : "#cdd6f4"
                            font.pixelSize: 8
                            font.bold: true
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor

                            onClicked: {
                                notificationModule
                                    .setDoNotDisturb(
                                        !notificationModule
                                            .doNotDisturb
                                    )
                            }
                        }
                    }

                    Rectangle {
                        width: 56
                        height: 28
                        anchors.verticalCenter:
                            parent.verticalCenter
                        radius: 8
                        color: "#313244"
                        opacity:
                            notificationModule
                                .historyNotifications.length > 0
                            ? 1
                            : 0.4

                        Text {
                            anchors.centerIn: parent
                            text: "Clear"
                            color: "#cdd6f4"
                            font.pixelSize: 8
                            font.bold: true
                        }

                        MouseArea {
                            anchors.fill: parent
                            enabled:
                                notificationModule
                                    .historyNotifications.length > 0
                            cursorShape: enabled
                                ? Qt.PointingHandCursor
                                : Qt.ArrowCursor

                            onClicked:
                                notificationModule.clearAll()
                        }
                    }
                }

                Item {
                    width: parent.width
                    height: parent.height - 44

                    Text {
                        anchors.centerIn: parent
                        visible:
                            notificationModule
                                .historyNotifications.length === 0
                        text:
                            notificationModule.doNotDisturb
                            ? "No notifications · Do Not Disturb is on"
                            : "No notifications"
                        color: "#7f849c"
                        font.pixelSize: 11
                    }

                    Flickable {
                        id: historyFlick

                        anchors.fill: parent
                        visible:
                            notificationModule
                                .historyNotifications.length > 0
                        clip: true
                        contentWidth: width
                        contentHeight:
                            historyColumn.implicitHeight

                        Column {
                            id: historyColumn

                            width: historyFlick.width
                            spacing: 9

                            Repeater {
                                model:
                                    notificationModule
                                        .historyNotifications

                                delegate: HistoryCard {
                                    required property var modelData

                                    notification: modelData
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
