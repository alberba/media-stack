"""What the Wiring knows about an Instance: its managers, their keys and folders.

Everything comes from the environment (the Instance's .env) and from the App data the
apps already wrote. A key found in an app's own config file wins over .env, because
that is the key the app really uses (an Instance configured before the Wiring existed).
"""

import json
import os
import re
from dataclasses import dataclass

from . import topology

TOPOLOGY = topology.load()


@dataclass
class Manager:
    """A Radarr or Sonarr of the Instance."""

    key: str  # radarr, sonarr, radarr-vo, sonarr-vo: service name and App data folder
    kind: str  # radarr or sonarr
    name: str
    port: int
    root: str  # root folder for the library
    category: str  # qBittorrent category; downloads land in /data/torrents/<category>
    vo: bool
    api_key: str = ""

    @property
    def env(self):
        return self.key.upper().replace("-", "_")


def profiles(environ):
    return topology.profiles(environ.get("COMPOSE_PROFILES") or "")


def managers(environ):
    """The managers this Instance runs: the Core ones, plus the VO ones with the vo Profile."""
    return [Manager(s["key"], port=s["port"], vo=bool(s.get("profile")), **s["manager"])
            for s in TOPOLOGY.managers(profiles(environ))]


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


def arr_key_in(appdata, key):
    text = read(os.path.join(appdata, key, "config.xml")) or ""
    m = re.search(r"<ApiKey>\s*([^<\s]+)\s*</ApiKey>", text)
    return m.group(1) if m else ""


def bazarr_key_in(appdata):
    text = read(os.path.join(appdata, "bazarr", "config", "config.yaml")) or ""
    m = re.search(r"^auth:\s*\n(?:[ \t]+.*\n)*?[ \t]+apikey:\s*['\"]?([0-9A-Za-z]+)", text, re.M)
    return m.group(1) if m else ""


def seerr_key_in(appdata):
    try:
        return json.loads(read(os.path.join(appdata, "seerr", "settings.json")) or "{}")["main"]["apiKey"]
    except (ValueError, KeyError, TypeError):
        return ""


def get(environ, name):
    return (environ.get(name) or "").strip()


def on(environ, name):
    return get(environ, name).lower() in ("on", "true", "yes", "1")


def arr_key(environ, appdata, key, env_name):
    return arr_key_in(appdata, key) or get(environ, f"{env_name}_API_KEY")


def load(environ, appdata="/appdata"):
    """Everything the Wiring needs, with the keys resolved."""
    ms = managers(environ)
    for m in ms:
        m.api_key = arr_key(environ, appdata, m.key, m.env)
    return {
        "managers": ms,
        "prowlarr_key": arr_key(environ, appdata, "prowlarr", "PROWLARR"),
        "seerr_key": seerr_key_in(appdata) or get(environ, "SEERR_API_KEY"),
        "qbittorrent_user": get(environ, "QBITTORRENT_USER") or "admin",
        "qbittorrent_password": get(environ, "QBITTORRENT_PASSWORD"),
        "jellyfin_user": get(environ, "JELLYFIN_ADMIN_USER"),
        "jellyfin_password": get(environ, "JELLYFIN_ADMIN_PASSWORD"),
        "jellyfin_abyss": on(environ, "JELLYFIN_ABYSS"),
        "jellyfin_seerr_reporter": on(environ, "JELLYFIN_SEERR_REPORTER"),
        "qualities": [q.strip() for q in get(environ, "QUALITIES").split(",") if q.strip()],
    }
