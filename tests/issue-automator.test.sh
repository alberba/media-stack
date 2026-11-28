#!/usr/bin/env bash
# Tests for the extras Profile's issue-automator: its settings come only from the
# environment (.env), and issues go to the right Radarr/Sonarr. Needs python3.
# Usage: tests/issue-automator.test.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

PYTHONPATH="$REPO/stacks/extras/issue-automator" python3 -B - <<'EOF'
import hashlib
import hmac
import http.client
import importlib
import json
import os
import tempfile
import threading
import time
import types
import unittest
import urllib.error
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
            "outbox_dir": "/outbox",
        })

    def test_the_outbox_folder_defaults_to_the_mount_and_can_be_moved(self):
        self.assertEqual(main.load_config(env(**INGEST, OUTBOX_DIR="/tmp/x"))["ingest"]["outbox_dir"], "/tmp/x")

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
        self.script = []  # answers for the next ingest requests, in order; then ingest_status
        self.raises = raises
        self.ingest_called = threading.Event()

    def __call__(self, url, method="GET", headers=None, data=None, timeout=12):
        self.calls.append({"url": url, "method": method, "headers": dict(headers or {}), "data": data})
        if url.startswith(INGEST["NOTIFY_INGEST_URL"]):
            self.ingest_called.set()
            if self.raises:
                raise self.raises
            return {}, (self.script.pop(0) if self.script else self.ingest_status)
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


class OutboxCase(unittest.TestCase):
    """The service configured for the hub, with its outbox in a temporary folder and the
    network replaced by FakeNetwork."""

    fake_network = True

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.outbox = folder.name
        self.load(**INGEST)
        self.addCleanup(main.CONFIG.clear)
        self.addCleanup(main.stop_outbox_worker)
        self.net = FakeNetwork()
        if self.fake_network:
            patcher = mock.patch.object(main, "api_request", self.net)
            patcher.start()
            self.addCleanup(patcher.stop)

    def load(self, **overrides):
        main.CONFIG.clear()
        main.CONFIG.update(main.load_config(env(OUTBOX_DIR=self.outbox, **overrides)))

    def files(self, suffix=".json"):
        return sorted(name for name in os.listdir(self.outbox) if name.endswith(suffix))

    def records(self):
        records = []
        for name in self.files():
            with open(os.path.join(self.outbox, name)) as handle:
                records.append(json.load(handle))
        return records

    def http(self, method, path, payload=None):
        """Calls the real HTTP handler; returns (status, parsed body)."""
        server = main.ThreadingHTTPServer(("127.0.0.1", 0), main.WebhookHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        conn = http.client.HTTPConnection("127.0.0.1", server.server_address[1], timeout=10)
        body = None if payload is None else json.dumps(payload)
        conn.request(method, path, body=body, headers={"Content-Type": "application/json"})
        response = conn.getresponse()
        parsed = json.loads(response.read())
        conn.close()
        return response.status, parsed

    def empty_outbox(self):
        for name in os.listdir(self.outbox):
            os.remove(os.path.join(self.outbox, name))


class Publish(OutboxCase):
    def created(self):
        return main.process_webhook_payload(
            {"notification_type": "ISSUE_CREATED", "subject": "<b>Film</b>", "issue": {"issue_id": "7"}})

    def sent(self):
        """Runs one drain and returns the requests it made to the hub."""
        main.outbox_drain()
        return self.net.deliveries()

    def test_a_created_issue_runs_the_automation_and_publishes_one_opening(self):
        result = self.created()
        self.assertTrue(self.net.to("/api/v3/command"), "the Radarr search still runs")
        self.assertTrue(self.net.to("/api/v1/issue/7/comment"), "Seerr still gets its comment")
        self.assertEqual(self.net.deliveries(), [], "the webhook does not wait for the hub")
        self.assertEqual(len(self.sent()), 1)
        event = json.loads(self.net.deliveries()[0]["data"])
        self.assertEqual(
            {k: event[k] for k in ("v", "source", "eventId", "hostId", "key", "state")},
            {"v": 1, "source": "issue-automator", "eventId": "issue:7:open",
             "hostId": "nas-home", "key": "issue:seerr:7", "state": "open"})
        self.assertEqual(set(event["data"]), {"subject", "reportedBy", "problem", "action"})
        self.assertTrue(result["queued"])

    def test_published_text_carries_no_markup(self):
        self.created()
        data = json.loads(self.sent()[0]["data"])["data"]
        self.assertEqual(data["subject"], "Film")
        self.assertEqual(data["reportedBy"], "Ana")
        for value in data.values():
            self.assertNotRegex(value, r"<[^>]*>")

    def test_published_text_is_capped_to_the_hub_limits(self):
        long_issue = dict(SEERR_ISSUE, comments=[{"message": "x" * 900}])
        with mock.patch.object(main, "get_seerr_issue", return_value=long_issue):
            main.process_webhook_payload({"notification_type": "ISSUE_CREATED", "issue": {"issue_id": "7"}})
        data = json.loads(self.sent()[0]["data"])["data"]
        for field, limit in main.INGEST_LIMITS.items():
            self.assertLessEqual(len(data[field]), limit)

    def test_the_signature_is_the_standard_hmac_over_timestamp_and_body(self):
        self.created()
        sent = self.sent()[0]
        body = sent["data"]
        self.assertIsInstance(body, bytes)
        timestamp = sent["headers"]["X-Ingest-Timestamp"]
        expected = hmac.new(INGEST["NOTIFY_INGEST_SECRET"].encode(), timestamp.encode() + b"." + body,
                            hashlib.sha256).hexdigest()
        self.assertEqual(sent["headers"]["X-Ingest-Signature"], "v1=" + expected)
        self.assertRegex(timestamp, r"^[0-9]{10}$")

    def test_nothing_goes_to_telegram(self):
        self.created()
        self.sent()
        self.assertEqual(self.net.to("telegram"), [])

    def test_without_ingest_settings_the_automation_runs_and_nothing_is_published(self):
        main.CONFIG["ingest"] = None
        result = self.created()
        self.assertEqual(self.sent(), [])
        self.assertEqual(self.files(), [])
        self.assertFalse(result["queued"])
        self.assertEqual(result["status"], "success")

    def webhook(self, payload, path="/webhook"):
        return self.http("POST", path, payload)

    def test_a_resolved_issue_publishes_one_closing_and_runs_no_automation(self):
        result = main.process_webhook_payload({"notification_type": "ISSUE_RESOLVED", "issue": {"issue_id": "7"}})
        self.assertEqual(len(self.sent()), 1)
        event = json.loads(self.net.deliveries()[0]["data"])
        self.assertEqual(event["state"], "resolved")
        self.assertEqual(event["eventId"], "issue:7:resolved")
        self.assertEqual(event["key"], "issue:seerr:7")
        self.assertEqual(event["data"], {})
        self.assertEqual(self.net.manager_calls(), [])
        self.assertTrue(result["queued"])

    def test_a_resolved_issue_id_can_come_from_any_of_the_three_places(self):
        for payload in ({"issue": {"id": 7}}, {"issue": {"issue_id": "7"}}, {"issue_id": "7"}):
            self.net.calls.clear()
            self.empty_outbox()
            main.process_webhook_payload(dict(payload, notification_type="ISSUE_RESOLVED"))
            event = json.loads(self.sent()[0]["data"])
            self.assertEqual((event["key"], event["state"]), ("issue:seerr:7", "resolved"))
            self.assertEqual(self.net.manager_calls(), [])

    def test_test_notifications_send_nothing_anywhere(self):
        for payload in ({"notification_type": "TEST_NOTIFICATION"}, {"event": "test"}):
            result = main.process_webhook_payload(payload)
            self.assertEqual(result["status"], "ok")
        self.assertEqual(self.net.calls, [])

    def test_other_notification_types_are_ignored_without_effects(self):
        for kind in ("ISSUE_COMMENT", "ISSUE_REOPENED"):
            result = main.process_webhook_payload({"notification_type": kind, "issue": {"issue_id": "7"}})
            self.assertEqual(result["status"], "ignored")
        self.assertEqual(self.net.calls, [])

    def test_a_payload_without_a_type_still_runs_the_automation(self):
        result = main.process_webhook_payload({"issue": {"issue_id": "7"}})
        self.assertTrue(self.net.to("/api/v3/command"))
        self.assertEqual(len(self.sent()), 1)
        self.assertEqual(result["status"], "success")

    def test_the_test_endpoint_answers_200_and_sends_nothing(self):
        status, body = self.webhook({}, path="/test")
        self.assertEqual(status, 200)
        self.assertTrue(body["ingest_configured"])
        self.assertEqual(self.net.calls, [])

    def test_a_queued_event_is_reported_and_the_webhook_answers_200_without_a_request(self):
        status, body = self.webhook({"notification_type": "ISSUE_RESOLVED", "issue": {"issue_id": "7"}})
        self.assertEqual(status, 200)
        self.assertTrue(body["queued"])
        self.assertEqual(self.net.deliveries(), [])
        self.assertEqual(len(self.files()), 1)

    def test_a_failed_delivery_keeps_the_event_and_the_webhook_still_answers_200(self):
        for code in (401, 409, 422, 500):
            self.net.calls.clear()
            self.empty_outbox()
            self.net.ingest_status = code
            status, body = self.webhook({"notification_type": "ISSUE_CREATED", "issue": {"issue_id": "7"}})
            self.assertEqual(status, 200, code)
            self.assertEqual(self.net.deliveries(), [], code)
            self.assertEqual(len(self.sent()), 1, code)
            self.assertEqual(len(self.files()), 1, code)
            self.assertTrue(body["queued"], code)
            self.assertTrue(body["action_success"], code)

    def test_a_non_numeric_issue_id_is_not_published(self):
        self.assertIsNone(main.numeric_issue_id("7; drop"))
        self.assertIsNone(main.numeric_issue_id("1234567890"))
        self.assertEqual(main.numeric_issue_id(7), "7")

    def test_an_unexpected_error_in_the_delivery_does_not_break_the_webhook(self):
        self.net.raises = RuntimeError("boom")
        status, body = self.webhook({"notification_type": "ISSUE_CREATED", "issue": {"issue_id": "7"}})
        self.assertEqual(status, 200)
        self.assertTrue(body["queued"])
        self.assertTrue(body["action_success"])
        self.assertEqual(main.outbox_drain()["failed"], 1)
        self.assertEqual(len(self.files()), 1)
        self.assertFalse(main.deliver_issue_event(main.build_issue_event("7", "open", {})))


T0 = 1_700_000_000
DAY = 86400


class Outbox(OutboxCase):
    def setUp(self):
        super().setUp()
        self.clock = T0
        self.patch_runtime()

    def patch_runtime(self):
        """A clock the tests move by hand, so retries need no sleeping."""
        patcher = mock.patch.object(main, "time", types.SimpleNamespace(time=lambda: self.clock))
        patcher.start()
        self.addCleanup(patcher.stop)

    def enqueue(self, issue_id, state, now=T0):
        event = main.build_issue_event(str(issue_id), state, {})
        self.assertTrue(main.outbox_enqueue(event, now=now))
        return event

    def verifies(self, request, secret):
        timestamp = request["headers"]["X-Ingest-Timestamp"]
        expected = hmac.new(secret.encode(), timestamp.encode() + b"." + request["data"], hashlib.sha256).hexdigest()
        return request["headers"]["X-Ingest-Signature"] == "v1=" + expected

    def created(self):
        return main.process_webhook_payload(
            {"notification_type": "ISSUE_CREATED", "subject": "Film", "issue": {"issue_id": "7"}})

    def test_a_created_issue_leaves_one_file_and_sends_nothing_during_the_webhook(self):
        result = self.created()
        self.assertTrue(result["queued"])
        self.assertEqual(self.net.deliveries(), [])
        (record,) = self.records()
        self.assertEqual((record["event_id"], record["state"]), ("issue:7:open", "open"))
        self.assertEqual(record["body"].encode("ascii"), main.ingest_body(json.loads(record["body"])))
        self.assertEqual(json.loads(record["body"])["eventId"], "issue:7:open")

    def test_the_stored_file_carries_neither_the_secret_nor_a_signature(self):
        self.created()
        for name in self.files():
            with open(os.path.join(self.outbox, name)) as handle:
                text = handle.read()
            self.assertNotIn(INGEST["NOTIFY_INGEST_SECRET"], text)
            self.assertNotIn("v1=", text)
            self.assertNotIn("ignature", text)

    def test_the_drain_sends_the_stored_bytes_signed_and_empties_the_outbox(self):
        self.created()
        (record,) = self.records()
        counts = main.outbox_drain()
        (sent,) = self.net.deliveries()
        self.assertEqual(sent["data"], record["body"].encode("ascii"))
        timestamp = sent["headers"]["X-Ingest-Timestamp"]
        expected = hmac.new(INGEST["NOTIFY_INGEST_SECRET"].encode(), timestamp.encode() + b"." + sent["data"],
                            hashlib.sha256).hexdigest()
        self.assertEqual(sent["headers"]["X-Ingest-Signature"], "v1=" + expected)
        self.assertEqual(counts, {"delivered": 1, "failed": 0, "dropped": 0, "pending": 0})
        self.assertEqual(self.files(), [])

    def test_the_worker_delivers_without_a_manual_drain(self):
        with mock.patch.object(main, "OUTBOX_POLL_SECONDS", 0.05):
            main.start_outbox_worker()
            self.created()
            self.assertTrue(self.net.ingest_called.wait(5), "the worker never reached the hub")
            main.stop_outbox_worker()
        self.assertIsNone(main.OUTBOX_WORKER["thread"])

    def test_a_new_event_wakes_a_worker_that_is_waiting_out_a_long_poll(self):
        main.start_outbox_worker()
        self.assertEqual(main.OUTBOX_POLL_SECONDS, 30)
        self.created()
        self.assertTrue(self.net.ingest_called.wait(5), "the worker did not wake for the new event")
        main.stop_outbox_worker()

    def test_a_failure_backs_off_15_then_30_seconds_and_the_third_pass_delivers(self):
        self.enqueue(7, "open")
        self.net.script = [500, 502, 202]
        self.assertEqual(main.outbox_drain(T0)["failed"], 1)
        (record,) = self.records()
        self.assertEqual((record["attempts"], record["next_attempt"]), (1, T0 + 15))
        self.clock = T0 + 10
        main.outbox_drain(T0 + 10)
        self.assertEqual(len(self.net.deliveries()), 1, "nothing is sent before next_attempt")
        self.clock = T0 + 15
        main.outbox_drain(T0 + 15)
        (record,) = self.records()
        self.assertEqual((record["attempts"], record["next_attempt"]), (2, T0 + 15 + 30))
        self.clock = T0 + 45
        self.assertEqual(main.outbox_drain(T0 + 45)["delivered"], 1)
        self.assertEqual(self.files(), [])
        requests = self.net.deliveries()
        self.assertEqual(len(requests), 3)
        self.assertEqual(len({r["data"] for r in requests}), 1, "the same body every time")
        self.assertEqual(len({json.loads(r["data"])["eventId"] for r in requests}), 1)
        self.assertEqual(len({r["headers"]["X-Ingest-Timestamp"] for r in requests}), 3)
        self.assertEqual(len({r["headers"]["X-Ingest-Signature"] for r in requests}), 3)
        for request in requests:
            self.assertTrue(self.verifies(request, INGEST["NOTIFY_INGEST_SECRET"]))

    def test_the_backoff_doubles_and_never_exceeds_900_seconds(self):
        self.enqueue(7, "open")
        self.net.ingest_status = 500
        now, delays = T0, []
        for _ in range(12):
            self.clock = now
            main.outbox_drain(now)
            (record,) = self.records()
            delays.append(record["next_attempt"] - now)
            now = record["next_attempt"]
        self.assertEqual(delays[:7], [15, 30, 60, 120, 240, 480, 900])
        self.assertEqual(set(delays[6:]), {900})
        path = os.path.join(self.outbox, self.files()[0])
        record["attempts"] = 100000
        main.outbox_write(path, record)
        main.outbox_drain(now)
        self.assertEqual(self.records()[0]["next_attempt"] - now, 900)

    def test_a_pending_event_survives_a_restart(self):
        self.enqueue(7, "open")
        self.net.ingest_status = 500
        main.outbox_drain(T0)
        main.stop_outbox_worker()
        importlib.reload(main)
        self.patch_runtime()
        patcher = mock.patch.object(main, "api_request", self.net)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.load(**INGEST)
        (record,) = self.records()
        self.assertEqual(record["attempts"], 1)
        self.net.ingest_status = 202
        self.clock = T0 + 15
        self.assertEqual(main.outbox_drain(T0 + 15)["delivered"], 1)
        self.assertEqual(self.files(), [])

    def test_a_closing_waits_for_its_opening_and_another_issue_does_not(self):
        self.enqueue(7, "open", T0)
        self.enqueue(7, "resolved", T0 + 1)
        self.enqueue(8, "open", T0 + 2)
        self.net.script = [500, 202]
        counts = main.outbox_drain(T0 + 2)
        sent = [json.loads(r["data"])["eventId"] for r in self.net.deliveries()]
        self.assertEqual(sent, ["issue:7:open", "issue:8:open"])
        self.assertEqual((counts["failed"], counts["delivered"], counts["pending"]), (1, 1, 2))
        main.outbox_drain(T0 + 17)
        sent = [json.loads(r["data"])["eventId"] for r in self.net.deliveries()]
        self.assertEqual(sent[2:], ["issue:7:open", "issue:7:resolved"], "the opening goes first, in the same pass")
        self.assertEqual(self.files(), [])

    def test_a_duplicate_is_a_confirmation_and_other_failures_are_retried(self):
        self.enqueue(7, "open")
        self.net.ingest_status = 200
        self.assertEqual(main.outbox_drain(T0)["delivered"], 1)
        self.assertEqual(self.files(), [])
        for code in (401, 409, 422, 503):
            self.empty_outbox()
            self.enqueue(7, "open")
            self.net.ingest_status = code
            main.outbox_drain(T0)
            (record,) = self.records()
            self.assertEqual((record["attempts"], record["next_attempt"]), (1, T0 + 15), code)
        self.empty_outbox()
        self.enqueue(7, "open")
        self.net.raises = OSError("network down")
        main.outbox_drain(T0)
        self.assertEqual(self.records()[0]["attempts"], 1)

    def test_queueing_the_same_event_twice_leaves_one_file(self):
        self.enqueue(7, "open", T0)
        self.enqueue(7, "open", T0 + 5)
        self.assertEqual(len(self.files()), 1)
        self.enqueue(7, "resolved", T0 + 6)
        self.assertEqual(len(self.files()), 2)

    def test_an_event_older_than_14_days_is_dropped_without_a_request(self):
        self.enqueue(7, "open", T0)
        self.enqueue(7, "resolved", T0 + 13 * DAY)
        body = main.build_issue_event("7", "open", {})["body"].decode()
        with self.assertLogs(level="DEBUG") as logs:
            counts = main.outbox_drain(T0 + 14 * DAY + 1)
        self.assertEqual((counts["dropped"], counts["delivered"]), (1, 1))
        sent = [json.loads(r["data"])["eventId"] for r in self.net.deliveries()]
        self.assertEqual(sent, ["issue:7:resolved"], "the dropped opening does not block its closing")
        logged = "\n".join(logs.output)
        self.assertIn("issue:7:open", logged)
        self.assertNotIn(body, logged)

    def test_the_201st_event_drops_the_oldest(self):
        for number in range(1, main.OUTBOX_MAX_EVENTS + 1):
            self.enqueue(number, "open", T0 + number)
        self.assertEqual(len(self.files()), main.OUTBOX_MAX_EVENTS)
        with self.assertLogs(level="ERROR") as logs:
            self.enqueue(main.OUTBOX_MAX_EVENTS + 1, "open", T0 + 1000)
        names = self.files()
        self.assertEqual(len(names), main.OUTBOX_MAX_EVENTS)
        self.assertFalse(any(name.endswith("-1-open.json") for name in names))
        self.assertTrue(any(name.endswith("-2-open.json") for name in names))
        self.assertTrue(any(name.endswith("-201-open.json") for name in names))
        self.assertIn("issue:1:open", "\n".join(logs.output))

    def test_a_corrupt_file_is_set_aside_once_and_blocks_nothing(self):
        garbage = os.path.join(self.outbox, "0000000000001-3-open.json")
        wrong_shape = os.path.join(self.outbox, "0000000000002-4-open.json")
        with open(garbage, "w") as handle:
            handle.write("{not json")
        with open(wrong_shape, "w") as handle:
            handle.write('{"v": 1}')
        self.enqueue(7, "open")
        with self.assertLogs(level="DEBUG") as logs:
            counts = main.outbox_drain(T0)
        self.assertEqual(counts["delivered"], 1)
        self.assertEqual(self.files(".corrupt"), ["0000000000001-3-open.json.corrupt", "0000000000002-4-open.json.corrupt"])
        logged = "\n".join(logs.output)
        self.assertEqual(logged.count("0000000000001-3-open.json"), 1)
        with self.assertNoLogs(level="ERROR"):
            main.outbox_drain(T0 + 1)

    def test_a_corrupt_file_older_than_14_days_is_deleted(self):
        old = os.path.join(self.outbox, "0000000000001-3-open.json.corrupt")
        fresh = os.path.join(self.outbox, "0000000000002-4-open.json.corrupt")
        for path in (old, fresh):
            with open(path, "w") as handle:
                handle.write("x")
        os.utime(old, (T0 - 15 * DAY, T0 - 15 * DAY))
        os.utime(fresh, (T0 - DAY, T0 - DAY))
        main.outbox_drain(T0)
        self.assertEqual(self.files(".corrupt"), ["0000000000002-4-open.json.corrupt"])

    def test_a_rotated_secret_signs_the_next_attempt(self):
        self.enqueue(7, "open")
        self.net.ingest_status = 500
        main.outbox_drain(T0)
        new_secret = "rotated-secret-0123456789abcdefghij"
        self.load(**dict(INGEST, NOTIFY_INGEST_SECRET=new_secret))
        self.net.ingest_status = 202
        self.clock = T0 + 15
        main.outbox_drain(T0 + 15)
        retry = self.net.deliveries()[-1]
        self.assertTrue(self.verifies(retry, new_secret))
        self.assertFalse(self.verifies(retry, INGEST["NOTIFY_INGEST_SECRET"]))
        self.assertEqual(self.files(), [])

    def test_health_reports_how_many_events_are_pending(self):
        self.assertEqual(self.http("GET", "/health")[1]["pending"], 0)
        self.enqueue(7, "open")
        self.enqueue(8, "open")
        self.assertEqual(self.http("GET", "/health")[1]["pending"], 2)
        main.CONFIG["ingest"] = None
        self.assertEqual(self.http("GET", "/health")[1]["pending"], 0)

    def test_check_outbox_creates_the_folder_and_sweeps_leftover_temporaries(self):
        target = os.path.join(self.outbox, "nested", "outbox")
        main.check_outbox(target)
        self.assertTrue(os.path.isdir(target))
        for name in ("0000000000001-3-open.tmp", "0000000000002-4-open.json"):
            with open(os.path.join(target, name), "w") as handle:
                handle.write("{}")
        main.check_outbox(target)
        self.assertEqual(sorted(os.listdir(target)), ["0000000000002-4-open.json"])

    def test_check_outbox_refuses_a_folder_it_cannot_write_and_names_it(self):
        blocker = os.path.join(self.outbox, "a-file")
        with open(blocker, "w") as handle:
            handle.write("x")
        target = os.path.join(blocker, "outbox")
        with self.assertRaises(main.ConfigError) as caught:
            main.check_outbox(target)
        self.assertIn(target, str(caught.exception))
        self.assertIn("scripts/init.sh", str(caught.exception))
        if os.geteuid() != 0:
            read_only = os.path.join(self.outbox, "read-only")
            os.mkdir(read_only, 0o500)
            self.addCleanup(os.chmod, read_only, 0o700)
            with self.assertRaises(main.ConfigError) as caught:
                main.check_outbox(read_only)
            self.assertIn(read_only, str(caught.exception))

    def test_the_service_refuses_to_start_without_a_writable_outbox(self):
        blocker = os.path.join(self.outbox, "a-file")
        with open(blocker, "w") as handle:
            handle.write("x")
        environ = env(**INGEST, OUTBOX_DIR=os.path.join(blocker, "outbox"))
        with mock.patch.dict(os.environ, environ, clear=True), \
                mock.patch.object(main, "run_server") as run_server, \
                mock.patch.object(main, "start_outbox_worker") as start_worker:
            with self.assertRaises(SystemExit) as caught:
                main.main()
        self.assertEqual(caught.exception.code, 1)
        run_server.assert_not_called()
        start_worker.assert_not_called()

    def test_the_service_starts_the_worker_before_serving_when_the_outbox_works(self):
        order = []
        with mock.patch.dict(os.environ, env(**INGEST, OUTBOX_DIR=self.outbox), clear=True), \
                mock.patch.object(main, "run_server", side_effect=lambda: order.append("serve")), \
                mock.patch.object(main, "start_outbox_worker", side_effect=lambda: order.append("worker")):
            main.main()
        self.assertEqual(order, ["worker", "serve"])

    def test_no_log_line_holds_the_secret_or_the_body(self):
        body = main.build_issue_event("7", "open", {})["body"].decode()
        scenarios = []

        def delivered():
            self.net.ingest_status = 202
            main.outbox_drain(T0)

        def failed():
            self.net.ingest_status = 401
            main.outbox_drain(T0)

        def expired():
            main.outbox_drain(T0 + 15 * DAY)

        def corrupt():
            with open(os.path.join(self.outbox, "0000000000001-3-open.json"), "w") as handle:
                handle.write("{not json")
            main.outbox_drain(T0)

        for scenario in (delivered, failed, expired, corrupt):
            self.empty_outbox()
            self.enqueue(7, "open")
            with self.assertLogs(level="DEBUG") as logs:
                scenario()
            logged = "\n".join(logs.output)
            self.assertNotIn(INGEST["NOTIFY_INGEST_SECRET"], logged, scenario.__name__)
            self.assertNotIn(body, logged, scenario.__name__)
            self.assertNotIn("v1=", logged, scenario.__name__)


class ContractVector(unittest.TestCase):
    """The same fixed secret, timestamp, body and signature the hub's tests pin (08-01)."""

    SECRET = "ingest-contract-secret-0123456789abcdef"
    TIMESTAMP = 1700000000
    BODY = (b'{"v":1,"source":"backup","eventId":"backup-failed:1700000000","hostId":"nas-home",'
            b'"key":"backup-failed","state":"open","data":{"errors":["restic backup failed (exit 1)"]}}')
    SIGNATURE = "4525b5167d3882979d6b063dde511c6c28d2bec94d65811d2f512581b76eada1"

    def event(self):
        return {"v": 1, "source": "backup", "eventId": "backup-failed:1700000000", "hostId": "nas-home",
                "key": "backup-failed", "state": "open",
                "data": {"errors": ["restic backup failed (exit 1)"]}}

    def test_the_body_is_the_exact_bytes_of_the_contract(self):
        self.assertEqual(main.ingest_body(self.event()), self.BODY)

    def test_the_body_keeps_the_contract_order_whatever_the_dict_order(self):
        shuffled = dict(reversed(list(self.event().items())))
        self.assertEqual(main.ingest_body(shuffled), self.BODY)

    def test_the_signature_is_the_contract_one(self):
        self.assertEqual(main.sign_ingest(self.SECRET, self.TIMESTAMP, self.BODY), self.SIGNATURE)


class Secrecy(OutboxCase):
    """Runs the real api_request with only the socket faked, to see what gets logged."""

    fake_network = False

    def cycle(self, outcome):
        def urlopen(request, timeout=None):
            if isinstance(outcome, Exception):
                raise outcome
            response = mock.MagicMock()
            response.__enter__.return_value = response
            response.status = outcome
            response.read.return_value = b"{}"
            return response
        with mock.patch.object(main.urllib.request, "urlopen", urlopen):
            with self.assertLogs(level="DEBUG") as logs:
                self.empty_outbox()
                result = main.process_webhook_payload(
                    {"notification_type": "ISSUE_RESOLVED", "issue": {"issue_id": "7"}})
                result["drain"] = main.outbox_drain()
        return result, "\n".join(logs.output)

    def test_neither_the_secret_nor_the_body_reach_the_log_or_the_response(self):
        body = main.build_issue_event("7", "resolved", {})["body"].decode()
        outcomes = (
            202,
            urllib.error.HTTPError(INGEST["NOTIFY_INGEST_URL"], 401, "Unauthorized", {}, None),
            urllib.error.URLError("connection refused"),
        )
        for outcome in outcomes:
            result, logged = self.cycle(outcome)
            for text in (logged, json.dumps(result)):
                self.assertNotIn(INGEST["NOTIFY_INGEST_SECRET"], text)
                self.assertNotIn(body, text)
                self.assertNotIn('"eventId"', text)


if __name__ == "__main__":
    unittest.main(argv=["issue-automator"], verbosity=1)
EOF
