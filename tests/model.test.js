// Tests for Model.js, run with: node tests/model.test.js
const fs = require("fs")
const path = require("path")
const vm = require("vm")
const assert = require("assert")

// Model.js is a QML ".pragma library" file; drop the pragma and load it as plain JS.
const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
const Model = {}
vm.runInNewContext(source + "\nObject.assign(exports, { parseStatus, clip, toInt, relativeTime, sizeText, statusSymbol, fileGlyph, kindKey, fileUri })",
  { exports: Model, String, Math, Number, JSON, Array, isFinite })

let passed = 0
function test(name, fn) {
  try { fn(); passed++ } catch (err) { console.error("FAIL " + name + "\n  " + err.message); process.exitCode = 1 }
}

test("rejects non-JSON", () => {
  assert.strictEqual(Model.parseStatus("<html>").ok, false)
  assert.strictEqual(Model.parseStatus("").ok, false)
})

test("whole-drive flag must be a real true", () => {
  assert.strictEqual(Model.parseStatus('{"syncAll":true}').syncAll, true)
  assert.strictEqual(Model.parseStatus('{"syncAll":"yes"}').syncAll, false)
  assert.strictEqual(Model.parseStatus('{}').syncAll, false)
})

test("start-at-login flag must be a real true", () => {
  assert.strictEqual(Model.parseStatus('{"enabled":true}').enabled, true)
  assert.strictEqual(Model.parseStatus('{"enabled":1}').enabled, false)
})

test("unknown states fall back to starting", () => {
  assert.strictEqual(Model.parseStatus('{"state":"<b>pwned</b>"}').state, "starting")
  assert.strictEqual(Model.parseStatus('{"state":"offline"}').state, "offline")
})

test("text is clipped and whitespace collapsed", () => {
  const long = "x".repeat(1000)
  const s = Model.parseStatus(JSON.stringify({ state: "error", lastError: long + "\n\nmore", files: [{ name: long }] }))
  assert.ok(s.lastError.length <= 300)
  assert.ok(s.files[0].name.length <= 200)
  assert.ok(!/\n/.test(s.lastError))
})

test("markup-shaped names stay as literal text", () => {
  // The panel renders these with Text.PlainText; the model must not alter or drop them.
  const name = '<img src="https://example.invalid/t">.pdf'
  const s = Model.parseStatus(JSON.stringify({ state: "synced", files: [{ name, path: "/x/" + name }] }))
  assert.strictEqual(s.files[0].name, name)
})

test("file lists are bounded", () => {
  const files = Array.from({ length: 500 }, (_, i) => ({ name: "f" + i }))
  assert.strictEqual(Model.parseStatus(JSON.stringify({ state: "synced", files })).files.length, 50)
})

test("numbers are sanitised", () => {
  const s = Model.parseStatus('{"state":"synced","fileCount":-5,"bytes":"lots","lastSync":1.9e9}')
  assert.strictEqual(s.fileCount, 0)
  assert.strictEqual(s.bytes, 0)
  assert.strictEqual(s.lastSync, 1900000000)
})

test("canControl defaults to true", () => {
  assert.strictEqual(Model.parseStatus('{"state":"synced"}').canControl, true)
  assert.strictEqual(Model.parseStatus('{"state":"synced","canControl":false}').canControl, false)
})

test("relative time", () => {
  const tn = (key, n) => key + ":" + n
  const now = 1_800_000_000 * 1000
  assert.strictEqual(Model.relativeTime(0, now, tn), "")
  assert.strictEqual(Model.relativeTime(1_800_000_000 - 30, now, tn), "time.justNow:0")
  assert.strictEqual(Model.relativeTime(1_800_000_000 - 300, now, tn), "time.minutes:5")
  assert.strictEqual(Model.relativeTime(1_800_000_000 - 7200, now, tn), "time.hours:2")
  assert.strictEqual(Model.relativeTime(1_800_000_000 - 3 * 86400, now, tn), "time.days:3")
})

test("sizes", () => {
  const fmt = (v, d) => v.toFixed(d)
  assert.strictEqual(Model.sizeText(0, fmt), "0 B")
  assert.strictEqual(Model.sizeText(1536, fmt), "1.5 KB")
  assert.strictEqual(Model.sizeText(503871682, fmt), "481 MB")
})

test("file URIs are percent-encoded per segment", () => {
  assert.strictEqual(Model.fileUri("/home/a/My Files/Verträge #1.pdf"), "file:///home/a/My%20Files/Vertr%C3%A4ge%20%231.pdf")
})

test("every state has a symbol, except the crossed-out ones", () => {
  for (const s of ["synced", "syncing", "starting", "paused", "error", "serviceMissing"])
    assert.ok(Model.statusSymbol(s).length > 0, s)
  assert.strictEqual(Model.statusSymbol("offline"), "")
  assert.strictEqual(Model.statusSymbol("notInstalled"), "")
  assert.strictEqual(Model.statusSymbol("syncing"), Model.statusSymbol("starting"))
})

test("change kinds map to translation keys", () => {
  assert.strictEqual(Model.kindKey("downloaded", false), "change.downloaded")
  assert.strictEqual(Model.kindKey("uploaded", true), "change.failed")
  assert.strictEqual(Model.kindKey("weird", false), "change.changed")
})

console.log(passed + " model tests passed")
