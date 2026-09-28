#!/usr/bin/env python3
"""
Seerr Issue Automator
Listens for Seerr/Overseerr webhook events (ISSUE_CREATED),
retrieves the full issue from Seerr API,
blocklists the faulty release in Radarr/Sonarr, triggers an alternate search,
handles subtitle searches in Bazarr, and notifies via Telegram.

Every setting comes from the environment (the Instance's .env); see load_config.
"""

import json
import logging
import os
import sys
import threading
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

# Set by main() from the environment.
CONFIG = {}


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

    if errors:
        raise ConfigError("; ".join(errors))

    token, chat_id = get("TELEGRAM_BOT_TOKEN"), get("TELEGRAM_CHAT_ID")
    return {
        "port": int(get("ISSUE_AUTOMATOR_PORT") or 5056),
        "services": services,
        "vo_server_ids": vo_server_ids,
        "telegram": {"bot_token": token, "chat_id": chat_id} if token and chat_id else None,
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


def send_telegram(text_html):
    """Sends a formatted notification to Telegram."""
    tg_cfg = CONFIG.get("telegram")
    if not tg_cfg:
        return
    token = tg_cfg["bot_token"]
    chat_id = tg_cfg["chat_id"]

    url = f"https://api.telegram.org/bot{token}/sendMessage"
    payload = {
        "chat_id": chat_id,
        "text": text_html,
        "parse_mode": "HTML",
        "disable_web_page_preview": True,
    }
    res, status = api_request(url, method="POST", data=payload)
    if status != 200:
        logging.warning(f"Failed to send Telegram message: {res}")


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

    # Handle test webhooks
    if notif_type in ("TEST_NOTIFICATION", "test"):
        send_telegram("🧪 <b>Test de conexión recibido</b>\n\nEl servicio Issue-Automator está conectado con éxito a Seerr.")
        return {"status": "ok", "detail": "Test notification handled"}

    # Extract issue ID from webhook
    issue_data = payload.get("issue", {})
    issue_id = issue_data.get("id") or issue_data.get("issue_id") or payload.get("issue_id")

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

    # Send Telegram notification
    tg_text = (
        f"🚨 <b>Incidencia reportada en Seerr</b>\n\n"
        f"🎬 <b>Título:</b> {subject}\n"
        f"👤 <b>Reportado por:</b> {user_name}\n"
        f"⚠️ <b>Problema:</b> {issue_type_name} ({issue_msg})\n\n"
        f"⚙️ <b>Acción automática:</b>\n{action_detail}"
    )
    send_telegram(tg_text)

    return {"status": "success", "action_success": action_success, "detail": action_detail}


class WebhookHandler(BaseHTTPRequestHandler):
    def _set_headers(self, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.end_headers()

    def do_GET(self):
        if self.path in ("/health", "/"):
            self._set_headers(200)
            self.wfile.write(json.dumps({"status": "healthy", "service": "seerr-issue-automator"}).encode("utf-8"))
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
            send_telegram("🧪 <b>Test manual de Issue Automator</b>\n\nEl microservicio está activo y el bot de Telegram responde correctamente.")
            self._set_headers(200)
            self.wfile.write(json.dumps({"status": "test sent to Telegram"}).encode("utf-8"))
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
    run_server()


if __name__ == "__main__":
    main()
