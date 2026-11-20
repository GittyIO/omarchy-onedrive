.pragma library

// Pure helpers for the OneDrive widget, kept free of QML state so they can be
// tested with plain JavaScript.

var STATES = ["synced", "syncing", "starting", "paused", "offline", "error", "notInstalled", "serviceMissing"]

function parseStatus(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object") return { ok: false }
    var state = STATES.indexOf(String(data.state)) >= 0 ? String(data.state) : "starting"
    var files = []
    var list = Array.isArray(data.files) ? data.files.slice(0, 50) : []
    for (var i = 0; i < list.length; i++) {
      var f = list[i] || {}
      files.push({
        name: clip(f.name, 200),
        folder: clip(f.folder, 300),
        path: clip(f.path, 1000),
        kind: String(f.kind || ""),
        failed: f.failed === true,
        time: toInt(f.time)
      })
    }
    var folders = Array.isArray(data.folders) ? data.folders.slice(0, 20).map(function(x) { return clip(x, 120) }) : []
    return {
      ok: true,
      installed: data.installed === true,
      running: data.running === true,
      enabled: data.enabled === true,
      state: state,
      lastSync: toInt(data.lastSync),
      lastError: clip(data.lastError, 300),
      syncDir: clip(data.syncDir, 1000),
      folderExists: data.folderExists === true,
      folders: folders,
      syncAll: data.syncAll === true,
      fileCount: toInt(data.fileCount),
      bytes: toInt(data.bytes),
      files: files,
      canControl: data.canControl !== false
    }
  } catch (err) {
    return { ok: false }
  }
}

function clip(value, max) {
  var text = String(value === undefined || value === null ? "" : value).replace(/\s+/g, " ").trim()
  return text.length > max ? text.substring(0, max - 1) + "…" : text
}

function toInt(value) {
  var n = Math.floor(Number(value))
  return isFinite(n) && n > 0 ? n : 0
}

// "just now", "4 min ago", "2 h ago", "3 days ago" — from translated templates.
function relativeTime(epochSecs, nowMs, tn) {
  if (!epochSecs) return ""
  var secs = Math.max(0, Math.round(nowMs / 1000 - epochSecs))
  if (secs < 60) return tn("time.justNow", 0)
  var mins = Math.floor(secs / 60)
  if (mins < 60) return tn("time.minutes", mins)
  var hours = Math.floor(mins / 60)
  if (hours < 24) return tn("time.hours", hours)
  return tn("time.days", Math.floor(hours / 24))
}

function sizeText(bytes, formatNumber) {
  var units = ["B", "KB", "MB", "GB", "TB"]
  var value = Number(bytes) || 0
  var unit = 0
  while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit++ }
  return formatNumber(value, unit === 0 || value >= 100 ? 0 : 1) + " " + units[unit]
}

// Nerd Font glyphs, built from code points so the source stays plain ASCII.
function glyph(code) { return String.fromCodePoint(code) }

// The symbol cut out of the bar cloud for each state ("" = none).
function statusSymbol(state) {
  if (state === "syncing" || state === "starting") return glyph(0xF04E6)  // sync arrows
  if (state === "paused") return glyph(0xF03E4)                            // pause
  if (state === "error" || state === "serviceMissing") return glyph(0xF0205) // exclamation
  if (state === "offline" || state === "notInstalled") return ""           // crossed-out cloud instead
  return glyph(0xF012C)                                                    // check
}

function logoGlyph() { return glyph(0xF03CA) } // microsoft-onedrive

function fileGlyph(name) {
  var ext = String(name || "").split(".").pop().toLowerCase()
  if (ext === "pdf") return glyph(0xF0226)
  if (["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "svg"].indexOf(ext) >= 0) return glyph(0xF021F)
  if (["doc", "docx", "odt", "rtf", "txt", "md"].indexOf(ext) >= 0) return glyph(0xF0219)
  if (["xls", "xlsx", "ods", "csv"].indexOf(ext) >= 0) return glyph(0xF021B)
  if (["zip", "7z", "rar", "tar", "gz"].indexOf(ext) >= 0) return glyph(0xF05C4)
  return glyph(0xF0214)
}

function kindKey(kind, failed) {
  if (failed) return "change.failed"
  if (kind === "downloaded") return "change.downloaded"
  if (kind === "uploaded") return "change.uploaded"
  if (kind === "deletedOnline") return "change.deletedOnline"
  if (kind === "deletedLocal") return "change.deletedLocal"
  return "change.changed"
}

function fileUri(path) {
  var parts = String(path || "").split("/")
  for (var i = 0; i < parts.length; i++) parts[i] = encodeURIComponent(parts[i])
  return "file://" + parts.join("/")
}
