"""The connections between the apps, one function per app. Each one lists what is
there and only creates what is missing (ADR-0002): nothing the Operator configured is
ever changed. Every function returns the lines to log.

Hosts: `clients` reach the apps from the Wiring's own container, on the media network.
The addresses written into the apps are the ones those apps use: Radarr, Sonarr,
Prowlarr, Bazarr and qBittorrent share gluetun's network, so they see each other on
localhost; Seerr is outside it and reaches them by service name.
"""

from .api import ApiError

LIBRARIES = [("Películas", "movies", "radarr"), ("Series", "tvshows", "sonarr")]
PROFILE = "Media Stack"
# Seerr's MediaServerType.
JELLYFIN, NOT_CONFIGURED = 2, 4


def field_values(resource, values):
    """Fills a provider schema's fields (download client, application, proxy)."""
    for field in resource.get("fields", []):
        if field["name"] in values:
            field["value"] = values[field["name"]]
    return resource


def from_schema(client, path, implementation, name, values, **extra):
    schema = next(s for s in client.get(f"{path}/schema") if s["implementation"] == implementation)
    body = field_values(schema, values)
    body.update({"name": name, **extra})
    body.pop("id", None)
    return client.post(path, body)


def field(resource, name):
    return next((f.get("value") for f in resource.get("fields", []) if f["name"] == name), None)


# --- Jellyfin -------------------------------------------------------------------

def jellyfin(client, cfg):
    if client.get("/System/Info/Public").get("StartupWizardCompleted"):
        return ["jellyfin: already set up, left as is"]
    if not (cfg["jellyfin_user"] and cfg["jellyfin_password"]):
        return ["jellyfin: WARN no JELLYFIN_ADMIN_USER/PASSWORD in .env, finish its setup wizard by hand"]
    log = []
    client.get("/Startup/User")
    try:
        client.post("/Startup/User", {"Name": cfg["jellyfin_user"], "Password": cfg["jellyfin_password"]})
        log.append(f"jellyfin: admin {cfg['jellyfin_user']} created")
    except ApiError as e:
        # 403: the admin already has a password (an earlier run, or the web wizard).
        if e.status != 403:
            raise

    existing = {f["Name"] for f in client.get("/Library/VirtualFolders")}
    for name, collection, kind in LIBRARIES:
        if name in existing:
            continue
        paths = ",".join(m.root for m in cfg["managers"] if m.kind == kind)
        client.post("/Library/VirtualFolders", None, name=name, collectionType=collection,
                    paths=paths, refreshLibrary="false")
        log.append(f"jellyfin: library {name} ({paths}) created")
    client.post("/Startup/Complete")
    log.append("jellyfin: setup wizard completed")
    return log


# --- Radarr / Sonarr ------------------------------------------------------------

def manager(client, m, cfg):
    log = []
    if m.root not in {r["path"].rstrip("/") for r in client.get("/api/v3/rootfolder")}:
        client.post("/api/v3/rootfolder", {"path": m.root})
        log.append(f"{m.key}: root folder {m.root} added")
    if any(c["implementation"] == "QBittorrent" for c in client.get("/api/v3/downloadclient")):
        log.append(f"{m.key}: qBittorrent already there, left as is")
    elif not cfg["qbittorrent_password"]:
        log.append(f"{m.key}: WARN no QBITTORRENT_PASSWORD in .env, add qBittorrent by hand")
    else:
        category = "movieCategory" if m.kind == "radarr" else "tvCategory"
        from_schema(client, "/api/v3/downloadclient", "QBittorrent", "qBittorrent", {
            "host": "localhost", "port": 8080, "username": cfg["qbittorrent_user"],
            "password": cfg["qbittorrent_password"], category: m.category,
        }, enable=True)
        log.append(f"{m.key}: qBittorrent added (category {m.category})")
    return log


# --- Prowlarr -------------------------------------------------------------------

def prowlarr(client, cfg):
    log = []
    apps = client.get("/api/v1/applications")
    wired = {field(a, "baseUrl").rstrip("/") for a in apps if field(a, "baseUrl")}
    for m in cfg["managers"]:
        url = f"http://localhost:{m.port}"
        if url in wired:
            continue
        from_schema(client, "/api/v1/applications", m.kind.capitalize(), m.name, {
            "prowlarrUrl": "http://localhost:9696", "baseUrl": url, "apiKey": m.api_key,
        }, syncLevel="fullSync")
        log.append(f"prowlarr: {m.name} added")
    if any(p["implementation"] == "FlareSolverr" for p in client.get("/api/v1/indexerProxy")):
        return log
    tag = next((t for t in client.get("/api/v1/tag") if t["label"] == "flaresolverr"), None)
    tag = tag or client.post("/api/v1/tag", {"label": "flaresolverr"})
    from_schema(client, "/api/v1/indexerProxy", "FlareSolverr", "FlareSolverr",
                {"host": "http://localhost:8191/"}, tags=[tag["id"]])
    log.append("prowlarr: FlareSolverr added as proxy (tag flaresolverr: add it to indexers that need it)")
    return log


# --- Seerr ----------------------------------------------------------------------

def seerr(client, cfg, arr_clients):
    log = []
    public = client.get("/api/v1/settings/public")
    # Until a media server is set up Seerr has no admin, so its API key opens nothing.
    if public.get("mediaServerType") == NOT_CONFIGURED:
        if not (cfg["jellyfin_user"] and cfg["jellyfin_password"]):
            return ["seerr: WARN no JELLYFIN_ADMIN_USER/PASSWORD in .env, finish its setup by hand"]
        client.post("/api/v1/auth/jellyfin", {
            "username": cfg["jellyfin_user"], "password": cfg["jellyfin_password"],
            "hostname": "jellyfin", "port": 8096, "urlBase": "", "useSsl": False,
            "serverType": JELLYFIN,
        })
        # Seerr v3.5: POST .../sync reads Jellyfin's libraries, PUT .../{id} turns one on.
        client.post("/api/v1/settings/jellyfin/library/sync")
        for lib in client.get("/api/v1/settings/jellyfin/library"):
            client.put(f"/api/v1/settings/jellyfin/library/{lib['id']}", {"enabled": True})
        log.append("seerr: signed in with Jellyfin, libraries enabled")
    for kind in ("radarr", "sonarr"):
        servers = client.get(f"/api/v1/settings/{kind}")
        for m in [m for m in cfg["managers"] if m.kind == kind]:
            if any(s["hostname"] == m.key and s["port"] == m.port for s in servers):
                continue
            body = dvr_server(m, arr_clients[m.key], default=not m.vo and not any(s["isDefault"] for s in servers))
            servers.append(client.post(f"/api/v1/settings/{kind}", body))
            log.append(f"seerr: {m.name} added{' as default' if body['isDefault'] else ''}")
    if not public.get("initialized"):
        client.post("/api/v1/settings/initialize")
        log.append("seerr: setup finished")
    return log


def dvr_server(m, arr, default):
    profiles = arr.get("/api/v3/qualityprofile")
    profile = next((p for p in profiles if p["name"] == PROFILE), profiles[0])
    body = {
        "name": m.name, "hostname": m.key, "port": m.port, "apiKey": m.api_key,
        "useSsl": False, "baseUrl": "", "activeProfileId": profile["id"],
        "activeProfileName": profile["name"], "activeDirectory": m.root, "tags": [],
        "is4k": False, "isDefault": default, "externalUrl": "", "syncEnabled": False,
        "preventSearch": False, "tagRequests": False, "overrideRule": [],
    }
    if m.kind == "radarr":
        body["minimumAvailability"] = "released"
    else:
        body.update({"seriesType": "standard", "animeSeriesType": "anime",
                     "activeAnimeProfileId": profile["id"], "activeAnimeProfileName": profile["name"],
                     "activeAnimeDirectory": m.root, "animeTags": [],
                     "enableSeasonFolders": True, "monitorNewItems": "all"})
    return body
