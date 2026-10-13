"""Notify only published image updates with verified security improvements."""
import base64
import datetime
import fcntl
import hashlib
import http.client
import json
import os
import re
import signal
from pathlib import Path
import socket
import subprocess
import sys
import urllib.parse
import urllib.request


class DockerConnection(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect('/var/run/docker.sock')


def running_images():
    connection = DockerConnection('localhost', timeout=30)
    try:
        connection.request('GET', '/containers/json')
        response = connection.getresponse()
        if response.status != 200:
            raise RuntimeError('Cannot list running Docker containers')
        containers = json.load(response)
    finally:
        connection.close()
    images = {}
    for container in containers:
        if container.get('Labels', {}).get('com.docker.compose.service') == 'security-monitor':
            continue
        image = images.setdefault(container['ImageID'], {'tag': container['Image'], 'names': []})
        image['names'].extend(name.lstrip('/') for name in container['Names'])
    return images


def wud_containers():
    credentials = (os.environ.get('WUD_ADMIN_USER', 'admin') + ':' +
                   os.environ.get('WUD_ADMIN_PASSWORD', ''))
    request = urllib.request.Request('http://wud:3000/api/containers', headers={
        'Authorization': 'Basic ' + base64.b64encode(credentials.encode()).decode(),
    })
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def update_candidates(images, containers):
    """Match WUD observations to the actual running image, rejecting stale entries."""
    running = {name: (image_id, image) for image_id, image in images.items()
               for name in image['names']}
    groups = {}
    for container in containers:
        name = container['name']
        if name not in running or not container.get('updateAvailable') or container.get('error'):
            continue
        if container.get('updateKind', {}).get('kind') != 'tag':
            continue
        image_id, image = running[name]
        if container['image']['id'] != image_id:
            continue
        remote_tag = container.get('result', {}).get('tag', '')
        if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}', remote_tag):
            continue
        local_ref = image['tag'].split('@', 1)[0]
        if local_ref.startswith('sha256:'):
            continue
        repo = local_ref.rsplit(':', 1)[0] if ':' in local_ref.rsplit('/', 1)[-1] else local_ref
        remote_ref = repo + ':' + remote_tag
        if remote_ref == local_ref:
            continue
        metadata = container['image']
        platform = metadata.get('os', 'linux') + '/' + metadata.get('architecture', 'amd64')
        if metadata.get('variant'):
            platform += '/' + metadata['variant']
        key = (image_id, remote_ref, platform)
        group = groups.setdefault(key, {'local_id': image_id, 'local_ref': local_ref,
            'remote_ref': remote_ref, 'platform': platform, 'names': [],
            'semver_diff': container.get('updateKind', {}).get('semverDiff')})
        group['names'].append(name)
    return list(groups.values())


def vulnerabilities(report):
    # Include ALL severities and unfixed findings: downgrades are not corrections.
    result = {}
    for target in report.get('Results', []):
        for vulnerability in target.get('Vulnerabilities') or []:
            key = (target['Type'], vulnerability['PkgName'], vulnerability['VulnerabilityID'])
            result.setdefault(key, []).append(vulnerability)
    return result


def corrected_cves(current, candidate):
    """Deduplicate CVEs and require package inventory in the candidate image."""
    before, after = vulnerabilities(current), vulnerabilities(candidate)
    inventory = {}
    for target in candidate.get('Results', []):
        for package in target.get('Packages', []):
            if not package.get('Name') or not package.get('Version'):
                continue
            inventory.setdefault((target['Type'], package['Name']), set()).add(package['Version'])
    # Unsupported/EOL OS coverage is not evidence that a vulnerability was fixed.
    if candidate.get('Metadata', {}).get('OS', {}).get('EOSL'):
        return {}
    fixed = {}
    for (kind, package, cve), occurrences in before.items():
        severe = [v for v in occurrences if v.get('Severity') in ('HIGH', 'CRITICAL')
                  and v.get('FixedVersion')]
        if not severe or (kind, package) not in inventory:
            continue
        # Count a CVE as corrected only if no analyzed package in the candidate has it.
        if any(key[2] == cve for key in after):
            continue
        affected = [(key, values) for key, values in before.items() if key[2] == cve]
        if any((key[0], key[1]) not in inventory or
               any(v['InstalledVersion'] in inventory[(key[0], key[1])] for v in values)
               for key, values in affected):
            continue
        severity = 'CRITICAL' if any(v['Severity'] == 'CRITICAL' for v in severe) else 'HIGH'
        if cve not in fixed or severity == 'CRITICAL':
            fixed[cve] = severity
    return fixed


def comparison(group, current, candidate, fixed):
    metadata = candidate.get('Metadata', {})
    digests = metadata.get('RepoDigests', [])
    repo = group['remote_ref'].rsplit(':', 1)[0]
    normalize = lambda name: name.removeprefix('docker.io/').removeprefix('library/')
    digest = next((ref.split('@', 1)[1] for ref in digests
                   if '@' in ref and normalize(ref.split('@', 1)[0]) == normalize(repo)), '')
    severe = lambda report: {(key[2], v['Severity']) for key, values in vulnerabilities(report).items()
                             for v in values if v.get('Severity') in ('HIGH', 'CRITICAL')}
    regressions = severe(candidate) - severe(current)
    return dict(group, fixed=fixed, candidate_id=metadata.get('ImageID'),
                pinned_ref=(group['remote_ref'] + '@' + digest) if digest else None,
                new_severe=sorted({cve for cve, severity in regressions}),
                verified_at=datetime.datetime.now(datetime.timezone.utc).isoformat())


def update_database():
    subprocess.run(['trivy', 'image', '--download-db-only', '--no-progress'],
                   check=True, timeout=960, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def scan(image_ref, report_path, source='docker', platform=None):
    argv = ['trivy', 'image', '--image-src', source, '--scanners', 'vuln',
            '--skip-db-update', '--list-all-pkgs', '--parallel', '1', '--no-progress',
            '--timeout', '15m', '--format', 'json', '--output', str(report_path)]
    if platform:
        argv.extend(['--platform', platform])
    subprocess.run(argv + [image_ref], check=True, timeout=960,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return json.loads(report_path.read_text())


def telegram(message):
    token, chat = os.environ.get('TELEGRAM_BOT_TOKEN'), os.environ.get('TELEGRAM_CHAT_ID')
    if not token or not chat:
        raise RuntimeError('Telegram is not configured; findings remain pending')
    data = urllib.parse.urlencode({'chat_id': chat, 'text': message, 'disable_web_page_preview': 'true'}).encode()
    request = urllib.request.Request(f'https://api.telegram.org/bot{token}/sendMessage', data=data)
    with urllib.request.urlopen(request, timeout=30) as response:
        if not json.load(response).get('ok'):
            raise RuntimeError('Telegram rejected notification')


def atomic_json(path, data):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(data, ensure_ascii=False))
    temporary.replace(path)


def digest(updates):
    title = ('1 actualización de seguridad verificada' if len(updates) == 1 else
             f'{len(updates)} actualizaciones de seguridad verificadas')
    lines = [f'NAS Monitor — {title}']
    for update in updates:
        names = ', '.join(sorted(update['names']))
        local_tag = update['local_ref'].rsplit(':', 1)[-1]
        remote_tag = update['remote_ref'].rsplit(':', 1)[-1]
        cves = update['fixed']
        examples = ', '.join(sorted(cves, key=lambda c: (cves[c] != 'CRITICAL', c))[:3])
        noun = 'CVE' if len(cves) == 1 else 'CVEs'
        lines.append(f'{names}: {local_tag} → {remote_tag}\n'
                     f'Corrige {len(cves)} {noun} HIGH/CRITICAL: {examples}' +
                     (f' y {len(cves)-3} más' if len(cves) > 3 else ''))
    lines.append('Comparación de las imágenes con Trivy. No se ha actualizado ningún contenedor.')
    # Keep a single bounded digest, even for very large fleets.
    message = '\n\n'.join(lines)
    if len(message) > 3500:
        message = lines[0] + '\n\n' + '\n'.join(
            f'{u["remote_ref"]}: {len(u["fixed"])} CVEs corregidas' for u in updates)
        message = message[:3300] + '\nDetalles en security-monitor/comparisons.'
    return message


def run(state, discover=running_images, candidates=wud_containers, scanner=scan,
        notify=telegram, prepare=update_database):
    state.mkdir(parents=True, exist_ok=True)
    (state / 'tmp').mkdir(exist_ok=True)
    reports = state / 'reports'
    reports.mkdir(exist_ok=True)
    comparisons = state / 'comparisons'
    comparisons.mkdir(exist_ok=True)
    with (state / 'run.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # Separate from the old package-alert history: only verified corrections count.
        history_path = state / 'notified-updates.json'
        history = json.loads(history_path.read_text()) if history_path.exists() else {}
        updates, next_history, errors = [], dict(history), []
        images = discover()
        groups = update_candidates(images, candidates())
        if groups:
            prepare()
        local_reports, remote_reports = {}, {}
        for group in groups:
            local_id, remote_ref = group['local_id'], group['remote_ref']
            print(f'Comparing {group["local_ref"]} -> {remote_ref}', flush=True)
            identity = json.dumps([local_id, remote_ref, group['platform']])
            pair_hash = hashlib.sha256(identity.encode()).hexdigest()
            try:
                if local_id not in local_reports:
                    local_path = reports / (hashlib.sha256(local_id.encode()).hexdigest() + '.json')
                    local_reports[local_id] = scanner(local_id, local_path, 'docker', group['platform'])
                remote_key = (remote_ref, group['platform'])
                if remote_key not in remote_reports:
                    remote_hash = hashlib.sha256(json.dumps(remote_key).encode()).hexdigest()
                    remote_reports[remote_key] = scanner(remote_ref, reports / (remote_hash + '.json'),
                                                         'remote', group['platform'])
                fixed = corrected_cves(local_reports[local_id], remote_reports[remote_key])
                atomic_json(comparisons / (pair_hash + '.json'),
                            comparison(group, local_reports[local_id], remote_reports[remote_key], fixed))
            except Exception as error:
                errors.append(remote_ref)
                print(f'Comparison failed: {remote_ref} ({type(error).__name__}); no alert', flush=True)
                continue
            # Do not repeat the same corrected CVE while that vulnerable image is running,
            # even if several later tags also correct it.
            fresh = set(fixed) - set(next_history.get(local_id, []))
            if fresh:
                updates.append(dict(group, fixed={cve: fixed[cve] for cve in sorted(fresh)}))
                next_history[local_id] = sorted(set(next_history.get(local_id, [])) | fresh)
        if updates and os.environ.get('SECURITY_AUTO_UPDATE') == 'on':
            print('Verified updates ready for the host auto-updater', flush=True)
        elif updates:
            notify(digest(updates))
            print(f'Security update digest delivered: {len(updates)} image updates', flush=True)
        else:
            print('No new verified security updates; no Telegram notification', flush=True)
        atomic_json(history_path, next_history)
        atomic_json(state / 'last-status.json', {
            'time': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'ok': not errors, 'failed_images': errors, 'images': len(images),
            'candidates': len(groups), 'security_updates': len(updates),
        })
        return 1 if errors else 0


def main():
    state = Path(os.environ.get('STATE_DIR', '/state'))
    if len(sys.argv) > 1 and sys.argv[1] == 'schedule':
        state.mkdir(parents=True, exist_ok=True)
        (state / 'tmp').mkdir(exist_ok=True)
        if os.environ.get('SECURITY_AUTO_UPDATE') == 'on':
            print('Automatic mode: scans are orchestrated by the host security-update timer', flush=True)
            while True:
                signal.pause()
        schedule = os.environ.get('SECURITY_SCAN_CRON', '0 6 * * *')
        # Cron is configuration, not arbitrary shell commands.
        if len(schedule.split()) != 5 or any(c not in '0123456789 */,-' for c in schedule):
            raise ValueError('SECURITY_SCAN_CRON must be a five-field cron expression')
        crontab = state / 'crontab'
        crontab.write_text(f'{schedule} python3 /app/main.py run\n')
        subprocess.run(['supercronic', '-test', str(crontab)], check=True)
        print(f'Security scans scheduled: {schedule} ({os.environ.get("TZ", "UTC")})', flush=True)
        os.execvp('supercronic', ['supercronic', str(crontab)])
    if len(sys.argv) > 1 and sys.argv[1] != 'run':
        raise ValueError('Usage: main.py schedule|run')
    return run(state)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        # HTTP exceptions may contain the bot token: never print their message/traceback.
        print(f'Security monitor failed ({type(error).__name__}); inspect scan status/configuration', file=sys.stderr)
        if not isinstance(error, BlockingIOError):
            state = Path(os.environ.get('STATE_DIR', '/state'))
            if state.is_dir():
                atomic_json(state / 'last-status.json', {
                    'time': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    'ok': False, 'error_type': type(error).__name__,
                })
        sys.exit(1)
