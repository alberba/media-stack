#!/usr/bin/env bash
# Tests for the extras Profile's issue-automator: its settings come only from the
# environment (.env), and issues go to the right Radarr/Sonarr. Needs python3.
# Usage: tests/issue-automator.test.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

PYTHONPATH="$REPO/stacks/extras/issue-automator" python3 -B - <<'EOF'
import unittest

import main

BASE = {
    "SEERR_URL": "http://seerr:5055", "SEERR_API_KEY": "s-key",
    "RADARR_URL": "http://radarr:7878", "RADARR_API_KEY": "r-key",
    "SONARR_URL": "http://sonarr:8989", "SONARR_API_KEY": "so-key",
}


def env(**overrides):
    e = dict(BASE)
    e.update(overrides)
    return {k: v for k, v in e.items() if v is not None}


class LoadConfig(unittest.TestCase):
    def test_reads_urls_and_keys_from_the_environment(self):
        config = main.load_config(env())
        self.assertEqual(config["services"]["seerr"], {"name": "Seerr", "url": "http://seerr:5055", "api_key": "s-key"})
        self.assertEqual(config["services"]["radarr"]["api_key"], "r-key")
        self.assertEqual(config["services"]["sonarr"]["url"], "http://sonarr:8989")

    def test_urls_default_to_the_service_names_on_the_media_network(self):
        config = main.load_config(env(SEERR_URL=None, RADARR_URL="", SONARR_URL=None))
        self.assertEqual(config["services"]["seerr"]["url"], "http://seerr:5055")
        self.assertEqual(config["services"]["radarr"]["url"], "http://radarr:7878")
        self.assertEqual(config["services"]["bazarr"]["url"], "http://bazarr:6767")

    def test_trailing_slashes_are_dropped(self):
        config = main.load_config(env(SEERR_URL="http://seerr:5055/"))
        self.assertEqual(config["services"]["seerr"]["url"], "http://seerr:5055")

    def test_missing_required_keys_are_all_reported(self):
        with self.assertRaises(main.ConfigError) as caught:
            main.load_config(env(SEERR_API_KEY="", SONARR_API_KEY=None))
        self.assertIn("SEERR_API_KEY", str(caught.exception))
        self.assertIn("SONARR_API_KEY", str(caught.exception))
        self.assertNotIn("RADARR_API_KEY", str(caught.exception))

    def test_bazarr_and_vo_are_optional(self):
        config = main.load_config(env())
        self.assertNotIn("radarr_vo", config["services"])
        self.assertNotIn("sonarr_vo", config["services"])
        self.assertIsNone(config["services"]["bazarr"]["api_key"])

    def test_vo_server_id_needs_the_vo_api_key(self):
        with self.assertRaises(main.ConfigError) as caught:
            main.load_config(env(SEERR_RADARR_VO_SERVER_ID="1"))
        self.assertIn("RADARR_VO_API_KEY", str(caught.exception))

    def test_vo_server_id_must_be_a_number(self):
        with self.assertRaises(main.ConfigError) as caught:
            main.load_config(env(SEERR_SONARR_VO_SERVER_ID="one", SONARR_VO_API_KEY="k"))
        self.assertIn("SEERR_SONARR_VO_SERVER_ID", str(caught.exception))

    def test_telegram_is_on_only_with_token_and_chat(self):
        self.assertIsNone(main.load_config(env(TELEGRAM_BOT_TOKEN="t"))["telegram"])
        self.assertEqual(main.load_config(env(TELEGRAM_BOT_TOKEN="t", TELEGRAM_CHAT_ID="42"))["telegram"],
                         {"bot_token": "t", "chat_id": "42"})

    def test_port_defaults_to_5056(self):
        self.assertEqual(main.load_config(env())["port"], 5056)


class PickManager(unittest.TestCase):
    def setUp(self):
        self.config = main.load_config(env(
            RADARR_VO_API_KEY="rv", SEERR_RADARR_VO_SERVER_ID="1",
            SONARR_VO_API_KEY="sv", SEERR_SONARR_VO_SERVER_ID="2"))

    def test_movies_and_series_go_to_the_core_managers(self):
        self.assertEqual(main.pick_manager(self.config, "movie", 0), "radarr")
        self.assertEqual(main.pick_manager(self.config, "tv", 0), "sonarr")

    def test_the_vo_server_ids_go_to_the_vo_managers(self):
        self.assertEqual(main.pick_manager(self.config, "movie", 1), "radarr_vo")
        self.assertEqual(main.pick_manager(self.config, "tv", 2), "sonarr_vo")
        self.assertEqual(main.pick_manager(self.config, "tv", 1), "sonarr")

    def test_without_vo_everything_goes_to_the_core_managers(self):
        config = main.load_config(env())
        self.assertEqual(main.pick_manager(config, "movie", 1), "radarr")

    def test_unknown_media_type(self):
        self.assertIsNone(main.pick_manager(self.config, "music", 0))


if __name__ == "__main__":
    unittest.main(argv=["issue-automator"], verbosity=1)
EOF
