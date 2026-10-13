#!/usr/bin/env bash
# Verify selective Tdarr retries using real hardlinks and a fake status API.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$REPO" <<'PY'
import copy
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "recheck", Path(sys.argv[1]) / "stacks/transcode/recheck-hardlinks/recheck.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class RecheckTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.media = self.root / "media"
        self.media.mkdir()
        self.path = self.media / "movie.mkv"
        self.path.write_bytes(b"video" * 1000)
        self.link = self.root / "torrent.mkv"
        os.link(self.path, self.link)
        s = self.path.stat()
        self.file = {"_id": "/data/media/movie.mkv", "DB": "library",
                     "TranscodeDecisionMaker": "Not required", "fileMedium": "video",
                     "file_size": s.st_size / 1024**2, "lastTranscodeDate": 123,
                     "statSync": {"nlink": 2, "size": s.st_size, "mtimeMs": s.st_mtime*1000},
                     "footprintId": "footprint"}
        self.reports = self.root / "reports"
        (self.reports / "footprint").mkdir(parents=True)
        self.report = self.reports / "footprint/job()transcode()id()123.txt"
        self.report.write_text("File has hardlinks, routing to output 1\n")
        self.updates = []
        self.staged = []
        self.fresh = copy.deepcopy(self.file)

    def api(self, collection, mode, doc_id, obj=None):
        if collection == "StagedJSONDB":
            return self.staged
        if mode == "getById":
            return self.fresh
        self.updates.append(obj)
        self.fresh.update(obj)

    def run_recheck(self, apply=True):
        return m.recheck([self.file], "library", 0.000001, self.media,
                         Path("/data/media"), self.reports, self.api, apply)

    def test_still_shared_stays_out_of_queue(self):
        self.assertEqual(self.run_recheck()["requeued"], 0)
        self.assertEqual(self.updates, [])

    def test_released_file_is_requeued_once_without_overwriting_other_fields(self):
        self.link.unlink()
        self.assertEqual(self.run_recheck()["requeued"], 1)
        self.assertEqual(self.updates, [{"TranscodeDecisionMaker": "Queued"}])
        self.assertEqual(self.run_recheck()["requeued"], 0)

    def test_dry_run_does_not_mutate(self):
        self.link.unlink()
        self.assertEqual(self.run_recheck(False)["released"], 1)
        self.assertEqual(self.updates, [])

    def test_replaced_content_is_not_retried_from_old_history(self):
        self.link.unlink()
        self.path.write_bytes(b"new download")
        self.assertEqual(self.run_recheck()["requeued"], 0)

    def test_small_and_successful_files_are_excluded(self):
        self.link.unlink()
        for key, value in [("file_size", 0), ("TranscodeDecisionMaker", "Transcode success"),
                           ("DB", "another-library")]:
            with self.subTest(key=key):
                original = self.file[key]
                self.file[key] = value
                self.assertEqual(self.run_recheck()["examined"], 0)
                self.file[key] = original

    def test_missing_or_unrelated_latest_report_is_excluded(self):
        self.link.unlink()
        self.report.unlink()
        self.assertEqual(self.run_recheck()["requeued"], 0)
        self.report.write_text("File is too small\n")
        self.assertEqual(self.run_recheck()["requeued"], 0)
        self.report.write_text("hardlinks: aún se comparte. Omitido.\n")
        self.assertEqual(self.run_recheck()["requeued"], 1)

    def test_staging_or_status_change_prevents_requeue(self):
        self.link.unlink()
        self.staged = [{"originalLibraryFile": {"_id": self.file["_id"]}}]
        self.assertEqual(self.run_recheck()["requeued"], 0)
        self.staged = []
        self.fresh["TranscodeDecisionMaker"] = "Queued"
        self.assertEqual(self.run_recheck()["requeued"], 0)

    def test_paths_outside_the_library_are_excluded(self):
        self.link.unlink()
        self.file["_id"] = "/data/media/../torrent.mkv"
        self.assertEqual(self.run_recheck()["requeued"], 0)

unittest.main(argv=["tdarr-hardlinks"], verbosity=2)
PY
