import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Browse OneDrive folders and tick the ones that sync to this computer, or sync
// the entire OneDrive. Folder names come from folders.py (read-only Microsoft
// Graph); "Apply" rewrites or removes sync_list through folders.py and runs
// resync.sh in a terminal.
Column {
  id: picker

  property string pluginDir: ""
  property var commonArgs: []
  property var catalog: null
  property color foreground: "white"
  property color dim: "gray"
  property color urgent: "red"
  property string fontFamily: Style.font.family

  property string path: "/"
  property var folders: []
  property var selected: []
  property var original: []
  // Whole-drive mode: no sync_list at all. Chosen explicitly, never by unticking everything.
  property bool syncAll: false
  property bool originalAll: false
  property bool loading: false
  property string error: ""
  // A request asked for while an older one is still running (the panel was
  // closed and reopened, say). The old one is stopped and its answer ignored.
  property string queuedPath: ""
  property bool currentQueued: false

  readonly property bool changed: syncAll !== originalAll
    || (!syncAll && JSON.stringify(selected.slice().sort()) !== JSON.stringify(original.slice().sort()))
  // An empty folder list is never written: the whole drive only syncs when syncAll is chosen.
  readonly property bool canApply: changed && (syncAll || selected.length > 0)
  readonly property bool busy: loading || applyProc.running

  signal finished(string message)
  signal cancelled()

  spacing: Style.space(10)

  function t(key) { return catalog ? catalog.t(key) : key }

  function start() {
    error = ""
    selected = []
    original = []
    syncAll = false
    originalAll = false
    folders = []
    path = "/"
    if (currentProc.running) {
      currentQueued = true
      currentProc.running = false
    } else {
      runCurrent()
    }
    browse("/")
  }

  function runCurrent() {
    currentQueued = false
    currentProc.command = ["python3", pluginDir + "/folders.py"].concat(commonArgs).concat(["current"])
    currentProc.running = true
  }

  function browse(target) {
    path = target
    folders = []
    error = ""
    loading = true
    if (listProc.running) {
      queuedPath = target
      listProc.running = false
      return
    }
    runList(target)
  }

  // Starts whatever was queued once the stopped process is really gone. Called
  // from both onExited and onRunningChanged; Qt.callLater runs it once.
  function kickQueue() {
    if (currentQueued && !currentProc.running) runCurrent()
    if (queuedPath !== "" && !listProc.running) runList(queuedPath)
  }

  function runList(target) {
    queuedPath = ""
    listProc.command = ["python3", pluginDir + "/folders.py"].concat(commonArgs).concat(["list", target])
    listProc.running = true
  }

  function up() {
    if (path === "/") return
    var i = path.lastIndexOf("/")
    browse(i <= 0 ? "/" : path.substring(0, i))
  }

  function shellQuote(word) { return "'" + String(word).replace(/'/g, "'\\''") + "'" }

  function full(name) { return path === "/" ? "/" + name : path + "/" + name }

  function stateOf(p) {
    if (syncAll) return "inherited"
    for (var i = 0; i < selected.length; i++) {
      var s = selected[i]
      if (s === p) return "on"
      if (p.indexOf(s + "/") === 0) return "inherited"
    }
    for (var j = 0; j < selected.length; j++)
      if (selected[j].indexOf(p + "/") === 0) return "partial"
    return "off"
  }

  function toggle(p) {
    var state = stateOf(p)
    if (state === "inherited") return
    var next = []
    for (var i = 0; i < selected.length; i++) {
      var s = selected[i]
      if (s === p || s.indexOf(p + "/") === 0) continue  // drop it and anything inside it
      next.push(s)
    }
    if (state !== "on") next.push(p)
    selected = next
  }

  function apply() {
    if (!canApply || applyProc.running) return
    error = ""
    applyProc.wholeDrive = syncAll
    applyProc.command = ["python3", pluginDir + "/folders.py"].concat(commonArgs)
      .concat(syncAll ? ["apply-all"] : ["apply"].concat(selected))
    applyProc.running = true
  }

  function checkGlyph(state) {
    if (state === "on" || state === "inherited") return String.fromCodePoint(0xF0132)
    if (state === "partial") return String.fromCodePoint(0xF0856)
    return String.fromCodePoint(0xF0131)
  }

  Process {
    id: currentProc
    onRunningChanged: if (!running && picker.currentQueued) Qt.callLater(picker.kickQueue)
    stdout: StdioCollector { id: currentOut; waitForEnd: true }
    onExited: function(code) {
      if (picker.currentQueued) { Qt.callLater(picker.kickQueue); return }
      try {
        var r = JSON.parse(currentOut.text)
        if (r.ok && Array.isArray(r.folders)) {
          picker.selected = r.folders.slice(0, 200).map(String)
          picker.original = picker.selected.slice()
          picker.syncAll = r.all === true
          picker.originalAll = picker.syncAll
        }
      } catch (e) {}
    }
  }

  Process {
    id: listProc
    onRunningChanged: if (!running && picker.queuedPath !== "") Qt.callLater(picker.kickQueue)
    stdout: StdioCollector { id: listOut; waitForEnd: true }
    onExited: function(code) {
      if (picker.queuedPath !== "") { Qt.callLater(picker.kickQueue); return }
      picker.loading = false
      try {
        var r = JSON.parse(listOut.text)
        if (!r.ok) { picker.error = Model.clip(r.error, 200); return }
        picker.folders = (r.folders || []).slice(0, 1000).map(function(f) {
          return { name: Model.clip(f.name, 255), children: Model.toInt(f.children) }
        })
      } catch (e) {
        picker.error = picker.t("picker.loadFailed")
      }
    }
  }

  Process {
    id: applyProc
    property bool wholeDrive: false
    stdout: StdioCollector { id: applyOut; waitForEnd: true }
    onExited: function(code) {
      var r = null
      try { r = JSON.parse(applyOut.text) } catch (e) {}
      if (!r || !r.ok) { picker.error = r ? Model.clip(r.error, 200) : picker.t("picker.applyFailed"); return }
      if (r.changed) {
        // The presentation wrapper takes one shell string, so quote every word.
        var words = [picker.pluginDir + "/resync.sh"].concat(picker.commonArgs)
          .concat(applyProc.wholeDrive ? ["--all"] : [])
        Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
          "bash " + words.map(picker.shellQuote).join(" ")])
        picker.finished(picker.t("picker.applied"))
      } else {
        picker.finished("")
      }
    }
  }

  // Header: back arrow and where you are.
  RowLayout {
    width: parent.width
    spacing: Style.space(8)

    PanelActionButton {
      iconText: String.fromCodePoint(0xF004D)
      tooltipText: picker.t("picker.back")
      foreground: picker.foreground
      fontFamily: picker.fontFamily
      enabled: picker.path !== "/" && !picker.loading
      opacity: enabled ? 1 : 0.35
      onClicked: picker.up()
    }

    Text {
      Layout.fillWidth: true
      textFormat: Text.PlainText
      text: "OneDrive" + (picker.path === "/" ? "" : picker.path.split("/").join(" › "))
      color: picker.foreground
      font.family: picker.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      elide: Text.ElideLeft
    }
  }

  Text {
    width: parent.width
    textFormat: Text.PlainText
    text: picker.t("picker.hint") + " " + picker.t("picker.disclosure")
    color: picker.dim
    font.family: picker.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  // Sync everything instead of chosen folders.
  CursorSurface {
    id: allRow
    width: parent.width
    foreground: picker.foreground
    hasCursor: allMouse.containsMouse
    implicitHeight: allLayout.implicitHeight + Style.space(10)

    MouseArea {
      id: allMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: picker.syncAll = !picker.syncAll
    }

    RowLayout {
      id: allLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: picker.checkGlyph(picker.syncAll ? "on" : "off")
        color: picker.foreground
        font.family: picker.fontFamily
        font.pixelSize: Style.font.icon * 1.15
        Layout.alignment: Qt.AlignVCenter
      }

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: picker.t("picker.syncAll")
        color: picker.foreground
        font.family: picker.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }
    }
  }

  Text {
    width: parent.width
    textFormat: Text.PlainText
    text: picker.syncAll ? picker.t("picker.allSelected")
      : picker.selected.length
      ? picker.t("picker.selected") + " " + picker.selected.map(function(p) { return p.split("/").pop() }).join(", ")
      : picker.t("picker.noneSelected")
    color: picker.syncAll || picker.selected.length ? picker.dim : picker.urgent
    font.family: picker.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  RowLayout {
    width: parent.width
    spacing: Style.space(8)

    Item { Layout.fillWidth: true }

    Button {
      text: picker.t("picker.cancel")
      foreground: picker.foreground
      fontFamily: picker.fontFamily
      fontSize: Style.font.bodySmall
      bordered: true
      onClicked: picker.cancelled()
    }

    Button {
      text: picker.t("picker.apply")
      foreground: picker.foreground
      fontFamily: picker.fontFamily
      fontSize: Style.font.bodySmall
      bordered: true
      active: picker.changed
      enabled: picker.canApply && !applyProc.running
      opacity: enabled ? 1 : 0.4
      onClicked: picker.apply()
    }
  }

  Text {
    visible: picker.loading || picker.error !== "" || (!picker.loading && picker.folders.length === 0)
    width: parent.width
    textFormat: Text.PlainText
    text: picker.loading ? picker.t("picker.loading")
      : picker.error !== "" ? picker.error : picker.t("picker.empty")
    color: picker.error !== "" ? picker.urgent : picker.dim
    font.family: picker.fontFamily
    font.pixelSize: Style.font.body
    wrapMode: Text.WordWrap
    horizontalAlignment: Text.AlignHCenter
  }

  Column {
    width: parent.width
    spacing: Style.space(2)

    Repeater {
      model: picker.folders
      CursorSurface {
        id: row
        required property var modelData
        readonly property string fullPath: picker.full(modelData.name)
        readonly property string checkState: picker.stateOf(fullPath)
        width: parent.width
        foreground: picker.foreground
        hasCursor: rowMouse.containsMouse
        implicitHeight: rowLayout.implicitHeight + Style.space(10)

        MouseArea {
          id: rowMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: row.modelData.children > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: if (row.modelData.children > 0) picker.browse(row.fullPath)
        }

        RowLayout {
          id: rowLayout
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(6)
          anchors.rightMargin: Style.space(8)
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            text: picker.checkGlyph(row.checkState)
            color: picker.foreground
            opacity: row.checkState === "inherited" ? 0.4 : 1
            font.family: picker.fontFamily
            font.pixelSize: Style.font.icon * 1.15
            Layout.alignment: Qt.AlignVCenter

            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.space(6)
              cursorShape: row.checkState === "inherited" ? Qt.ArrowCursor : Qt.PointingHandCursor
              onClicked: picker.toggle(row.fullPath)
            }
          }

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: row.modelData.name
            color: picker.foreground
            font.family: picker.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Text {
            visible: row.checkState === "partial"
            textFormat: Text.PlainText
            text: picker.t("picker.partial")
            color: picker.dim
            font.family: picker.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            text: row.modelData.children > 0 ? String.fromCodePoint(0xF0142) : ""
            color: picker.dim
            font.family: picker.fontFamily
            font.pixelSize: Style.font.icon
            Layout.preferredWidth: Style.font.icon
          }
        }
      }
    }
  }

}
