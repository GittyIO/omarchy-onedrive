"""Tests for folders.py: path rules and sync_list rewriting.

Every test points folders.py at a throwaway config directory and never touches
the network or the real ~/.config/onedrive.
"""

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import folders  # noqa: E402


def run(fn, *args):
    """Call a folders.py command and return its JSON reply (fail() exits)."""
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        try:
            fn(*args)
        except SystemExit:
            pass
    return json.loads(out.getvalue())


class Paths(unittest.TestCase):
    def test_valid_paths(self):
        for p in ["/Documents", "/Documents/Receipts", "/Verträge 2026", "/a b/c (1)"]:
            self.assertTrue(folders.valid_path(p), p)

    def test_rejected_paths(self):
        for p in ["", "/", "relative", "/a/../etc", "/a/", "/a\nb", "/a*", "/a?", "/" + "x" * 500]:
            self.assertFalse(folders.valid_path(p), repr(p))

    def test_folder_lines(self):
        self.assertTrue(folders.is_folder_line("/Documents/Receipts"))
        for line in ["# comment", "!/Exclude", "-/Exclude", "/*.tmp", "//x", "Relative/Path"]:
            self.assertFalse(folders.is_folder_line(line), line)


class Apply(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        folders.configure(self.tmp.name)
        self.sync_list = os.path.join(self.tmp.name, "sync_list")
        with open(self.sync_list, "w") as f:
            f.write("# my rules\n!/Documents/Receipts/Old\n/Documents/Receipts\n/Documents/Photos\n")

    def tearDown(self):
        self.tmp.cleanup()

    def lines(self):
        with open(self.sync_list) as f:
            return f.read().splitlines()

    def backups(self):
        return [n for n in os.listdir(self.tmp.name) if n.startswith("sync_list.bak.")]

    def test_refuses_empty_selection(self):
        before = self.lines()
        reply = run(folders.apply, [])
        self.assertFalse(reply["ok"])
        self.assertEqual(self.lines(), before)

    def test_refuses_invalid_path_without_writing(self):
        before = self.lines()
        reply = run(folders.apply, ["/Documents/Receipts", "/Documents/../etc"])
        self.assertFalse(reply["ok"])
        self.assertEqual(self.lines(), before)
        self.assertEqual(self.backups(), [])

    def test_unchanged_selection_writes_nothing(self):
        reply = run(folders.apply, ["/Documents/Receipts", "/Documents/Photos"])
        self.assertEqual((reply["ok"], reply["changed"]), (True, False))
        self.assertEqual(self.backups(), [])

    def test_change_keeps_rules_and_backs_up(self):
        reply = run(folders.apply, ["/Documents/Receipts", "/Documents/Taxes"])
        self.assertTrue(reply["changed"])
        self.assertEqual(self.lines(), ["# my rules", "!/Documents/Receipts/Old", "/Documents/Receipts", "/Documents/Taxes"])
        self.assertEqual(len(self.backups()), 1)

    def test_only_newest_backups_are_kept(self):
        for t in range(1000, 1008):
            with open(f"{self.sync_list}.bak.{t}", "w") as f:
                f.write("old\n")
        with open(f"{self.sync_list}.bak.notes", "w") as f:
            f.write("not a backup\n")
        run(folders.apply, ["/Documents/Taxes"])
        kept = sorted(self.backups())
        self.assertEqual(len([n for n in kept if n[len("sync_list.bak."):].isdigit()]), folders.KEEP_BACKUPS)
        self.assertNotIn("sync_list.bak.1000", kept)
        self.assertIn("sync_list.bak.notes", kept)

    def test_folders_inside_a_selected_folder_are_dropped(self):
        reply = run(folders.apply, ["/Documents/Receipts/2026", "/Documents", "/Documents/Receipts"])
        self.assertEqual(reply["folders"], ["/Documents"])

    def test_current_lists_only_folder_lines(self):
        reply = run(folders.current)
        self.assertEqual(reply["folders"], ["/Documents/Receipts", "/Documents/Photos"])


class Account(unittest.TestCase):
    def write_config(self, text):
        self.tmp = tempfile.TemporaryDirectory()
        with open(os.path.join(self.tmp.name, "config"), "w") as f:
            f.write(text)
        folders.configure(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def test_defaults_to_personal_drive(self):
        self.write_config("")
        self.assertTrue(folders.drive_root().endswith("/me/drive/root"))
        self.assertEqual(folders.ACCOUNT["app_id"], folders.cfg.DEFAULT_APP_ID)

    def test_sharepoint_drive_id(self):
        self.write_config('drive_id = "b!AbC-123_x"\n')
        self.assertIn("/drives/b!AbC-123_x/root", folders.drive_root())

    def test_suspicious_settings_are_not_used(self):
        self.write_config('drive_id = "../../me"\napplication_id = "not-a-guid"\n')
        self.assertIsNone(folders.ACCOUNT["drive_id"])
        self.assertIsNone(folders.ACCOUNT["app_id"])
        with self.assertRaises(RuntimeError):
            folders.access_token()

    def test_national_cloud_is_refused_before_any_network_call(self):
        self.write_config('azure_ad_endpoint = "USL4"\n')
        with open(os.path.join(self.tmp.name, "refresh_token"), "w") as f:
            f.write("dummy")
        folders.CACHE_FILE = os.path.join(self.tmp.name, "no-cache.json")
        with self.assertRaises(RuntimeError) as ctx:
            folders.access_token()
        self.assertIn("global cloud", str(ctx.exception))


class Network(unittest.TestCase):
    def test_only_microsoft_https_hosts(self):
        self.assertTrue(folders.allowed_url("https://graph.microsoft.com/v1.0/me/drive/root/children"))
        self.assertTrue(folders.allowed_url("https://login.microsoftonline.com/common/oauth2/v2.0/token"))
        for url in ["http://graph.microsoft.com/v1.0", "https://graph.microsoft.com.evil.example/",
                    "https://evil.example/?https://graph.microsoft.com/", "https://user@graph.microsoft.com/",
                    "https://graph.microsoft.com:8443/", "file:///etc/passwd"]:
            self.assertFalse(folders.allowed_url(url), url)
        with self.assertRaises(RuntimeError):
            folders.http("https://evil.example/")

    def test_redirects_are_refused(self):
        handler = folders._NoRedirect()
        req = folders.urllib.request.Request("https://graph.microsoft.com/v1.0/x",
                                             headers={"Authorization": "Bearer secret"})
        with self.assertRaises(folders.urllib.error.HTTPError) as ctx:
            handler.redirect_request(req, None, 302, "Found", {}, "https://evil.example/")
        ctx.exception.close()


class TokenCache(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        os.chmod(self.tmp.name, 0o700)
        saved = (folders.CACHE_DIR, folders.CACHE_FILE)
        self.addCleanup(lambda: setattr(folders, "CACHE_DIR", saved[0]) or setattr(folders, "CACHE_FILE", saved[1]))
        folders.CACHE_DIR = os.path.join(self.tmp.name, "gittyio-onedrive")
        folders.CACHE_FILE = os.path.join(folders.CACHE_DIR, "graph-token-test.json")

    def test_round_trip_is_private(self):
        folders.write_cached_token("tok", 3000)
        self.assertEqual(folders.read_cached_token(), "tok")
        self.assertEqual(os.stat(folders.CACHE_DIR).st_mode & 0o777, 0o700)
        self.assertEqual(os.stat(folders.CACHE_FILE).st_mode & 0o777, 0o600)
        self.assertEqual(os.listdir(folders.CACHE_DIR), ["graph-token-test.json"])

    def test_no_cache_without_runtime_dir(self):
        folders.CACHE_DIR = folders.CACHE_FILE = None
        folders.write_cached_token("tok", 3000)
        self.assertIsNone(folders.read_cached_token())

    def test_symlinked_cache_dir_is_refused(self):
        target = os.path.join(self.tmp.name, "elsewhere")
        os.mkdir(target, 0o700)
        os.symlink(target, folders.CACHE_DIR)
        folders.write_cached_token("tok", 3000)
        self.assertEqual(os.listdir(target), [])
        self.assertIsNone(folders.read_cached_token())

    def test_open_cache_dir_is_refused(self):
        os.mkdir(folders.CACHE_DIR, 0o700)
        os.chmod(folders.CACHE_DIR, 0o777)
        folders.write_cached_token("tok", 3000)
        self.assertEqual(os.listdir(folders.CACHE_DIR), [])

    def test_symlinked_cache_file_is_not_read(self):
        os.mkdir(folders.CACHE_DIR, 0o700)
        planted = os.path.join(self.tmp.name, "planted.json")
        with open(planted, "w") as f:
            json.dump({"token": "evil", "expires": 9e9}, f)
        os.chmod(planted, 0o600)
        os.symlink(planted, folders.CACHE_FILE)
        self.assertIsNone(folders.read_cached_token())

    def test_readable_cache_file_is_not_trusted(self):
        folders.write_cached_token("tok", 3000)
        os.chmod(folders.CACHE_FILE, 0o644)
        self.assertIsNone(folders.read_cached_token())


if __name__ == "__main__":
    unittest.main()
