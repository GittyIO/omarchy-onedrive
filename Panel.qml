import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// OneDrive bar widget for the OneDrive Client for Linux (abraunegg), modelled
// on Omarchy's own Dropbox widget. Click: panel. Right-click: refresh.
// Middle-click: open the OneDrive folder.
Panel {
  id: root
  moduleName: "gittyio.onedrive"
  // A second widget for another account gets its own IPC name.
  ipcTarget: onedrive.serviceName === "onedrive" ? "gittyio.onedrive" : "gittyio.onedrive." + onedrive.serviceName.replace(/[^A-Za-z0-9_-]/g, "-")
  manageIpc: false

  readonly property Item panelFlick: panel.loadedContent ? panel.loadedContent.panelFlick : null
  readonly property Item fileColumn: panel.loadedContent ? panel.loadedContent.fileColumn : null

  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string syncState: onedrive.shownState
  readonly property bool problem: syncState === "error" || syncState === "notInstalled"
    || syncState === "serviceMissing" || onedrive.readError !== ""
  readonly property color barIconColor: problem ? urgent
    : (syncState === "paused" || syncState === "offline" ? Qt.darker(barForeground, 1.55) : barForeground)

  property double nowMs: Date.now()
  property string message: ""
  property bool messageIsError: false
  property bool cursorActive: false
  property int fileIndex: 0
  property bool picking: false

  readonly property string lastSyncedText: onedrive.lastSync
    ? strings.t("lastSynced").arg(Model.relativeTime(onedrive.lastSync, nowMs, root.timeText)) : ""
  readonly property string statusLine: onedrive.readError !== "" ? strings.t("readFailed")
    : strings.t("state." + syncState)

  function timeText(key, n) { return strings.tn(key, n).arg(Commons.I18n.formatNumber(n, 0)) }

  function say(text, isError) {
    message = text
    messageIsError = isError === true
    messageTimer.restart()
  }

  function moveCursor(dy) {
    if (onedrive.files.length === 0) return
    if (!cursorActive) { cursorActive = true; fileIndex = 0; return }
    fileIndex = Math.max(0, Math.min(onedrive.files.length - 1, fileIndex + dy))
    scrollCursorIntoView()
  }

  function scrollCursorIntoView() {
    if (!panelFlick || !fileColumn || fileIndex >= fileColumn.children.length) return
    var item = fileColumn.children[fileIndex]
    Qt.callLater(function() {
      if (!item || !panelFlick) return
      var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
      var bottom = top + item.height
      if (top < panelFlick.contentY) panelFlick.contentY = Math.max(0, top - Style.space(6))
      else if (bottom > panelFlick.contentY + panelFlick.height)
        panelFlick.contentY = Math.min(Math.max(0, panelFlick.contentHeight - panelFlick.height), bottom + Style.space(6) - panelFlick.height)
    })
  }

  function chooseFolders() {
    if (!panel.loadedContent || !onedrive.pickerEnabled || !onedrive.canControl) return
    picking = true
    if (panelFlick) panelFlick.contentY = 0
    panel.loadedContent.picker.start()
  }

  function syncNow() {
    onedrive.syncNow()
    say(strings.t("syncNowStarted"), false)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    picking = false
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    onedrive.refresh()
    Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
  }

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  Service {
    id: onedrive
    settings: root.settings
    pluginDir: root.pluginDir
  }

  Connections {
    target: onedrive
    function onActionErrorChanged() {
      if (onedrive.actionError !== "") root.say(strings.t("commandFailed").arg(onedrive.actionError), true)
    }
    function onFilesChanged() {
      if (root.fileIndex >= onedrive.files.length) root.fileIndex = Math.max(0, onedrive.files.length - 1)
    }
  }

  Timer {
    id: messageTimer
    interval: 5000
    onTriggered: root.message = ""
  }

  Timer {
    interval: 30000
    repeat: true
    running: root.opened
    onTriggered: root.nowMs = Date.now()
  }

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { onedrive.refresh(); return "ok" }
    function status(): string { return onedrive.shownState }
    function demo(on: bool): string { onedrive.setDemo(on); root.nowMs = Date.now(); return "ok" }
    function chooseFolders(): void { root.open(); Qt.callLater(root.chooseFolders) }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.stateGlyph(root.problem && root.syncState !== "notInstalled" ? "error" : root.syncState)
    foreground: root.barIconColor
    // The cloud is wide and flat, so centring its ink still reads as sitting
    // high next to the taller icons; lower it slightly.
    transform: Translate { y: root.bar && root.bar.vertical ? 0 : 0.5 }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) onedrive.refresh()
      else if (buttonCode === Qt.MiddleButton) onedrive.openFolder()
      else root.toggle()
    }
  }

  // Pulsing dot beside the cloud while a sync is running.
  Rectangle {
    id: syncDot
    readonly property bool syncing: root.syncState === "syncing" || root.syncState === "starting"
    visible: syncing
    width: Math.max(3, Math.round(Style.space(4)))
    height: width
    radius: width / 2
    color: root.barForeground
    // Just right of the cloud's drawn edge, on its centre line.
    x: Math.round(button.width / 2 + button.glyphPaintedWidth / 2 + Style.space(2))
    y: Math.round((button.height - height) / 2)

    SequentialAnimation on opacity {
      running: syncDot.visible && Style.duration(900) > 0
      loops: Animation.Infinite
      onRunningChanged: if (!running) syncDot.opacity = 1
      NumberAnimation { from: 1; to: 0.2; duration: Style.duration(900) }
      NumberAnimation { from: 0.2; to: 1; duration: Style.duration(900) }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(560))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias panelFlick: panelFlick
      property alias fileColumn: fileColumn
      property alias picker: picker
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: if (root.cursorActive) onedrive.openFile(onedrive.files[root.fileIndex])
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var k = String(t).toLowerCase()
        if (k === "r") onedrive.refresh()
        else if (k === "p") onedrive.toggleRunning()
        else if (k === "o") onedrive.openFolder()
        else if (k === "s") root.syncNow()
        else if (k === "l") onedrive.showLog()
        else if (k === "f") root.chooseFolders()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          FolderPicker {
            id: picker
            visible: root.picking
            width: parent.width
            pluginDir: root.pluginDir
            catalog: strings
            commonArgs: onedrive.commonArgs
            foreground: root.foreground
            dim: root.dim
            urgent: root.urgent
            fontFamily: root.fontFamily
            onFinished: function(text) {
              root.picking = false
              if (text !== "") root.say(text, false)
              onedrive.refresh()
            }
            onCancelled: root.picking = false
          }

          Column {
          id: mainView
          visible: !root.picking
          width: parent.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: strings.t("title")
            meta: root.statusLine
            detail: root.syncState === "error" && onedrive.lastError !== "" ? onedrive.lastError : root.lastSyncedText
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.syncState === "paused" ? 0.5 : 1.0
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: Model.logoGlyph()
                color: root.problem ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                id: powerSwitch
                visible: onedrive.installed && onedrive.canControl
                checked: onedrive.active
                busy: onedrive.busy
                hasCursor: false
                foreground: root.foreground
                onToggled: onedrive.toggleRunning()

                PanelToolTip {
                  visible: powerSwitch.containsMouse
                  text: onedrive.active ? strings.t("pause") : strings.t("resume")
                  fontFamily: root.fontFamily
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.message !== ""
            width: parent.width
            text: root.message
            color: root.messageIsError ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Row {
            spacing: Style.space(8)

            PanelActionButton {
              iconText: String.fromCodePoint(0xF024B)
              tooltipText: strings.t("openFolder") + "  (O)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: onedrive.openFolder()
            }
            PanelActionButton {
              iconText: String.fromCodePoint(0xF0450)
              tooltipText: strings.t("syncNow") + "  (S)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              visible: onedrive.canControl
              enabled: onedrive.installed && !onedrive.busy
              onClicked: root.syncNow()
            }
            PanelActionButton {
              iconText: String.fromCodePoint(0xF018D)
              tooltipText: strings.t("showLog") + "  (L)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: onedrive.showLog()
            }
            PanelActionButton {
              iconText: String.fromCodePoint(0xF0257)
              tooltipText: strings.t("chooseFolders") + "  (F)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              visible: onedrive.pickerEnabled && onedrive.canControl
              enabled: onedrive.installed
              onClicked: root.chooseFolders()
            }
          }

          Column {
            width: parent.width
            spacing: Style.spacing.labelGap
            InfoPair { label: strings.t("folder"); value: onedrive.syncDir.replace(Quickshell.env("HOME"), "~") }
            InfoPair {
              label: strings.t("stored")
              value: strings.tn("storedValue", onedrive.fileCount)
                .arg(Commons.I18n.formatNumber(onedrive.fileCount, 0))
                .arg(Model.sizeText(onedrive.bytes, Commons.I18n.formatNumber))
            }
          }

          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: strings.t("recentChanges")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: onedrive.files.length === 0
              width: parent.width
              text: strings.t("noChanges")
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }

            Column {
              id: fileColumn
              visible: onedrive.files.length > 0
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: onedrive.files
                FileRow {
                  required property var modelData
                  required property int index
                  width: fileColumn.width
                  file: modelData
                  rowIndex: index
                }
              }
            }
          }
          }
        }
      }
    }
  }

  component FileRow: CursorSurface {
    id: fileRow
    property var file: null
    property int rowIndex: 0
    readonly property bool openable: file && file.path !== ""

    hasCursor: root.cursorActive && root.fileIndex === rowIndex
    foreground: root.foreground
    implicitHeight: fileContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: fileRow.openable ? Qt.PointingHandCursor : Qt.ArrowCursor
      onEntered: { root.cursorActive = true; root.fileIndex = fileRow.rowIndex }
      onClicked: onedrive.openFile(fileRow.file)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: Model.fileGlyph(fileRow.file ? fileRow.file.name : "")
        color: fileRow.file && fileRow.file.failed ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: fileContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: fileRow.file ? fileRow.file.name : ""
          color: root.foreground
          opacity: fileRow.openable ? 1 : 0.6
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideMiddle
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: !fileRow.file ? "" : [
            strings.t(Model.kindKey(fileRow.file.kind, fileRow.file.failed)),
            Model.relativeTime(fileRow.file.time, root.nowMs, root.timeText),
            fileRow.openable || fileRow.file.kind.indexOf("deleted") === 0 ? fileRow.file.folder : strings.t("removed")
          ].filter(function(x) { return x !== "" }).join(" · ")
          color: fileRow.file && fileRow.file.failed ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  component InfoPair: RowLayout {
    // Labels stay on the first line when a long value wraps.
    property string label: ""
    property string value: ""
    width: parent.width
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      text: label
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      textFormat: Text.PlainText
      Layout.fillWidth: true
      horizontalAlignment: Text.AlignRight
      text: value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }
  }
}
