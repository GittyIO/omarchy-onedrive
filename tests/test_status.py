"""Tests for status.py: log reading, the client's status file, and state decisions."""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import status  # noqa: E402

NOW = 1_800_000_000


def journal(lines, start=NOW - 100):
    return status.read_journal([(start + i, line) for i, line in enumerate(lines)])


def monitor(state="idle", result="success", failures=0, reach="reachable", initial=True, last="2027-01-15T08:00:00.1234567Z"):
    return {
        "schema_version": 1,
        "pid": 42,
        "conditions": {"onedrive_reachability": reach},
        "process": {"state": state},
        "sync": {
            "initial_successful_sync_completed": initial,
            "last_successful_sync_at": last,
            "last_cycle": {"result": result, "download_failures": failures, "upload_failures": 0},
        },
    }


class ReadJournal(unittest.TestCase):
    def test_file_changes_in_order(self):
        changes = journal([
            "Downloading file: Documents/Receipts/scan.pdf ... done",
            "Uploading new file: Documents/Photos/bookmarks.html ... done",
            "Uploading modified file: Notes/todo.txt ... done",
            "Deleting item from Microsoft OneDrive: Old/a.txt",
            "Deleting local file: Old/b.txt",
        ])[4]
        self.assertEqual([c["kind"] for c in changes],
                         ["downloaded", "uploaded", "uploaded", "deletedOnline", "deletedLocal"])
        self.assertEqual(changes[0]["path"], "Documents/Receipts/scan.pdf")
        self.assertFalse(changes[0]["failed"])

    def test_failed_upload_is_marked(self):
        change = journal(["Uploading new file: a/b.docx ... failed!"])[4][0]
        self.assertTrue(change["failed"])
        self.assertEqual(change["path"], "a/b.docx")

    def test_markup_shaped_names_pass_through_as_text(self):
        # The widget renders names with Text.PlainText; the parser must keep them intact, not interpret them.
        change = journal(['Downloading file: x/<img src="https://example.invalid/t">.pdf ... done'])[4][0]
        self.assertEqual(change["path"], 'x/<img src="https://example.invalid/t">.pdf')

    def test_sync_markers_and_errors(self):
        start, complete, err_at, err, _ = journal([
            "Starting a sync with Microsoft OneDrive",
            "Sync with Microsoft OneDrive is complete",
            "ERROR: Microsoft OneDrive API returned an error: invalid_grant",
        ])
        self.assertLess(start, complete)
        self.assertGreater(err_at, complete)
        self.assertIn("invalid_grant", err)

    def test_harmless_lines_are_not_errors(self):
        _, _, err_at, _, _ = journal(["No changes or items that can be applied were discovered"])
        self.assertEqual(err_at, 0)


class StatusFile(unittest.TestCase):
    def test_parse_time_with_seven_fraction_digits(self):
        from datetime import datetime, timezone
        expected = int(datetime(2027, 1, 15, 8, 0, 0, tzinfo=timezone.utc).timestamp())
        self.assertEqual(status.parse_time("2027-01-15T08:00:00.1234567Z"), expected)
        self.assertEqual(status.parse_time("2027-01-15T08:00:00Z"), expected)
        self.assertEqual(status.parse_time(""), 0)
        self.assertEqual(status.parse_time("not a date"), 0)

    def test_states(self):
        self.assertEqual(status.state_from_monitor(monitor())[0], "synced")
        self.assertEqual(status.state_from_monitor(monitor(state="syncing"))[0], "syncing")
        self.assertEqual(status.state_from_monitor(monitor(initial=False))[0], "starting")
        self.assertEqual(status.state_from_monitor(monitor(reach="unreachable"))[0], "offline")
        state, _, problem = status.state_from_monitor(monitor(failures=2))
        self.assertEqual(state, "error")
        self.assertIn("2", problem)
        self.assertEqual(status.state_from_monitor(monitor(result="failure"))[0], "error")

    def test_status_file_from_another_process_is_ignored(self):
        import json
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "monitor-status.json"), "w") as f:
                json.dump(monitor(), f)
            self.assertIsNotNone(status.read_monitor_status(d, 42))
            self.assertIsNone(status.read_monitor_status(d, 43))


class DecideState(unittest.TestCase):
    empty = (0, 0, 0, "", [])

    def test_basic_states(self):
        self.assertEqual(status.decide_state(False, True, None, self.empty, NOW)[0], "notInstalled")
        self.assertEqual(status.decide_state(True, True, None, self.empty, NOW, unit_found=False)[0], "serviceMissing")
        self.assertEqual(status.decide_state(True, False, None, self.empty, NOW)[0], "paused")
        self.assertEqual(status.decide_state(True, True, None, self.empty, NOW)[0], "starting")

    def test_journal_fallback(self):
        syncing = (NOW - 10, NOW - 100, 0, "", [])
        self.assertEqual(status.decide_state(True, True, None, syncing, NOW)[0], "syncing")
        stale = (NOW - 3600, NOW - 7200, 0, "", [])
        self.assertEqual(status.decide_state(True, True, None, stale, NOW)[0], "synced")
        failed = (NOW - 100, NOW - 90, NOW - 5, "ERROR: x", [])
        state, _, problem = status.decide_state(True, True, None, failed, NOW)
        self.assertEqual((state, problem), ("error", "ERROR: x"))

    def test_newest_sync_time_wins(self):
        _, last, _ = status.decide_state(True, True, monitor(last="2020-01-01T00:00:00Z"), (0, NOW - 5, 0, "", []), NOW)
        self.assertEqual(last, NOW - 5)


class UsageCache(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = tempfile.TemporaryDirectory()
        self.saved = status.CACHE_DIR
        status.CACHE_DIR = self.tmp.name
        self.walks = 0

    def tearDown(self):
        status.CACHE_DIR = self.saved
        self.tmp.cleanup()

    def walk(self, root):
        self.walks += 1
        return 10 * self.walks, 100 * self.walks

    def usage(self, last_sync, now, root="/home/me/OneDrive"):
        return status.cached_usage(root, last_sync, now=now, walk=self.walk)

    def test_reused_until_it_expires(self):
        self.assertEqual(self.usage(500, 1000), (10, 100))
        self.assertEqual(self.usage(500, 1000 + status.USAGE_TTL_SECS - 1), (10, 100))
        self.assertEqual(self.walks, 1)
        self.assertEqual(self.usage(500, 1000 + status.USAGE_TTL_SECS + 1), (20, 200))

    def test_newer_sync_walks_again(self):
        self.usage(500, 1000)
        self.assertEqual(self.usage(1001, 1002), (20, 200))

    def test_other_folder_is_not_mixed_up(self):
        self.usage(500, 1000)
        self.usage(500, 1001, root="/home/me/OneDrive-Work")
        self.assertEqual(self.walks, 2)

    def test_broken_cache_file_is_ignored(self):
        os.makedirs(status.CACHE_DIR, exist_ok=True)
        with open(status.usage_cache_file("/home/me/OneDrive"), "w") as f:
            f.write("{not json")
        self.assertEqual(self.usage(500, 1000), (10, 100))

    def test_no_cache_without_runtime_dir(self):
        status.CACHE_DIR = None
        self.usage(500, 1000)
        self.usage(500, 1001)
        self.assertEqual(self.walks, 2)

    def test_symlinked_cache_file_is_not_read(self):
        planted = os.path.join(self.tmp.name, "planted.json")
        with open(planted, "w") as f:
            f.write('{"root": "/home/me/OneDrive", "at": 1000, "count": 999, "bytes": 999}')
        os.symlink(planted, status.usage_cache_file("/home/me/OneDrive"))
        self.assertEqual(self.usage(500, 1000), (10, 100))


if __name__ == "__main__":
    unittest.main()
