#!/usr/bin/env bash
# Tests for the Wiring (stacks/wire): what it seeds before the apps start, and what it
# connects afterwards, against fake apps served over HTTP. Needs python3.
# Usage: tests/wire.test.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

PYTHONPATH="$REPO/stacks/wire" python3 -B - <<'EOF'
import base64
import hashlib
import json
import os
import re
import tempfile
import threading
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from wire import config, quality, seed, steps
from wire.api import Client


class FakeApp:
    """An app's API kept in memory. `lists` maps a path to the items GET returns and
    POST appends to; `values` maps a path to a fixed answer. Every call is recorded."""

    def __init__(self, lists=None, values=None, schemas=None):
        self.lists = {k: list(v) for k, v in (lists or {}).items()}
        self.values = dict(values or {})
        self.schemas = schemas or {}
        self.calls = []
        self.handlers = {}
        app = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do(self, method):
                url = urllib.parse.urlsplit(self.path)
                length = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(length)) if length else None
                app.calls.append((method, url.path, dict(urllib.parse.parse_qsl(url.query)), body, dict(self.headers)))
                status, answer = app.answer(method, url.path, body)
                raw = b"" if answer is None else json.dumps(answer).encode()
                self.send_response(status)
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            do_GET = lambda self: self.do("GET")
            do_POST = lambda self: self.do("POST")
            do_PUT = lambda self: self.do("PUT")

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    def answer(self, method, path, body):
        if (method, path) in self.handlers:
            return self.handlers[(method, path)](body)
        if method == "GET" and path.endswith("/schema"):
            return 200, self.schemas[path[: -len("/schema")]]
        if method == "GET" and path in self.lists:
            return 200, self.lists[path]
        if method == "GET" and path in self.values:
            return 200, self.values[path]
        if method == "POST" and path in self.lists:
            item = dict(body, id=len(self.lists[path]) + 1)
            self.lists[path].append(item)
            return 201, item
        if method in ("POST", "PUT"):
            return 204, None
        return 404, {"error": path}

    def posts(self, path=None):
        return [c for c in self.calls if c[0] == "POST" and (path is None or c[1] == path)]

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def schema(implementation, *names):
    return [{"implementation": implementation, "id": 0, "fields": [{"name": n, "value": None} for n in names]}]


def fields(item):
    return {f["name"]: f["value"] for f in item["fields"]}


ENV = {"RADARR_API_KEY": "r" * 32, "SONARR_API_KEY": "s" * 32, "PROWLARR_API_KEY": "p" * 32,
       "BAZARR_API_KEY": "b" * 32, "SEERR_API_KEY": "e" * 32, "QBITTORRENT_PASSWORD": "qpass",
       "JELLYFIN_ADMIN_USER": "ana", "JELLYFIN_ADMIN_PASSWORD": "jpass", "PUID": "1000", "PGID": "1000"}


class Case(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.appdata = os.path.join(self.tmp.name, "appdata")
        self.data = os.path.join(self.tmp.name, "data")
        os.makedirs(self.appdata)
        os.makedirs(self.data)
        self.apps = []

    def tearDown(self):
        for app in self.apps:
            app.close()
        self.tmp.cleanup()

    def app(self, **kwargs):
        app = FakeApp(**kwargs)
        self.apps.append(app)
        return app

    def cfg(self, **env):
        return config.load({**ENV, **env}, self.appdata)

    def write(self, relpath, text):
        path = os.path.join(self.appdata, relpath)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)

    def read(self, relpath):
        with open(os.path.join(self.appdata, relpath)) as f:
            return f.read()


class Wait(Case):
    def test_any_answer_counts_for_a_login_page(self):
        app = self.app()
        Client(app.url).wait("/nothing-here", timeout=1, interval=0.1, any_answer=True)

    def test_times_out_naming_the_url(self):
        app = self.app()
        with self.assertRaises(TimeoutError) as caught:
            Client(app.url).wait("/nothing-here", timeout=0.2, interval=0.1)
        self.assertIn("/nothing-here", str(caught.exception))


class Config(Case):
    def test_core_managers_without_the_vo_profile(self):
        self.assertEqual([m.key for m in self.cfg().get("managers")], ["radarr", "sonarr"])

    def test_vo_profile_adds_the_vo_managers(self):
        cfg = self.cfg(COMPOSE_PROFILES="backup, vo", RADARR_VO_API_KEY="rv")
        self.assertEqual([m.key for m in cfg["managers"]], ["radarr", "sonarr", "radarr-vo", "sonarr-vo"])
        self.assertEqual(cfg["managers"][2].api_key, "rv")

    def test_the_key_the_app_already_uses_wins_over_env(self):
        self.write("radarr/config.xml", "<Config>\n  <Port>7878</Port>\n  <ApiKey>fromfile</ApiKey>\n</Config>")
        self.write("seerr/settings.json", json.dumps({"main": {"apiKey": "seerrfile"}}))
        cfg = self.cfg()
        self.assertEqual(cfg["managers"][0].api_key, "fromfile")
        self.assertEqual(cfg["managers"][1].api_key, "s" * 32)
        self.assertEqual(cfg["seerr_key"], "seerrfile")

    def test_bazarr_key_is_read_from_its_config(self):
        self.write("bazarr/config/config.yaml", "general:\n  ip: '*'\nauth:\n  type: null\n  apikey: abc123\n")
        self.assertEqual(config.bazarr_key_in(self.appdata), "abc123")

    def test_qualities_are_a_list(self):
        self.assertEqual(self.cfg(QUALITIES="WEB 1080p, Bluray-1080p")["qualities"], ["WEB 1080p", "Bluray-1080p"])


class Seed(Case):
    def seed(self, **env):
        return seed.Seeder({**ENV, **env}, self.appdata, self.data).run()

    def test_seeds_the_managers_keys(self):
        self.seed()
        self.assertIn("<ApiKey>" + "r" * 32 + "</ApiKey>", self.read("radarr/config.xml"))
        self.assertIn("<ApiKey>" + "p" * 32 + "</ApiKey>", self.read("prowlarr/config.xml"))
        self.assertFalse(os.path.exists(os.path.join(self.appdata, "radarr-vo")))
        self.assertEqual(os.stat(os.path.join(self.appdata, "radarr/config.xml")).st_mode & 0o777, 0o600)

    def test_never_touches_a_file_that_exists(self):
        self.write("radarr/config.xml", "<Config><ApiKey>mine</ApiKey></Config>")
        self.write("qbittorrent/qBittorrent/qBittorrent.conf", "[Preferences]\n")
        log = self.seed()
        self.assertEqual(self.read("radarr/config.xml"), "<Config><ApiKey>mine</ApiKey></Config>")
        self.assertEqual(self.read("qbittorrent/qBittorrent/qBittorrent.conf"), "[Preferences]\n")
        self.assertIn("kept radarr/config.xml (already there)", log)

    def test_bazarr_is_seeded_connected_to_radarr_and_sonarr(self):
        self.seed()
        text = self.read("bazarr/config/config.yaml")
        self.assertIn("apikey: " + "b" * 32, text)
        self.assertIn("use_radarr: true", text)
        self.assertIn("apikey: " + "s" * 32, text)
        self.assertEqual(config.bazarr_key_in(self.appdata), "b" * 32)

    def test_qbittorrent_password_is_stored_as_qbittorrents_pbkdf2(self):
        self.seed()
        text = self.read("qbittorrent/qBittorrent/qBittorrent.conf")
        salt, digest = re.search(r'Password_PBKDF2="@ByteArray\(([^:]+):([^)]+)\)"', text).groups()
        expected = hashlib.pbkdf2_hmac("sha512", b"qpass", base64.b64decode(salt), 100000, 64)
        self.assertEqual(base64.b64decode(digest), expected)
        self.assertIn("WebUI\\Username=admin", text)
        self.assertIn("Session\\DefaultSavePath=/data/torrents/", text)
        self.assertIn("WebUI\\LocalHostAuth=true", text)

    def test_port_forwarding_lets_gluetun_in_from_localhost(self):
        self.seed(VPN_PORT_FORWARDING="on")
        self.assertIn("WebUI\\LocalHostAuth=false", self.read("qbittorrent/qBittorrent/qBittorrent.conf"))

    def test_nothing_is_seeded_without_keys(self):
        seed.Seeder({"PUID": "1000"}, self.appdata, self.data).run()
        self.assertEqual(os.listdir(self.appdata), [])

    def test_vo_profile_gets_its_own_keys_and_folders(self):
        self.seed(COMPOSE_PROFILES="vo", SONARR_VO_API_KEY="sv")
        self.assertIn("<ApiKey>sv</ApiKey>", self.read("sonarr-vo/config.xml"))
        for folder in ("media/movies-vo", "media/tv-vo", "torrents/movies-vo", "torrents/tv", "media/movies"):
            self.assertTrue(os.path.isdir(os.path.join(self.data, folder)), folder)


class Jellyfin(Case):
    def jellyfin(self, completed=False, folders=()):
        return self.app(lists={"/Library/VirtualFolders": [{"Name": n} for n in folders]},
                        values={"/System/Info/Public": {"StartupWizardCompleted": completed},
                                "/Startup/User": {"Name": "root"}})

    def test_runs_the_startup_wizard(self):
        app = self.jellyfin()
        log = steps.jellyfin(Client(app.url), self.cfg(COMPOSE_PROFILES="vo"))
        self.assertEqual(app.posts("/Startup/User")[0][3], {"Name": "ana", "Password": "jpass"})
        libraries = [c[2] for c in app.posts("/Library/VirtualFolders")]
        self.assertEqual(libraries[0]["collectionType"], "movies")
        self.assertEqual(libraries[0]["paths"], "/data/media/movies,/data/media/movies-vo")
        self.assertEqual(libraries[1]["paths"], "/data/media/tv,/data/media/tv-vo")
        self.assertEqual(app.posts()[-1][1], "/Startup/Complete")
        self.assertIn("jellyfin: setup wizard completed", log)

    def test_carries_on_when_the_admin_already_has_a_password(self):
        app = self.jellyfin()
        app.handlers[("POST", "/Startup/User")] = lambda _: (403, None)
        log = steps.jellyfin(Client(app.url), self.cfg())
        self.assertNotIn("jellyfin: admin ana created", log)
        self.assertEqual(app.posts()[-1][1], "/Startup/Complete")

    def test_an_existing_library_is_not_added_again(self):
        app = self.jellyfin(folders=["Películas"])
        steps.jellyfin(Client(app.url), self.cfg())
        self.assertEqual([c[2]["name"] for c in app.posts("/Library/VirtualFolders")], ["Series"])

    def test_a_set_up_jellyfin_is_left_alone(self):
        app = self.jellyfin(completed=True)
        self.assertEqual(steps.jellyfin(Client(app.url), self.cfg()), ["jellyfin: already set up, left as is"])
        self.assertEqual(app.posts(), [])

    def test_without_credentials_it_warns(self):
        app = self.jellyfin()
        log = steps.jellyfin(Client(app.url), self.cfg(JELLYFIN_ADMIN_PASSWORD=""))
        self.assertIn("WARN", log[0])
        self.assertEqual(app.posts(), [])


class Manager(Case):
    def radarr(self, roots=(), clients=()):
        return self.app(lists={"/api/v3/rootfolder": [{"path": p} for p in roots],
                               "/api/v3/downloadclient": list(clients)},
                        schemas={"/api/v3/downloadclient": schema(
                            "QBittorrent", "host", "port", "username", "password", "movieCategory", "tvCategory")})

    def test_adds_the_root_folder_and_qbittorrent_with_its_category(self):
        app = self.radarr()
        cfg = self.cfg()
        steps.manager(Client(app.url), cfg["managers"][0], cfg)
        self.assertEqual(app.lists["/api/v3/rootfolder"], [{"path": "/data/media/movies", "id": 1}])
        client = app.lists["/api/v3/downloadclient"][0]
        self.assertEqual(client["name"], "qBittorrent")
        self.assertNotIn("id", app.posts("/api/v3/downloadclient")[0][3])
        self.assertEqual(fields(client), {"host": "localhost", "port": 8080, "username": "admin",
                                          "password": "qpass", "movieCategory": "movies", "tvCategory": None})

    def test_sonarr_uses_the_tv_category(self):
        app = self.radarr()
        cfg = self.cfg()
        steps.manager(Client(app.url), cfg["managers"][1], cfg)
        self.assertEqual(fields(app.lists["/api/v3/downloadclient"][0])["tvCategory"], "tv")
        self.assertEqual(app.lists["/api/v3/rootfolder"][0]["path"], "/data/media/tv")

    def test_what_is_there_is_left_alone(self):
        app = self.radarr(roots=["/data/media/movies/"], clients=[{"implementation": "QBittorrent", "name": "mine"}])
        cfg = self.cfg()
        log = steps.manager(Client(app.url), cfg["managers"][0], cfg)
        self.assertEqual(app.posts(), [])
        self.assertEqual(log, ["radarr: qBittorrent already there, left as is"])

    def test_without_the_qbittorrent_password_it_warns(self):
        app = self.radarr()
        cfg = self.cfg(QBITTORRENT_PASSWORD="")
        log = steps.manager(Client(app.url), cfg["managers"][0], cfg)
        self.assertIn("WARN no QBITTORRENT_PASSWORD", log[-1])
        self.assertEqual(app.lists["/api/v3/downloadclient"], [])


class Prowlarr(Case):
    def prowlarr(self, apps=(), proxies=(), tags=()):
        return self.app(
            lists={"/api/v1/applications": list(apps), "/api/v1/indexerProxy": list(proxies), "/api/v1/tag": list(tags)},
            schemas={"/api/v1/applications": schema("Radarr", "prowlarrUrl", "baseUrl", "apiKey")
                     + schema("Sonarr", "prowlarrUrl", "baseUrl", "apiKey"),
                     "/api/v1/indexerProxy": schema("FlareSolverr", "host", "requestTimeout")})

    def test_adds_every_manager_and_flaresolverr(self):
        app = self.prowlarr()
        steps.prowlarr(Client(app.url), self.cfg(COMPOSE_PROFILES="vo", RADARR_VO_API_KEY="rv", SONARR_VO_API_KEY="sv"))
        added = app.lists["/api/v1/applications"]
        self.assertEqual([a["name"] for a in added], ["Radarr", "Sonarr", "Radarr VO", "Sonarr VO"])
        self.assertEqual(fields(added[2]), {"prowlarrUrl": "http://localhost:9696",
                                            "baseUrl": "http://localhost:7879", "apiKey": "rv"})
        self.assertEqual(added[0]["syncLevel"], "fullSync")
        proxy = app.lists["/api/v1/indexerProxy"][0]
        self.assertEqual(fields(proxy)["host"], "http://localhost:8191/")
        self.assertEqual(proxy["tags"], [app.lists["/api/v1/tag"][0]["id"]])

    def test_what_is_there_is_left_alone(self):
        wired = [{"implementation": "Radarr", "fields": [{"name": "baseUrl", "value": "http://localhost:7878/"}]},
                 {"implementation": "Sonarr", "fields": [{"name": "baseUrl", "value": "http://localhost:8989"}]}]
        app = self.prowlarr(apps=wired, proxies=[{"implementation": "FlareSolverr"}])
        self.assertEqual(steps.prowlarr(Client(app.url), self.cfg()), [])
        self.assertEqual(app.posts(), [])

    def test_reuses_an_existing_flaresolverr_tag(self):
        app = self.prowlarr(tags=[{"id": 7, "label": "flaresolverr"}])
        steps.prowlarr(Client(app.url), self.cfg())
        self.assertEqual(app.posts("/api/v1/tag"), [])
        self.assertEqual(app.lists["/api/v1/indexerProxy"][0]["tags"], [7])


class Seerr(Case):
    def seerr(self, media_server=4, radarr=(), sonarr=(), initialized=False):
        app = self.app(lists={"/api/v1/settings/radarr": list(radarr), "/api/v1/settings/sonarr": list(sonarr)},
                       values={"/api/v1/settings/public": {"initialized": initialized, "mediaServerType": media_server}})
        app.values["/api/v1/settings/jellyfin/library"] = [{"id": "a1", "name": "Películas"}, {"id": "b2", "name": "Series"}]
        return app

    def arrs(self, cfg, profiles=({"id": 1, "name": "Any"}, {"id": 4, "name": "Media Stack"})):
        return {m.key: Client(self.app(values={"/api/v3/qualityprofile": list(profiles)}).url) for m in cfg["managers"]}

    def test_sets_up_seerr_from_scratch(self):
        cfg = self.cfg()
        app = self.seerr()
        steps.seerr(Client(app.url, {"X-Api-Key": "k"}), cfg, self.arrs(cfg))
        auth = app.posts("/api/v1/auth/jellyfin")[0][3]
        self.assertEqual((auth["username"], auth["hostname"], auth["port"], auth["serverType"]), ("ana", "jellyfin", 8096, 2))
        library = [c[2] for c in app.calls if c[1] == "/api/v1/settings/jellyfin/library"]
        self.assertEqual(library, [{"sync": "true"}, {"enable": "a1,b2"}])
        radarr = app.lists["/api/v1/settings/radarr"][0]
        self.assertEqual((radarr["hostname"], radarr["port"], radarr["apiKey"]), ("radarr", 7878, "r" * 32))
        self.assertEqual((radarr["activeProfileId"], radarr["activeDirectory"], radarr["isDefault"]),
                         (4, "/data/media/movies", True))
        sonarr = app.lists["/api/v1/settings/sonarr"][0]
        self.assertEqual((sonarr["seriesType"], sonarr["activeDirectory"]), ("standard", "/data/media/tv"))
        self.assertEqual(app.posts()[-1][1], "/api/v1/settings/initialize")
        self.assertEqual(app.calls[-1][4]["X-Api-Key"], "k")

    def test_falls_back_to_the_first_profile(self):
        cfg = self.cfg()
        app = self.seerr()
        steps.seerr(Client(app.url), cfg, self.arrs(cfg, profiles=[{"id": 9, "name": "HD"}]))
        self.assertEqual(app.lists["/api/v1/settings/radarr"][0]["activeProfileName"], "HD")

    def test_vo_managers_are_added_but_never_as_default(self):
        cfg = self.cfg(COMPOSE_PROFILES="vo", RADARR_VO_API_KEY="rv", SONARR_VO_API_KEY="sv")
        radarr = [{"hostname": "radarr", "port": 7878, "isDefault": True}]
        sonarr = [{"hostname": "sonarr", "port": 8989, "isDefault": True}]
        app = self.seerr(media_server=2, radarr=radarr, sonarr=sonarr, initialized=True)
        log = steps.seerr(Client(app.url), cfg, self.arrs(cfg))
        self.assertEqual(log, ["seerr: Radarr VO added", "seerr: Sonarr VO added"])
        added = app.lists["/api/v1/settings/radarr"][1]
        self.assertEqual((added["hostname"], added["port"], added["isDefault"]), ("radarr-vo", 7879, False))

    def test_a_set_up_seerr_is_left_alone(self):
        cfg = self.cfg()
        app = self.seerr(media_server=2, initialized=True,
                         radarr=[{"hostname": "radarr", "port": 7878, "isDefault": True}],
                         sonarr=[{"hostname": "sonarr", "port": 8989, "isDefault": True}])
        self.assertEqual(steps.seerr(Client(app.url), cfg, self.arrs(cfg)), [])
        self.assertEqual(app.posts(), [])


class Quality(Case):
    def generate(self, existing=None, **env):
        cfg = self.cfg(**env)
        existing = existing or {m.key: {"Any"} for m in cfg["managers"]}
        quality.write_config(self.tmp.name, cfg["managers"], ["Bluray-2160p", "WEB 1080p", "BR-DISK"], existing)
        with open(os.path.join(self.tmp.name, "recyclarr.yml")) as f:
            return json.load(f)

    def test_a_new_profile_gets_the_chosen_qualities_best_first(self):
        radarr = self.generate()["radarr"]["radarr"]
        profile = radarr["quality_profiles"][0]
        self.assertEqual(profile["name"], "Media Stack")
        enabled = [q["name"] for q in profile["qualities"] if q["enabled"]]
        self.assertEqual(enabled, ["Bluray-2160p", "WEB 1080p", "BR-DISK"])
        self.assertEqual(profile["qualities"][0], {"name": "Remux-2160p", "enabled": False})
        self.assertEqual(profile["upgrade"]["until_quality"], "Bluray-2160p")
        web = next(q for q in profile["qualities"] if q["name"] == "WEB 1080p")
        self.assertEqual(web["qualities"], ["WEBDL-1080p", "WEBRip-1080p"])
        self.assertEqual(radarr["base_url"], "http://radarr:7878")

    def test_sonarr_gets_its_own_quality_names(self):
        names = [q["name"] for q in self.generate()["sonarr"]["sonarr"]["quality_profiles"][0]["qualities"]]
        self.assertIn("Bluray-2160p Remux", names)
        self.assertNotIn("BR-DISK", names)
        self.assertTrue(set(names) <= {q[2] if isinstance(q[2], str) else q[0] for q in quality.QUALITIES})

    def test_an_existing_profile_keeps_its_qualities(self):
        profile = self.generate(existing={"radarr": {"Media Stack"}, "sonarr": set()})["radarr"]["radarr"]["quality_profiles"][0]
        self.assertEqual(profile, {"name": "Media Stack"})

    def test_core_managers_prefer_spanish_and_vo_ones_the_original_language(self):
        config_ = self.generate(COMPOSE_PROFILES="vo", RADARR_VO_API_KEY="rv", SONARR_VO_API_KEY="sv")
        core = config_["radarr"]["radarr"]["custom_formats"][0]["trash_ids"]
        vo = config_["radarr"]["radarr_vo"]["custom_formats"][0]["trash_ids"]
        self.assertIn(quality.spanish_trash_id("radarr"), core)
        self.assertNotIn(quality.spanish_trash_id("radarr"), vo)
        self.assertIn("d6e9318c875905d6cfb5bee961afcea9", vo)  # Language: Not Original
        self.assertNotIn("b6832f586342ef70d9c128d40c07b872", core)  # Bad Dual Groups
        with open(os.path.join(self.tmp.name, "custom-formats", "radarr", "spanish.json")) as f:
            self.assertEqual(json.load(f)["specifications"][0]["fields"]["value"], 3)
        with open(os.path.join(self.tmp.name, "settings.yml")) as f:
            self.assertEqual(json.load(f)["resource_providers"][1]["service"], "sonarr")
        self.assertEqual(os.stat(os.path.join(self.tmp.name, "recyclarr.yml")).st_mode & 0o777, 0o600)

    def test_a_manager_without_any_chosen_quality_is_skipped_with_a_warning(self):
        cfg = self.cfg()
        log = quality.write_config(self.tmp.name, cfg["managers"], ["BR-DISK"], {"radarr": set(), "sonarr": set()})
        with open(os.path.join(self.tmp.name, "recyclarr.yml")) as f:
            written = json.load(f)
        self.assertIn("radarr", written)
        self.assertNotIn("sonarr", written)
        self.assertIn("none of QUALITIES exists in Sonarr", log[0])

    def test_every_offered_quality_has_a_name(self):
        self.assertEqual(len(quality.NAMES), len(set(quality.NAMES)))


if __name__ == "__main__":
    unittest.main(argv=["wire"], verbosity=1)
EOF
