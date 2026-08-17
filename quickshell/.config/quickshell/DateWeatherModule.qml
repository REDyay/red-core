pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Io
import QtQuick

Item {
    id: dateWeather

    property var service: null

    property string locationName: ""
    property real latitude: NaN
    property real longitude: NaN
    property string locationTimezone: "auto"

    property var currentWeather: ({})
    property var dailyForecast: []
    property double weatherUpdatedAt: 0

    property bool locationEditorOpen: false
    property var locationResults: []
    property string locationMessage: ""
    property string weatherMessage: ""

    property string weatherRequestUrl: ""
    property string locationRequestUrl: ""

    property int locationGeneration: 0
    property int weatherRequestGeneration: 0
    property bool pendingWeatherRefresh: false

    property int locationSearchGeneration: 0
    property int activeLocationSearchGeneration: 0

    property date calendarMonth: new Date(
        clock.date.getFullYear(),
        clock.date.getMonth(),
        1
    )

    readonly property bool locationConfigured:
        dateWeather.locationName !== "" &&
        Number.isFinite(dateWeather.latitude) &&
        Number.isFinite(dateWeather.longitude)

    readonly property bool weatherAvailable:
        Number.isFinite(
            Number(
                dateWeather.currentWeather
                    .temperature_2m
            )
        )

    readonly property bool keyboardInputActive:
        weatherPopup.visible &&
        dateWeather.locationEditorOpen

    readonly property var calendarCells:
        dateWeather.buildCalendarCells()

    implicitWidth: weatherTimeRow.implicitWidth + 20
    implicitHeight: 32
    width: implicitWidth
    height: implicitHeight


    function sameDay(first, second) {
        return (
            first.getFullYear() === second.getFullYear() &&
            first.getMonth() === second.getMonth() &&
            first.getDate() === second.getDate()
        )
    }


    function buildCalendarCells() {
        const first = new Date(
            dateWeather.calendarMonth.getFullYear(),
            dateWeather.calendarMonth.getMonth(),
            1
        )
        const mondayOffset = (first.getDay() + 6) % 7
        const cells = []

        for (let index = 0; index < 42; ++index) {
            const value = new Date(
                first.getFullYear(),
                first.getMonth(),
                index - mondayOffset + 1
            )

            cells.push({
                "day": value.getDate(),
                "currentMonth":
                    value.getMonth() === first.getMonth(),
                "today": dateWeather.sameDay(
                    value,
                    clock.date
                ),
                "weekend":
                    value.getDay() === 0 ||
                    value.getDay() === 6
            })
        }

        return cells
    }


    function moveCalendarMonth(offset) {
        dateWeather.calendarMonth = new Date(
            dateWeather.calendarMonth.getFullYear(),
            dateWeather.calendarMonth.getMonth() + offset,
            1
        )
    }


    function showCurrentMonth() {
        dateWeather.calendarMonth = new Date(
            clock.date.getFullYear(),
            clock.date.getMonth(),
            1
        )
    }


    function weatherDescription(code) {
        const value = Number(code)

        if (value === 0)
            return "Clear"
        if (value >= 1 && value <= 3)
            return "Partly cloudy"
        if (value === 45 || value === 48)
            return "Fog"
        if (value >= 51 && value <= 57)
            return "Drizzle"
        if (value >= 61 && value <= 67)
            return "Rain"
        if (value >= 71 && value <= 77)
            return "Snow"
        if (value >= 80 && value <= 82)
            return "Showers"
        if (value === 85 || value === 86)
            return "Snow showers"
        if (value >= 95)
            return "Thunderstorm"

        return "Unknown"
    }


    function weatherSymbol(code, isDay) {
        const value = Number(code)

        if (value === 0)
            return isDay === false ? "☾" : "☀"
        if (value >= 1 && value <= 3)
            return "☁"
        if (value === 45 || value === 48)
            return "≋"
        if (
            (value >= 51 && value <= 67) ||
            (value >= 80 && value <= 82)
        ) {
            return "☂"
        }
        if (
            (value >= 71 && value <= 77) ||
            value === 85 ||
            value === 86
        ) {
            return "❄"
        }
        if (value >= 95)
            return "⚡"

        return "·"
    }


    function temperatureLabel(value) {
        const temperature = Number(value)

        return Number.isFinite(temperature)
            ? Math.round(temperature) + "°"
            : "--°"
    }


    function forecastDayLabel(value) {
        const date = new Date(
            String(value || "") + "T12:00:00"
        )

        return Number.isNaN(date.getTime())
            ? "--"
            : Qt.formatDate(date, "ddd")
    }


    function locationResultLabel(result) {
        const parts = [String(result.name || "")]
        const region = String(result.admin1 || "")
        const country = String(result.country || "")

        if (region !== "" && region !== parts[0])
            parts.push(region)
        if (country !== "")
            parts.push(country)

        return parts.join(", ")
    }


    function restoreCache() {
        const serialized = String(
            weatherCache.text() || ""
        ).trim()

        if (serialized === "")
            return

        try {
            const saved = JSON.parse(serialized)
            const location = saved.location || ({})
            const weather = saved.weather || ({})

            dateWeather.locationName = String(
                location.name || ""
            )
            dateWeather.latitude = Number(
                location.latitude
            )
            dateWeather.longitude = Number(
                location.longitude
            )
            dateWeather.locationTimezone = String(
                location.timezone || "auto"
            )
            dateWeather.currentWeather =
                weather.current || ({})
            dateWeather.dailyForecast =
                Array.isArray(weather.daily)
                ? weather.daily
                : []
            dateWeather.weatherUpdatedAt = Number(
                saved.updatedAt || 0
            )

            if (dateWeather.locationConfigured) {
                Qt.callLater(function() {
                    dateWeather.refreshWeather(false)
                })
            }
        } catch (error) {
            dateWeather.locationMessage =
                "Saved weather data could not be read"
        }
    }


    function saveCache() {
        weatherCache.setText(
            JSON.stringify({
                "version": 1,
                "location": {
                    "name": dateWeather.locationName,
                    "latitude": dateWeather.latitude,
                    "longitude": dateWeather.longitude,
                    "timezone":
                        dateWeather.locationTimezone
                },
                "weather": {
                    "current":
                        dateWeather.currentWeather,
                    "daily":
                        dateWeather.dailyForecast
                },
                "updatedAt":
                    dateWeather.weatherUpdatedAt
            })
        )
    }

    function secureWeatherCache() {
        weatherPermissions.command = [
            "chmod",
            "600",
            weatherCache.path
        ]
        weatherPermissions.running = true
    }


    function weatherUrl() {
        const latitude = encodeURIComponent(
            String(dateWeather.latitude)
        )
        const longitude = encodeURIComponent(
            String(dateWeather.longitude)
        )

        return (
            "https://api.open-meteo.com/v1/forecast" +
            "?latitude=" + latitude +
            "&longitude=" + longitude +
            "&current=" +
            "temperature_2m,apparent_temperature," +
            "relative_humidity_2m,weather_code," +
            "wind_speed_10m,is_day" +
            "&daily=" +
            "weather_code,temperature_2m_max," +
            "temperature_2m_min," +
            "precipitation_probability_max" +
            "&timezone=auto" +
            "&forecast_days=7" +
            "&temperature_unit=celsius" +
            "&wind_speed_unit=kmh"
        )
    }


    function refreshWeather(force) {
        if (
            !dateWeather.locationConfigured ||
            weatherProcess.running
        ) {
            return
        }

        const age = Date.now() -
            dateWeather.weatherUpdatedAt

        if (
            force !== true &&
            dateWeather.weatherAvailable &&
            age >= 0 &&
            age < 15 * 60 * 1000
        ) {
            return
        }

        dateWeather.weatherMessage = "Updating weather…"
        dateWeather.weatherRequestGeneration =
            dateWeather.locationGeneration
        dateWeather.pendingWeatherRefresh = false
        dateWeather.weatherRequestUrl =
            dateWeather.weatherUrl()
        weatherProcess.running = true
    }


    function handleWeatherResponse(output) {
        if (
            dateWeather.weatherRequestGeneration !==
                dateWeather.locationGeneration
        ) {
            weatherRestartTimer.restart()
            return
        }

        const serialized = String(output || "").trim()

        if (serialized === "") {
            dateWeather.weatherMessage =
                dateWeather.weatherAvailable
                ? "Offline · showing saved data"
                : "Weather is unavailable"
            return
        }

        try {
            const data = JSON.parse(serialized)
            const current = data.current || ({})

            if (
                !Number.isFinite(
                    Number(current.temperature_2m)
                )
            ) {
                throw new Error("missing current weather")
            }

            const daily = data.daily || ({})
            const dates = Array.isArray(daily.time)
                ? daily.time
                : []
            const result = []

            for (
                let index = 0;
                index < Math.min(7, dates.length);
                ++index
            ) {
                result.push({
                    "date": dates[index],
                    "code": Number(
                        (daily.weather_code || [])[index]
                    ),
                    "maximum": Number(
                        (daily.temperature_2m_max || [])[index]
                    ),
                    "minimum": Number(
                        (daily.temperature_2m_min || [])[index]
                    ),
                    "precipitation": Number(
                        (
                            daily
                                .precipitation_probability_max ||
                            []
                        )[index]
                    )
                })
            }

            dateWeather.currentWeather = current
            dateWeather.dailyForecast = result
            dateWeather.weatherUpdatedAt = Date.now()
            dateWeather.weatherMessage = ""
            dateWeather.saveCache()
        } catch (error) {
            dateWeather.weatherMessage =
                dateWeather.weatherAvailable
                ? "Invalid update · showing saved data"
                : "Weather data could not be read"
        }
    }


    function searchLocation() {
        const query = String(
            cityInput.text || ""
        ).trim()

        if (query.length < 2) {
            dateWeather.locationMessage =
                "Enter at least two characters"
            return
        }

        if (locationProcess.running)
            return

        dateWeather.locationResults = []
        dateWeather.locationMessage = "Searching…"
        dateWeather.activeLocationSearchGeneration =
            dateWeather.locationSearchGeneration
        dateWeather.locationRequestUrl =
            "https://geocoding-api.open-meteo.com/v1/search" +
            "?name=" + encodeURIComponent(query) +
            "&count=5&language=en&format=json"
        locationProcess.running = true
    }


    function handleLocationResponse(output) {
        if (
            dateWeather.activeLocationSearchGeneration !==
                dateWeather.locationSearchGeneration
        ) {
            return
        }

        const serialized = String(output || "").trim()

        if (serialized === "") {
            dateWeather.locationMessage =
                "Location search is unavailable"
            return
        }

        try {
            const data = JSON.parse(serialized)
            dateWeather.locationResults =
                Array.isArray(data.results)
                ? data.results
                : []
            dateWeather.locationMessage =
                dateWeather.locationResults.length > 0
                ? ""
                : "No matching location"
        } catch (error) {
            dateWeather.locationMessage =
                "Location results could not be read"
        }
    }


    function chooseLocation(result) {
        const latitude = Number(result.latitude)
        const longitude = Number(result.longitude)

        if (
            !Number.isFinite(latitude) ||
            !Number.isFinite(longitude)
        ) {
            dateWeather.locationMessage =
                "This location has invalid coordinates"
            return
        }

        dateWeather.locationName =
            dateWeather.locationResultLabel(result)
        dateWeather.locationGeneration += 1
        dateWeather.latitude = latitude
        dateWeather.longitude = longitude
        dateWeather.locationTimezone = String(
            result.timezone || "auto"
        )
        dateWeather.currentWeather = ({})
        dateWeather.dailyForecast = []
        dateWeather.weatherUpdatedAt = 0
        dateWeather.locationResults = []
        dateWeather.locationMessage = ""
        dateWeather.locationEditorOpen = false
        cityInput.text = ""
        dateWeather.saveCache()

        if (weatherProcess.running) {
            dateWeather.pendingWeatherRefresh = true
        } else {
            dateWeather.refreshWeather(true)
        }
    }


    function updatedLabel() {
        if (dateWeather.weatherUpdatedAt <= 0)
            return "Never updated"

        return "Updated " + Qt.formatDateTime(
            new Date(dateWeather.weatherUpdatedAt),
            "dd/MM HH:mm"
        )
    }


    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }


    FileView {
        id: weatherCache

        path: Quickshell.cacheDir +
            "/red-core-weather.json"
        preload: true
        atomicWrites: true
        watchChanges: false
        printErrors: false

        onLoaded: {
            dateWeather.restoreCache()
            dateWeather.secureWeatherCache()
        }

        onSaved: dateWeather.secureWeatherCache()
    }


    Process {
        id: weatherPermissions

        running: false
        stdout: StdioCollector {}
        stderr: StdioCollector {}
    }


    Process {
        id: weatherProcess

        command: [
            "curl",
            "--fail",
            "--silent",
            "--show-error",
            "--location",
            "--connect-timeout",
            "5",
            "--max-time",
            "15",
            dateWeather.weatherRequestUrl
        ]

        stdout: StdioCollector {
            id: weatherOutput
            waitForEnd: true

            onStreamFinished: {
                dateWeather.handleWeatherResponse(text)
            }
        }

        stderr: StdioCollector {
            waitForEnd: true
        }

    }


    Process {
        id: locationProcess

        command: [
            "curl",
            "--fail",
            "--silent",
            "--show-error",
            "--location",
            "--connect-timeout",
            "5",
            "--max-time",
            "15",
            dateWeather.locationRequestUrl
        ]

        stdout: StdioCollector {
            id: locationOutput
            waitForEnd: true

            onStreamFinished: {
                dateWeather.handleLocationResponse(text)
            }
        }

        stderr: StdioCollector {
            waitForEnd: true
        }

    }


    Timer {
        id: weatherRestartTimer

        interval: 50
        repeat: false

        onTriggered: {
            if (!dateWeather.pendingWeatherRefresh)
                return

            if (weatherProcess.running) {
                weatherRestartTimer.restart()
                return
            }

            dateWeather.pendingWeatherRefresh = false
            dateWeather.refreshWeather(true)
        }
    }


    Timer {
        interval: 30 * 60 * 1000
        running: true
        repeat: true

        onTriggered: dateWeather.refreshWeather(true)
    }


    Rectangle {
        id: dateWeatherButton

        anchors.fill: parent
        radius: 10
        color: "#313244"

        Row {
            id: weatherTimeRow

            anchors.centerIn: parent
            spacing: 8

            Text {
                text:
                    dateWeather.weatherAvailable
                    ? dateWeather.weatherSymbol(
                          dateWeather.currentWeather
                              .weather_code,
                          Number(
                              dateWeather.currentWeather
                                  .is_day
                          ) !== 0
                      ) + " " +
                      dateWeather.temperatureLabel(
                          dateWeather.currentWeather
                              .temperature_2m
                      )
                    : "--°"
                color: "#cdd6f4"
                font.pixelSize: 12
            }

            Text {
                text: Qt.formatDateTime(
                    clock.date,
                    "dd/MM"
                )
                color: "#cdd6f4"
                font.pixelSize: 12
            }

            Text {
                text: Qt.formatDateTime(
                    clock.date,
                    "HH:mm"
                )
                color: "#cdd6f4"
                font.pixelSize: 12
            }
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor

            onClicked: {
                if (dateWeather.service !== null) {
                    dateWeather.service.togglePopup(
                        "date-weather"
                    )
                } else {
                    weatherPopup.visible =
                        !weatherPopup.visible
                }
            }
        }
    }


    Connections {
        target: dateWeather.service

        function onActivePopupChanged() {
            weatherPopup.visible =
                dateWeather.service.activePopup ===
                    "date-weather"
        }
    }


    PopupWindow {
        id: weatherPopup

        visible: false
        grabFocus: true
        color: "transparent"
        implicitWidth: 440
        implicitHeight: 620

        anchor {
            item: dateWeatherButton
            edges: Edges.Bottom | Edges.Right
            gravity: Edges.Bottom | Edges.Left
            adjustment: PopupAdjustment.All
        }

        onVisibleChanged: {
            if (visible) {
                dateWeather.refreshWeather(false)

                if (!dateWeather.locationConfigured) {
                    dateWeather.locationEditorOpen = true
                    Qt.callLater(function() {
                        cityInput.forceActiveFocus()
                    })
                }

                return
            }

            dateWeather.locationEditorOpen = false
            dateWeather.locationSearchGeneration += 1
            dateWeather.locationResults = []
            dateWeather.locationMessage = ""
            cityInput.focus = false

            if (
                dateWeather.service !== null &&
                dateWeather.service.activePopup ===
                    "date-weather"
            ) {
                dateWeather.service.closePopup(
                    "date-weather"
                )
            }
        }

        Rectangle {
            anchors.fill: parent
            radius: 16
            color: "#1e1e2e"
            border.width: 1
            border.color: "#45475a"

            Flickable {
                id: weatherFlick

                anchors.fill: parent
                anchors.margins: 16
                clip: true
                contentWidth: width
                contentHeight: weatherContent.implicitHeight

                Column {
                    id: weatherContent

                    width: weatherFlick.width
                    spacing: 12

                    Row {
                        width: parent.width
                        height: 32
                        spacing: 8

                        Column {
                            width: parent.width - 146
                            spacing: 2

                            Text {
                                width: parent.width
                                text: dateWeather.locationConfigured
                                    ? dateWeather.locationName
                                    : "Date & Weather"
                                elide: Text.ElideRight
                                color: "#cdd6f4"
                                font.pixelSize: 15
                                font.bold: true
                            }

                            Text {
                                width: parent.width
                                text: dateWeather.updatedLabel()
                                elide: Text.ElideRight
                                color: "#7f849c"
                                font.pixelSize: 8
                            }
                        }

                        Rectangle {
                            width: 68
                            height: 28
                            radius: 8
                            color: "#313244"

                            Text {
                                anchors.centerIn: parent
                                text:
                                    dateWeather.locationEditorOpen
                                    ? "Cancel"
                                    : (
                                        dateWeather.locationConfigured
                                        ? "Change"
                                        : "Set city"
                                      )
                                color: "#cdd6f4"
                                font.pixelSize: 8
                                font.bold: true
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor

                                onClicked: {
                                    dateWeather.locationEditorOpen =
                                        !dateWeather
                                            .locationEditorOpen
                                    dateWeather.locationResults = []
                                    dateWeather.locationMessage = ""

                                    if (
                                        dateWeather.locationEditorOpen
                                    ) {
                                        Qt.callLater(function() {
                                            cityInput.forceActiveFocus()
                                        })
                                    } else {
                                        cityInput.focus = false
                                    }
                                }
                            }
                        }

                        Rectangle {
                            width: 62
                            height: 28
                            radius: 8
                            color: "#313244"
                            opacity:
                                dateWeather.locationConfigured &&
                                !weatherProcess.running
                                ? 1
                                : 0.4

                            Text {
                                anchors.centerIn: parent
                                text: weatherProcess.running
                                    ? "Wait…"
                                    : "Refresh"
                                color: "#89b4fa"
                                font.pixelSize: 8
                                font.bold: true
                            }

                            MouseArea {
                                anchors.fill: parent
                                enabled:
                                    dateWeather.locationConfigured &&
                                    !weatherProcess.running
                                cursorShape: enabled
                                    ? Qt.PointingHandCursor
                                    : Qt.ArrowCursor

                                onClicked:
                                    dateWeather.refreshWeather(true)
                            }
                        }
                    }

                    Column {
                        visible: dateWeather.locationEditorOpen
                        width: parent.width
                        height: visible
                            ? implicitHeight
                            : 0
                        spacing: 7

                        Row {
                            width: parent.width
                            height: 34
                            spacing: 8

                            Rectangle {
                                width: parent.width - 82
                                height: 34
                                radius: 8
                                color: "#28283d"
                                border.width:
                                    cityInput.activeFocus ? 1 : 0
                                border.color: "#89b4fa"

                                TextInput {
                                    id: cityInput

                                    anchors.fill: parent
                                    anchors.margins: 9
                                    verticalAlignment:
                                        TextInput.AlignVCenter
                                    color: "#cdd6f4"
                                    selectionColor: "#89b4fa"
                                    selectedTextColor: "#11111b"
                                    clip: true
                                    font.pixelSize: 10

                                    Keys.onReturnPressed:
                                        dateWeather.searchLocation()
                                    Keys.onEnterPressed:
                                        dateWeather.searchLocation()
                                }

                                Text {
                                    anchors {
                                        left: parent.left
                                        leftMargin: 9
                                        verticalCenter:
                                            parent.verticalCenter
                                    }
                                    visible: cityInput.text === ""
                                    text: "Enter a city or postal code"
                                    color: "#7f849c"
                                    font.pixelSize: 10
                                }
                            }

                            Rectangle {
                                width: 74
                                height: 34
                                radius: 8
                                color: "#89b4fa"
                                opacity:
                                    locationProcess.running
                                    ? 0.6
                                    : 1

                                Text {
                                    anchors.centerIn: parent
                                    text: locationProcess.running
                                        ? "Wait…"
                                        : "Search"
                                    color: "#11111b"
                                    font.pixelSize: 9
                                    font.bold: true
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    enabled: !locationProcess.running
                                    cursorShape: enabled
                                        ? Qt.PointingHandCursor
                                        : Qt.ArrowCursor

                                    onClicked:
                                        dateWeather.searchLocation()
                                }
                            }
                        }

                        Text {
                            visible:
                                dateWeather.locationMessage !== ""
                            width: parent.width
                            text: dateWeather.locationMessage
                            color: "#f9e2af"
                            font.pixelSize: 9
                        }

                        Repeater {
                            model: dateWeather.locationResults

                            delegate: Rectangle {
                                id: locationResult

                                required property var modelData

                                width: weatherContent.width
                                height: 34
                                radius: 8
                                color: "#28283d"

                                Text {
                                    anchors {
                                        left: parent.left
                                        right: parent.right
                                        margins: 10
                                        verticalCenter:
                                            parent.verticalCenter
                                    }
                                    text:
                                        dateWeather.locationResultLabel(
                                            locationResult.modelData
                                        )
                                    elide: Text.ElideRight
                                    color: "#cdd6f4"
                                    font.pixelSize: 9
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape:
                                        Qt.PointingHandCursor

                                    onClicked: {
                                        dateWeather.chooseLocation(
                                            locationResult.modelData
                                        )
                                    }
                                }
                            }
                        }
                    }

                    Rectangle {
                        width: parent.width
                        height: 94
                        radius: 11
                        color: "#28283d"

                        Row {
                            anchors.fill: parent
                            anchors.margins: 12
                            spacing: 12

                            Text {
                                width: 54
                                anchors.verticalCenter:
                                    parent.verticalCenter
                                horizontalAlignment:
                                    Text.AlignHCenter
                                text:
                                    dateWeather.weatherAvailable
                                    ? dateWeather.weatherSymbol(
                                          dateWeather.currentWeather
                                              .weather_code,
                                          Number(
                                              dateWeather.currentWeather
                                                  .is_day
                                          ) !== 0
                                      )
                                    : "·"
                                color: "#89b4fa"
                                font.pixelSize: 34
                            }

                            Column {
                                width: parent.width - 66
                                anchors.verticalCenter:
                                    parent.verticalCenter
                                spacing: 4

                                Row {
                                    width: parent.width

                                    Text {
                                        width: 86
                                        text:
                                            dateWeather.temperatureLabel(
                                                dateWeather
                                                    .currentWeather
                                                    .temperature_2m
                                            )
                                        color: "#cdd6f4"
                                        font.pixelSize: 25
                                        font.bold: true
                                    }

                                    Text {
                                        width: parent.width - 86
                                        anchors.verticalCenter:
                                            parent.verticalCenter
                                        horizontalAlignment:
                                            Text.AlignRight
                                        text:
                                            dateWeather.weatherAvailable
                                            ? dateWeather
                                                  .weatherDescription(
                                                      dateWeather
                                                          .currentWeather
                                                          .weather_code
                                                  )
                                            : "Choose a city for weather"
                                        elide: Text.ElideRight
                                        color: "#cdd6f4"
                                        font.pixelSize: 10
                                    }
                                }

                                Text {
                                    width: parent.width
                                    text:
                                        dateWeather.weatherAvailable
                                        ? "Feels " +
                                          dateWeather.temperatureLabel(
                                              dateWeather
                                                  .currentWeather
                                                  .apparent_temperature
                                          ) +
                                          " · Humidity " +
                                          Math.round(
                                              Number(
                                                  dateWeather
                                                      .currentWeather
                                                      .relative_humidity_2m
                                              )
                                          ) + "% · Wind " +
                                          Math.round(
                                              Number(
                                                  dateWeather
                                                      .currentWeather
                                                      .wind_speed_10m
                                              )
                                          ) + " km/h"
                                        : "No weather data"
                                    elide: Text.ElideRight
                                    color: "#a6adc8"
                                    font.pixelSize: 9
                                }

                                Text {
                                    visible:
                                        dateWeather.weatherMessage !== ""
                                    width: parent.width
                                    text: dateWeather.weatherMessage
                                    elide: Text.ElideRight
                                    color: "#f9e2af"
                                    font.pixelSize: 8
                                }
                            }
                        }
                    }

                    Row {
                        visible:
                            dateWeather.dailyForecast.length > 0
                        width: parent.width
                        height: visible ? 76 : 0
                        spacing: 6

                        Repeater {
                            model:
                                dateWeather.dailyForecast.slice(0, 5)

                            delegate: Rectangle {
                                id: forecastCard

                                required property var modelData

                                width:
                                    (weatherContent.width - 24) / 5
                                height: 76
                                radius: 9
                                color: "#28283d"

                                Column {
                                    anchors.centerIn: parent
                                    spacing: 3

                                    Text {
                                        anchors.horizontalCenter:
                                            parent.horizontalCenter
                                        text:
                                            dateWeather.forecastDayLabel(
                                                forecastCard.modelData
                                                    .date
                                            )
                                        color: "#a6adc8"
                                        font.pixelSize: 8
                                    }

                                    Text {
                                        anchors.horizontalCenter:
                                            parent.horizontalCenter
                                        text:
                                            dateWeather.weatherSymbol(
                                                forecastCard.modelData
                                                    .code,
                                                true
                                            )
                                        color: "#89b4fa"
                                        font.pixelSize: 16
                                    }

                                    Text {
                                        anchors.horizontalCenter:
                                            parent.horizontalCenter
                                        text:
                                            dateWeather.temperatureLabel(
                                                forecastCard.modelData
                                                    .maximum
                                            ) + " / " +
                                            dateWeather.temperatureLabel(
                                                forecastCard.modelData
                                                    .minimum
                                            )
                                        color: "#cdd6f4"
                                        font.pixelSize: 8
                                        font.bold: true
                                    }
                                }
                            }
                        }
                    }

                    Rectangle {
                        width: parent.width
                        height: 1
                        color: "#45475a"
                    }

                    Row {
                        width: parent.width
                        height: 30
                        spacing: 8

                        Rectangle {
                            width: 30
                            height: 30
                            radius: 8
                            color: "#313244"

                            Text {
                                anchors.centerIn: parent
                                text: "‹"
                                color: "#cdd6f4"
                                font.pixelSize: 17
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked:
                                    dateWeather.moveCalendarMonth(-1)
                            }
                        }

                        Text {
                            width: parent.width - 142
                            anchors.verticalCenter:
                                parent.verticalCenter
                            horizontalAlignment:
                                Text.AlignHCenter
                            text: Qt.formatDate(
                                dateWeather.calendarMonth,
                                "MMMM yyyy"
                            )
                            color: "#cdd6f4"
                            font.pixelSize: 13
                            font.bold: true
                        }

                        Rectangle {
                            width: 56
                            height: 30
                            radius: 8
                            color: "#313244"

                            Text {
                                anchors.centerIn: parent
                                text: "Today"
                                color: "#89b4fa"
                                font.pixelSize: 8
                                font.bold: true
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked:
                                    dateWeather.showCurrentMonth()
                            }
                        }

                        Rectangle {
                            width: 30
                            height: 30
                            radius: 8
                            color: "#313244"

                            Text {
                                anchors.centerIn: parent
                                text: "›"
                                color: "#cdd6f4"
                                font.pixelSize: 17
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked:
                                    dateWeather.moveCalendarMonth(1)
                            }
                        }
                    }

                    Row {
                        width: parent.width
                        height: 20

                        Repeater {
                            model: [
                                "Mon", "Tue", "Wed", "Thu",
                                "Fri", "Sat", "Sun"
                            ]

                            delegate: Text {
                                id: weekDay

                                required property string modelData

                                width: weatherContent.width / 7
                                height: 20
                                horizontalAlignment:
                                    Text.AlignHCenter
                                verticalAlignment:
                                    Text.AlignVCenter
                                text: weekDay.modelData
                                color: "#7f849c"
                                font.pixelSize: 8
                                font.bold: true
                            }
                        }
                    }

                    Grid {
                        width: parent.width
                        height: 174
                        columns: 7
                        rows: 6

                        Repeater {
                            model: dateWeather.calendarCells

                            delegate: Item {
                                id: calendarDay

                                required property var modelData

                                width: weatherContent.width / 7
                                height: 29

                                Rectangle {
                                    anchors.centerIn: parent
                                    width: 28
                                    height: 25
                                    radius: 8
                                    color:
                                        calendarDay.modelData.today
                                        ? "#89b4fa"
                                        : "transparent"
                                }

                                Text {
                                    anchors.centerIn: parent
                                    text:
                                        String(
                                            calendarDay.modelData.day
                                        )
                                    color:
                                        calendarDay.modelData.today
                                        ? "#11111b"
                                        : (
                                            calendarDay.modelData
                                                .currentMonth
                                            ? (
                                                calendarDay.modelData
                                                    .weekend
                                                ? "#f9e2af"
                                                : "#cdd6f4"
                                              )
                                            : "#585b70"
                                          )
                                    font.pixelSize: 9
                                    font.bold:
                                        calendarDay.modelData.today
                                }
                            }
                        }
                    }

                    Text {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        text: "Weather data: Open-Meteo"
                        color: "#585b70"
                        font.pixelSize: 8
                    }
                }
            }
        }
    }
}
