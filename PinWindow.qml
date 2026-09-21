import Quickshell
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Ui

PanelWindow {
  id: pin

  required property var modelData
  property var closeHandler: null
  property var saveHandler: null
  property var markupHandler: null
  property var copyHandler: null

  readonly property string pinId: modelData.id
  property real posX: modelData.x
  property real posY: modelData.y
  readonly property bool hovered: cardHover.hovered
  // One shared centered tooltip rather than one per corner — a pin can be
  // as small as ~150px wide, too narrow for four independent floating
  // labels to avoid clipping or overlapping each other.
  readonly property string hotLabel: closeMouse.containsMouse ? "Dismiss"
    : copyMouse.containsMouse ? "Copy"
    : markupMouse.containsMouse ? "Markup"
    : saveMouse.containsMouse ? "Save"
    : ""

  // A fresh capture preview isn't free-floating: it can only be swiped off
  // the left screen edge it's docked against, which saves it. Deliberately
  // pinned shots (transient: false) keep the old drag-anywhere behavior.
  //
  // The swipe slides the card *inside* a stationary layer window that spans
  // from the screen edge to the card, rather than moving the window itself:
  // pointer coordinates stay stable and there's no compositor round-trip per
  // frame. Input is masked to the card so the empty strip stays click-through.
  readonly property bool swipeToSave: modelData.transient === true
  // Card offset from its docked spot, in px; always <= 0 (toward the edge).
  property real swipeOffset: 0
  property bool dismissing: false
  property real dismissFade: 1

  // Past this fraction of its width, releasing commits the swipe.
  readonly property real commitFraction: 0.4

  function flyOff() {
    pin.dismissing = true
    flyAnim.start()
  }

  ParallelAnimation {
    id: flyAnim
    NumberAnimation {
      target: pin
      property: "swipeOffset"
      to: -(pin.modelData.x + pin.modelData.w + Style.space(4))
      duration: 240
      easing.type: Easing.InCubic
    }
    NumberAnimation {
      target: pin
      property: "dismissFade"
      to: 0
      duration: 240
      easing.type: Easing.InQuad
    }
    // Save only once the card is gone: savePin() removes a transient pin
    // from the model, which would destroy this window mid-animation.
    onFinished: if (pin.saveHandler) pin.saveHandler(pin.pinId, pin.modelData.fullPath)
  }

  ParallelAnimation {
    id: snapBackAnim
    NumberAnimation {
      target: pin
      property: "swipeOffset"
      to: 0
      duration: 200
      easing.type: Easing.OutCubic
    }
    NumberAnimation {
      target: pin
      property: "dismissFade"
      to: 1
      duration: 200
      easing.type: Easing.OutCubic
    }
  }

  anchors { top: true; left: true }
  margins.left: swipeToSave ? 0 : Math.round(posX)
  margins.top: Math.round(posY)
  implicitWidth: swipeToSave ? modelData.x + modelData.w : modelData.w
  implicitHeight: modelData.h
  color: "transparent"
  WlrLayershell.namespace: "vibeshot-pin"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Ignore
  mask: Region { item: card }

  BorderSurface {
    id: card
    x: (pin.swipeToSave ? pin.modelData.x : 0) + pin.swipeOffset
    y: 0
    width: pin.modelData.w
    height: pin.modelData.h
    clip: true
    color: "transparent"
    radius: Style.cornerRadius
    // Hairline, translucent accent: a fraction of a logical pixel (about one
    // physical pixel at 1.6x scale), antialiased rather than pixel-snapped.
    // Themed and distinct from the solid popup borders without shouting.
    border.pixelAligned: false
    borderSpec: Border.flat(Util.alpha(Color.accent, 0.5), 0.5)

    // Entry animation: fade + scale up from the bottom-left corner where pins
    // stack. Scale stays <= 1 so nothing overshoots the layer window's bounds.
    property real appear: 0
    opacity: appear * pin.dismissFade
    scale: 0.9 + 0.1 * appear
    transformOrigin: Item.BottomLeft
    NumberAnimation on appear {
      from: 0
      to: 1
      duration: 220
      easing.type: Easing.OutCubic
    }

    HoverHandler { id: cardHover }

    Image {
      anchors.fill: parent
      anchors.margins: card.borderTop
      source: Util.fileUrl(pin.modelData.path)
      // The window is already sized to the image's aspect ratio, but w/h are
      // rounded independently — PreserveAspectFit then letterboxes a
      // sub-pixel sliver on one axis. Stretch fills the box exactly instead.
      fillMode: Image.Stretch
      asynchronous: true
      smooth: true
      // Rectangle.clip is rectangular, so when the theme rounds its corners
      // the image gets a mask matching the border's inner radius.
      layer.enabled: card.radius > 0
      layer.effect: MultiEffect {
        maskEnabled: true
        maskSource: imageMask
      }
    }

    Rectangle {
      id: imageMask
      anchors.fill: parent
      anchors.margins: card.borderTop
      radius: Math.max(0, card.radius - card.borderTop)
      visible: false
      layer.enabled: card.radius > 0
    }

    // Drag surface sits under the buttons/close chrome so those keep click
    // priority; declared first so later (visually on top) items win hit-testing.
    MouseArea {
      id: dragArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: pin.swipeToSave ? (pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor) : Qt.SizeAllCursor
      property real pressGlobalX: 0
      property real pressGlobalY: 0
      property real startPosX: 0
      property real startPosY: 0
      // Swipe mode: press point and drag distance toward the edge, measured
      // in window coordinates (stable, unlike this item's own as it slides).
      property real pressSceneX: 0
      property real swipeTravel: 0

      onPressed: function(mouse) {
        if (pin.dismissing) return
        snapBackAnim.stop()
        pressGlobalX = mouse.x
        pressGlobalY = mouse.y
        startPosX = pin.posX
        startPosY = pin.posY
        pressSceneX = dragArea.mapToItem(null, mouse.x, mouse.y).x + pin.swipeOffset * -1
        swipeTravel = 0
      }

      onPositionChanged: function(mouse) {
        if (!pressed || pin.dismissing) return
        if (!pin.swipeToSave) {
          pin.posX = Math.max(0, startPosX + (mouse.x - pressGlobalX))
          pin.posY = Math.max(0, startPosY + (mouse.y - pressGlobalY))
          return
        }
        // Horizontal only, toward the edge; dragging the other way goes nowhere.
        var sceneX = dragArea.mapToItem(null, mouse.x, mouse.y).x
        swipeTravel = Math.max(0, pressSceneX - sceneX)
        pin.swipeOffset = -swipeTravel
        // Fades a little as it nears the commit point.
        pin.dismissFade = 1 - 0.4 * Math.min(1, swipeTravel / (pin.modelData.w * pin.commitFraction))
      }

      onReleased: {
        if (!pin.swipeToSave || pin.dismissing) return
        if (swipeTravel > pin.modelData.w * pin.commitFraction) pin.flyOff()
        else if (swipeTravel > 0) snapBackAnim.start()
      }

      onCanceled: if (pin.swipeToSave && !pin.dismissing) snapBackAnim.start()

      onDoubleClicked: Util.execArgv(["xdg-open", pin.modelData.path])
    }

    // Four corner controls, each a small frosted circular badge with a
    // Lucide icon (see icons/, MIT-compatible ISC license) recolored to the
    // live theme foreground via a MultiEffect colorization pass.
    Item {
      id: closeButton
      visible: pin.hovered
      width: Style.space(24)
      height: Style.space(24)
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.margins: Style.space(4)

      Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: Util.alpha(Color.background, 0.5)
        border.color: Util.alpha(Color.foreground, 0.3)
        border.width: 1
      }

      Image {
        id: closeIcon
        anchors.centerIn: parent
        width: Style.space(14)
        height: Style.space(14)
        source: "icons/x.svg"
        sourceSize: Qt.size(width, height)
        smooth: true
        layer.enabled: true
        layer.effect: MultiEffect {
          colorization: 1.0
          colorizationColor: Color.foreground
        }
      }

      MouseArea {
        id: closeMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: if (pin.closeHandler) pin.closeHandler(pin.pinId)
      }
    }

    Item {
      id: copyButton
      visible: pin.hovered
      width: Style.space(24)
      height: Style.space(24)
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.margins: Style.space(4)

      Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: Util.alpha(Color.background, 0.5)
        border.color: Util.alpha(Color.foreground, 0.3)
        border.width: 1
      }

      Image {
        id: copyIcon
        anchors.centerIn: parent
        width: Style.space(14)
        height: Style.space(14)
        source: "icons/copy.svg"
        sourceSize: Qt.size(width, height)
        smooth: true
        layer.enabled: true
        layer.effect: MultiEffect {
          colorization: 1.0
          colorizationColor: Color.foreground
        }
      }

      MouseArea {
        id: copyMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: if (pin.copyHandler) pin.copyHandler(pin.pinId, pin.modelData.fullPath)
      }
    }

    Item {
      id: markupButton
      // The still-image annotation editor can't meaningfully edit a GIF.
      visible: pin.hovered && pin.modelData.kind !== "gif"
      width: Style.space(24)
      height: Style.space(24)
      anchors.bottom: parent.bottom
      anchors.left: parent.left
      anchors.margins: Style.space(4)

      Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: Util.alpha(Color.background, 0.5)
        border.color: Util.alpha(Color.foreground, 0.3)
        border.width: 1
      }

      Image {
        id: markupIcon
        anchors.centerIn: parent
        width: Style.space(14)
        height: Style.space(14)
        source: "icons/pencil.svg"
        sourceSize: Qt.size(width, height)
        smooth: true
        layer.enabled: true
        layer.effect: MultiEffect {
          colorization: 1.0
          colorizationColor: Color.foreground
        }
      }

      MouseArea {
        id: markupMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: if (pin.markupHandler) pin.markupHandler(pin.pinId, pin.modelData.fullPath)
      }
    }

    Item {
      id: saveButton
      visible: pin.hovered
      width: Style.space(24)
      height: Style.space(24)
      anchors.bottom: parent.bottom
      anchors.right: parent.right
      anchors.margins: Style.space(4)

      Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: Util.alpha(Color.background, 0.5)
        border.color: Util.alpha(Color.foreground, 0.3)
        border.width: 1
      }

      Image {
        id: saveIcon
        anchors.centerIn: parent
        width: Style.space(14)
        height: Style.space(14)
        source: "icons/save.svg"
        sourceSize: Qt.size(width, height)
        smooth: true
        layer.enabled: true
        layer.effect: MultiEffect {
          colorization: 1.0
          colorizationColor: Color.foreground
        }
      }

      MouseArea {
        id: saveMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: if (pin.saveHandler) pin.saveHandler(pin.pinId, pin.modelData.fullPath)
      }
    }

    Rectangle {
      id: hotLabelBadge
      visible: pin.hotLabel !== ""
      anchors.centerIn: parent
      radius: 3
      color: Color.tooltip.background
      border.color: Color.tooltip.border
      border.width: 1
      width: hotLabelText.implicitWidth + Style.space(12)
      height: hotLabelText.implicitHeight + Style.space(6)

      Text {
        id: hotLabelText
        anchors.centerIn: parent
        text: pin.hotLabel
        color: Color.tooltip.text
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }
}
