#!/usr/bin/env bash
# Tests for the extras Profile's issue-automator: its settings come only from the
# environment (.env), and issues go to the right Radarr/Sonarr. Needs python3.
# Usage: tests/issue-automator.test.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

PYTHONPATH="$REPO/stacks/extras/issue-automator" python3 -B - <<'EOF'
import hashlib
import hmac
import json
import unittest
from unittest import mock

import main

BASE = {
    "SEERR_URL": "http://seerr:5055", "SEERR_API_KEY": "s-key",
    "RADARR_URL": "http://radarr:7878", "RADARR_API_KEY": "r-key",
    "SONARR_URL": "http://sonarr:8989", "SONARR_API_KEY": "so-key",
}
INGEST = {
    "NOTIFY_INGEST_URL": "http://hub:3000/api/notifications/ingest",
    "NOTIFY_INGEST_SECRET": "ingest-test-secret-0123456789abcdef",
    "NOTIFY_INGEST_HOST_ID": "nas-home",
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

    def test_ingest_is_on_with_all_three_settings(self):
        self.assertEqual(main.load_config(env(**INGEST))["ingest"], {
            "url": INGEST["NOTIFY_INGEST_URL"],
            "secret": INGEST["NOTIFY_INGEST_SECRET"],
            "host_id": "nas-home",
        })

    def test_ingest_is_off_with_none_of_the_settings(self):
        self.assertIsNone(main.load_config(env())["ingest"])

    def test_an_incomplete_ingest_group_names_what_is_missing(self):
        with self.assertRaises(main.ConfigError) as caught:
            main.load_config(env(NOTIFY_INGEST_URL=INGEST["NOTIFY_INGEST_URL"]))
        self.assertIn("NOTIFY_INGEST_SECRET", str(caught.exception))
        self.assertIn("NOTIFY_INGEST_HOST_ID", str(caught.exception))

    def test_there_is_no_telegram_setting_any_more(self):
        self.assertNotIn("telegram", main.load_config(env(**INGEST)))

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

SEERR_ISSUE = {
    "id": 7, "issueType": 1,
    "media": {"mediaType": "movie", "serviceId": 0, "externalServiceId": 55, "tmdbId": 99},
    "createdBy": {"displayName": "<b>Ana</b>"},
    "comments": [{"message": "no picture"}],
}


class FakeNetwork:
    """Stands in for main.api_request: routes by URL, records every call."""

    def __init__(self, ingest_status=202, raises=None):
        self.calls = []
        self.ingest_status = ingest_status
        self.raises = raises

    def __call__(self, url, method="GET", headers=None, data=None, timeout=12):
        self.calls.append({"url": url, "method": method, "headers": dict(headers or {}), "data": data})
        if url.startswith(INGEST["NOTIFY_INGEST_URL"]):
            if self.raises:
                raise self.raises
            return {}, self.ingest_status
        if url.endswith("/api/v1/issue/7"):
            return SEERR_ISSUE, 200
        if "/comment" in url:
            return {}, 201
        if "history" in url:
            return [], 200
        return {}, 200

    def to(self, fragment):
        return [c for c in self.calls if fragment in c["url"]]

    def deliveries(self):
        return self.to(INGEST["NOTIFY_INGEST_URL"])

    def manager_calls(self):
        return [c for c in self.calls if any(h in c["url"] for h in ("seerr", "radarr", "sonarr", "bazarr"))]


class Publish(unittest.TestCase):
    def setUp(self):
        main.CONFIG.clear()
        main.CONFIG.update(main.load_config(env(**INGEST)))
        self.addCleanup(main.CONFIG.clear)
        self.net = FakeNetwork()
        patcher = mock.patch.object(main, "api_request", self.net)
        patcher.start()
        self.addCleanup(patcher.stop)

    def created(self):
        return main.process_webhook_payload(
            {"notification_type": "ISSUE_CREATED", "subject": "<b>Film</b>", "issue": {"issue_id": "7"}})

    def test_a_created_issue_runs_the_automation_and_publishes_one_opening(self):
        result = self.created()
        self.assertTrue(self.net.to("/api/v3/command"), "the Radarr search still runs")
        self.assertTrue(self.net.to("/api/v1/issue/7/comment"), "Seerr still gets its comment")
        self.assertEqual(len(self.net.deliveries()), 1)
        event = json.loads(self.net.deliveries()[0]["data"])
        self.assertEqual(
            {k: event[k] for k in ("v", "source", "eventId", "hostId", "key", "state")},
            {"v": 1, "source": "issue-automator", "eventId": "issue:7:open",
             "hostId": "nas-home", "key": "issue:seerr:7", "state": "open"})
        self.assertEqual(set(event["data"]), {"subject", "reportedBy", "problem", "action"})
        self.assertTrue(result["published"])

    def test_published_text_carries_no_markup(self):
        self.created()
        data = json.loads(self.net.deliveries()[0]["data"])["data"]
        self.assertEqual(data["subject"], "Film")
        self.assertEqual(data["reportedBy"], "Ana")
        for value in data.values():
            self.assertNotRegex(value, r"<[^>]*>")

    def test_published_text_is_capped_to_the_hub_limits(self):
        long_issue = dict(SEERR_ISSUE, comments=[{"message": "x" * 900}])
        with mock.patch.object(main, "get_seerr_issue", return_value=long_issue):
            main.process_webhook_payload({"notification_type": "ISSUE_CREATED", "issue": {"issue_id": "7"}})
        data = json.loads(self.net.deliveries()[0]["data"])["data"]
        for field, limit in main.INGEST_LIMITS.items():
            self.assertLessEqual(len(data[field]), limit)

    def test_the_signature_is_the_standard_hmac_over_timestamp_and_body(self):
        self.created()
        sent = self.net.deliveries()[0]
        body = sent["data"]
        self.assertIsInstance(body, bytes)
        timestamp = sent["headers"]["X-Ingest-Timestamp"]
        expected = hmac.new(INGEST["NOTIFY_INGEST_SECRET"].encode(), timestamp.encode() + b"." + body,
                            hashlib.sha256).hexdigest()
        self.assertEqual(sent["headers"]["X-Ingest-Signature"], "v1=" + expected)
        self.assertRegex(timestamp, r"^[0-9]{10}$")

    def test_nothing_goes_to_telegram(self):
        self.created()
        self.assertEqual(self.net.to("telegram"), [])

    def test_without_ingest_settings_the_automation_runs_and_nothing_is_published(self):
        main.CONFIG["ingest"] = None
        result = self.created()
        self.assertEqual(self.net.deliveries(), [])
        self.assertFalse(result["published"])
        self.assertEqual(result["status"], "success")

    def test_a_non_numeric_issue_id_is_not_published(self):
        self.assertIsNone(main.numeric_issue_id("7; drop"))
        self.assertIsNone(main.numeric_issue_id("1234567890"))
        self.assertEqual(main.numeric_issue_id(7), "7")


if __name__ == "__main__":
    unittest.main(argv=["issue-automator"], verbosity=1)
EOF
