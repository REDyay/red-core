import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Window
import Qt.labs.folderlistmodel

PanelWindow {
    id: picker

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    exclusiveZone: 0
    color: "transparent"

    property bool pickerVisible: false
    visible: pickerVisible
    focusable: pickerVisible

    // ---------------------------------------------------------
    // Same scaling idea used by the reference theme.
    // Base design: 1920x1080.
    // ---------------------------------------------------------

    readonly property real baseScale: {
        if (width <= 0 || height <= 0)
            return 1.0

        const rw = width / 1920.0
        const rh = height / 1080.0
        const r = Math.min(rw, rh)

        if (r <= 1.0)
            return Math.max(
                0.35,
                Math.pow(r, 0.85)
            )

        return Math.pow(r, 0.5)
    }

    function s(value) {
        return Math.round(
            value * picker.baseScale
        )
    }

    // ---------------------------------------------------------
    // Reference carousel geometry.
    // ---------------------------------------------------------

    readonly property real itemWidth:
        picker.s(400)

    readonly property real itemHeight:
        picker.s(420)

    readonly property real borderWidth:
        picker.s(3)

    readonly property real itemSpacing:
        picker.s(10)

    readonly property real skewFactor:
        -0.35

    readonly property int animationDuration:
        500

    property bool initialFocusSet: false
    property bool initialFocusScheduled: false

    property int rememberedIndex: -1

    property int scrollAccum: 0

    readonly property real scrollThreshold:
        picker.s(300)

    // ---------------------------------------------------------
    // Stable wallpaper filter layer.
    //
    // The carousel itself stays untouched.
    // We only rebuild the model it receives.
    // ---------------------------------------------------------

    property string currentFilter: "All"
    property var colorMap: ({})
    property int cacheVersion: 0

    readonly property string colorMarkerDirectory:
        "file://" +
        Quickshell.env("HOME") +
        "/.cache/red-core/wallpaper-picker/colors_markers"

    function getHexBucket(hexStr) {
        if (!hexStr)
            return "Monochrome"

        let hex =
            String(hexStr)
                .replace("#", "")
                .trim()

        if (hex.length > 6)
            hex = hex.substring(0, 6)

        if (hex.length !== 6)
            return "Monochrome"

        const r =
            parseInt(hex.substring(0, 2), 16) / 255

        const g =
            parseInt(hex.substring(2, 4), 16) / 255

        const b =
            parseInt(hex.substring(4, 6), 16) / 255

        if (
            isNaN(r) ||
            isNaN(g) ||
            isNaN(b)
        )
            return "Monochrome"

        const max =
            Math.max(r, g, b)

        const min =
            Math.min(r, g, b)

        const d =
            max - min

        const saturation =
            max === 0
            ? 0
            : d / max

        const value = max

        if (
            saturation < 0.08 ||
            value < 0.10
        )
            return "Monochrome"

        let h = 0

        if (d !== 0) {
            if (max === r) {
                h =
                    60 *
                    (
                        ((g - b) / d) % 6
                    )
            } else if (max === g) {
                h =
                    60 *
                    (
                        ((b - r) / d) + 2
                    )
            } else {
                h =
                    60 *
                    (
                        ((r - g) / d) + 4
                    )
            }
        }

        if (h < 0)
            h += 360

        if (h >= 345 || h < 15)
            return "Red"

        if (h < 45)
            return "Orange"

        if (h < 75)
            return "Yellow"

        if (h < 165)
            return "Green"

        if (h < 260)
            return "Blue"

        if (h < 315)
            return "Purple"

        if (h < 345)
            return "Pink"

        return "Monochrome"
    }

    function processMarkers() {
        let map = {}

        for (
            let i = 0;
            i < markerModel.count;
            i++
        ) {
            const marker =
                markerModel.get(
                    i,
                    "fileName"
                ) || ""

            const split =
                marker.lastIndexOf(
                    "_HEX_"
                )

            if (split < 0)
                continue

            const file =
                marker.substring(
                    0,
                    split
                )

            const hex =
                marker.substring(
                    split + 5
                )

            map[file] =
                "#" + hex
        }

        picker.colorMap = map
        picker.cacheVersion++

        picker.rebuildFilteredModel()
    }

    function wallpaperMatches(
        fileName
    ) {
        if (
            picker.currentFilter ===
            "All"
        )
            return true

        const hex =
            picker.colorMap[
                String(fileName)
            ]

        if (!hex)
            return false

        return (
            picker.getHexBucket(hex) ===
            picker.currentFilter
        )
    }

    function rebuildFilteredModel() {
        if (
            wallpaperModel.status !==
            FolderListModel.Ready
        )
            return

        filteredModel.clear()

        for (
            let i = 0;
            i < wallpaperModel.count;
            i++
        ) {
            const name =
                wallpaperModel.get(
                    i,
                    "fileName"
                ) || ""

            const url =
                wallpaperModel.get(
                    i,
                    "fileUrl"
                ) || ""

            if (
                picker.wallpaperMatches(
                    name
                )
            ) {
                filteredModel.append({
                    fileName: name,
                    fileUrl: url
                })
            }
        }

        Qt.callLater(function() {
            view.forceLayout()

            if (
                filteredModel.count > 0
            ) {
                view.currentIndex = 0

                view.positionViewAtIndex(
                    0,
                    ListView.Center
                )
            } else {
                view.currentIndex = -1
            }
        })
    }

    function setFilter(name) {
        if (
            picker.currentFilter ===
            name
        )
            return

        picker.currentFilter = name

        picker.rebuildFilteredModel()
    }

    property string wallpaperDirectory:
        "file://" +
        Quickshell.env("HOME") +
        "/.local/share/red-core/wallpapers"

    // ---------------------------------------------------------
    // Navigation.
    //
    // IMPORTANT:
    // We only change currentIndex.
    // StrictlyEnforceRange moves the strip for us.
    // ---------------------------------------------------------

    function previousWallpaper() {
        if (
            filteredModel.count <= 0 ||
            view.currentIndex <= 0
        )
            return

        view.currentIndex--
    }

    function nextWallpaper() {
        if (
            filteredModel.count <= 0 ||
            view.currentIndex >=
                filteredModel.count - 1
        )
            return

        view.currentIndex++
    }

    // Only used when the picker first opens.
    function restoreInitialPosition() {
        if (
            !picker.pickerVisible ||
            filteredModel.count <= 0 ||
            picker.initialFocusScheduled
        )
            return

        picker.initialFocusScheduled = true

        Qt.callLater(function() {
            let target =
                picker.rememberedIndex

            if (
                target < 0 ||
                target >= filteredModel.count
            ) {
                target =
                    Math.floor(
                        filteredModel.count / 2
                    )
            }

            view.forceLayout()

            // Initial snap: no animation.
            view.positionViewAtIndex(
                target,
                ListView.Center
            )

            view.currentIndex = target

            picker.initialFocusSet = true
            picker.initialFocusScheduled = false
        })
    }

    function applyWallpaper(url) {
        if (!url || url === "")
            return

        let path = String(url)

        if (path.startsWith("file://")) {
            path = decodeURIComponent(
                path.substring(7)
            )
        }

        wallpaperApplyProcess.command = [
            Quickshell.env("HOME") +
                "/.local/bin/redcore-wallpaper",
            path
        ]

        wallpaperApplyProcess.running = true
    }

    onPickerVisibleChanged: {
        if (pickerVisible) {
            initialFocusSet = false
            initialFocusScheduled = false
            restoreInitialPosition()
        } else {
            initialFocusSet = false
            initialFocusScheduled = false
        }
    }

    // ---------------------------------------------------------
    // Wallpaper library.
    // ---------------------------------------------------------

    ListModel {
        id: filteredModel
    }

    FolderListModel {
        id: markerModel

        folder:
            picker.colorMarkerDirectory

        showDirs: false

        nameFilters: [
            "*_HEX_*"
        ]

        Component.onCompleted: {
            Qt.callLater(function() {
                picker.processMarkers()
            })
        }

        onCountChanged:
            picker.processMarkers()

        onStatusChanged: {
            if (
                status ===
                FolderListModel.Ready
            ) {
                picker.processMarkers()
            }
        }
    }

    FolderListModel {
        id: wallpaperModel

        folder: picker.wallpaperDirectory

        nameFilters: [
            "*.jpg",
            "*.jpeg",
            "*.png",
            "*.webp",
            "*.JPG",
            "*.JPEG",
            "*.PNG",
            "*.WEBP"
        ]

        showDirs: false
        showDotAndDotDot: false

        sortField:
            FolderListModel.Name

        onCountChanged: {
            picker.rebuildFilteredModel()
            picker.restoreInitialPosition()
        }

        onStatusChanged: {
            if (
                status ===
                FolderListModel.Ready
            ) {
                picker.rebuildFilteredModel()
            }
        }
    }

    Process {
        id: wallpaperApplyProcess

        running: false

        stdout: StdioCollector {}
        stderr: StdioCollector {}
    }

    Timer {
        id: scrollThrottle
        interval: 150
    }

    // ---------------------------------------------------------
    // Keyboard.
    // ---------------------------------------------------------

    Item {
        anchors.fill: parent

        focus: picker.pickerVisible

        Keys.onLeftPressed:
            picker.previousWallpaper()

        Keys.onRightPressed:
            picker.nextWallpaper()

        Keys.onEscapePressed:
            picker.pickerVisible = false
    }

    // ---------------------------------------------------------
    // IMPORTANT:
    //
    // Original theme does NOT use the whole screen height for
    // the picker layout.
    //
    // It uses a ~650px-high region centered vertically.
    // Toolbar and carousel live inside the SAME region.
    // ---------------------------------------------------------

    Item {
        id: contentFrame

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter:
            parent.verticalCenter

        height:
            Math.min(
                parent.height,
                picker.s(650)
            )

        // =====================================================
        // CAROUSEL
        // =====================================================

        ListView {
            id: view

            anchors.fill: parent

            model: filteredModel

            orientation:
                ListView.Horizontal

            spacing: 0
            clip: false

            interactive: true

            cacheBuffer: 2000

            boundsBehavior:
                Flickable.StopAtBounds

            // This is the key part from the reference.
            highlightRangeMode:
                ListView.StrictlyEnforceRange

            preferredHighlightBegin:
                (width / 2) -
                (
                    (
                        picker.itemWidth * 1.5 +
                        picker.itemSpacing
                    ) / 2
                )

            preferredHighlightEnd:
                (width / 2) +
                (
                    (
                        picker.itemWidth * 1.5 +
                        picker.itemSpacing
                    ) / 2
                )

            highlightMoveDuration:
                picker.initialFocusSet
                ? picker.animationDuration
                : 0

            focus: true

            onCurrentIndexChanged: {
                if (currentIndex >= 0)
                    picker.rememberedIndex =
                        currentIndex
            }

            // Allows first and last wallpaper to reach
            // the real center of the screen.
            header: Item {
                width:
                    Math.max(
                        0,
                        view.width / 2 -
                        (
                            picker.itemWidth *
                            1.5
                        ) / 2
                    )

                height: 1
            }

            footer: Item {
                width:
                    Math.max(
                        0,
                        view.width / 2 -
                        (
                            picker.itemWidth *
                            1.5
                        ) / 2
                    )

                height: 1
            }

            // Wheel behaviour from the reference.
            MouseArea {
                anchors.fill: parent

                acceptedButtons:
                    Qt.NoButton

                onWheel: wheel => {
                    if (scrollThrottle.running) {
                        wheel.accepted = true
                        return
                    }

                    const dx =
                        wheel.angleDelta.x

                    const dy =
                        wheel.angleDelta.y

                    const delta =
                        Math.abs(dx) >
                        Math.abs(dy)
                        ? dx
                        : dy

                    picker.scrollAccum +=
                        delta

                    if (
                        Math.abs(
                            picker.scrollAccum
                        ) >=
                        picker.scrollThreshold
                    ) {
                        if (
                            picker.scrollAccum > 0
                        ) {
                            picker.previousWallpaper()
                        } else {
                            picker.nextWallpaper()
                        }

                        picker.scrollAccum = 0
                        scrollThrottle.start()
                    }

                    wheel.accepted = true
                }
            }

            delegate: Item {
                id: delegateRoot

                required property int index
                required property string fileUrl
                required property string fileName

                readonly property bool isCurrent:
                    ListView.isCurrentItem

                // Exact proportions used by reference.
                readonly property real targetWidth:
                    isCurrent
                    ? picker.itemWidth * 1.5
                    : picker.itemWidth * 0.5

                readonly property real targetHeight:
                    isCurrent
                    ? picker.itemHeight +
                      picker.s(30)
                    : picker.itemHeight

                // Delegate owns the spacing.
                width:
                    targetWidth +
                    picker.itemSpacing

                height:
                    targetHeight

                anchors.verticalCenter:
                    parent.verticalCenter

                anchors.verticalCenterOffset:
                    picker.s(15)

                opacity:
                    isCurrent
                    ? 1.0
                    : 0.6

                z:
                    isCurrent
                    ? 10
                    : 1

                // EXACT animation style from the reference.
                Behavior on width {
                    enabled:
                        picker.initialFocusSet

                    NumberAnimation {
                        duration:
                            picker.animationDuration

                        easing.type:
                            Easing.InOutQuad
                    }
                }

                Behavior on height {
                    enabled:
                        picker.initialFocusSet

                    NumberAnimation {
                        duration:
                            picker.animationDuration

                        easing.type:
                            Easing.InOutQuad
                    }
                }

                Behavior on opacity {
                    enabled:
                        picker.initialFocusSet

                    NumberAnimation {
                        duration:
                            picker.animationDuration

                        easing.type:
                            Easing.InOutQuad
                    }
                }

                // Actual parallelogram.
                Item {
                    id: skewedCard

                    anchors.centerIn: parent

                    // Compensates for the extra height while
                    // keeping skewed neighbours aligned.
                    anchors.horizontalCenterOffset:
                        (
                            (
                                picker.itemHeight -
                                height
                            ) / 2
                        ) *
                        picker.skewFactor

                    width:
                        parent.width > 0
                        ? parent.width *
                          (
                            delegateRoot.targetWidth /
                            (
                                delegateRoot.targetWidth +
                                picker.itemSpacing
                            )
                          )
                        : 0

                    height: parent.height

                    transform: Matrix4x4 {
                        matrix:
                            Qt.matrix4x4(
                                1,
                                picker.skewFactor,
                                0,
                                0,

                                0,
                                1,
                                0,
                                0,

                                0,
                                0,
                                1,
                                0,

                                0,
                                0,
                                0,
                                1
                            )
                    }

                    // Reference uses the wallpaper itself
                    // around the inner crop, creating a very
                    // natural thin border.
                    Image {
                        anchors.fill: parent

                        source:
                            delegateRoot.fileUrl

                        sourceSize:
                            Qt.size(1, 1)

                        fillMode:
                            Image.Stretch

                        asynchronous: true
                    }

                    Item {
                        anchors.fill: parent

                        anchors.margins:
                            picker.borderWidth

                        clip: true

                        Rectangle {
                            anchors.fill: parent
                            color: "#11111b"
                        }

                        // IMPORTANT:
                        // Image dimensions stay based on MAX
                        // selected size. The card clips it while
                        // shrinking. This avoids ugly stretching.
                        Image {
                            anchors.centerIn: parent

                            anchors.horizontalCenterOffset:
                                picker.s(-50)

                            width:
                                (
                                    picker.itemWidth *
                                    1.5
                                ) +
                                (
                                    (
                                        picker.itemHeight +
                                        picker.s(30)
                                    ) *
                                    Math.abs(
                                        picker.skewFactor
                                    )
                                ) +
                                picker.s(50)

                            height:
                                picker.itemHeight +
                                picker.s(30)

                            source:
                                delegateRoot.fileUrl

                            fillMode:
                                Image.PreserveAspectCrop

                            asynchronous: true
                            cache: true

                            // Undo the parent's shear so the
                            // wallpaper itself is not distorted.
                            transform: Matrix4x4 {
                                matrix:
                                    Qt.matrix4x4(
                                        1,
                                        -picker.skewFactor,
                                        0,
                                        0,

                                        0,
                                        1,
                                        0,
                                        0,

                                        0,
                                        0,
                                        1,
                                        0,

                                        0,
                                        0,
                                        0,
                                        1
                                    )
                            }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent

                        cursorShape:
                            Qt.PointingHandCursor

                        onClicked: {
                            if (
                                view.currentIndex !==
                                delegateRoot.index
                            ) {
                                // ONLY change currentIndex.
                                // No forceLayout here.
                                view.currentIndex =
                                    delegateRoot.index
                            } else {
                                picker.applyWallpaper(
                                    delegateRoot.fileUrl
                                )
                            }
                        }
                    }
                }
            }
        }


        // =====================================================
        // TOOLBAR
        // =====================================================

        Rectangle {
            id: filterBarBackground

            property bool searchOpen: false

            anchors.top: parent.top
            anchors.topMargin: picker.s(40)

            anchors.horizontalCenter:
                parent.horizontalCenter

            z: 100

            height: picker.s(56)

            width:
                filterRow.width +
                picker.s(24)

            radius: picker.s(14)

            color: "#E622222A"

            border.width: 1
            border.color: "#665A5A66"

            Behavior on width {
                NumberAnimation {
                    duration: 450
                    easing.type: Easing.OutBack
                    easing.overshoot: 0.5
                }
            }

            Row {
                id: filterRow

                anchors.centerIn: parent

                spacing: picker.s(10)

                // =============================================
                // ALL
                // =============================================

                Item {
                    width: picker.s(42)
                    height: picker.s(42)

                    Rectangle {
                        anchors.centerIn: parent

                        width: picker.s(34)
                        height: picker.s(34)

                        radius: picker.s(9)

                        color:
                            picker.currentFilter === "All"
                            ? "#4A4A58"
                            : "transparent"

                        border.width:
                            picker.currentFilter === "All"
                            ? picker.s(2)
                            : 1

                        border.color:
                            picker.currentFilter === "All"
                            ? "#FFFFFF"
                            : "#665A5A66"

                        scale:
                            picker.currentFilter === "All"
                            ? 1.15
                            : (
                                allMouse.containsMouse
                                ? 1.08
                                : 1.0
                              )

                        Behavior on scale {
                            NumberAnimation {
                                duration: 300
                                easing.type: Easing.OutBack
                            }
                        }

                        Item {
                            width: picker.s(14)
                            height: picker.s(14)

                            anchors.centerIn: parent

                            Repeater {
                                model: 4

                                Rectangle {
                                    required property int index

                                    width: picker.s(6)
                                    height: picker.s(6)

                                    radius: picker.s(1)

                                    x:
                                        index % 2 === 0
                                        ? 0
                                        : picker.s(8)

                                    y:
                                        index < 2
                                        ? 0
                                        : picker.s(8)

                                    color: "#FFFFFF"
                                }
                            }
                        }
                    }

                    MouseArea {
                        id: allMouse

                        anchors.fill: parent

                        hoverEnabled: true

                        cursorShape:
                            Qt.PointingHandCursor

                        onClicked: {
                            filterBarBackground.searchOpen = false
                            picker.setFilter("All")
                            view.forceActiveFocus()
                        }
                    }
                }

                // =============================================
                // COLOR FILTERS
                // =============================================

                Repeater {
                    model: [
                        {
                            name: "Red",
                            hex: "#FF4500"
                        },
                        {
                            name: "Orange",
                            hex: "#FFA500"
                        },
                        {
                            name: "Yellow",
                            hex: "#FFD700"
                        },
                        {
                            name: "Green",
                            hex: "#32CD32"
                        },
                        {
                            name: "Blue",
                            hex: "#1E90FF"
                        },
                        {
                            name: "Purple",
                            hex: "#8A2BE2"
                        },
                        {
                            name: "Pink",
                            hex: "#FF69B4"
                        },
                        {
                            name: "Monochrome",
                            hex: "#A9A9A9"
                        }
                    ]

                    Item {
                        id: colorItem

                        required property var modelData

                        width: picker.s(36)
                        height: picker.s(42)

                        Rectangle {
                            anchors.centerIn: parent

                            width: picker.s(28)
                            height: picker.s(28)

                            radius: picker.s(7)

                            color:
                                colorItem.modelData.hex

                            border.width:
                                picker.currentFilter ===
                                colorItem.modelData.name
                                ? picker.s(2)
                                : 1

                            border.color:
                                picker.currentFilter ===
                                colorItem.modelData.name
                                ? "#FFFFFF"
                                : "#665A5A66"

                            scale:
                                picker.currentFilter ===
                                colorItem.modelData.name
                                ? 1.15
                                : (
                                    colorMouse.containsMouse
                                    ? 1.08
                                    : 1.0
                                  )

                            Behavior on scale {
                                NumberAnimation {
                                    duration: 300
                                    easing.type: Easing.OutBack
                                }
                            }

                            Behavior on border.color {
                                ColorAnimation {
                                    duration: 180
                                }
                            }
                        }

                        MouseArea {
                            id: colorMouse

                            anchors.fill: parent

                            hoverEnabled: true

                            cursorShape:
                                Qt.PointingHandCursor

                            onClicked: {
                                filterBarBackground.searchOpen = false

                                picker.setFilter(
                                    colorItem.modelData.name
                                )

                                view.forceActiveFocus()
                            }
                        }
                    }
                }

                // =============================================
                // SEARCH
                //
                // Visual interaction works now.
                // DuckDuckGo will be connected after filters
                // are verified.
                // =============================================

                Rectangle {
                    id: searchBox

                    width:
                        filterBarBackground.searchOpen
                        ? picker.s(300)
                        : picker.s(42)

                    height: picker.s(42)

                    radius: picker.s(9)

                    clip: true

                    color:
                        filterBarBackground.searchOpen
                        ? "#454550"
                        : "transparent"

                    border.width: 1

                    border.color:
                        filterBarBackground.searchOpen
                        ? "#FFFFFF"
                        : "#665A5A66"

                    Behavior on width {
                        NumberAnimation {
                            duration: 450
                            easing.type: Easing.OutBack
                            easing.overshoot: 0.5
                        }
                    }

                    Item {
                        id: searchIcon

                        width: picker.s(42)
                        height: picker.s(42)

                        anchors.left: parent.left

                        Rectangle {
                            width: picker.s(13)
                            height: picker.s(13)

                            radius: width / 2

                            anchors.centerIn: parent

                            anchors.horizontalCenterOffset:
                                picker.s(-2)

                            anchors.verticalCenterOffset:
                                picker.s(-2)

                            color: "transparent"

                            border.width: picker.s(2)
                            border.color: "#E0E0E5"
                        }

                        Rectangle {
                            width: picker.s(7)
                            height: picker.s(2)

                            radius: height / 2

                            rotation: 45

                            anchors.centerIn: parent

                            anchors.horizontalCenterOffset:
                                picker.s(6)

                            anchors.verticalCenterOffset:
                                picker.s(6)

                            color: "#E0E0E5"
                        }

                        MouseArea {
                            anchors.fill: parent

                            cursorShape:
                                Qt.PointingHandCursor

                            onClicked: {
                                filterBarBackground.searchOpen =
                                    !filterBarBackground.searchOpen

                                if (
                                    filterBarBackground.searchOpen
                                ) {
                                    Qt.callLater(function() {
                                        searchInput.forceActiveFocus()
                                    })
                                } else {
                                    searchInput.focus = false
                                    view.forceActiveFocus()
                                }
                            }
                        }
                    }

                    Text {
                        anchors.left:
                            searchIcon.right

                        anchors.leftMargin:
                            picker.s(4)

                        anchors.verticalCenter:
                            parent.verticalCenter

                        visible:
                            filterBarBackground.searchOpen &&
                            searchInput.text.length === 0

                        text: "Search wallpapers..."

                        color: "#888894"

                        font.pixelSize:
                            picker.s(14)
                    }

                    TextInput {
                        id: searchInput

                        anchors.left:
                            searchIcon.right

                        anchors.leftMargin:
                            picker.s(4)

                        anchors.right:
                            parent.right

                        anchors.rightMargin:
                            picker.s(12)

                        anchors.verticalCenter:
                            parent.verticalCenter

                        visible:
                            filterBarBackground.searchOpen

                        color: "#F2F2F5"

                        font.pixelSize:
                            picker.s(14)

                        clip: true

                        Keys.onEscapePressed: {
                            filterBarBackground.searchOpen = false
                            focus = false
                            view.forceActiveFocus()
                        }
                    }
                }
            }
        }
    }
}
