#!/usr/bin/env bash
# Policy plus real Compose updates, rollback of App data and interrupted-update recovery.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
export SECURITY_TEST_REPO="$REPO"
PYTHONPATH="$REPO/stacks/monitoring/security-monitor" python3 -B - <<'PY'
import copy
import datetime
import fcntl
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import uuid
import updater


def plan():
    return {'local_ref': 'example/app:1.2.0', 'remote_ref': 'example/app:1.2.1',
        'semver_diff': 'patch', 'fixed': {'CVE-1': 'HIGH'}, 'new_severe': [],
        'candidate_id': 'sha256:' + 'f'*64, 'pinned_ref': 'example/app:1.2.1@sha256:' + 'a'*64,
        'verified_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}


class Policy(unittest.TestCase):
    def test_verified_nonmajor_security_update_is_eligible(self):
        self.assertIsNone(updater.manual_reason(plan()))

    def test_major_is_manual_even_when_security_fix_is_verified(self):
        p = plan()
        p.update(remote_ref='example/app:2.0.0', semver_diff='major')
        self.assertIn('major', updater.manual_reason(p))

    def test_prerelease_unknown_or_regression_is_manual(self):
        for changes in ({'remote_ref': 'example/app:1.3.0-beta1'}, {'semver_diff': None},
                        {'new_severe': ['CVE-new']}, {'candidate_id': None}, {'pinned_ref': None},
                        {'fixed': {}}):
            self.assertIsNotNone(updater.manual_reason(dict(plan(), **changes)))

    def test_stale_verification_is_manual(self):
        p = plan()
        p['verified_at'] = (datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=1)).isoformat()
        self.assertIn('stale', updater.manual_reason(p))

    def test_linuxserver_builds_and_digest_pins_preserve_major(self):
        self.assertEqual(updater.stable_major('lscr.io/linuxserver/bazarr:v1.6.2-ls367@sha256:abc'), 1)
        self.assertEqual(updater.stable_major('app:5.2.4_v2.0.15-ls479'), 5)
        self.assertEqual(updater.stable_major('app:6.4.4.10685-ls319'), 6)

    def test_backup_lock_prevents_update_before_any_mutation(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root/'backup').mkdir()
            host = updater.Host(root, root/'security-monitor', root)
            with (root/'backup/run.lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                with patch.object(host, '_apply') as apply:
                    with self.assertRaises(BlockingIOError):
                        host.apply('app', plan())
                apply.assert_not_called()


class ComposeTransactions(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory(prefix='.security-update-test-', dir=os.environ['SECURITY_TEST_REPO'])
        cls.root = Path(cls.workspace.name)
        cls.prefix = 'media-stack-security-test-' + uuid.uuid4().hex[:12]
        cls.images = {mode: cls.prefix + ':' + mode for mode in ('old', 'good', 'bad')}
        (cls.root/'.dockerignore').write_text('*\n!Dockerfile\n!entrypoint.sh\n')
        (cls.root/'entrypoint.sh').write_text('''#!/bin/sh
mkdir -p /config
case "$MODE" in
 old) test -f /config/data || echo original > /config/data ;;
 good) echo upgraded > /config/data ;;
 bad) echo corrupted > /config/data ;;
esac
exec sleep 600
''')
        (cls.root/'Dockerfile').write_text('''FROM alpine:3.24
ARG MODE
ENV MODE=$MODE
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
HEALTHCHECK --interval=1s --timeout=1s --retries=1 CMD test "$MODE" != bad
ENTRYPOINT ["/entrypoint.sh"]
''')
        try:
            for mode, ref in cls.images.items():
                updater.command(['docker','build','-q','--build-arg','MODE='+mode,'-t',ref,str(cls.root)])
        except Exception:
            cls.tearDownClass()
            raise

    @classmethod
    def tearDownClass(cls):
        for ref in cls.images.values():
            try: updater.command(['docker','image','rm',ref])
            except Exception: pass
        cls.workspace.cleanup()

    def setUp(self):
        self.project = self.root/uuid.uuid4().hex
        self.project.mkdir()
        self.appdata = self.project/'appdata'
        (self.appdata/'app').mkdir(parents=True)
        self.state = self.appdata/'security-monitor'
        self.state.mkdir()
        self.pins = self.state/'images.compose.json'
        self.pins.write_text(json.dumps({'services':{}}))
        (self.project/'.env').write_text('COMPOSE_FILE=compose.yaml:'+str(self.pins)+'\n')
        model = {'name': self.prefix+'-'+self.project.name[:8], 'services': {'app': {
            'image': self.images['old'], 'volumes': [str(self.appdata/'app')+':/config']}}}
        (self.project/'compose.yaml').write_text(json.dumps(model))
        self.host = updater.Host(self.project,self.state,self.appdata,timeout=15,stable=0.2)
        self.host.compose('up','-d')
        self.old_id = self.host.inspect(self.images['old'])['Id']
        self.assertTrue(self.host.healthy('app',self.old_id))
        real_command = updater.command
        def local_images(argv, **kwargs):
            # These scratch candidates are locally built fixtures, not registry images.
            if argv[:2] == ['docker','pull']: return ''
            return real_command(argv, **kwargs)
        self.mock = patch.object(updater,'command',side_effect=local_images)
        self.mock.start()
        self.addCleanup(self.mock.stop)
        self.addCleanup(self.host.compose,'down','--remove-orphans')

    def candidate(self, mode):
        return {'local_id':self.old_id,'platform':'linux/amd64','pinned_ref':self.images[mode],
                'candidate_id':self.host.inspect(self.images[mode])['Id']}

    def test_healthy_update_survives_another_compose_up(self):
        p = self.candidate('good')
        self.assertIsNone(self.host.eligibility('app',p))
        self.assertIn('actualizada',self.host.apply('app',p))
        self.assertEqual(self.host.container('app')['Image'],p['candidate_id'])
        self.assertEqual((self.appdata/'app/data').read_text().strip(),'upgraded')
        self.host.compose('up','-d')
        self.assertEqual(self.host.container('app')['Image'],p['candidate_id'])
        self.assertFalse(self.host.pending.exists())

    def test_failed_health_restores_original_image_and_app_data(self):
        p = self.candidate('bad')
        self.assertIn('rollback',self.host.apply('app',p))
        self.assertEqual(self.host.container('app')['Image'],self.old_id)
        self.assertEqual((self.appdata/'app/data').read_text().strip(),'original')
        self.assertFalse(self.host.pending.exists())
        failed = list(self.host.transactions.glob('*/failed-data-*/data'))
        self.assertEqual(failed[0].read_text().strip(),'corrupted')
        self.host.compose('up','-d')
        self.assertEqual(self.host.container('app')['Image'],self.old_id)

    def test_interrupted_deployment_recovers_from_persistent_journal(self):
        with patch.object(self.host,'healthy',side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                self.host.apply('app',self.candidate('good'))
        self.assertTrue(self.host.pending.exists())
        transaction = json.loads(self.host.pending.read_text())
        self.assertIn('rollback',self.host.rollback(transaction))
        self.assertEqual(self.host.container('app')['Image'],self.old_id)
        self.assertEqual((self.appdata/'app/data').read_text().strip(),'original')
        self.assertFalse(self.host.pending.exists())


unittest.main()
PY
