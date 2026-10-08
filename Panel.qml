import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The Vibe Buddy box in the bar. A client of vibebuddyd's local HTTP API, like the
// desktop app: it shows what the tray menu shows (the box, its mode, today's stats)
// plus the volume, and never anything about the agents. Those are told by the box.
Panel {
  id: root
  moduleName: "io.github.second-state.vibebuddy"
  ipcTarget: "vibebuddy"
  manageIpc: false

  readonly property string api: "http://127.0.0.1:7331"

  // The daemon's last snapshot; null while the daemon isn't answering.
  property var status: null
  // The level being dragged, until the box reports it back.
  property int pendingVolume: -1

  readonly property var device: status ? (status.device || {}) : ({})
  readonly property bool online: !!device.connected
  readonly property var operation: status ? status.operation : null
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string deviceLine: {
    if (!status) return "The daemon isn't running"
    if (device.foreign_firmware) return "The box runs other firmware"
    if (!online) return "Box not found"
    var build = device.firmware_build ? String(device.firmware_build).split(" ")[0] : ""
    return "Box online · firmware " + (device.firmware_version || build || "?")
  }

  readonly property string modeLine: {
    if (!online) return ""
    var names = { duty: "On duty", pomodoro: "Pomodoro", leisure: "Leisure" }
    return names[device.mode] ? "Mode: " + names[device.mode] : ""
  }

  readonly property string todayLine: {
    var today = status ? (status.today || {}) : {}
    return (today.done || 0) + " done · " + (today.asks || 0) + " asks · busy " + duration(today.busy_seconds || 0)
  }

  readonly property string operationLine: {
    if (!operation) return ""
    var percent = Math.round((operation.progress || 0) * 100) + "%"
    var pack = operation.kind === "voice_pack"
    if (operation.state === "failed") return "Failed: " + operation.message
    if (operation.state === "replug") return "Firmware flashed, but the box didn't start it. Unplug the box and plug it back in."
    if (operation.state === "running") return (pack ? "Writing character pack… " : "Flashing firmware… ") + percent
    return pack ? "Character pack written" : "Firmware flashed, the box has restarted"
  }

  function duration(seconds) {
    var hours = Math.floor(seconds / 3600)
    var minutes = Math.floor((seconds % 3600) / 60)
    return hours > 0 ? hours + " h " + minutes + " min" : minutes + " min"
  }

  function readEvent(line) {
    var text = String(line)
    if (text.indexOf("data:") !== 0) return
    try {
      status = JSON.parse(text.slice(5))
      pendingVolume = -1
    } catch (e) {}
  }

  function setVolume(level) {
    pendingVolume = level
    Util.execArgv(["curl", "-s", "-X", "POST", "-H", "content-type: application/json",
                   "-d", JSON.stringify({ level: level, preview: false }), api + "/v1/device/volume"])
  }

  // --settings opens the window whether or not the app is already running. The pacman
  // package puts the app on PATH; install.sh puts it in ~/.local/bin.
  function openSettings() {
    close()
    Util.execDetached('command -v vibebuddy-desktop >/dev/null && exec vibebuddy-desktop --settings || exec "$HOME/.local/bin/vibebuddy-desktop" --settings')
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) Qt.callLater(function() { keyCatcher.forceActiveFocus() })

  // One snapshot on connect, then one per change. Started through bash so a missing
  // curl still exits; when the daemon is gone or restarts, try again shortly.
  Process {
    id: stream
    command: ["bash", "-c", 'exec curl -sN --fail "$1"/v1/status/stream', "bash", root.api]
    running: true
    stdout: SplitParser { onRead: function(line) { root.readEvent(line) } }
    onExited: {
      root.status = null
      retry.start()
    }
  }

  Timer {
    id: retry
    interval: 2000
    onTriggered: stream.running = true
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    // Read-only snapshot for scripts and tests.
    function state(): string {
      return JSON.stringify({ daemon: root.status !== null, online: root.online, device: root.deviceLine,
                              mode: root.modeLine, today: root.todayLine, volume: root.device.volume || null,
                              operation: root.operationLine })
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: "Vibe Buddy: " + root.deviceLine
    iconComponent: Component {
      Face {
        eyesClosed: !root.online
        color: root.barForeground
        opacity: root.online ? 1 : 0.5
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.openSettings()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(480))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "s" || t === "S") root.openSettings()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        PanelHero {
          width: parent.width
          title: "Vibe Buddy"
          meta: root.deviceLine
          detail: root.modeLine
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconComponent: Component {
            Face {
              implicitWidth: Style.font.display
              implicitHeight: Style.font.display
              eyesClosed: !root.online
              color: root.online ? root.foreground : root.dim
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.status === null
          width: parent.width
          text: "Start it with  systemctl --user start vibebuddyd, or install Vibe Buddy first (see the plugin's README)."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          textFormat: Text.PlainText
          visible: root.operationLine !== ""
          width: parent.width
          text: root.operationLine
          color: root.operation && root.operation.state === "failed" ? root.urgent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        PanelSeparator { visible: root.status !== null; foreground: root.foreground }

        PanelSectionHeader {
          visible: root.status !== null
          text: "TODAY"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Text {
          textFormat: Text.PlainText
          visible: root.status !== null
          width: parent.width
          text: root.todayLine
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        PanelSectionHeader {
          visible: root.online
          text: "VOLUME"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        RowLayout {
          visible: root.online
          width: parent.width
          spacing: Style.space(10)

          // 20 to 100 in steps of 5, as in the settings window; the box has no zero, mute is on the box.
          PanelSlider {
            id: volume
            bar: root.bar
            Layout.fillWidth: true
            minimum: 20
            maximum: 100
            step: 5
            integer: true
            enabled: root.device.volume !== undefined && root.device.volume !== null
            value: root.pendingVolume >= 0 ? root.pendingVolume : (root.device.volume || 60)
            onReleased: function(v) { root.setVolume(Math.round(v / 5) * 5) }
          }

          Text {
            textFormat: Text.PlainText
            text: Math.round(volume.liveValue)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            Layout.minimumWidth: Style.space(28)
            horizontalAlignment: Text.AlignRight
          }
        }

        PanelSeparator { foreground: root.foreground }

        Button {
          width: parent.width
          text: "Open settings"
          iconText: "󰒓"
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.openSettings()
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: "S: settings · right-click the face: settings"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }

  // The buddy's 18×18 pixel face, the same drawing as the tray icon and the Mac
  // menu bar. Closed eyes mean the box (or the daemon) is gone.
  component Face: Canvas {
    property bool eyesClosed: false
    property color color: "white"
    onEyesClosedChanged: requestPaint()
    onColorChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var unit = Math.max(1, Math.floor(Math.min(width, height) / 18))
      var x0 = Math.floor((width - unit * 18) / 2)
      var y0 = Math.floor((height - unit * 18) / 2)
      ctx.fillStyle = color
      function px(x, y, w, h) { ctx.fillRect(x0 + x * unit, y0 + y * unit, w * unit, h * unit) }
      px(8, 0, 2, 3)        // antenna
      px(3, 4, 12, 1)       // head
      px(2, 5, 1, 9)
      px(15, 5, 1, 9)
      px(3, 14, 12, 1)
      if (eyesClosed) {
        px(5, 9, 3, 1)
        px(10, 9, 3, 1)
        px(7, 12, 4, 1)
      } else {
        px(5, 7, 3, 3)
        px(10, 7, 3, 3)
        px(6, 12, 1, 1)
        px(7, 13, 4, 1)
        px(11, 12, 1, 1)
      }
      px(5, 15, 2, 2)       // legs
      px(11, 15, 2, 2)
    }
  }
}
