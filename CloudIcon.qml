import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar icon: a filled cloud with the sync status cut out of its middle,
// so it reads on any bar background, glassy ones included.
//   synced ✓   syncing/starting ⟳ (turning)   paused ‖   error/missing !
// Offline and "client not installed" use the crossed-out cloud instead.
Item {
  id: root

  property string status: "synced"
  property color color: Commons.Color.foreground
  property string fontFamily: Style.font.family
  // Size of the cloud's longest side (its width), in pixels.
  property real size: Style.bar.iconSize * 1.4

  readonly property bool crossedOut: status === "offline" || status === "notInstalled"
  readonly property string symbol: Model.statusSymbol(status)
  readonly property bool spinning: status === "syncing" || status === "starting"

  implicitWidth: size
  implicitHeight: size

  // The cloud, drawn off-screen so the effect below can punch the symbol out of it.
  OpticalGlyph {
    id: cloud
    anchors.fill: parent
    visible: root.crossedOut
    text: root.crossedOut ? Model.glyph(0xF0164) : Model.glyph(0xF015F) // cloud-off-outline / cloud
    fontFamily: root.fontFamily
    fontSize: root.size
    paintedSize: root.size
    color: root.color
    layer.enabled: !root.crossedOut
  }

  // White symbol on transparent: the shape to remove from the cloud.
  Item {
    id: mask
    anchors.fill: parent
    visible: false
    layer.enabled: true

    OpticalGlyph {
      id: symbolGlyph
      width: root.size * 0.42
      height: width
      // The cloud's body sits below its ink centre (the bumps are on top).
      x: cloud.paintedCenterX - width / 2
      y: cloud.paintedCenterY - height / 2 + cloud.paintedHeight * 0.1
      text: root.symbol
      fontFamily: root.fontFamily
      fontSize: width
      paintedSize: width
      color: "white"
      rotation: 0

      RotationAnimation on rotation {
        running: root.spinning && Style.duration(1600) > 0
        from: 0; to: 360
        duration: Style.duration(1600)
        loops: Animation.Infinite
        onRunningChanged: if (!running) symbolGlyph.rotation = 0
      }
    }
  }

  MultiEffect {
    anchors.fill: cloud
    visible: !root.crossedOut
    source: cloud
    maskEnabled: root.symbol !== ""
    maskSource: mask
    maskInverted: true
    maskThresholdMin: 0.5
    maskSpreadAtMin: 0.2
  }
}
