#!/usr/bin/env bash
# Behavioural tests of topology resolution and Compose drift detection; no containers.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PYTHONPATH="$REPO/stacks/wire" python3 -B - "$REPO" <<'PY'
import copy
import json
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from wire import config, seed, topology

repo = Path(sys.argv[1])
discrepancies = runpy.run_path(str(repo / "tests/topology-compose.py"))["discrepancies"]


def definition():
    return {"services": [
        {"key": "gateway", "namespace": "gateway", "expect": "healthy"},
        {"key": "wire", "namespace": "wire", "expect": "completed"},
        {"key": "films", "namespace": "gateway", "expect": "healthy", "port": 4100,
         "publication": {"service": "gateway", "port": 5100}, "health_path": "/ping",
         "port_env": "SERVER_PORT", "data_mount": "/data",
         "manager": {"kind": "radarr", "name": "Films", "root": "/data/media/films", "category": "films"}},
        {"key": "films-vo", "namespace": "gateway", "expect": "healthy", "port": 4200, "profile": "vo",
         "manager": {"kind": "radarr", "name": "Films VO", "root": "/data/media/original", "category": "original"}},
    ]}


def compose_model():
    return {"services": {
        "gateway": {"container_name": "gateway", "networks": {"media": {"aliases": ["films", "films-vo"]}},
                    "ports": [{"target": 4100, "published": "5100", "protocol": "tcp"}]},
        "wire": {"container_name": "wire", "networks": {"media": {}}, "restart": "no"},
        "films": {"container_name": "films", "network_mode": "service:gateway", "environment": {"SERVER_PORT": "4100"},
                  "healthcheck": {"test": ["CMD-SHELL", "curl http://localhost:4100/ping"]},
                  "volumes": [{"type": "bind", "source": "/library", "target": "/data"}]},
    }}


class TopologyTests(unittest.TestCase):
    def test_namespace_and_external_endpoints_use_listener_not_publication(self):
        t = topology.Topology(definition())
        self.assertEqual(t.endpoint("gateway", "films"), ("localhost", 4100))
        self.assertEqual(t.endpoint("wire", "films"), ("films", 4100))
        self.assertEqual(t.url("wire", "films"), "http://films:4100")

    def test_activation_and_folders_follow_the_same_managers(self):
        t = topology.Topology(definition())
        self.assertEqual([s["key"] for s in t.managers()], ["films"])
        self.assertEqual(t.folders(), ["media/films", "torrents/films"])
        enabled = topology.profiles(" backup, vo, ")
        self.assertEqual(t.folders(enabled), ["media/films", "torrents/films", "media/original", "torrents/original"])
        self.assertEqual(t.active({"*"}), t.active({"vo"}))

    def test_invalid_definitions_are_rejected(self):
        cases = [
            (lambda d: d["services"].append(copy.deepcopy(d["services"][0])), "duplicate"),
            (lambda d: d["services"][2].pop("namespace"), "namespace"),
            (lambda d: d["services"][2].update(port=True), "invalid port"),
            (lambda d: d["services"][2].update(port=65536), "invalid port"),
            (lambda d: d["services"][3].update(port=4100), "conflicting listener"),
            (lambda d: d["services"][2]["manager"].update(root="/data/media/../escape"), "unsafe"),
            (lambda d: d["services"][2]["manager"].update(root="/outside/media"), "unsafe"),
            (lambda d: d["services"][2]["manager"].update(category="../../escape"), "category"),
            (lambda d: d["services"][2].update(namespace="absent", publication={"service": "absent", "port": 5100}), "owner"),
            (lambda d: d["services"][2].update(publication={"service": "wire", "port": 5100}), "publication"),
        ]
        for mutate, message in cases:
            with self.subTest(message=message):
                document = definition()
                mutate(document)
                with self.assertRaisesRegex(ValueError, message):
                    topology.Topology(document)

    def test_missing_or_malformed_files_have_actionable_errors(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "topology.json"
            with self.assertRaisesRegex(ValueError, "cannot load topology"):
                topology.load(path)
            path.write_text("{broken")
            with self.assertRaisesRegex(ValueError, "cannot load topology"):
                topology.load(path)

    def test_invalid_cli_has_no_partial_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            reader = Path(tmp) / "topology.py"
            reader.write_text((repo / "stacks/wire/wire/topology.py").read_text())
            reader.with_suffix(".json").write_text('{"services": []}')
            result = subprocess.run([sys.executable, "-B", str(reader), "folders"], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
            self.assertIn("non-empty services", result.stderr)

    def test_seed_uses_changed_topology_without_overwriting_existing_files(self):
        document = json.loads((repo / "stacks/wire/wire/topology.json").read_text())
        radarr = next(s for s in document["services"] if s["key"] == "radarr")
        radarr["port"] = 4100
        radarr["manager"].update(root="/data/media/films", category="films")
        t = topology.Topology(document)
        env = {"RADARR_API_KEY": "radarr", "SONARR_API_KEY": "sonarr", "BAZARR_API_KEY": "bazarr"}
        with tempfile.TemporaryDirectory() as tmp, patch.object(config, "TOPOLOGY", t):
            appdata, data = Path(tmp) / "appdata", Path(tmp) / "data"
            seed.Seeder(env, str(appdata), str(data)).run()
            text = (appdata / "bazarr/config/config.yaml").read_text()
            self.assertIn("port: 4100", text)
            self.assertTrue((data / "media/films").is_dir())
            self.assertTrue((data / "torrents/films").is_dir())
            self.assertFalse((data / "media/movies").exists())
            (appdata / "bazarr/config/config.yaml").write_text("Operator configuration")
            seed.Seeder(env, str(appdata), str(data)).run()
            self.assertEqual((appdata / "bazarr/config/config.yaml").read_text(), "Operator configuration")


class ComposeTests(unittest.TestCase):
    def setUp(self):
        self.t = topology.Topology(definition())

    def test_accepts_different_host_and_listener_ports_and_unrelated_profiles(self):
        model = compose_model()
        model["services"]["another-profile"] = {"profiles": ["extras"]}
        self.assertEqual(discrepancies(self.t, model, set(), "/library"), [])

    def test_drift_fails_with_the_service_and_reason(self):
        cases = [
            (lambda s: s["gateway"]["ports"][0].update(published="5101"), "publish"),
            (lambda s: s["films"]["environment"].update(SERVER_PORT="4101"), "SERVER_PORT"),
            (lambda s: s["films"]["healthcheck"].update(test=["CMD-SHELL", "curl http://localhost:41000/ping"]), "healthcheck"),
            (lambda s: s["films"].update(network_mode="service:wire"), "namespace"),
            (lambda s: s["gateway"]["networks"]["media"].update(aliases=[]), "alias"),
            (lambda s: s["films"]["volumes"][0].update(source="/wrong"), "bind mount"),
            (lambda s: s["films"]["volumes"][0].update(read_only=True), "writable"),
            (lambda s: s["films"].update(profiles=["vo"]), "Profile"),
            (lambda s: s.pop("films"), "missing"),
        ]
        for mutate, message in cases:
            with self.subTest(message=message):
                model = compose_model()
                mutate(model["services"])
                errors = discrepancies(self.t, model, set(), "/library")
                self.assertTrue(any("films:" in error and message in error for error in errors), errors)

    def test_vo_activation_and_one_shot_expectations_are_checked(self):
        model = compose_model()
        self.assertIn("films-vo: active service is missing", discrepancies(self.t, model, {"vo"}, "/library"))
        model["services"]["films-vo"] = {"container_name": "films-vo", "network_mode": "service:gateway", "profiles": ["vo"]}
        self.assertEqual(discrepancies(self.t, model, {"vo"}, "/library"), [])
        self.assertIn("films-vo: inactive Profile service is present", discrepancies(self.t, model, set(), "/library"))
        model["services"]["wire"]["restart"] = "always"
        self.assertTrue(any("wire: one-shot" in error for error in discrepancies(self.t, model, {"vo"}, "/library")))

    def test_vpn_forwarding_hooks_follow_the_qbittorrent_api_listener(self):
        t = topology.Topology({"services": [
            {"key": "gluetun", "namespace": "gluetun", "expect": "healthy"},
            {"key": "qbittorrent", "namespace": "gluetun", "expect": "healthy", "port": 4100},
        ]})
        endpoint = "http://127.0.0.1:4100/api/v2/app/setPreferences"
        model = {"services": {
            "gluetun": {"container_name": "gluetun", "networks": {"media": {"aliases": ["qbittorrent"]}},
                        "environment": {"VPN_PORT_FORWARDING_UP_COMMAND": endpoint, "VPN_PORT_FORWARDING_DOWN_COMMAND": endpoint}},
            "qbittorrent": {"container_name": "qbittorrent", "network_mode": "service:gluetun"},
        }}
        self.assertEqual(discrepancies(t, model, set(), "/library"), [])
        model["services"]["gluetun"]["environment"]["VPN_PORT_FORWARDING_DOWN_COMMAND"] = endpoint.replace(":4100/", ":8080/")
        self.assertTrue(any("gluetun: VPN_PORT_FORWARDING_DOWN_COMMAND" in error
                            for error in discrepancies(t, model, set(), "/library")))


unittest.main(argv=[sys.argv[0]])
PY
