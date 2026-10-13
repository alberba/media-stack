#!/usr/bin/env python3
"""Requeue unchanged Tdarr videos previously omitted because of hardlinks.

Runs on the Instance with local library/App data access. SQLite is read-only;
all status changes use Tdarr's API. Default mode only reports counts.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import stat
import urllib.request


def crud(api_url, collection, mode, doc_id, obj=None):
    headers = {"Content-Type": "application/json"}
    if os.environ.get("TDARR_API_KEY"):
        headers["x-api-key"] = os.environ["TDARR_API_KEY"]
    payload = {"data": {"collection": collection, "mode": mode,
                        "docID": doc_id, "obj": obj or {}}}
    request = urllib.request.Request(api_url.rstrip("/") + "/api/v2/cruddb",
                                     data=json.dumps(payload).encode(), headers=headers)
    with urllib.request.urlopen(request, timeout=30) as response:
        body = response.read()
    return json.loads(body) if body else None


def previously_hardlinked(file, library_id, min_gib):
    return (file.get("DB") == library_id
            and file.get("TranscodeDecisionMaker") == "Not required"
            and file.get("fileMedium") == "video"
            and file.get("statSync", {}).get("nlink", 0) > 1
            and file.get("file_size", 0) >= min_gib * 1024)


def omitted_for_hardlinks(file, reports_root):
    footprint = file.get("footprintId", "")
    if not footprint or Path(footprint).name != footprint:
        return False
    reports = list((reports_root / footprint).glob("*()transcode()*.txt"))
    if not reports:
        return False
    # Report filenames end in the job's start time in milliseconds.
    latest = max(reports, key=lambda p: int(p.stem.rsplit("()", 1)[-1]))
    with latest.open(errors="replace") as report:
        return any("File has hardlinks, routing to output 1" in line
                   or ("hardlinks: aún se comparte. Omitido." in line)
                   for line in report)


def released_unchanged(file, media_root, server_root, min_gib):
    try:
        relative = Path(file["_id"]).relative_to(server_root)
        path = (media_root / relative).resolve()
        path.relative_to(media_root.resolve())
        current = path.stat()
    except (KeyError, ValueError, OSError):
        return False
    recorded = file.get("statSync", {})
    size = recorded.get("size", round(file.get("file_size", 0) * 1024**2))
    return (stat.S_ISREG(current.st_mode) and current.st_nlink == 1
            and current.st_size >= min_gib * 1024**3
            and current.st_size == size
            and abs(current.st_mtime * 1000 - recorded.get("mtimeMs", -1)) < 2)


def active_paths(staged):
    paths = set()
    for entry in staged:
        paths.add(entry.get("_id"))
        paths.add(entry.get("originalLibraryFile", {}).get("_id"))
    return paths


def validate_library(library, flow):
    if not library.get("decisionMaker", {}).get("settingsFlows"):
        raise ValueError("Library must use Flows with hardlink and Skiplist protection")
    enabled = {p["pluginName"] for p in flow.get("flowPlugins", []) if p.get("fpEnabled")}
    if not {"checkForHardlinks", "processedCheck", "processedAdd"}.issubset(enabled):
        raise ValueError("Flow is missing hardlink or Skiplist protection")


def recheck(files, library_id, min_gib, media_root, server_root, reports_root,
            api, apply=False):
    counts = {"examined": 0, "released": 0, "requeued": 0}
    busy = active_paths(api("StagedJSONDB", "getAll", ""))
    for file in files:
        if not previously_hardlinked(file, library_id, min_gib):
            continue
        counts["examined"] += 1
        if (file["_id"] in busy or not omitted_for_hardlinks(file, reports_root)
                or not released_unchanged(file, media_root, server_root, min_gib)):
            continue
        counts["released"] += 1
        if not apply:
            continue
        # Re-read the status, staging and filesystem immediately before enqueueing.
        fresh = api("FileJSONDB", "getById", file["_id"])
        if (not fresh or not previously_hardlinked(fresh, library_id, min_gib)
                or fresh.get("lastTranscodeDate") != file.get("lastTranscodeDate")
                or file["_id"] in active_paths(api("StagedJSONDB", "getAll", ""))
                or not released_unchanged(fresh, media_root, server_root, min_gib)):
            continue
        api("FileJSONDB", "update", file["_id"], {"TranscodeDecisionMaker": "Queued"})
        counts["requeued"] += 1
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tdarr-data-root", type=Path, required=True,
                        help="Host path corresponding to /app/server/Tdarr")
    parser.add_argument("--media-root", type=Path, required=True,
                        help="Host path corresponding to --server-media-root")
    parser.add_argument("--server-media-root", type=Path, default=Path("/data/media"))
    parser.add_argument("--library-id", required=True)
    parser.add_argument("--api-url", default="http://127.0.0.1:8265")
    parser.add_argument("--min-size-gib", type=float, default=10)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    if args.min_size_gib <= 0:
        parser.error("--min-size-gib must be positive")
    api = lambda collection, mode, doc_id, obj=None: crud(
        args.api_url, collection, mode, doc_id, obj)
    # Lock in App data, shared by manual runs and scheduled invocations.
    with (args.tdarr_data_root / "hardlink-recheck.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("Another hardlink recheck is running")
            return
        library = api("LibrarySettingsJSONDB", "getById", args.library_id)
        if not library:
            raise ValueError("Library not found")
        validate_library(library, api("FlowsJSONDB", "getById", library.get("flowId", "")))
        db = args.tdarr_data_root / "DB2/SQL/database.db"
        with sqlite3.connect(db.resolve().as_uri() + "?mode=ro", uri=True) as connection:
            rows = connection.execute(
                "SELECT json_data FROM filejsondb WHERE db=? "
                "AND transcode_decision_maker='Not required'", (args.library_id,)).fetchall()
        counts = recheck((json.loads(row[0]) for row in rows), args.library_id,
                         args.min_size_gib, args.media_root, args.server_media_root,
                         args.tdarr_data_root / "DB2/JobReports", api, args.apply)
        print(json.dumps({"mode": "apply" if args.apply else "dry-run", **counts}))


if __name__ == "__main__":
    main()
