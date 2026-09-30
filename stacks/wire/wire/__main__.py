"""The Wiring (CONTEXT.md, ADR-0002).

  python -m wire seed   before the apps start: seeds the keys and passwords from .env
  python -m wire wire   once they answer: connects them and syncs the quality profile

Exits non-zero, naming what failed, when any step fails; the others still run.
"""

import os
import subprocess
import sys

from . import config, quality, steps
from .api import Client
from .seed import Seeder

APPDATA = os.environ.get("WIRE_APPDATA", "/appdata")
DATA = os.environ.get("WIRE_DATA", "/data")
RECYCLARR_DIR = os.environ.get("RECYCLARR_CONFIG_DIR", "/config")
WAIT = int(os.environ.get("WIRE_WAIT_SECONDS", "900"))


def arr(host, port, key, version):
    return Client(f"http://{host}:{port}", {"X-Api-Key": key}), f"/api/{version}/system/status"


def run(name, step, failures):
    try:
        for line in step():
            print(line, flush=True)
    except Exception as e:  # noqa: BLE001 - report it and carry on with the other apps
        print(f"{name}: FAIL {e}", flush=True)
        failures.append(name)


def recyclarr(cfg, arr_clients):
    if not cfg["qualities"]:
        return ["quality: no QUALITIES in .env, quality profiles left as they are"]
    existing = {m.key: {p["name"] for p in arr_clients[m.key].get("/api/v3/qualityprofile")}
                for m in cfg["managers"]}
    log = quality.write_config(RECYCLARR_DIR, cfg["managers"], cfg["qualities"], existing)
    subprocess.run(["recyclarr", "sync"], check=True)
    return log + [f"quality: profile '{steps.PROFILE}' synced with the TRaSH Guides"]


def wire():
    cfg = config.load(os.environ, APPDATA)
    failures = []
    missing = [m.env + "_API_KEY" for m in cfg["managers"] if not m.api_key]
    missing += [n for n, k in (("PROWLARR_API_KEY", cfg["prowlarr_key"]), ("SEERR_API_KEY", cfg["seerr_key"])) if not k]
    if missing:
        print(f"FAIL no API key for {', '.join(missing)}: run scripts/setup.sh", flush=True)
        return 1

    jellyfin = Client("http://jellyfin:8096")
    seerr = Client("http://seerr:5055", {"X-Api-Key": cfg["seerr_key"]})
    arr_clients = {}
    waits = [(jellyfin, "/System/Info/Public", False), (seerr, "/api/v1/status", False)]
    for m in cfg["managers"]:
        arr_clients[m.key], path = arr(m.key, m.port, m.api_key, "v3")
        waits.append((arr_clients[m.key], path, False))
    prowlarr, path = arr("prowlarr", 9696, cfg["prowlarr_key"], "v1")
    waits.append((prowlarr, path, False))
    # Radarr, Sonarr and Prowlarr test the connection when qBittorrent and FlareSolverr
    # are added, so those must answer too. qBittorrent's page answers without a login.
    waits += [(Client("http://qbittorrent:8080"), "/", True), (Client("http://flaresolverr:8191"), "/health", False)]
    for client, path, any_answer in waits:
        try:
            client.wait(path, WAIT, any_answer=any_answer)
        except TimeoutError as e:
            print(f"FAIL {e}", flush=True)
            return 1

    run("jellyfin", lambda: steps.jellyfin(jellyfin, cfg), failures)
    for m in cfg["managers"]:
        run(m.key, lambda m=m: steps.manager(arr_clients[m.key], m, cfg), failures)
    run("prowlarr", lambda: steps.prowlarr(prowlarr, cfg), failures)
    run("quality", lambda: recyclarr(cfg, arr_clients), failures)
    # Last: Seerr picks the quality profile the step above created.
    run("seerr", lambda: steps.seerr(seerr, cfg, arr_clients), failures)
    if failures:
        print(f"FAIL wiring incomplete: {', '.join(failures)}. Fix it and run `docker compose up wire` again.", flush=True)
        return 1
    print("ok   every app is wired", flush=True)
    return 0


def main(argv):
    if argv[1:] == ["seed"]:
        for line in Seeder(os.environ, APPDATA, DATA).run():
            print(line, flush=True)
        return 0
    if argv[1:] == ["wire"]:
        return wire()
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
