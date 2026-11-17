import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Polls status.py, which reads the client's systemd unit, status file, journal
// and sync folder. Pause, resume and "sync now" are plain systemctl calls on
// that unit (user units only); nothing here talks to Microsoft directly.
Item {
  id: root

  property var settings: ({})
  property string pluginDir: ""

  // Which client setup this widget follows (plugin settings; empty = defaults).
  readonly property string confDir: String(settings && settings.configDir ? settings.configDir : "")
  readonly property string serviceName: String(settings && settings.serviceName ? settings.serviceName : "onedrive")
  readonly property string serviceScope: settings && settings.serviceScope === "system" ? "system" : "user"
  readonly property bool pickerEnabled: !(settings && settings.folderPicker === false)
  readonly property var commonArgs: ["--confdir", confDir, "--service", serviceName, "--scope", serviceScope]
  readonly property string unit: /\.service$/.test(serviceName) ? serviceName : serviceName + ".service"

  property bool installed: true
  property bool running: false
  property string syncState: "starting"
  property int lastSync: 0
  property string lastError: ""
  property string syncDir: Quickshell.env("HOME") + "/OneDrive"
  property bool folderExists: true
  property int fileCount: 0
  property double bytes: 0
  property var files: []
  property bool canControl: true
  property bool loaded: false
  property string readError: ""
  property string actionError: ""
  // Sample data for README screenshots (IPC: demo true/false); never real names.
  property bool demo: false

  // Shown straight away while systemctl catches up: -1 follow reality, 0/1 pending.
  property int _desired: -1
  readonly property bool active: _desired === -1 ? running : (_desired === 1)
  readonly property string shownState: _desired === 0 ? "paused" : (_desired === 1 && !running ? "starting" : syncState)
  readonly property bool busy: controlProcess.running

  readonly property int refreshIntervalSec: {
    var n = parseInt(String(settings && settings.refreshIntervalSec !== undefined ? settings.refreshIntervalSec : 15), 10)
    return isFinite(n) ? Math.max(5, Math.min(3600, n)) : 15
  }

  function setDemo(on) {
    demo = on
    if (!on) { refresh(); return }
    var now = Math.floor(Date.now() / 1000)
    _desired = -1
    installed = true; running = true; canControl = true; readError = ""
    syncState = "synced"; lastSync = now - 120; lastError = ""
    syncDir = Quickshell.env("HOME") + "/OneDrive"; folderExists = true
    fileCount = 1284; bytes = 2468000000
    files = [
      { name: "Quarterly report.xlsx", folder: "Work/Reports", path: "/demo", kind: "uploaded", failed: false, time: now - 140 },
      { name: "Lease agreement.pdf", folder: "Documents/Home", path: "/demo", kind: "downloaded", failed: false, time: now - 900 },
      { name: "Beach day.jpg", folder: "Pictures/Summer", path: "/demo", kind: "downloaded", failed: false, time: now - 3600 },
      { name: "Old notes.txt", folder: "Documents", path: "/demo", kind: "deletedOnline", failed: false, time: now - 7300 }
    ]
    loaded = true
  }

  function refresh() {
    if (demo || statusProcess.running || !pluginDir) return
    statusProcess.command = ["python3", pluginDir + "/status.py"].concat(commonArgs).concat(["--max", "8"])
    statusProcess.running = true
  }

  function apply(raw) {
    var s = Model.parseStatus(raw)
    if (!s.ok) { readError = "read"; return }
    readError = ""
    installed = s.installed
    running = s.running
    syncState = s.state
    lastSync = s.lastSync
    lastError = s.lastError
    if (s.syncDir) syncDir = s.syncDir
    folderExists = s.folderExists
    fileCount = s.fileCount
    bytes = s.bytes
    files = s.files
    canControl = s.canControl
    loaded = true
    if (_desired !== -1 && running === (_desired === 1)) _desired = -1
  }

  function control(verb, desired) {
    if (!installed || !canControl || controlProcess.running) return
    _desired = desired
    actionError = ""
    controlProcess.command = ["systemctl", "--user", verb, unit]
    controlProcess.running = true
  }

  function pause() { control("stop", 0) }
  function resume() { control("start", 1) }
  function toggleRunning() { active ? pause() : resume() }
  // The client runs in monitor mode; a restart makes it sync everything right away.
  function syncNow() { control("restart", 1) }

  function openFolder() {
    Quickshell.execDetached(["uwsm-app", "--", "nautilus", "--new-window", Model.fileUri(syncDir)])
  }

  function openFile(file) {
    if (!file || !file.path) return
    Quickshell.execDetached(["uwsm-app", "--", "nautilus", "--select", Model.fileUri(String(file.path))])
  }

  function showLog() {
    var journal = serviceScope === "user" ? ["journalctl", "--user"] : ["journalctl"]
    Quickshell.execDetached(["uwsm-app", "--", "xdg-terminal-exec", "--title=OneDrive sync log"]
      .concat(journal).concat(["-u", unit, "-n", "200", "-f"]))
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Poll quickly for a little while after pause, resume or sync now.
  Timer {
    id: settleTimer
    property int ticks: 0
    interval: 1500
    repeat: true
    onTriggered: {
      ticks += 1
      root.refresh()
      if (ticks >= 8) { ticks = 0; running = false; root._desired = -1 }
    }
  }

  Process {
    id: statusProcess
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.apply(statusOut.text)
      else root.readError = "read"
    }
  }

  Process {
    id: controlProcess
    stderr: StdioCollector { id: controlErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root._desired = -1
        root.actionError = Model.clip(controlErr.text || ("exit " + exitCode), 200)
      }
      settleTimer.ticks = 0
      settleTimer.restart()
      root.refresh()
    }
  }
}
