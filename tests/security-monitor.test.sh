#!/usr/bin/env bash
# Exercise actual-image/candidate comparisons and the count of verified security updates.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PYTHONPATH="$REPO/stacks/monitoring/security-monitor" python3 -B - <<'PY'
import copy
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
import urllib.request
from unittest.mock import patch
import main


def report(vulnerable=True, severity='HIGH', fixed='2.0', version='1.0', target='image-a'):
    vulnerabilities = [{'VulnerabilityID': 'CVE-2026-1234', 'PkgName': 'test',
        'Severity': severity, 'FixedVersion': fixed, 'InstalledVersion': version}] if vulnerable else []
    return {'Results': [{'Target': target, 'Class': 'os-pkgs', 'Type': 'alpine',
        'Packages': [{'Name': 'test', 'Version': version}], 'Vulnerabilities': vulnerabilities}]}


def observation(name='app', image='sha256:a', tag='2', registry='hub.public'):
    return {'name': name, 'updateAvailable': True, 'image': {'id': image,
        'registry': {'name': registry}, 'architecture': 'amd64', 'os': 'linux'},
        'updateKind': {'kind': 'tag'}, 'result': {'tag': tag}}


class Monitor(unittest.TestCase):
    def test_apps_server_discovery_ignores_other_projects(self):
        containers = [
            {'ImageID': 'sha256:apps', 'Image': 'app:1', 'Names': ['/seerr'],
             'Labels': {'com.docker.compose.project': 'media-stack-apps'}},
            {'ImageID': 'sha256:other', 'Image': 'other:1', 'Names': ['/finance'],
             'Labels': {'com.docker.compose.project': 'finance'}},
        ]
        response = io.StringIO(json.dumps(containers))
        response.status = 200
        with patch.object(main, 'DockerConnection') as connection, \
                patch.dict(main.os.environ, {'SECURITY_COMPOSE_PROJECT': 'media-stack-apps'}):
            connection.return_value.getresponse.return_value = response
            self.assertEqual(set(main.running_images()), {'sha256:apps'})

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name)
        self.images = {'sha256:a': {'tag': 'app:1', 'names': ['app', 'app-vo']}}
        self.observations = [observation(), observation('app-vo')]
        self.reports = {'sha256:a': report(), 'app:2': report(False, version='2.0')}
        self.scans = []
        # The Operator's Telegram settings are present: the monitor must never use them.
        env = patch.dict(os.environ, {'TELEGRAM_BOT_TOKEN': 'token', 'TELEGRAM_CHAT_ID': '1'})
        env.start()
        self.addCleanup(env.stop)
        network = patch.object(urllib.request, 'urlopen', side_effect=AssertionError('network request'))
        self.urlopen = network.start()
        self.addCleanup(network.stop)

    def scan(self, image, path, source, platform):
        self.scans.append((image, source, platform))
        result = self.reports[image]
        if isinstance(result, Exception):
            raise result
        main.atomic_json(path, result)
        return result

    def run_scan(self):
        code = main.run(self.state, lambda: self.images, lambda: self.observations,
                        self.scan, lambda: None)
        self.urlopen.assert_not_called()
        return code

    def security_updates(self):
        return json.loads((self.state / 'last-status.json').read_text())['security_updates']

    def test_existing_vulnerabilities_without_candidate_are_silent(self):
        self.observations = []
        self.assertEqual(self.run_scan(), 0)
        self.assertEqual(self.security_updates(), 0)
        self.assertEqual(self.scans, [])

    def test_package_fix_available_but_candidate_still_vulnerable_is_silent(self):
        self.reports['app:2'] = report(version='1.5')
        self.run_scan()
        self.assertEqual(self.security_updates(), 0)

    def test_confirmed_fix_counts_once_and_groups_shared_containers(self):
        self.run_scan()
        self.assertEqual(self.security_updates(), 1)
        self.run_scan()
        self.assertEqual(self.security_updates(), 0)
        comparisons = [json.loads(path.read_text()) for path in (self.state / 'comparisons').glob('*.json')]
        self.assertEqual([sorted(comparison['names']) for comparison in comparisons], [['app', 'app-vo']])
        self.assertEqual(self.scans[:2], [('sha256:a', 'docker', 'linux/amd64'),
                                         ('app:2', 'remote', 'linux/amd64')])

    def test_candidate_unfixed_finding_and_severity_downgrade_are_not_fixes(self):
        for data in (report(severity='LOW', version='2.0'), report(fixed='', version='2.0')):
            self.reports['app:2'] = data
            self.run_scan()
            self.assertEqual(self.security_updates(), 0)

    def test_missing_package_inventory_or_eol_is_not_proof_of_fix(self):
        for data in ({'Results': []}, {'Results': [{'Type': 'alpine', 'Packages': []}]},
                     dict(report(False, version='2.0'), Metadata={'OS': {'EOSL': True}})):
            self.reports['app:2'] = data
            self.run_scan()
            self.assertEqual(self.security_updates(), 0)

    def test_same_cve_across_dependencies_is_counted_once(self):
        data = report()
        target = copy.deepcopy(data['Results'][0])
        target.update(Type='node-pkg', Target='app/package.json')
        data['Results'].append(target)
        candidate = report(False, version='2.0')
        other = copy.deepcopy(candidate['Results'][0])
        other.update(Type='node-pkg', Target='new/path/package.json')
        candidate['Results'].append(other)
        self.reports.update({'sha256:a': data, 'app:2': candidate})
        self.run_scan()
        self.assertEqual(self.security_updates(), 1)
        comparison = json.loads(next((self.state / 'comparisons').glob('*.json')).read_text())
        self.assertEqual(list(comparison['fixed']), ['CVE-2026-1234'])

    def test_unchanged_package_version_is_not_proof_of_fix(self):
        self.reports['app:2'] = report(False, version='1.0')
        self.run_scan()
        self.assertEqual(self.security_updates(), 0)

    def test_unversioned_go_binary_does_not_abort_other_package_comparisons(self):
        self.reports['app:2']['Results'].append({'Type': 'gobinary',
            'Packages': [{'Name': 'main/Tdarr_Node_Tray'}]})
        self.assertEqual(self.run_scan(), 0)
        self.assertEqual(self.security_updates(), 1)

    def test_affected_package_without_candidate_version_is_not_proof_of_fix(self):
        del self.reports['app:2']['Results'][0]['Packages'][0]['Version']
        self.run_scan()
        self.assertEqual(self.security_updates(), 0)

    def test_missing_inventory_of_one_affected_dependency_is_not_proof(self):
        data = report()
        other = copy.deepcopy(data['Results'][0])
        other.update(Type='node-pkg', Target='app/package.json')
        data['Results'].append(other)
        self.reports['sha256:a'] = data
        self.run_scan()
        self.assertEqual(self.security_updates(), 0)

    def test_cve_still_in_another_package_is_not_counted_as_fixed(self):
        other = report(version='2.0')
        other['Results'][0]['Vulnerabilities'][0]['PkgName'] = 'another'
        self.reports['app:2'] = other
        self.run_scan()
        self.assertEqual(self.security_updates(), 0)

    def test_the_monitor_has_no_telegram_or_digest_and_run_takes_no_notify(self):
        self.assertFalse(hasattr(main, 'telegram'))
        self.assertFalse(hasattr(main, 'digest'))
        with self.assertRaises(TypeError):
            main.run(self.state, lambda: self.images, lambda: self.observations,
                     self.scan, notify=lambda message: None, prepare=lambda: None)

    def test_automatic_mode_leaves_the_verified_update_ready_for_the_host_updater(self):
        with patch.dict(os.environ, {'SECURITY_AUTO_UPDATE': 'on'}):
            self.assertEqual(self.run_scan(), 0)
        self.assertEqual(self.security_updates(), 1)
        comparisons = [json.loads(path.read_text()) for path in (self.state / 'comparisons').glob('*.json')]
        self.assertEqual([list(comparison['fixed']) for comparison in comparisons], [['CVE-2026-1234']])

    def test_candidate_scan_failure_does_not_create_false_fix(self):
        self.reports['app:2'] = RuntimeError('scan failed')
        self.assertEqual(self.run_scan(), 1)
        self.assertEqual(self.security_updates(), 0)
        self.assertFalse(json.loads((self.state / 'last-status.json').read_text())['ok'])
        self.reports['app:2'] = report(False, version='2.0')
        self.run_scan()
        self.assertEqual(self.security_updates(), 1)

    def test_later_tag_fixing_same_cve_does_not_repeat_for_running_image(self):
        self.run_scan()
        self.observations = [observation(tag='3')]
        self.reports['app:3'] = report(False, version='3.0')
        self.run_scan()
        self.assertEqual(self.security_updates(), 0)

    def test_different_candidates_of_same_running_image_do_not_duplicate_cves(self):
        self.observations[1] = observation('app-vo', tag='3')
        self.reports['app:3'] = report(False, version='3.0')
        self.run_scan()
        self.assertEqual(self.security_updates(), 1)

    def test_stale_wud_observation_is_not_compared(self):
        self.observations = [observation(image='sha256:outdated')]
        self.run_scan()
        self.assertEqual(self.scans, [])
        self.assertEqual(self.security_updates(), 0)

    def test_remote_reference_uses_actual_repository(self):
        for ref, expected in [('lscr.io/linuxserver/app:1','lscr.io/linuxserver/app:2'),
                              ('ghcr.io/org/app:1','ghcr.io/org/app:2'),
                              ('localhost:5000/org/app:1','localhost:5000/org/app:2')]:
            self.images['sha256:a']['tag'] = ref
            candidate = main.update_candidates(self.images, self.observations)[0]
            self.assertEqual(candidate['remote_ref'], expected)

    def test_no_update_or_digest_only_candidate_is_skipped(self):
        for change in ({'updateAvailable': False}, {'updateKind': {'kind': 'digest'}},
                       {'result': {'tag': 'bad/tag'}}, {'error': {'message': 'registry failed'}}):
            self.observations = [dict(observation(), **change)]
            self.run_scan()
            self.assertEqual(self.security_updates(), 0)
        self.assertEqual(self.scans, [])

    def test_scan_preserves_all_vulnerabilities_for_honest_comparison(self):
        target = self.state / 'report.json'
        target.write_text(json.dumps(report()))
        with patch.object(main.subprocess, 'run') as command:
            main.scan('repo/app:2', target, 'remote', 'linux/amd64')
        argv = command.call_args.args[0]
        self.assertEqual(argv[-1], 'repo/app:2')
        self.assertEqual(argv[argv.index('--image-src')+1], 'remote')
        self.assertIn('--skip-db-update', argv)
        self.assertNotIn('--ignore-unfixed', argv)
        self.assertNotIn('--severity', argv)
        self.assertEqual(argv[argv.index('--scanners')+1], 'vuln')


unittest.main()
PY
