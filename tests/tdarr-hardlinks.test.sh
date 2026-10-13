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

    def test_remembers_omission_after_report_is_purged(self):
        evidence = {}
        m.remember_omissions([self.file], evidence, self.reports)
        self.report.unlink()
        self.link.unlink()
        counts = m.recheck([self.file], "library", 0.000001, self.media,
                          Path("/data/media"), self.reports, self.api, True, evidence)
        self.assertEqual(counts["requeued"], 1)

    def test_old_evidence_cannot_authorize_a_new_file_revision(self):
        evidence = {}
        m.remember_omissions([self.file], evidence, self.reports)
        self.report.unlink()
        self.link.unlink()
        self.file["lastTranscodeDate"] += 1
        counts = m.recheck([self.file], "library", 0.000001, self.media,
                          Path("/data/media"), self.reports, self.api, True, evidence)
        self.assertEqual(counts["requeued"], 0)

    def test_evidence_survives_atomic_save_and_reload(self):
        evidence = {}
        m.remember_omissions([self.file], evidence, self.reports)
        path = self.root / "evidence.json"
        m.save_evidence(path, evidence)
        self.assertEqual(m.load_evidence(path), evidence)

    def test_paths_outside_the_library_are_excluded(self):
        self.link.unlink()
        self.file["_id"] = "/data/media/../torrent.mkv"
        self.assertEqual(self.run_recheck()["requeued"], 0)

class FlowValidationTests(unittest.TestCase):
    def setUp(self):
        self.library = {"decisionMaker": {"settingsFlows": True}}
        names = {"input": "inputFile", "links": "checkForHardlinks",
                 "check": "processedCheck", "encoder": "runClassicTranscodePlugin",
                 "changed": "checkFileChanged", "replace": "replaceOriginalFile",
                 "add": "processedAdd"}
        self.flow = {"flowPlugins": [
            {"id": id, "pluginName": name, "fpEnabled": True,
             "sourceRepo": "Community", "version": "1.0.0",
             "inputsDB": {"checkType": "fileHash", "fileToAdd": "workingFile"}}
            for id, name in names.items()], "flowEdges": [
            {"source": a, "sourceHandle": handle, "target": b}
            for a, handle, b in [("input", "1", "links"), ("links", "2", "check"),
                                  ("check", "1", "encoder"), ("encoder", "1", "changed"),
                                  ("changed", "1", "replace"), ("replace", "1", "add")]]}

    def test_conservative_functions_are_verified_and_cannot_be_bypassed(self):
        scripts = Path(sys.argv[1]) / "stacks/transcode/flows"
        for id, filename in [("select", "conservative-select.js"), ("validate", "conservative-output.js")]:
            self.flow["flowPlugins"].append({"id": id, "pluginName": "customFunction",
                "fpEnabled": True, "sourceRepo": "Community", "version": "1.0.0",
                "inputsDB": {"code": (scripts / filename).read_text()}})
        next(e for e in self.flow["flowEdges"] if e["source"] == "links")["target"] = "select"
        next(e for e in self.flow["flowEdges"] if e["source"] == "changed")["target"] = "validate"
        self.flow["flowEdges"] += [{"source": "select", "sourceHandle": "1", "target": "check"},
                                   {"source": "validate", "sourceHandle": "1", "target": "replace"}]
        m.validate_library(self.library, self.flow)
        for source, target in [("links", "check"), ("changed", "replace")]:
            with self.subTest(source=source):
                flow = copy.deepcopy(self.flow)
                next(e for e in flow["flowEdges"] if e["source"] == source)["target"] = target
                with self.assertRaises(ValueError): m.validate_library(self.library, flow)
        self.flow["flowPlugins"][-1]["inputsDB"]["code"] = "module.exports = async args => args;"
        with self.assertRaises(ValueError): m.validate_library(self.library, self.flow)

    def test_valid_flow(self):
        m.validate_library(self.library, self.flow)

    def test_disconnected_protections_are_rejected(self):
        self.flow["flowEdges"] = []
        with self.assertRaises(ValueError): m.validate_library(self.library, self.flow)

    def test_skiplist_requires_content_hash_and_working_output(self):
        for id, key, value in [("check", "checkType", "filePath"),
                               ("add", "checkType", "fileName"),
                               ("add", "fileToAdd", "originalFile")]:
            with self.subTest(id=id, key=key):
                flow = copy.deepcopy(self.flow)
                next(p for p in flow["flowPlugins"] if p["id"] == id)["inputsDB"][key] = value
                with self.assertRaises(ValueError): m.validate_library(self.library, flow)

    def test_bypassing_each_guard_is_rejected(self):
        for source, target in [("input", "encoder"), ("links", "encoder"),
                               ("encoder", "replace"), ("encoder", "add")]:
            with self.subTest(source=source, target=target):
                flow = copy.deepcopy(self.flow)
                next(e for e in flow["flowEdges"] if e["source"] == source)["target"] = target
                with self.assertRaises(ValueError): m.validate_library(self.library, flow)

    def test_protected_outputs_cannot_reach_encoder(self):
        for source, handle in [("links", "1"), ("check", "2")]:
            with self.subTest(source=source):
                flow = copy.deepcopy(self.flow)
                flow["flowEdges"].append({"source": source, "sourceHandle": handle, "target": "encoder"})
                with self.assertRaises(ValueError): m.validate_library(self.library, flow)

    def test_missing_registration_and_cycles_are_rejected(self):
        self.flow["flowEdges"].pop()
        with self.assertRaises(ValueError): m.validate_library(self.library, self.flow)
        self.flow["flowEdges"].append({"source": "replace", "sourceHandle": "1", "target": "encoder"})
        with self.assertRaises(ValueError): m.validate_library(self.library, self.flow)

unittest.main(argv=["tdarr-hardlinks"], verbosity=2)
PY
