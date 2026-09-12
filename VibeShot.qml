import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQml.Models
import qs.Commons
import qs.Ui

Item {
  id: root

  property bool opened: false
  property bool menuOpen: false
  property bool gifRecording: false
  property string capturePath: ""
  property int captureW: 0
  property int captureH: 0
  property var ops: []
  property var redoStack: []
  property var currentOp: null
  property string activeTool: "arrow"
  property color activeColor: Color.accent
  property int strokeIdx: 1
  readonly property var strokeWidths: [2, 4, 7]
  readonly property int strokeWidth: strokeWidths[strokeIdx]
  readonly property int naturalTextSize: 30
  property var pendingTextAt: null
  property string pendingTextValue: ""
  property var pins: []
  property int pinCounter: 0
  readonly property int pinMaxWidth: 192

  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/aayork.vibeshot"
  readonly property string cacheDir: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/aayork.vibeshot"
  readonly property string picturesDir: (Quickshell.env("XDG_PICTURES_DIR") || (Quickshell.env("HOME") + "/Pictures")) + "/Screenshots"

  readonly property var palette: [
    Color.foreground, Color.accent, Color.urgent, Color.muted,
    "#e8544a", "#f2b94a", "#4ac98a", "#4a9ef2"
  ]

  // --- lifecycle: called by omarchy-shell's summon/hide over IPC ---

  // The actual pixel grab (grim/slurp/hyprpicker) is launched by Hyprland
  // directly — see bindings.lua — never as a child of this Quickshell
  // process. Routing the interactive slurp session through a Quickshell
  // Process broke hyprpicker's screen freeze and cut slurp's selection short
  // on the first click, even though the same script worked perfectly when
  // Hyprland exec'd it directly. capture.sh calls back into `captured()`
  // over `omarchy-shell shell call` once it has a finished PNG.
  function open(payloadJson) {
    var args = {}
    try { args = JSON.parse(payloadJson || "{}") || {} } catch (e) { args = {} }
    if (args.path) root.captured(String(args.path))
  }

  // A fresh capture shows the small corner preview (Markup/Save/dismiss),
  // not the full editor — matches CleanShot's quick-look popup. The full
  // editor only opens if the user picks Markup on it.
  function captured(path) {
    previewSizer.pendingKind = "image"
    previewSizer.pendingPath = path
  }

  // Capture-mode picker popup, opened by a single ordinary keybind (no
  // Hyprland submap — that briefly disabled every other SUPER+... shortcut
  // on the system while active, which is worse than the problem it solved).
  function showMenu() {
    root.menuOpen = true
    Qt.callLater(function() { menuKeyCatcher.forceActiveFocus() })
  }
  function hideMenu() { root.menuOpen = false }

  // Hands a command to Hyprland to launch (hl.dsp.exec_cmd), rather than
  // running it directly as a child of this Quickshell process. Anything that
  // itself shells out to slurp/hyprpicker (capture.sh, record-gif.sh) MUST
  // start this way — a Quickshell-spawned slurp breaks mid-selection, same
  // root cause as the capture.sh/bindings.lua fix, just reachable from a
  // button click instead of a keybind.
  function execViaHyprland(cmd) {
    var luaEscaped = cmd.replace(/\\/g, "\\\\").replace(/"/g, "\\\"")
    Util.execDetached("hyprctl dispatch 'hl.dsp.exec_cmd(\"" + luaEscaped + "\")'")
  }

  function menuPick(mode) {
    root.menuOpen = false
    root.execViaHyprland(root.pluginDir + "/capture.sh " + mode)
  }

  function menuToggleGif() {
    root.menuOpen = false
    root.execViaHyprland(root.pluginDir + "/record-gif.sh")
  }

  function gifStarted() { root.gifRecording = true }

  function gifFailed() {
    root.gifRecording = false
    Util.execArgv(["omarchy-notification-send", "-u", "critical", "GIF recording failed"])
  }

  function gifReady(path) {
    root.gifRecording = false
    previewSizer.pendingKind = "gif"
    previewSizer.pendingPath = path
  }

  // New pins stack straight up from the bottom-left, each sitting directly
  // above the ones already there (rather than cascading diagonally) — sums
  // the actual heights already stacked so it works regardless of aspect
  // ratio. Removing a pin from the middle of the stack can leave a gap since
  // the ones above it aren't re-flowed, but each pin stays freely draggable.
  function nextPinPosition(h) {
    var margin = Style.space(10)
    var gap = Style.space(8)
    var stacked = 0
    for (var i = 0; i < root.pins.length; i++) stacked += root.pins[i].h + gap
    return { x: margin, y: panel.screen.height - margin - stacked - h }
  }

  function showPreview(path, w, h, kind) {
    root.pinCounter += 1
    var scale = Math.min(1, root.pinMaxWidth / w)
    var tw = Math.round(w * scale)
    var th = Math.round(h * scale)
    var pos = root.nextPinPosition(th)
    root.pins = root.pins.concat([{
      id: "pin" + root.pinCounter,
      path: path,
      fullPath: path,
      w: tw,
      h: th,
      x: pos.x,
      y: pos.y,
      kind: kind || "image",
      transient: true
    }])
  }

  function openEditor(path) {
    if (root.opened) root.discardCapture()
    root.capturePath = path
    root.ops = []
    root.redoStack = []
    root.activeTool = "arrow"
    root.opened = true
  }

  function close() {
    root.discardCapture()
    root.opened = false
  }

  function discardCapture() {
    if (root.capturePath) Util.execDetached("rm -f " + Util.shellQuote(root.capturePath))
    root.capturePath = ""
    root.captureW = 0
    root.captureH = 0
    root.ops = []
    root.redoStack = []
    root.currentOp = null
    root.pendingTextAt = null
    root.pendingTextValue = ""
    root.activeTool = "arrow"
  }

  // --- ops / undo-redo ---

  function pushOp(op) {
    root.ops = root.ops.concat([op])
    root.redoStack = []
    canvas.requestPaint()
  }

  function undo() {
    if (root.ops.length === 0) return
    var last = root.ops[root.ops.length - 1]
    root.ops = root.ops.slice(0, -1)
    root.redoStack = root.redoStack.concat([last])
    canvas.requestPaint()
  }

  function redo() {
    if (root.redoStack.length === 0) return
    var last = root.redoStack[root.redoStack.length - 1]
    root.redoStack = root.redoStack.slice(0, -1)
    root.ops = root.ops.concat([last])
    canvas.requestPaint()
  }

  function makeOp(tool, x, y) {
    if (tool === "pen" || tool === "highlighter")
      return { type: tool, color: root.activeColor, width: root.strokeWidth, points: [{ x: x, y: y }] }
    if (tool === "line" || tool === "arrow")
      return { type: tool, color: root.activeColor, width: root.strokeWidth, x1: x, y1: y, x2: x, y2: y }
    if (tool === "rect" || tool === "ellipse" || tool === "redact")
      return { type: tool, color: root.activeColor, width: root.strokeWidth, x: x, y: y, w: 0, h: 0 }
    return null
  }

  function updateOp(op, x, y) {
    if (op.type === "pen" || op.type === "highlighter") {
      op.points.push({ x: x, y: y })
    } else if (op.type === "line" || op.type === "arrow") {
      op.x2 = x
      op.y2 = y
    } else if (op.type === "rect" || op.type === "ellipse" || op.type === "redact") {
      op.w = x - op.x
      op.h = y - op.y
    }
  }

  // --- text tool ---

  function commitText() {
    if (root.pendingTextAt && root.pendingTextValue.length > 0) {
      root.pushOp({
        type: "text",
        color: root.activeColor,
        x: root.pendingTextAt.nx,
        y: root.pendingTextAt.ny,
        text: root.pendingTextValue,
        fontSize: root.naturalTextSize
      })
    }
    root.pendingTextAt = null
    root.pendingTextValue = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function cancelText() {
    root.pendingTextAt = null
    root.pendingTextValue = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // --- painting ---

  function paintArrow(ctx, op) {
    ctx.strokeStyle = op.color
    ctx.fillStyle = op.color
    ctx.lineWidth = op.width
    ctx.lineCap = "round"
    var dx = op.x2 - op.x1, dy = op.y2 - op.y1
    var len = Math.sqrt(dx * dx + dy * dy) || 1
    var ux = dx / len, uy = dy / len
    var headLen = Math.max(10, op.width * 4)
    var backX = op.x2 - ux * headLen
    var backY = op.y2 - uy * headLen
    ctx.beginPath()
    ctx.moveTo(op.x1, op.y1)
    ctx.lineTo(backX, backY)
    ctx.stroke()
    var perpX = -uy, perpY = ux
    var wing = headLen * 0.55
    ctx.beginPath()
    ctx.moveTo(op.x2, op.y2)
    ctx.lineTo(backX + perpX * wing, backY + perpY * wing)
    ctx.lineTo(backX - perpX * wing, backY - perpY * wing)
    ctx.closePath()
    ctx.fill()
  }

  function paintOp(ctx, op) {
    ctx.save()
    if (op.type === "pen") {
      ctx.strokeStyle = op.color
      ctx.lineWidth = op.width
      ctx.lineJoin = "round"
      ctx.lineCap = "round"
      ctx.beginPath()
      for (var i = 0; i < op.points.length; i++) {
        var p = op.points[i]
        if (i === 0) ctx.moveTo(p.x, p.y); else ctx.lineTo(p.x, p.y)
      }
      ctx.stroke()
    } else if (op.type === "highlighter") {
      ctx.strokeStyle = Util.alpha(op.color, 0.35)
      ctx.lineWidth = op.width * 4
      ctx.lineJoin = "round"
      ctx.lineCap = "round"
      ctx.beginPath()
      for (var j = 0; j < op.points.length; j++) {
        var q = op.points[j]
        if (j === 0) ctx.moveTo(q.x, q.y); else ctx.lineTo(q.x, q.y)
      }
      ctx.stroke()
    } else if (op.type === "line") {
      ctx.strokeStyle = op.color
      ctx.lineWidth = op.width
      ctx.lineCap = "round"
      ctx.beginPath()
      ctx.moveTo(op.x1, op.y1)
      ctx.lineTo(op.x2, op.y2)
      ctx.stroke()
    } else if (op.type === "arrow") {
      root.paintArrow(ctx, op)
    } else if (op.type === "rect") {
      ctx.strokeStyle = op.color
      ctx.lineWidth = op.width
      ctx.strokeRect(op.x, op.y, op.w, op.h)
    } else if (op.type === "ellipse") {
      var cx = op.x + op.w / 2, cy = op.y + op.h / 2
      var rx = Math.abs(op.w / 2) || 0.001, ry = Math.abs(op.h / 2) || 0.001
      ctx.save()
      ctx.translate(cx, cy)
      ctx.scale(rx, ry)
      ctx.beginPath()
      ctx.arc(0, 0, 1, 0, Math.PI * 2)
      ctx.restore()
      ctx.strokeStyle = op.color
      ctx.lineWidth = op.width
      ctx.stroke()
    } else if (op.type === "redact") {
      ctx.fillStyle = Color.background
      ctx.fillRect(op.x, op.y, op.w, op.h)
    } else if (op.type === "text") {
      ctx.fillStyle = op.color
      ctx.font = op.fontSize + "px " + Style.font.family
      ctx.textBaseline = "top"
      ctx.fillText(op.text, op.x, op.y)
    }
    ctx.restore()
  }

  // --- export actions ---

  function flattenTo(path) {
    canvas.requestPaint()
    return canvas.save(path)
  }

  function doCopy() {
    var tmp = root.cacheDir + "/copy-" + Date.now() + ".png"
    if (root.flattenTo(tmp)) {
      Util.execDetached("wl-copy --type image/png < " + Util.shellQuote(tmp) +
        " && omarchy-notification-send 'Copied to clipboard' --image " + Util.shellQuote(tmp))
    }
    root.close()
  }

  function doSave() {
    var ts = Qt.formatDateTime(new Date(), "yyyy-MM-dd_HH-mm-ss")
    var path = root.picturesDir + "/screenshot-" + ts + ".png"
    if (root.flattenTo(path)) Util.execArgv(["omarchy-notification-send", "Screenshot saved", "--image", path])
    root.close()
  }

  function doPin() {
    root.pinCounter += 1
    var stamp = Date.now() + "-" + root.pinCounter
    var fullPath = root.cacheDir + "/pins/pin-" + stamp + "-full.png"
    var thumbPath = root.cacheDir + "/pins/pin-" + stamp + "-thumb.png"
    canvas.requestPaint()
    var okFull = canvas.save(fullPath)
    var scale = Math.min(1, root.pinMaxWidth / root.captureW)
    var tw = Math.round(root.captureW * scale)
    var th = Math.round(root.captureH * scale)
    var okThumb = canvas.save(thumbPath, Qt.size(tw, th))
    if (!okFull || !okThumb) { root.close(); return }

    var pos = root.nextPinPosition(th)
    root.pins = root.pins.concat([{
      id: "pin" + root.pinCounter,
      path: thumbPath,
      fullPath: fullPath,
      w: tw,
      h: th,
      x: pos.x,
      y: pos.y,
      kind: "image",
      transient: false
    }])
    root.close()
  }

  function findPin(id) {
    for (var i = 0; i < root.pins.length; i++) if (root.pins[i].id === id) return root.pins[i]
    return null
  }

  function removePin(id) {
    var next = []
    var removedThumb = "", removedFull = ""
    for (var i = 0; i < root.pins.length; i++) {
      if (root.pins[i].id === id) { removedThumb = root.pins[i].path; removedFull = root.pins[i].fullPath }
      else next.push(root.pins[i])
    }
    root.pins = next
    if (removedThumb) Util.execDetached("rm -f " + Util.shellQuote(removedThumb) + " " + Util.shellQuote(removedFull))
  }

  function savePin(id, fullPath) {
    var ts = Qt.formatDateTime(new Date(), "yyyy-MM-dd_HH-mm-ss")
    var dest = root.picturesDir + "/screenshot-" + ts + ".png"
    Util.execDetached("cp " + Util.shellQuote(fullPath) + " " + Util.shellQuote(dest) +
      " && omarchy-notification-send 'Screenshot saved' --image " + Util.shellQuote(dest))
    // The quick post-capture preview resolves once you act on it; a
    // deliberately pinned shot stays put so you can keep referencing it.
    var pin = root.findPin(id)
    if (pin && pin.transient) root.removePin(id)
  }

  function copyPin(id, fullPath) {
    Util.execDetached("wl-copy --type image/png < " + Util.shellQuote(fullPath) +
      " && omarchy-notification-send 'Copied to clipboard' --image " + Util.shellQuote(fullPath))
    var pin = root.findPin(id)
    if (pin && pin.transient) root.removePin(id)
  }

  function markupPin(id, fullPath) {
    var thumbToRemove = ""
    var next = []
    for (var i = 0; i < root.pins.length; i++) {
      if (root.pins[i].id === id) thumbToRemove = root.pins[i].path
      else next.push(root.pins[i])
    }
    root.pins = next
    if (thumbToRemove && thumbToRemove !== fullPath) Util.execDetached("rm -f " + Util.shellQuote(thumbToRemove))

    root.openEditor(fullPath)
  }

  Component.onCompleted: initProc.running = true

  Process {
    id: initProc
    command: ["bash", "-c", "mkdir -p " + Util.shellQuote(root.cacheDir + "/pins") + " " + Util.shellQuote(root.picturesDir)]
  }


  Image {
    id: baseImg
    visible: false
    source: root.capturePath ? Util.fileUrl(root.capturePath) : ""
    asynchronous: true
    onStatusChanged: {
      if (status === Image.Ready) {
        root.captureW = sourceSize.width
        root.captureH = sourceSize.height
        Qt.callLater(function() {
          canvas.requestPaint()
          keyCatcher.forceActiveFocus()
        })
      }
    }
  }

  // Measures a freshly captured PNG so the quick preview pin can be sized
  // before any editor session (and its canvas) exists.
  Image {
    id: previewSizer
    visible: false
    property string pendingPath: ""
    property string pendingKind: "image"
    source: pendingPath ? Util.fileUrl(pendingPath) : ""
    asynchronous: true
    onStatusChanged: {
      if (status === Image.Ready && pendingPath) {
        root.showPreview(pendingPath, sourceSize.width, sourceSize.height, pendingKind)
        pendingPath = ""
      }
    }
  }

  Instantiator {
    model: root.pins
    delegate: PinWindow {
      closeHandler: root.removePin
      saveHandler: root.savePin
      markupHandler: root.markupPin
      copyHandler: root.copyPin
    }
  }

  PanelWindow {
    id: panel

    visible: root.opened || root.menuOpen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "aayork-vibeshot-editor"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: (root.opened || root.menuOpen) ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      visible: root.opened
      color: Util.alpha(Color.background, 0.55)
    }

    MouseArea {
      anchors.fill: parent
      enabled: root.opened || root.menuOpen
      onClicked: {
        if (root.menuOpen) root.hideMenu()
        else root.close()
      }
    }

    BorderSurface {
      id: menuCard
      visible: root.menuOpen
      anchors.top: parent.top
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.topMargin: Style.space(60)
      width: menuRow.implicitWidth + Style.spacing.panelPadding
      height: menuRow.implicitHeight + Style.spacing.panelPadding
      radius: Style.cornerRadius
      color: Util.alpha(Color.popups.background, 0.98)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))

      MouseArea { anchors.fill: parent; onClicked: {} }

      Row {
        id: menuRow
        anchors.centerIn: parent
        spacing: Style.spacing.lg

        Button {
          text: "Fullscreen"
          bordered: true
          onClicked: root.menuPick("fullscreen")
        }
        Button {
          text: "Area"
          bordered: true
          onClicked: root.menuPick("smart")
        }
        Button {
          text: "Window"
          bordered: true
          onClicked: root.menuPick("windows")
        }
      }
    }

    Item {
      id: menuKeyCatcher
      anchors.fill: parent
      focus: false

      Keys.onPressed: function(event) {
        if (!root.menuOpen) return
        if (event.key === Qt.Key_Escape) {
          root.hideMenu(); event.accepted = true
        } else if (event.key === Qt.Key_3) {
          root.menuPick("fullscreen"); event.accepted = true
        } else if (event.key === Qt.Key_4) {
          root.menuPick("smart"); event.accepted = true
        } else if (event.key === Qt.Key_5) {
          root.menuPick("windows"); event.accepted = true
        }
      }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.onPressed: function(event) {
        if (!root.opened) return
        if (event.key === Qt.Key_Escape) {
          if (root.pendingTextAt) root.cancelText(); else root.close()
          event.accepted = true
        } else if (event.key === Qt.Key_Z && (event.modifiers & Qt.ControlModifier) && (event.modifiers & Qt.ShiftModifier)) {
          root.redo(); event.accepted = true
        } else if (event.key === Qt.Key_Z && (event.modifiers & Qt.ControlModifier)) {
          root.undo(); event.accepted = true
        } else if (event.key === Qt.Key_Y && (event.modifiers & Qt.ControlModifier)) {
          root.redo(); event.accepted = true
        } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !root.pendingTextAt) {
          root.doCopy(); event.accepted = true
        }
      }
    }

    Column {
      id: composition
      visible: root.opened && root.captureW > 0
      anchors.centerIn: parent
      spacing: Style.spacing.lg

      readonly property real maxContentW: panel.width * 0.86
      readonly property real maxContentH: panel.height * 0.7
      readonly property real fitScale: root.captureW > 0 ? Math.min(1, composition.maxContentW / root.captureW, composition.maxContentH / root.captureH) : 1

      Item {
        id: content
        width: root.captureW * composition.fitScale
        height: root.captureH * composition.fitScale

        Canvas {
          id: canvas
          width: root.captureW
          height: root.captureH
          scale: composition.fitScale
          transformOrigin: Item.TopLeft
          antialiasing: true

          onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            ctx.clearRect(0, 0, width, height)
            if (baseImg.status === Image.Ready) ctx.drawImage(baseImg, 0, 0, width, height)
            for (var i = 0; i < root.ops.length; i++) root.paintOp(ctx, root.ops[i])
            if (root.currentOp) root.paintOp(ctx, root.currentOp)
          }
        }

        MouseArea {
          id: drawArea
          anchors.fill: parent
          enabled: root.pendingTextAt === null
          cursorShape: Qt.CrossCursor

          onPressed: function(mouse) {
            var nx = mouse.x / composition.fitScale
            var ny = mouse.y / composition.fitScale
            if (root.activeTool === "text") {
              root.pendingTextAt = { x: mouse.x, y: mouse.y, nx: nx, ny: ny }
              root.pendingTextValue = ""
              Qt.callLater(function() { textInput.forceActiveFocus() })
              return
            }
            root.currentOp = root.makeOp(root.activeTool, nx, ny)
          }
          onPositionChanged: function(mouse) {
            if (!root.currentOp) return
            root.updateOp(root.currentOp, mouse.x / composition.fitScale, mouse.y / composition.fitScale)
            canvas.requestPaint()
          }
          onReleased: function(mouse) {
            if (!root.currentOp) return
            root.pushOp(root.currentOp)
            root.currentOp = null
          }
        }

        Item {
          id: textEditorHost
          visible: root.pendingTextAt !== null
          x: root.pendingTextAt ? root.pendingTextAt.x : 0
          y: root.pendingTextAt ? root.pendingTextAt.y : 0
          width: Math.max(80, textInput.contentWidth + Style.space(12))
          height: textInput.contentHeight + Style.space(8)
          z: 10

          Rectangle {
            anchors.fill: parent
            anchors.margins: -4
            color: Util.alpha(Color.background, 0.85)
            border.color: root.activeColor
            border.width: 1
            radius: 3
          }

          TextInput {
            id: textInput
            anchors.fill: parent
            anchors.margins: 4
            color: root.activeColor
            font.family: Style.font.family
            font.pixelSize: root.naturalTextSize * composition.fitScale
            text: root.pendingTextValue
            onTextChanged: root.pendingTextValue = text
            Keys.onReturnPressed: root.commitText()
            Keys.onEnterPressed: root.commitText()
            Keys.onEscapePressed: root.cancelText()
          }
        }
      }

      BorderSurface {
        id: toolbar
        anchors.horizontalCenter: parent.horizontalCenter
        width: toolbarRow.implicitWidth + Style.spacing.panelPadding
        height: toolbarRow.implicitHeight + Style.spacing.panelPadding
        radius: Style.cornerRadius
        color: Util.alpha(Color.popups.background, 0.98)
        borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))

        MouseArea { anchors.fill: parent; onClicked: {} }

        Row {
          id: toolbarRow
          anchors.centerIn: parent
          spacing: Style.spacing.controlGap

          Button { iconText: "↗"; tooltipText: "Arrow"; selected: root.activeTool === "arrow"; onClicked: root.activeTool = "arrow" }
          Button { iconText: "╱"; tooltipText: "Line"; selected: root.activeTool === "line"; onClicked: root.activeTool = "line" }
          Button { iconText: "▭"; tooltipText: "Rectangle"; selected: root.activeTool === "rect"; onClicked: root.activeTool = "rect" }
          Button { iconText: "◯"; tooltipText: "Ellipse"; selected: root.activeTool === "ellipse"; onClicked: root.activeTool = "ellipse" }
          Button { iconText: "✎"; tooltipText: "Pen"; selected: root.activeTool === "pen"; onClicked: root.activeTool = "pen" }
          Button { iconText: "▤"; tooltipText: "Highlighter"; selected: root.activeTool === "highlighter"; onClicked: root.activeTool = "highlighter" }
          Button { iconText: "T"; tooltipText: "Text"; selected: root.activeTool === "text"; onClicked: root.activeTool = "text" }
          Button { iconText: "▦"; tooltipText: "Redact"; selected: root.activeTool === "redact"; onClicked: root.activeTool = "redact" }

          Rectangle { width: 1; height: Style.space(20); color: Color.popups.border; anchors.verticalCenter: parent.verticalCenter }

          Repeater {
            model: root.palette
            Rectangle {
              width: Style.space(18); height: Style.space(18); radius: width / 2
              anchors.verticalCenter: parent.verticalCenter
              color: modelData
              border.color: Color.foreground
              border.width: Qt.colorEqual(root.activeColor, modelData) ? 2 : 0
              MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.activeColor = modelData }
            }
          }

          Rectangle { width: 1; height: Style.space(20); color: Color.popups.border; anchors.verticalCenter: parent.verticalCenter }

          Repeater {
            model: [0, 1, 2]
            Rectangle {
              id: dot
              readonly property int dotSize: 6 + modelData * 4
              width: Style.space(22); height: Style.space(22)
              radius: Style.cornerRadius > 0 ? 4 : 0
              color: root.strokeIdx === modelData ? Style.selectedFill : "transparent"
              anchors.verticalCenter: parent.verticalCenter
              Rectangle {
                anchors.centerIn: parent
                width: dot.dotSize; height: dot.dotSize; radius: dot.dotSize / 2
                color: Color.foreground
              }
              MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.strokeIdx = modelData }
            }
          }

          Rectangle { width: 1; height: Style.space(20); color: Color.popups.border; anchors.verticalCenter: parent.verticalCenter }

          Button { iconText: "↶"; tooltipText: "Undo"; onClicked: root.undo() }
          Button { iconText: "↷"; tooltipText: "Redo"; onClicked: root.redo() }

          Rectangle { width: 1; height: Style.space(20); color: Color.popups.border; anchors.verticalCenter: parent.verticalCenter }

          Button { text: "Pin"; tooltipText: "Pin to desktop"; onClicked: root.doPin() }
          Button { text: "Copy"; tooltipText: "Copy to clipboard (Enter)"; onClicked: root.doCopy() }
          Button { text: "Save"; tooltipText: "Save to Pictures/Screenshots"; onClicked: root.doSave() }
          Button { iconText: "✕"; tooltipText: "Cancel (Esc)"; onClicked: root.close() }
        }
      }
    }
  }
}
