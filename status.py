#!/usr/bin/env python3
"""Report the OneDrive Client for Linux (abraunegg) state as JSON for the bar widget.

Reads only local sources: the client's systemd unit, its monitor-status.json
(client v2.5.10+), its journal, its config and sync_list, and the sync folder
on disk. It never contacts Microsoft and never changes anything.

Usage: status.py [--confdir DIR] [--service NAME] [--scope user|system] [--max N]
"""

import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime

sys.dont_write_bytecode = True  # keep the plugin folder clean; the shell watches it
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import onedrive_config as cfg  # noqa: E402

MAX_TEXT = 300
JOURNAL_LINES = 600
SYNCING_STALE_SECS = 15 * 60
MAX_WALK_FILES = 200_000

CHANGE_PREFIXES = [
    ("Downloading file: ", "downloaded"),
    ("Uploading new file: ", "uploaded"),
    ("Uploading modified file: ", "uploaded"),
    ("Deleting item from Microsoft OneDrive: ", "deletedOnline"),
    ("Deleting local file: ", "deletedLocal"),
    ("Trying to delete local file: ", "deletedLocal"),
]

ERROR_MARKERS = ("error", "failed", "unable to", "cannot ", "authentication", "invalid_grant", "access denied")
IGNORED_ERROR_LINES = ("no changes or items", "renaming of local file failed")


def clip(text):
    text = " ".join(str(text or "").split())
    return text if len(text) <= MAX_TEXT else text[: MAX_TEXT - 1] + "…"


def run(args, timeout=5):
    try:
        out = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return out.returncode, out.stdout
    except (OSError, subprocess.SubprocessError):
        return 1, ""


def parse_time(value):
    """ISO 8601 from the status file (7 fractional digits, Z) to epoch seconds."""
    if not isinstance(value, str) or not value:
        return 0
    text = value.strip().replace("Z", "+00:00")
    if "." in text:
        head, rest = text.split(".", 1)
        digits = re.match(r"\d*", rest).group(0)  # leading fraction digits only, not the offset's
        tz = rest[len(digits):]
        text = head + "." + digits[:6].ljust(6, "0") + tz
    try:
        return int(datetime.fromisoformat(text).timestamp())
    except ValueError:
        return 0


def synced_folders(confdir):
    folders = []
    try:
        with open(os.path.join(confdir, "sync_list"), encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith(("#", ";", "!", "-")):
                    folders.append(clip(line.strip("/").split("/")[-1] or line))
    except OSError:
        pass
    return folders[:20]


def local_usage(root):
    count, size = 0, 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for name in filenames:
            if name.startswith("."):
                continue
            try:
                size += os.lstat(os.path.join(dirpath, name)).st_size
            except OSError:
                continue
            count += 1
            if count >= MAX_WALK_FILES:
                return count, size
    return count, size


def journal_entries(scope, service):
    code, out = run(cfg.journalctl(scope) + ["-u", service, "-o", "json", "--no-pager", "-n", str(JOURNAL_LINES),
                                             "--output-fields=MESSAGE,__REALTIME_TIMESTAMP"])
    entries = []
    if code != 0:
        return entries
    for line in out.splitlines():
        try:
            item = json.loads(line)
        except ValueError:
            continue
        message = item.get("MESSAGE")
        if isinstance(message, list):  # journald sends non-UTF-8 text as a byte list
            message = bytes(b for b in message if isinstance(b, int) and 0 <= b < 256).decode("utf-8", "replace")
        try:
            stamp = int(item.get("__REALTIME_TIMESTAMP", "0")) / 1_000_000
        except (TypeError, ValueError):
            stamp = 0
        entries.append((stamp, str(message or "")))
    return entries


def read_journal(entries):
    """Sync markers, the latest error line, and file changes from the client's log."""
    last_start = last_complete = last_error_at = 0
    last_error = ""
    changes = []
    for stamp, message in entries:
        text = message.strip()
        lower = text.lower()
        if text.startswith("Starting a sync with Microsoft OneDrive") or text.startswith("Performing initial synchronisation"):
            last_start = stamp
        elif text.startswith("Sync with Microsoft OneDrive is complete"):
            last_complete = stamp
        for prefix, kind in CHANGE_PREFIXES:
            if text.startswith(prefix):
                rest = text[len(prefix):]
                failed = rest.endswith("failed!")
                for suffix in (" ... done", " ... failed!", " ... done.", "done"):
                    if rest.endswith(suffix):
                        rest = rest[: -len(suffix)]
                        break
                rel = rest.strip().strip("/")
                if rel:
                    changes.append({"path": rel, "kind": kind, "failed": failed, "time": stamp})
                break
        else:
            if any(m in lower for m in ERROR_MARKERS) and not any(i in lower for i in IGNORED_ERROR_LINES):
                last_error_at, last_error = stamp, clip(text)
    return last_start, last_complete, last_error_at, last_error, changes


def read_monitor_status(confdir, main_pid):
    """The client's own status file, when it belongs to the running process."""
    try:
        with open(os.path.join(confdir, "monitor-status.json"), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or data.get("schema_version") != 1:
        return None
    if main_pid and data.get("pid") != main_pid:
        return None
    return data


def state_from_monitor(data):
    """(state, last_sync, problem) from monitor-status.json."""
    process = data.get("process") if isinstance(data.get("process"), dict) else {}
    sync = data.get("sync") if isinstance(data.get("sync"), dict) else {}
    cycle = sync.get("last_cycle") if isinstance(sync.get("last_cycle"), dict) else {}
    conditions = data.get("conditions") if isinstance(data.get("conditions"), dict) else {}
    last_sync = parse_time(sync.get("last_successful_sync_at"))

    if conditions.get("onedrive_reachability") == "unreachable":
        return "offline", last_sync, ""
    phase = process.get("state")
    if phase == "syncing":
        return "syncing", last_sync, ""
    if phase == "starting" or not sync.get("initial_successful_sync_completed"):
        return "starting", last_sync, ""
    failures = sum(int(cycle.get(k) or 0) for k in ("download_failures", "upload_failures", "recycle_bin_failures")
                   if isinstance(cycle.get(k), (int, float)))
    result = cycle.get("result")
    if failures or (result and result != "success"):
        return "error", last_sync, f"Last sync: {failures} item(s) failed" if failures else f"Last sync result: {clip(result)}"
    return "synced", last_sync, ""


def decide_state(installed, running, monitor, journal, now, unit_found=True):
    last_start, last_complete, last_error_at, last_error, _ = journal
    if not installed:
        return "notInstalled", int(last_complete), ""
    if not unit_found:
        return "serviceMissing", int(last_complete), ""
    if not running:
        return "paused", int(last_complete), ""
    if monitor is not None:
        state, last_sync, problem = state_from_monitor(monitor)
        # The status file is rewritten once per monitor loop; the log notes every sync.
        last_sync = max(last_sync, int(last_complete))
        if state == "error":
            return state, last_sync, last_error if last_error_at > last_complete else problem
        return state, last_sync, ""
    if last_error_at and last_error_at > max(last_complete, last_start - 1):
        return "error", int(last_complete), last_error
    if last_start > last_complete and now - last_start < SYNCING_STALE_SECS:
        return "syncing", int(last_complete), ""
    if last_complete:
        return "synced", int(last_complete), ""
    return "starting", 0, ""


def main():
    parser = cfg.parser("OneDrive status for the Omarchy bar")
    parser.add_argument("--max", type=int, default=8)
    args = parser.parse_args()
    try:
        confdir, service, scope = cfg.resolve(args)
    except ValueError as err:
        print(json.dumps({"error": str(err)}))
        return 1
    max_files = max(0, min(50, args.max))

    installed = shutil.which("onedrive") is not None
    _, shown = run(cfg.systemctl(scope) + ["show", service, "-p", "ActiveState", "-p", "MainPID", "-p", "UnitFileState", "-p", "LoadState"])
    props = dict(line.split("=", 1) for line in shown.splitlines() if "=" in line)
    running = props.get("ActiveState") == "active"
    try:
        main_pid = int(props.get("MainPID") or 0)
    except ValueError:
        main_pid = 0

    root = cfg.sync_dir(confdir)
    journal = read_journal(journal_entries(scope, service))
    monitor = read_monitor_status(confdir, main_pid) if running else None
    unit_found = props.get("LoadState", "loaded") != "not-found"
    state, last_sync, problem = decide_state(installed, running, monitor, journal, time.time(), unit_found)

    recent, seen = [], set()
    for change in reversed(journal[4]):
        if change["path"] in seen:
            continue
        seen.add(change["path"])
        local = os.path.join(root, change["path"])
        recent.append({
            "name": clip(os.path.basename(change["path"])),
            "folder": clip(os.path.dirname(change["path"])),
            "path": local if os.path.exists(local) else "",
            "kind": change["kind"],
            "failed": change["failed"],
            "time": int(change["time"]),
        })
        if len(recent) >= max_files:
            break

    count, size = local_usage(root) if os.path.isdir(root) else (0, 0)
    print(json.dumps({
        "installed": installed,
        "running": running,
        "enabled": props.get("UnitFileState") == "enabled",
        "state": state,
        "source": "monitor-status" if monitor is not None else "journal",
        "lastSync": last_sync,
        "lastError": problem if state == "error" else "",
        "syncDir": root,
        "folderExists": os.path.isdir(root),
        "folders": synced_folders(confdir),
        "fileCount": count,
        "bytes": size,
        "files": recent,
        "canControl": scope == "user",
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
