#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PYTHONPATH="$REPO/stacks/monitoring/security-monitor" python3 -B - <<'PY'
import datetime
import json
from pathlib import Path
import tempfile
import unittest
from healthcheck import healthy


class Health(unittest.TestCase):
    def test_scheduler_requires_successful_recent_scan(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            for process in (b'python3\0/app/main.py\0schedule\0', b'supercronic\0/state/crontab\0'):
                for ok, hours, expected in ((True, 1, True), (False, 1, False),
                                            (True, 49, False), (True, -1, False)):
                    with self.subTest(process=process, ok=ok, hours=hours):
                        (state / 'last-status.json').write_text(json.dumps({
                            'ok': ok, 'time': (now - datetime.timedelta(hours=hours)).isoformat()}))
                        self.assertEqual(healthy(state, process, now), expected)
            (state / 'last-status.json').write_text(json.dumps({'ok': True, 'time': now.isoformat()}))
            self.assertFalse(healthy(state, b'python3\0/app/main.py\0run\0', now))


unittest.main()
PY
