#!/usr/bin/env bash
# Exercise actual-image/candidate comparisons and persistent notification delivery.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PYTHONPATH="$REPO/stacks/monitoring/security-monitor" python3 -B - <<'PY'
import copy
import json
from pathlib import Path
import tempfile
import unittest
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
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name)
        self.images = {'sha256:a': {'tag': 'app:1', 'names': ['app', 'app-vo']}}
        self.observations = [observation(), observation('app-vo')]
        self.reports = {'sha256:a': report(), 'app:2': report(False, version='2.0')}
        self.messages, self.scans = [], []

    def scan(self, image, path, source, platform):
        self.scans.append((image, source, platform))
        result = self.reports[image]
        if isinstance(result, Exception):
            raise result
        main.atomic_json(path, result)
        return result

    def run_scan(self, notify=None):
        return main.run(self.state, lambda: self.images, lambda: self.observations,
                        self.scan, notify or self.messages.append, lambda: None)

    def test_existing_vulnerabilities_without_candidate_are_silent(self):
        self.observations = []
        self.assertEqual(self.run_scan(), 0)
        self.assertEqual(self.messages, [])
        self.assertEqual(self.scans, [])

    def test_package_fix_available_but_candidate_still_vulnerable_is_silent(self):
        self.reports['app:2'] = report(version='1.5')
        self.run_scan()
        self.assertEqual(self.messages, [])

    def test_confirmed_fix_notifies_once_and_groups_shared_containers(self):
        self.run_scan()
        self.run_scan()
        self.assertEqual(len(self.messages), 1)
        self.assertIn('1 actualización', self.messages[0])
        self.assertIn('app, app-vo: 1 → 2', self.messages[0])
        self.assertIn('1 CVE ', self.messages[0])
        self.assertEqual(self.scans[:2], [('sha256:a', 'docker', 'linux/amd64'),
                                         ('app:2', 'remote', 'linux/amd64')])

    def test_candidate_unfixed_finding_and_severity_downgrade_are_not_fixes(self):
        for data in (report(severity='LOW', version='2.0'), report(fixed='', version='2.0')):
            self.reports['app:2'] = data
            self.run_scan()
        self.assertEqual(self.messages, [])

    def test_missing_package_inventory_or_eol_is_not_proof_of_fix(self):
        for data in ({'Results': []}, {'Results': [{'Type': 'alpine', 'Packages': []}]},
                     dict(report(False, version='2.0'), Metadata={'OS': {'EOSL': True}})):
            self.reports['app:2'] = data
            self.run_scan()
        self.assertEqual(self.messages, [])

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
        self.assertIn('Corrige 1 CVE ', self.messages[0])

    def test_unchanged_package_version_is_not_proof_of_fix(self):
        self.reports['app:2'] = report(False, version='1.0')
        self.run_scan()
        self.assertEqual(self.messages, [])

    def test_unversioned_go_binary_does_not_abort_other_package_comparisons(self):
        self.reports['app:2']['Results'].append({'Type': 'gobinary',
            'Packages': [{'Name': 'main/Tdarr_Node_Tray'}]})
        self.assertEqual(self.run_scan(), 0)
        self.assertEqual(len(self.messages), 1)

    def test_affected_package_without_candidate_version_is_not_proof_of_fix(self):
        del self.reports['app:2']['Results'][0]['Packages'][0]['Version']
        self.run_scan()
        self.assertEqual(self.messages, [])

    def test_missing_inventory_of_one_affected_dependency_is_not_proof(self):
        data = report()
        other = copy.deepcopy(data['Results'][0])
        other.update(Type='node-pkg', Target='app/package.json')
        data['Results'].append(other)
        self.reports['sha256:a'] = data
        self.run_scan()
        self.assertEqual(self.messages, [])

    def test_cve_still_in_another_package_is_not_counted_as_fixed(self):
        other = report(version='2.0')
        other['Results'][0]['Vulnerabilities'][0]['PkgName'] = 'another'
        self.reports['app:2'] = other
        self.run_scan()
        self.assertEqual(self.messages, [])

    def test_delivery_failure_keeps_verified_update_pending(self):
        def fail(message):
            raise RuntimeError('delivery failed')
        with self.assertRaises(RuntimeError):
            self.run_scan(fail)
        self.assertFalse((self.state / 'notified-updates.json').exists())
        self.run_scan()
        self.assertEqual(len(self.messages), 1)

    def test_candidate_scan_failure_does_not_create_false_fix(self):
        self.reports['app:2'] = RuntimeError('scan failed')
        self.assertEqual(self.run_scan(), 1)
        self.assertEqual(self.messages, [])
        self.assertFalse(json.loads((self.state / 'last-status.json').read_text())['ok'])
        self.reports['app:2'] = report(False, version='2.0')
        self.run_scan()
        self.assertEqual(len(self.messages), 1)

    def test_later_tag_fixing_same_cve_does_not_repeat_for_running_image(self):
        self.run_scan()
        self.observations = [observation(tag='3')]
        self.reports['app:3'] = report(False, version='3.0')
        self.run_scan()
        self.assertEqual(len(self.messages), 1)

    def test_different_candidates_of_same_running_image_do_not_duplicate_cves(self):
        self.observations[1] = observation('app-vo', tag='3')
        self.reports['app:3'] = report(False, version='3.0')
        self.run_scan()
        self.assertEqual(len(self.messages), 1)
        self.assertIn('1 actualización', self.messages[0])

    def test_stale_wud_observation_is_not_compared(self):
        self.observations = [observation(image='sha256:outdated')]
        self.run_scan()
        self.assertEqual(self.scans, [])
        self.assertEqual(self.messages, [])

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
        self.assertEqual(self.messages, [])
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
