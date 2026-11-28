#!/usr/bin/env python3
"""
Seerr Issue Automator
Listens for Seerr/Overseerr webhook events (ISSUE_CREATED),
retrieves the full issue from Seerr API,
blocklists the faulty release in Radarr/Sonarr, triggers an alternate search,
handles subtitle searches in Bazarr, and publishes the opening of each issue to the
hub's notification ingest (ISSUE_RESOLVED publishes its closing). Events are kept in
an on-disk outbox and retried until the hub confirms them, so a hub outage or a
restart does not lose a closing. The hub decides whether and how anyone is told;
this service never talks to Telegram.

Every setting comes from the environment (the Instance's .env); see load_config.
"""

import hashlib
import hmac
import json
import logging
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)

# key: (environment prefix, display name, default URL on the media network, API key required)
SERVICES = {
    "seerr": ("SEERR", "Seerr", "http://seerr:5055", True),
    "radarr": ("RADARR", "Radarr", "http://radarr:7878", True),
    "sonarr": ("SONARR", "Sonarr", "http://sonarr:8989", True),
    "bazarr": ("BAZARR", "Bazarr", "http://bazarr:6767", False),
    "radarr_vo": ("RADARR_VO", "Radarr VO", "http://radarr-vo:7879", False),
    "sonarr_vo": ("SONARR_VO", "Sonarr VO", "http://sonarr-vo:8990", False),
}
# Media type in Seerr -> (core manager, VO manager, variable with the VO server's id in Seerr)
MANAGERS = {
    "movie": ("radarr", "radarr_vo", "SEERR_RADARR_VO_SERVER_ID"),
    "tv": ("sonarr", "sonarr_vo", "SEERR_SONARR_VO_SERVER_ID"),
}

# The hub ingest settings go together: all three or none.
INGEST_VARS = ("NOTIFY_INGEST_URL", "NOTIFY_INGEST_SECRET", "NOTIFY_INGEST_HOST_ID")
# Longest text per field the hub's schema accepts.
INGEST_LIMITS = {"subject": 200, "reportedBy": 100, "problem": 300, "action": 500}

# Outbox: one JSON file per event not yet confirmed by the hub. 14 days stays below
# the 30 days the hub remembers event ids, so a repeat after a lost 2xx is still a duplicate.
OUTBOX_MAX_EVENTS = 200
OUTBOX_MAX_AGE_SECONDS = 14 * 86400
OUTBOX_BACKOFF_BASE = 15
OUTBOX_BACKOFF_CAP = 900
OUTBOX_POLL_SECONDS = 30
OUTBOX_STATES = ("open", "resolved")

# Set by main() from the environment.
CONFIG = {}

OUTBOX_LOCK = threading.Lock()
OUTBOX_DRAIN_LOCK = threading.Lock()
OUTBOX_WAKE = threading.Event()
OUTBOX_WORKER = {"thread": None, "stop": None}


class ConfigError(Exception):
    pass


def load_config(environ):
    """Builds the configuration from environment variables, or raises ConfigError
    naming every variable that is missing or wrong."""
    get = lambda name: (environ.get(name) or "").strip()
    errors = []
    services = {}
    for key, (prefix, name, default_url, required) in SERVICES.items():
        api_key = get(f"{prefix}_API_KEY") or None
        if required and not api_key:
            errors.append(f"{prefix}_API_KEY is empty")
        # The VO managers only exist when the "vo" Profile is set up.
        if key.endswith("_vo") and not api_key:
            continue
        url = (get(f"{prefix}_URL") or default_url).rstrip("/")
        services[key] = {"name": name, "url": url, "api_key": api_key}

    vo_server_ids = {}
    for media_type, (_, vo_key, id_var) in MANAGERS.items():
        raw = get(id_var)
        if not raw:
            continue
        if not raw.isdigit():
            errors.append(f"{id_var} must be a number, got '{raw}'")
            continue
        if vo_key not in services:
            errors.append(f"{id_var} is set but {SERVICES[vo_key][0]}_API_KEY is empty")
            continue
        vo_server_ids[media_type] = int(raw)

    ingest_values = {name: get(name) for name in INGEST_VARS}
    ingest = None
    if any(ingest_values.values()):
        missing = [name for name, value in ingest_values.items() if not value]
        if missing:
            errors.append(f"{', '.join(missing)} must be set together with the other NOTIFY_INGEST_* variables")
        else:
            ingest = {
                "url": ingest_values["NOTIFY_INGEST_URL"],
                "secret": ingest_values["NOTIFY_INGEST_SECRET"],
                "host_id": ingest_values["NOTIFY_INGEST_HOST_ID"],
                # Only the tests set OUTBOX_DIR; the Instance mounts its folder on /outbox.
                "outbox_dir": get("OUTBOX_DIR") or "/outbox",
            }

    if errors:
        raise ConfigError("; ".join(errors))

    return {
        "port": 5056,
        "services": services,
        "vo_server_ids": vo_server_ids,
        "ingest": ingest,
    }


def pick_manager(config, media_type, service_id):
    """Radarr/Sonarr that owns a Seerr media item: the VO one when Seerr's server id
    for it is the configured VO server, otherwise the Core one."""
    if media_type not in MANAGERS:
        return None
    core, vo, _ = MANAGERS[media_type]
    if config["vo_server_ids"].get(media_type) == service_id:
        return vo
    return core


def api_request(url, method="GET", headers=None, data=None, timeout=12):
    """Utility to perform HTTP requests using Python standard library."""
    if headers is None:
        headers = {}
    encoded_data = None
    if data is not None:
        if isinstance(data, dict):
            encoded_data = json.dumps(data).encode("utf-8")
            headers["Content-Type"] = "application/json; charset=utf-8"
        elif isinstance(data, str):
            encoded_data = data.encode("utf-8")
        elif isinstance(data, bytes):
            encoded_data = data

    req = urllib.request.Request(url, data=encoded_data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            content = resp.read().decode("utf-8")
            try:
                return json.loads(content), resp.status
            except json.JSONDecodeError:
                return content, resp.status
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="ignore")
        logging.error(f"HTTPError {e.code} for {method} {url}: {err_body}")
        return {"error": str(e), "body": err_body}, e.code
    except Exception as e:
        logging.error(f"Request failed for {method} {url}: {e}")
        return {"error": str(e)}, 500


def sign_ingest(secret, timestamp, body):
    """HMAC-SHA256 over "<timestamp>.<body>", as the hub's ingest verifies it."""
    message = str(timestamp).encode("utf-8") + b"." + body
    return hmac.new(secret.encode("utf-8"), message, hashlib.sha256).hexdigest()


def ingest_body(event):
    """The exact bytes that get signed and sent: compact JSON, fixed field order."""
    ordered = {key: event[key] for key in ("v", "source", "eventId", "hostId", "key", "state", "data")}
    return json.dumps(ordered, separators=(",", ":")).encode("utf-8")


def build_issue_event(issue_id, state, data):
    """One event per issue transition. The body is serialised once, with a stable
    eventId, so every delivery of it is the same event to the hub."""
    event_id = f"issue:{issue_id}:{state}"
    body = ingest_body({
        "v": 1,
        "source": "issue-automator",
        "eventId": event_id,
        "hostId": CONFIG["ingest"]["host_id"],
        "key": f"issue:seerr:{issue_id}",
        "state": state,
        "data": data,
    })
    return {"issue_id": issue_id, "state": state, "event_id": event_id, "body": body}


def deliver_issue_event(event):
    """One signed attempt to deliver an event. True only when the hub answers 2xx.
    Nothing from the request (secret, body) is ever logged here."""
    ingest = CONFIG["ingest"]
    timestamp = int(time.time())
    signature = sign_ingest(ingest["secret"], timestamp, event["body"])
    headers = {
        "Content-Type": "application/json",
        "X-Ingest-Timestamp": str(timestamp),
        "X-Ingest-Signature": f"v1={signature}",
    }
    try:
        _, status = api_request(ingest["url"], method="POST", headers=headers, data=event["body"])
    except Exception as e:
        # Only the exception type: its text could carry request details.
        logging.error(f"Delivery of {event['event_id']} failed unexpectedly: {type(e).__name__}")
        return False
    return 200 <= status < 300


def outbox_dir():
    ingest = CONFIG.get("ingest")
    return ingest["outbox_dir"] if ingest else None


def outbox_write(path, record):
    """Atomic: a temporary file next to the target, then a rename, so a crash leaves
    either the old record or the new one."""
    temporary = path[: -len(".json")] + ".tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(record))
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def outbox_remove(path):
    try:
        os.remove(path)
    except FileNotFoundError:
        pass


def outbox_names(directory):
    """File names of the pending events, oldest first."""
    try:
        return sorted(name for name in os.listdir(directory) if name.endswith(".json"))
    except OSError:
        return []


def outbox_enqueue(event, now=None):
    """Stores the event on disk for the drain to deliver. True when it is in the outbox
    (also when it already was), False when it could not be written."""
    directory = outbox_dir()
    issue_id = numeric_issue_id(event.get("issue_id"))
    state = event.get("state")
    if not directory or not issue_id or state not in OUTBOX_STATES:
        logging.error("Event not queued: no outbox, or an invalid issue id or state")
        return False
    now = time.time() if now is None else now
    event_id = event["event_id"]
    record = {
        "v": 1,
        "event_id": event_id,
        "issue_id": issue_id,
        "state": state,
        "body": event["body"].decode("ascii"),
        "created_at": now,
        "attempts": 0,
        "next_attempt": now,
    }
    try:
        with OUTBOX_LOCK:
            names = outbox_names(directory)
            if any(name.endswith(f"-{issue_id}-{state}.json") for name in names):
                return True
            while len(names) >= OUTBOX_MAX_EVENTS:
                oldest = names.pop(0)
                outbox_remove(os.path.join(directory, oldest))
                logging.error(f"Outbox full: dropped the oldest event {outbox_event_id(oldest)}")
            name = f"{int(now * 1000):013d}-{issue_id}-{state}.json"
            outbox_write(os.path.join(directory, name), record)
    except OSError as e:
        # Only the exception type: nothing from the event is logged.
        logging.error(f"Could not queue {event_id}: {type(e).__name__}")
        return False
    OUTBOX_WAKE.set()
    return True


def outbox_event_id(name):
    """The event id a file name stands for: <ms>-<issue>-<state>.json."""
    _, issue_id, state = name[: -len(".json")].split("-", 2)
    return f"issue:{issue_id}:{state}"


def outbox_pending():
    """(path, record) of every pending event, oldest first."""
    directory = outbox_dir()
    pending = []
    for name in outbox_names(directory) if directory else []:
        path = os.path.join(directory, name)
        try:
            with open(path, encoding="utf-8") as handle:
                record = json.load(handle)
        except (FileNotFoundError, PermissionError):
            continue
        except (OSError, ValueError):
            record = None
        if not valid_record(record):
            quarantine(path, name)
            continue
        pending.append((path, record))
    return pending


def valid_record(record):
    if not isinstance(record, dict) or record.get("v") != 1:
        return False
    number = lambda value: isinstance(value, (int, float)) and not isinstance(value, bool)
    issue_id = numeric_issue_id(record.get("issue_id"))
    return (
        issue_id is not None
        and record.get("state") in OUTBOX_STATES
        and record.get("event_id") == f"issue:{issue_id}:{record.get('state')}"
        and isinstance(record.get("body"), str)
        and number(record.get("created_at"))
        and isinstance(record.get("attempts"), int) and not isinstance(record.get("attempts"), bool)
        and number(record.get("next_attempt"))
    )


def quarantine(path, name):
    """Sets an unreadable record aside, once, so it never blocks the rest."""
    try:
        os.replace(path, path + ".corrupt")
        logging.error(f"Outbox file {name} is not a valid event: set aside as .corrupt")
    except OSError as e:
        logging.error(f"Outbox file {name} is not a valid event and could not be set aside: {type(e).__name__}")


def outbox_drain(now=None):
    """Delivers what is due. A file goes away only when the hub answers 2xx; a failure
    keeps it and schedules the next attempt. Returns the counts of this pass."""
    now = time.time() if now is None else now
    counts = {"delivered": 0, "failed": 0, "dropped": 0, "pending": 0}
    with OUTBOX_DRAIN_LOCK:
        if not CONFIG.get("ingest"):
            return counts
        # Issues with an event ahead that is not confirmed: their later events wait.
        blocked = set()
        for path, record in outbox_pending():
            event_id = record["event_id"]
            if now - record["created_at"] > OUTBOX_MAX_AGE_SECONDS:
                outbox_remove(path)
                counts["dropped"] += 1
                logging.error(f"Dropped {event_id}: older than the outbox keeps events")
                continue
            if record["issue_id"] in blocked or record["next_attempt"] > now:
                blocked.add(record["issue_id"])
                continue
            event = {
                "issue_id": record["issue_id"],
                "state": record["state"],
                "event_id": event_id,
                "body": record["body"].encode("ascii"),
            }
            if deliver_issue_event(event):
                outbox_remove(path)
                counts["delivered"] += 1
                logging.info(f"Published {event_id} to the hub")
                continue
            record["attempts"] += 1
            delay = min(OUTBOX_BACKOFF_CAP, OUTBOX_BACKOFF_BASE * 2 ** min(record["attempts"] - 1, 20))
            record["next_attempt"] = now + delay
            outbox_write(path, record)
            blocked.add(record["issue_id"])
            counts["failed"] += 1
            logging.error(f"Could not deliver {event_id} (attempt {record['attempts']}); retrying in {delay}s")
        counts["pending"] = len(outbox_names(outbox_dir()))
    return counts


def outbox_loop(stop):
    while not stop.is_set():
        try:
            outbox_drain()
        except Exception as e:
            logging.error(f"Outbox drain failed: {type(e).__name__}")
        OUTBOX_WAKE.wait(OUTBOX_POLL_SECONDS)
        OUTBOX_WAKE.clear()


def start_outbox_worker():
    """Starts the thread that delivers the outbox: now, on every new event, and every poll."""
    stop_outbox_worker()
    stop = threading.Event()
    thread = threading.Thread(target=outbox_loop, args=(stop,), name="outbox", daemon=True)
    OUTBOX_WORKER.update(thread=thread, stop=stop)
    thread.start()


def stop_outbox_worker():
    thread, stop = OUTBOX_WORKER["thread"], OUTBOX_WORKER["stop"]
    if thread is None:
        return
    stop.set()
    OUTBOX_WAKE.set()
    thread.join(timeout=15)
    OUTBOX_WORKER.update(thread=None, stop=None)


def publish_issue_event(issue_id, state, data):
    """Builds the event for an issue transition and queues it; True when it is in the outbox."""
    if not CONFIG.get("ingest"):
        logging.warning(f"Issue #{issue_id} {state} not published: NOTIFY_INGEST_* is not set")
        return False
    event = build_issue_event(issue_id, state, data)
    if outbox_enqueue(event):
        logging.info(f"Queued {event['event_id']} for the hub")
        return True
    return False


def numeric_issue_id(value):
    """The issue id as a string of 1-9 digits (what the hub's key accepts), else None."""
    text = str(value) if isinstance(value, (int, str)) and not isinstance(value, bool) else ""
    return text if re.fullmatch(r"[0-9]{1,9}", text) else None


def plain_text(value, limit):
    """Text the hub composes as plain text: markup removed, whitespace collapsed, capped."""
    text = re.sub(r"<[^>]*>", "", str(value))
    return " ".join(text.split())[:limit]


def get_seerr_issue(issue_id):
    """Fetches the full authoritative issue object directly from Seerr."""
    seerr_cfg = CONFIG["services"]["seerr"]
    base_url = seerr_cfg["url"]
    api_key = seerr_cfg["api_key"]
    url = f"{base_url}/api/v1/issue/{issue_id}"
    headers = {"X-Api-Key": api_key}
    res, status = api_request(url, headers=headers)
    if status == 200 and isinstance(res, dict):
        return res
    logging.warning(f"Failed to fetch issue #{issue_id} from Seerr: {res}")
    return None


def comment_seerr_issue(issue_id, comment_text):
    """Adds a comment to the Seerr issue confirming automated action."""
    if not issue_id:
        return
    seerr_cfg = CONFIG["services"]["seerr"]
    base_url = seerr_cfg["url"]
    api_key = seerr_cfg["api_key"]
    url = f"{base_url}/api/v1/issue/{issue_id}/comment"
    headers = {"X-Api-Key": api_key}
    data = {"message": comment_text}
    res, status = api_request(url, method="POST", headers=headers, data=data)
    if status not in (200, 201):
        logging.warning(f"Could not comment on Seerr issue #{issue_id}: {res}")


def handle_radarr_issue(service_key, tmdb_id, movie_id, issue_type_name, title):
    """
    Blocklists the faulty release in Radarr and triggers MoviesSearch for replacement.
    """
    radarr_cfg = CONFIG["services"][service_key]
    base_url = radarr_cfg["url"]
    api_key = radarr_cfg["api_key"]
    headers = {"X-Api-Key": api_key}
    inst_name = radarr_cfg.get("name", service_key)

    # 1. Resolve movie ID if missing
    if not movie_id and tmdb_id:
        lookup_url = f"{base_url}/api/v3/movie?tmdbId={tmdb_id}"
        res, status = api_request(lookup_url, headers=headers)
        if status == 200 and isinstance(res, list) and len(res) > 0:
            movie_id = res[0].get("id")

    if not movie_id:
        return False, f"No se encontró la película (TMDB: {tmdb_id}) en {inst_name}"

    # 2. Query history for this movie
    history_url = f"{base_url}/api/v3/history/movie?movieId={movie_id}"
    history, status = api_request(history_url, headers=headers)
    if status != 200 or not isinstance(history, list) or len(history) == 0:
        # Trigger MoviesSearch anyway
        cmd_url = f"{base_url}/api/v3/command"
        api_request(cmd_url, method="POST", headers=headers, data={"name": "MoviesSearch", "movieIds": [movie_id]})
        return True, f"Película monitorizada en {inst_name}. Sin descargas previas registradas; se inició búsqueda de versión."

    # Look for last imported or grabbed event
    target_event = None
    for ev in history:
        ev_type = ev.get("eventType")
        if ev_type in ("downloadFolderImported", "movieFileImported", "grabbed"):
            target_event = ev
            break
    if not target_event:
        target_event = history[0]

    history_id = target_event.get("id")
    source_title = target_event.get("sourceTitle", "Release actual")

    # 3. Blocklist release via failed endpoint
    failed_url = f"{base_url}/api/v3/history/failed/{history_id}"
    f_res, f_status = api_request(failed_url, method="POST", headers=headers)

    # 4. Trigger explicit search for an alternate release
    cmd_url = f"{base_url}/api/v3/command"
    api_request(cmd_url, method="POST", headers=headers, data={"name": "MoviesSearch", "movieIds": [movie_id]})

    msg = f"🚫 Release <b>{source_title}</b> bloqueada en la lista negra de {inst_name}.\n🔍 Búsqueda de reemplazo iniciada."
    return True, msg


def handle_sonarr_issue(service_key, tvdb_id, series_id, issue_type_name, title):
    """
    Blocklists the faulty release in Sonarr and triggers SeriesSearch for replacement.
    """
    sonarr_cfg = CONFIG["services"][service_key]
    base_url = sonarr_cfg["url"]
    api_key = sonarr_cfg["api_key"]
    headers = {"X-Api-Key": api_key}
    inst_name = sonarr_cfg.get("name", service_key)

    if not series_id and tvdb_id:
        lookup_url = f"{base_url}/api/v3/series?tvdbId={tvdb_id}"
        res, status = api_request(lookup_url, headers=headers)
        if status == 200 and isinstance(res, list) and len(res) > 0:
            series_id = res[0].get("id")

    if not series_id:
        return False, f"No se encontró la serie (TVDB: {tvdb_id}) en {inst_name}"

    history_url = f"{base_url}/api/v3/history/series?seriesId={series_id}"
    history, status = api_request(history_url, headers=headers)
    if status != 200 or not isinstance(history, list) or len(history) == 0:
        cmd_url = f"{base_url}/api/v3/command"
        api_request(cmd_url, method="POST", headers=headers, data={"name": "SeriesSearch", "seriesId": series_id})
        return True, f"Serie monitorizada en {inst_name}. Se inició SeriesSearch."

    target_event = None
    for ev in history:
        ev_type = ev.get("eventType")
        if ev_type in ("downloadFolderImported", "episodeFileImported", "grabbed"):
            target_event = ev
            break
    if not target_event:
        target_event = history[0]

    history_id = target_event.get("id")
    source_title = target_event.get("sourceTitle", "Episodio actual")

    # Mark as failed / Blocklist
    failed_url = f"{base_url}/api/v3/history/failed/{history_id}"
    api_request(failed_url, method="POST", headers=headers)

    # Trigger search
    cmd_url = f"{base_url}/api/v3/command"
    api_request(cmd_url, method="POST", headers=headers, data={"name": "SeriesSearch", "seriesId": series_id})

    msg = f"🚫 Release <b>{source_title}</b> bloqueada en lista negra de {inst_name}.\n🔍 Búsqueda de reemplazo iniciada."
    return True, msg


def handle_subtitle_issue(movie_id, series_id, title):
    """Forces subtitle search and sync in Bazarr."""
    bazarr_cfg = CONFIG["services"]["bazarr"]
    if not bazarr_cfg["api_key"]:
        return False, "Bazarr no está configurado (BAZARR_API_KEY vacío)."
    base_url = bazarr_cfg["url"]
    api_key = bazarr_cfg["api_key"]
    headers = {"X-Api-Key": api_key}

    if movie_id:
        search_url = f"{base_url}/api/movies/subtitles?radarrId={movie_id}"
        s_res, s_status = api_request(search_url, method="PATCH", headers=headers, data={"action": "search"})
        if s_status in (200, 204):
            return True, "Subtítulos solicitados y forzada sincronización en Bazarr."
        else:
            return True, f"Petición enviada a Bazarr (código {s_status})."

    return True, "Incidencia de subtítulos registrada. Bazarr re-escaneará el contenido."


def process_webhook_payload(payload):
    """Main webhook processor."""
    notif_type = payload.get("notification_type") or payload.get("event")
    logging.info(f"Received webhook event: {notif_type}")

    # Seerr's connection test and our own /test do nothing beyond answering.
    if notif_type in ("TEST_NOTIFICATION", "test"):
        return {"status": "ok", "detail": "Test notification handled"}

    # Extract issue ID from webhook
    issue_data = payload.get("issue", {})
    issue_id = issue_data.get("id") or issue_data.get("issue_id") or payload.get("issue_id")

    # A resolution only closes the incident in the hub: it must never run the
    # blocklist, the search or the Bazarr request again.
    if notif_type == "ISSUE_RESOLVED":
        event_issue_id = numeric_issue_id(issue_id)
        if not event_issue_id:
            logging.error("Resolved issue has no numeric id: nothing published to the hub")
            return {"status": "ok", "detail": "Resolved issue without a numeric id", "queued": False}
        queued = publish_issue_event(event_issue_id, "resolved", {})
        return {"status": "ok", "detail": "Issue resolved", "queued": queued}

    # Comments, reopenings and anything else Seerr may send are not ours to act on.
    if notif_type and notif_type != "ISSUE_CREATED":
        logging.info(f"Ignoring notification type {notif_type}")
        return {"status": "ignored", "detail": f"Notification type {notif_type} is not handled"}

    # If we have an issue_id, query Seerr directly for the complete authoritative data
    full_issue = None
    if issue_id:
        full_issue = get_seerr_issue(issue_id)

    if full_issue:
        issue = full_issue
        issue_id = issue.get("id")
        issue_type = issue.get("issueType", 4)
        media = issue.get("media", {})
        media_type = media.get("mediaType", "movie")
        service_id = media.get("serviceId", 0)
        ext_id = media.get("externalServiceId")
        tmdb_id = media.get("tmdbId")
        tvdb_id = media.get("tvdbId")
        created_by = issue.get("createdBy", {})
        user_name = created_by.get("displayName") or created_by.get("username") or created_by.get("email") or "Usuario"
        comments = issue.get("comments", [])
        issue_msg = comments[0].get("message") if comments else "Sin detalles"
        subject = payload.get("subject") or f"{media_type.upper()} ID {ext_id or tmdb_id or tvdb_id}"
    else:
        # Fallback to payload body
        issue = issue_data
        issue_type = issue.get("issueType") or issue.get("issue_type", 4)
        if isinstance(issue_type, str):
            mapping = {"video": 1, "audio": 2, "subtitles": 3, "other": 4}
            issue_type = mapping.get(issue_type.lower(), 4)
        media = issue.get("media", {}) or payload.get("media", {})
        media_type = media.get("media_type") or media.get("mediaType", "movie")
        service_id = media.get("serviceId", 0)
        ext_id = media.get("externalServiceId")
        tmdb_id = media.get("tmdbId") or media.get("tmdbid")
        tvdb_id = media.get("tvdbId") or media.get("tvdbid")
        user_name = payload.get("reportedBy_username") or "Usuario"
        issue_msg = payload.get("message") or "Sin detalles"
        subject = payload.get("subject", "Contenido multimedia")

    issue_type_map = {1: "Vídeo", 2: "Audio", 3: "Subtítulos", 4: "Otro"}
    issue_type_name = issue_type_map.get(issue_type, f"Tipo {issue_type}")

    logging.info(f"Processing issue #{issue_id} ({issue_type_name}) for '{subject}' (mediaType={media_type}, serviceId={service_id})")

    action_success = False
    action_detail = ""

    # Subtitles issue -> Bazarr
    if issue_type == 3:
        action_success, action_detail = handle_subtitle_issue(
            movie_id=ext_id if media_type == "movie" else None,
            series_id=ext_id if media_type == "tv" else None,
            title=subject,
        )

    # Audio or Video issue -> Radarr / Sonarr Blocklist & Re-Search
    elif issue_type in (1, 2):
        service_key = pick_manager(CONFIG, media_type, service_id)
        if media_type == "movie":
            action_success, action_detail = handle_radarr_issue(
                service_key=service_key,
                tmdb_id=tmdb_id,
                movie_id=ext_id,
                issue_type_name=issue_type_name,
                title=subject,
            )
        elif media_type == "tv":
            action_success, action_detail = handle_sonarr_issue(
                service_key=service_key,
                tvdb_id=tvdb_id,
                series_id=ext_id,
                issue_type_name=issue_type_name,
                title=subject,
            )
        else:
            action_detail = f"Tipo de medio no reconocido: {media_type}"
    else:
        action_detail = "Incidencia de tipo 'Otro'. Requiere revisión manual."

    # Send comment to Seerr issue
    clean_detail = action_detail.replace("<b>", "").replace("</b>", "")
    comment_text = f"🤖 [Auto-Responder]\nIncidencia procesada: {issue_type_name}.\n{clean_detail}"
    comment_seerr_issue(issue_id, comment_text)

    # Queue the opening for the hub; it decides who gets told.
    queued = False
    event_issue_id = numeric_issue_id(issue_id)
    if event_issue_id:
        queued = publish_issue_event(event_issue_id, "open", {
            "subject": plain_text(subject, INGEST_LIMITS["subject"]),
            "reportedBy": plain_text(user_name, INGEST_LIMITS["reportedBy"]),
            "problem": plain_text(f"{issue_type_name} ({issue_msg})", INGEST_LIMITS["problem"]),
            "action": plain_text(action_detail, INGEST_LIMITS["action"]),
        })
    else:
        logging.error("Issue has no numeric id: nothing published to the hub")

    return {"status": "success", "action_success": action_success, "detail": action_detail, "queued": queued}


class WebhookHandler(BaseHTTPRequestHandler):
    def _set_headers(self, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.end_headers()

    def do_GET(self):
        if self.path in ("/health", "/"):
            self._set_headers(200)
            pending = len(outbox_names(outbox_dir())) if CONFIG.get("ingest") else 0
            self.wfile.write(json.dumps(
                {"status": "healthy", "service": "seerr-issue-automator", "pending": pending}).encode("utf-8"))
        else:
            self._set_headers(404)
            self.wfile.write(json.dumps({"error": "Not found"}).encode("utf-8"))

    def do_POST(self):
        if self.path in ("/webhook", "/webhook/"):
            content_length = int(self.headers.get("Content-Length", 0))
            raw_data = self.rfile.read(content_length)
            try:
                payload = json.loads(raw_data.decode("utf-8"))
            except Exception as e:
                self._set_headers(400)
                self.wfile.write(json.dumps({"error": f"Invalid JSON: {e}"}).encode("utf-8"))
                return

            res = process_webhook_payload(payload)
            self._set_headers(200)
            self.wfile.write(json.dumps(res).encode("utf-8"))

        elif self.path in ("/test", "/test/"):
            self._set_headers(200)
            self.wfile.write(json.dumps({"status": "ok", "ingest_configured": bool(CONFIG.get("ingest"))}).encode("utf-8"))
        else:
            self._set_headers(404)
            self.wfile.write(json.dumps({"error": "Not found"}).encode("utf-8"))

    def log_message(self, format, *args):
        logging.info(f"{self.client_address[0]} - {format % args}")


def run_server():
    host = "0.0.0.0"
    port = CONFIG["port"]

    server = ThreadingHTTPServer((host, port), WebhookHandler)
    logging.info(f"Starting Seerr Issue Automator on http://{host}:{port}...")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logging.info("Shutting down server...")
        server.server_close()


def main():
    try:
        CONFIG.update(load_config(os.environ))
    except ConfigError as e:
        logging.error(f"Invalid configuration, set these in .env: {e}")
        sys.exit(1)
    if CONFIG["ingest"]:
        start_outbox_worker()
    else:
        logging.warning("NOTIFY_INGEST_* is not set: issues are handled but no notices are published")
    run_server()


if __name__ == "__main__":
    main()
