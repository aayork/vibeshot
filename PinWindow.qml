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

  anchors { top: true; left: true }
  margins.left: Math.round(posX)
  margins.top: Math.round(posY)
  implicitWidth: modelData.w
  implicitHeight: modelData.h
  color: "transparent"
  WlrLayershell.namespace: "vibeshot-pin"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Ignore

  BorderSurface {
    id: card
    anchors.fill: parent
    clip: true
    color: "transparent"
    radius: Style.cornerRadius
    borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))

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
    }

    // Drag surface sits under the buttons/close chrome so those keep click
    // priority; declared first so later (visually on top) items win hit-testing.
    MouseArea {
      id: dragArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.SizeAllCursor
      property real pressGlobalX: 0
      property real pressGlobalY: 0
      property real startPosX: 0
      property real startPosY: 0

      onPressed: function(mouse) {
        pressGlobalX = mouse.x
        pressGlobalY = mouse.y
        startPosX = pin.posX
        startPosY = pin.posY
      }

      onPositionChanged: function(mouse) {
        if (!pressed) return
        pin.posX = Math.max(0, startPosX + (mouse.x - pressGlobalX))
        pin.posY = Math.max(0, startPosY + (mouse.y - pressGlobalY))
      }

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
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: if (pin.copyHandler) pin.copyHandler(pin.pinId, pin.modelData.fullPath)
      }
    }

    Item {
      id: markupButton
      visible: pin.hovered
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
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: if (pin.saveHandler) pin.saveHandler(pin.pinId, pin.modelData.fullPath)
      }
    }
  }
}
