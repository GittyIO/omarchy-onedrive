#!/usr/bin/env python3
"""Folder picker backend for the OneDrive bar widget.

  folders.py [opts] current          Print the folders listed in sync_list.
  folders.py [opts] list <path>      Print the subfolders of an OneDrive folder ("/" = top).
  folders.py [opts] apply <path>...  Rewrite sync_list's folder lines to exactly <path>...

[opts] are --confdir/--service/--scope, see onedrive_config.py. The account
details (application_id, azure_tenant_id, drive_id) come from the client's
own config, so a business account or a SharePoint library works too. National
clouds (azure_ad_endpoint) are not supported by the picker.

`list` reads the folder names straight from Microsoft Graph, read-only. It
borrows the OneDrive client's sign-in: it redeems a copy of the client's
refresh token for a short-lived access token, which is kept only in a private
file under $XDG_RUNTIME_DIR (memory-backed, cleared at logout). The client's
own token file is never written. Only fixed Microsoft HTTPS endpoints are used.

`apply` keeps comments and exclusion rules, backs up the old file, and leaves
the --resync the client needs after a sync_list change to resync.sh.
"""

import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.dont_write_bytecode = True  # keep the plugin folder clean; the shell watches it
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import onedrive_config as cfg  # noqa: E402

LOGIN = "https://login.microsoftonline.com"
GRAPH = "https://graph.microsoft.com/v1.0"
# Least privilege first; the client's own consent covers the broader ones.
SCOPES = ["Files.Read offline_access", "Files.Read.All offline_access",
          "Files.ReadWrite offline_access", "Files.ReadWrite.All Sites.ReadWrite.All offline_access"]
MAX_BYTES = 4 * 1024 * 1024
MAX_PAGES = 10
TIMEOUT = 15

CONFIG_DIR = cfg.default_confdir()
SYNC_LIST = os.path.join(CONFIG_DIR, "sync_list")
ACCOUNT = {}
CACHE_DIR = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "gittyio-onedrive")
CACHE_FILE = os.path.join(CACHE_DIR, "graph-token.json")


def configure(confdir):
    """Point the module at one client config directory and read its account settings."""
    global CONFIG_DIR, SYNC_LIST, ACCOUNT, CACHE_FILE
    CONFIG_DIR = confdir
    SYNC_LIST = os.path.join(confdir, "sync_list")
    conf = cfg.read_config(confdir)
    app_id = conf.get("application_id") or cfg.DEFAULT_APP_ID
    tenant = conf.get("azure_tenant_id") or "common"
    drive_id = conf.get("drive_id") or ""
    ACCOUNT = {
        "app_id": app_id if re.fullmatch(r"[0-9a-fA-F-]{36}", app_id) else None,
        "tenant": tenant if re.fullmatch(r"[A-Za-z0-9.-]{1,100}", tenant) else None,
        "drive_id": drive_id if re.fullmatch(r"[A-Za-z0-9!_.-]{0,200}", drive_id) else None,
        "national_cloud": bool(conf.get("azure_ad_endpoint")),
    }
    # One cached token per account, so two widgets never mix them up.
    key = hashlib.sha256(os.path.realpath(confdir).encode()).hexdigest()[:16]
    CACHE_FILE = os.path.join(CACHE_DIR, f"graph-token-{key}.json")


def drive_root():
    if ACCOUNT.get("drive_id"):
        return f"{GRAPH}/drives/{urllib.parse.quote(ACCOUNT['drive_id'], safe='!')}/root"
    return f"{GRAPH}/me/drive/root"


def fail(message, code=1):
    print(json.dumps({"ok": False, "error": message}))
    sys.exit(code)


def valid_path(path):
    return (isinstance(path, str) and path.startswith("/") and 1 < len(path) <= 400
            and not re.search(r"[\x00-\x1f\x7f*?]", path)
            and ".." not in path.split("/") and not path.endswith("/"))


def is_folder_line(line):
    s = line.strip()
    return s.startswith("/") and not s.startswith(("/*", "//")) and "*" not in s


KEEP_BACKUPS = 5


def prune_backups(keep=KEEP_BACKUPS):
    """Keep only the newest `keep` sync_list.bak.<time> files."""
    folder, base = os.path.split(SYNC_LIST)
    pattern = re.compile(re.escape(base) + r"\.bak\.(\d+)$")
    try:
        found = sorted(((int(m.group(1)), n) for n in os.listdir(folder or ".")
                        if (m := pattern.match(n))), reverse=True)
    except OSError:
        return
    for _, name in found[keep:]:
        try:
            os.remove(os.path.join(folder, name))
        except OSError:
            pass


def read_sync_list():
    try:
        with open(SYNC_LIST, encoding="utf-8") as f:
            return f.read().splitlines()
    except FileNotFoundError:
        return []


def http(url, data=None, headers=None):
    req = urllib.request.Request(url, data=data, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            body = resp.read(MAX_BYTES + 1)
    except urllib.error.HTTPError as err:
        body = err.read(MAX_BYTES + 1)
        try:
            detail = json.loads(body).get("error", {})
            detail = detail.get("message") if isinstance(detail, dict) else str(detail)
        except ValueError:
            detail = ""
        raise RuntimeError(f"HTTP {err.code} {detail or ''}".strip()[:200])
    except (urllib.error.URLError, TimeoutError, OSError) as err:
        raise RuntimeError(f"Network error: {err}"[:200])
    if len(body) > MAX_BYTES:
        raise RuntimeError("Response too large")
    return json.loads(body)


def access_token():
    try:
        with open(CACHE_FILE, encoding="utf-8") as f:
            cached = json.load(f)
        if cached.get("expires", 0) > time.time() + 60 and isinstance(cached.get("token"), str):
            return cached["token"]
    except (OSError, ValueError):
        pass

    try:
        with open(os.path.join(CONFIG_DIR, "refresh_token"), encoding="utf-8") as f:
            refresh = f.read().strip()
    except OSError:
        raise RuntimeError("The OneDrive client isn't signed in.")
    if not refresh:
        raise RuntimeError("The OneDrive client isn't signed in.")

    last = None
    if ACCOUNT.get("national_cloud"):
        raise RuntimeError("The folder picker only supports Microsoft's global cloud.")
    if not ACCOUNT.get("app_id") or not ACCOUNT.get("tenant") or ACCOUNT.get("drive_id") is None:
        raise RuntimeError("The client's account settings look unusual, so the picker won't use them.")
    token_url = f"{LOGIN}/{ACCOUNT['tenant']}/oauth2/v2.0/token"
    for scope in SCOPES:
        form = urllib.parse.urlencode({"client_id": ACCOUNT["app_id"], "grant_type": "refresh_token",
                                       "refresh_token": refresh, "scope": scope}).encode()
        try:
            reply = http(token_url, form, {"Content-Type": "application/x-www-form-urlencoded"})
        except RuntimeError as err:
            last = err
            continue
        token = reply.get("access_token")
        if isinstance(token, str) and token:
            os.makedirs(CACHE_DIR, mode=0o700, exist_ok=True)
            os.chmod(CACHE_DIR, 0o700)
            fd = os.open(CACHE_FILE + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                json.dump({"token": token, "expires": time.time() + int(reply.get("expires_in", 3000))}, f)
            os.replace(CACHE_FILE + ".tmp", CACHE_FILE)
            return token
    raise RuntimeError(f"Couldn't sign in to OneDrive ({last})")


def list_folders(path):
    if path != "/" and not valid_path(path):
        fail("Invalid folder path.")
    if path == "/":
        url = drive_root() + "/children"
    else:
        url = drive_root() + ":" + urllib.parse.quote(path, safe="/") + ":/children"
    url += "?$select=name,folder,remoteItem&$top=200"

    token = access_token()
    folders = []
    for _ in range(MAX_PAGES):
        page = http(url, headers={"Authorization": "Bearer " + token, "Accept": "application/json"})
        for item in page.get("value", [])[:1000]:
            if not isinstance(item, dict) or "folder" not in item or "remoteItem" in item:
                continue
            name = str(item.get("name", ""))
            if not name or "/" in name or re.search(r"[\x00-\x1f\x7f]", name):
                continue
            count = item.get("folder", {}).get("childCount", 0)
            folders.append({"name": name[:255], "children": count if isinstance(count, int) else 0})
        url = page.get("@odata.nextLink")
        if not isinstance(url, str) or not url.startswith("https://graph.microsoft.com/"):
            break
    folders.sort(key=lambda f: f["name"].casefold())
    print(json.dumps({"ok": True, "path": path, "folders": folders}))


def current():
    paths = [l.strip() for l in read_sync_list() if is_folder_line(l)]
    print(json.dumps({"ok": True, "folders": paths}))


def apply(paths):
    if not paths:
        # An empty sync_list makes the client sync the entire OneDrive.
        fail("Refusing to save an empty folder list: that would sync your whole OneDrive.")
    clean = []
    for p in paths:
        p = p.rstrip("/")
        if not valid_path(p):
            fail(f"Invalid folder path: {p[:80]}")
        if p not in clean:
            clean.append(p)
    # A folder already covered by a selected parent is redundant.
    clean = [p for p in clean if not any(p.startswith(q + "/") for q in clean if q != p)]

    lines = read_sync_list()
    kept = [l for l in lines if not is_folder_line(l)]
    new = kept + clean
    if [l.strip() for l in lines if l.strip()] == [l.strip() for l in new if l.strip()]:
        print(json.dumps({"ok": True, "changed": False, "folders": clean}))
        return
    if lines:
        backup = f"{SYNC_LIST}.bak.{int(time.time())}"
        with open(backup, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        prune_backups()
    tmp = SYNC_LIST + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(new) + "\n")
    os.replace(tmp, SYNC_LIST)
    print(json.dumps({"ok": True, "changed": True, "folders": clean}))


def main():
    parser = cfg.parser("OneDrive folder picker backend")
    parser.add_argument("command", choices=["current", "list", "apply"])
    parser.add_argument("paths", nargs="*")
    args = parser.parse_args()
    try:
        confdir, _, _ = cfg.resolve(args)
    except ValueError as err:
        fail(str(err))
    configure(confdir)
    try:
        if args.command == "current":
            current()
        elif args.command == "list" and len(args.paths) == 1:
            list_folders(args.paths[0])
        elif args.command == "apply":
            apply(args.paths)
        else:
            fail("Unknown command.")
    except RuntimeError as err:
        fail(str(err))


if __name__ == "__main__":
    main()
