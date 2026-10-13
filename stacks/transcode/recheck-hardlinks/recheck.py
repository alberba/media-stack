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
import tempfile
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
    """Validate every reachable path in the supported classic-encoder Flow."""
    if not library.get("decisionMaker", {}).get("settingsFlows") or not flow:
        raise ValueError("Library must use a protected Flow")
    outputs = {"inputFile": ("1",), "checkFileSize": ("1", "2"),
               "checkVideoBitrate": ("1", "2"), "checkForHardlinks": ("1", "2"),
               "processedCheck": ("1", "2"), "checkNodeHardwareEncoder": ("1", "2"),
               "runClassicTranscodePlugin": ("1",), "checkFileChanged": ("1", "2"),
               "replaceOriginalFile": ("1",), "processedAdd": ("1",), "customFunction": ("1", "2")}
    nodes = {p["id"]: p for p in flow.get("flowPlugins", [])}
    if len(nodes) != len(flow.get("flowPlugins", [])):
        raise ValueError("Duplicate Flow node IDs")
    starts = [id for id, p in nodes.items() if p["pluginName"] == "inputFile"]
    if len(starts) != 1:
        raise ValueError("Flow needs exactly one Input File")
    edges = {}
    for edge in flow.get("flowEdges", []):
        key = (edge["source"], str(edge["sourceHandle"]))
        if key in edges or edge["source"] not in nodes or edge["target"] not in nodes:
            raise ValueError("Ambiguous or dangling Flow connection")
        edges[key] = edge["target"]
    reached_encoders = set()
    scripts = Path(__file__).resolve().parent.parent / "flows"
    selection_code = (scripts / "conservative-select.js").read_text()
    output_code = (scripts / "conservative-output.js").read_text()
    conservative = any(p.get("pluginName") == "customFunction" for p in nodes.values())

    def walk(id, evidence, ancestors):
        if id in ancestors:
            raise ValueError("Cyclic Flows cannot be verified")
        node = nodes[id]
        name = node["pluginName"]
        if (not node.get("fpEnabled") or name not in outputs
                or node.get("sourceRepo") != "Community" or node.get("version") != "1.0.0"):
            raise ValueError("Unsupported or disabled step on a reachable Flow path")
        inputs = node.get("inputsDB", {})
        if name in {"processedCheck", "processedAdd"} and inputs.get("checkType") != "fileHash":
            raise ValueError("Skiplist must identify content by fileHash")
        if name == "customFunction" and inputs.get("code") not in {selection_code, output_code}:
            raise ValueError("Unverified Custom Function")
        current = set(evidence)
        if name == "runClassicTranscodePlugin":
            if not {"links-clear", "unprocessed"}.issubset(current):
                raise ValueError("Encoder bypasses hardlink or Skiplist protection")
            if "encoded" in current:
                raise ValueError("Multiple encoders on one path cannot be verified")
            if conservative and "selected" not in current:
                raise ValueError("Encoder bypasses conservative bitrate selection")
            reached_encoders.add(id)
            current.add("encoded")
        elif name == "replaceOriginalFile":
            if not {"encoded", "changed"}.issubset(current):
                raise ValueError("Replacement must follow encoding and Check File Changed")
            if conservative and "validated" not in current:
                raise ValueError("Replacement bypasses conservative output validation")
            current.add("replaced")
        elif name == "processedAdd":
            if (inputs.get("fileToAdd") != "workingFile"
                    or not {"encoded", "changed", "replaced"}.issubset(current)):
                raise ValueError("Register the working output only after a changed file is replaced")
            current.add("recorded")
        for output in outputs[name]:
            branch = set(current)
            if name == "checkForHardlinks":
                if output == "2": branch.add("links-clear")
                else: branch.discard("links-clear")
            elif name == "processedCheck":
                if output == "1": branch.add("unprocessed")
                else: branch.discard("unprocessed")
            elif name == "checkFileChanged":
                if output == "1": branch.add("changed")
                else: branch.difference_update({"encoded", "changed", "replaced", "recorded"})
            elif name == "customFunction":
                if inputs["code"] == selection_code:
                    if output == "1": branch.add("selected")
                    else: branch.discard("selected")
                elif output == "1":
                    if not {"encoded", "changed"}.issubset(branch):
                        raise ValueError("Output validation must follow a changed encode")
                    branch.add("validated")
                else:
                    # The canonical output function throws on failure; no output 2 exists.
                    if (id, output) in edges:
                        raise ValueError("Output validation has no failure bypass")
                    continue
            target = edges.get((id, output))
            if target:
                walk(target, branch, ancestors | {id})
            elif "encoded" in branch and "recorded" not in branch:
                raise ValueError("Encoded output can terminate without Skiplist registration")
        if any(source == id and handle not in outputs[name] for source, handle in edges):
            raise ValueError("Unknown Flow output")

    walk(starts[0], set(), set())
    if not reached_encoders:
        raise ValueError("Flow has no reachable protected encoder")


def omission_identity(file):
    """Bind cached proof to a library, scan revision and unchanged file metadata."""
    recorded = file.get("statSync", {})
    return {"library": file.get("DB"), "footprint": file.get("footprintId"),
            "lastTranscodeDate": file.get("lastTranscodeDate"),
            "size": recorded.get("size", round(file.get("file_size", 0) * 1024**2)),
            "mtimeMs": recorded.get("mtimeMs")}


def remember_omissions(files, evidence, reports_root):
    for file in files:
        identity = omission_identity(file)
        if (evidence.get(file["_id"]) != identity
                and omitted_for_hardlinks(file, reports_root)):
            evidence[file["_id"]] = identity


def load_evidence(path):
    if not path.exists():
        return {}
    data = json.loads(path.read_text())
    if data.get("version") != 1 or not isinstance(data.get("omissions"), dict):
        raise ValueError("Unsupported hardlink omission state")
    return data["omissions"]


def save_evidence(path, evidence):
    # Atomic replacement preserves the previous state if writing is interrupted.
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as state:
            temporary = Path(state.name)
            json.dump({"version": 1, "omissions": evidence}, state)
            state.flush()
            os.fsync(state.fileno())
        os.replace(temporary, path)
    finally:
        if temporary and temporary.exists():
            temporary.unlink()


def recheck(files, library_id, min_gib, media_root, server_root, reports_root,
            api, apply=False, evidence=None):
    evidence = evidence if evidence is not None else {}
    counts = {"examined": 0, "released": 0, "requeued": 0}
    busy = active_paths(api("StagedJSONDB", "getAll", ""))
    for file in files:
        if not previously_hardlinked(file, library_id, min_gib):
            continue
        counts["examined"] += 1
        if (file["_id"] in busy or (evidence.get(file["_id"]) != omission_identity(file)
                    and not omitted_for_hardlinks(file, reports_root))
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
    parser.add_argument("--min-size-gib", type=float, default=0)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    if args.min_size_gib < 0:
        parser.error("--min-size-gib must be non-negative")
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
        files = [json.loads(row[0]) for row in rows]
        candidates = [file for file in files if previously_hardlinked(
            file, args.library_id, args.min_size_gib)]
        state_path = args.tdarr_data_root / "hardlink-omissions.json"
        evidence = load_evidence(state_path)
        remember_omissions(candidates, evidence, args.tdarr_data_root / "DB2/JobReports")
        # Save proof before any queue mutation, including files still shared.
        if args.apply:
            save_evidence(state_path, evidence)
        counts = recheck(files, args.library_id,
                         args.min_size_gib, args.media_root, args.server_media_root,
                         args.tdarr_data_root / "DB2/JobReports", api, args.apply, evidence)
        print(json.dumps({"mode": "apply" if args.apply else "dry-run", **counts}))


if __name__ == "__main__":
    main()
