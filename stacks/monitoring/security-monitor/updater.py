"""Host-side Compose updates with persistent image pins and App data rollback."""
import copy
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid

from main import atomic_json


def command(argv, *, cwd=None, stdin=None, timeout=1200):
    result = subprocess.run(argv, cwd=cwd, input=stdin, text=True, capture_output=True,
                            timeout=timeout)
    if result.returncode:
        # Compose config/HTTP errors can contain credentials. Never echo their output.
        raise RuntimeError('Command failed: ' + Path(argv[0]).name)
    return result.stdout


def stable_major(reference):
    tag = reference.split('@', 1)[0].rsplit(':', 1)[-1]
    match = re.fullmatch(r'v?(\d+)\.\d+\.\d+(?:\.\d+)?(?:-ls\d+|_v[\d.]+(?:-ls\d+)?)?', tag)
    return int(match[1]) if match else None


def manual_reason(plan, now=None):
    if not plan.get('fixed'):
        return 'no verified security correction'
    local, remote = stable_major(plan['local_ref']), stable_major(plan['remote_ref'])
    if local is None or remote is None:
        return 'unknown or prerelease version'
    if local != remote or plan.get('semver_diff') == 'major':
        return 'major version: manual review'
    if plan.get('semver_diff') not in ('minor', 'patch', 'prerelease', 'build'):
        return 'unclassified version change'
    if plan.get('new_severe'):
        return 'candidate introduces or escalates HIGH/CRITICAL CVEs'
    if not re.fullmatch(r'sha256:[a-f0-9]{64}', plan.get('candidate_id') or ''):
        return 'candidate image identity missing'
    if not re.fullmatch(re.escape(plan['remote_ref']) + r'@sha256:[a-f0-9]{64}', plan.get('pinned_ref') or ''):
        return 'candidate registry digest missing'
    verified = datetime.datetime.fromisoformat(plan['verified_at'])
    now = now or datetime.datetime.now(datetime.timezone.utc)
    if not datetime.timedelta(0) <= now - verified <= datetime.timedelta(hours=6):
        return 'stale comparison'
    return None


class Host:
    def __init__(self, repo, state, appdata, *, timeout=300, stable=30):
        self.repo, self.state, self.appdata = Path(repo), Path(state), Path(appdata).resolve()
        self.pins = self.state / 'images.compose.json'
        self.pending = self.state / 'active-update.json'
        self.timeout, self.stable = timeout, stable
        self.transactions = self.state / 'transactions'
        self.transactions.mkdir(mode=0o700, parents=True, exist_ok=True)

    def compose(self, *args):
        return command(['docker', 'compose', *args], cwd=self.repo)

    def inspect(self, target):
        return json.loads(command(['docker', 'inspect', target]))[0]

    def container(self, service):
        cid = self.compose('ps', '-a', '-q', service).strip()
        if not cid or '\n' in cid:
            raise RuntimeError('Expected one container per service')
        return self.inspect(cid)

    def live(self):
        ids = command(['docker', 'ps', '-q']).split()
        return json.loads(command(['docker', 'inspect', *ids])) if ids else []

    def eligibility(self, service, plan):
        container = self.container(service)
        labels = container['Config'].get('Labels', {})
        model = json.loads(self.compose('config', '--format', 'json'))
        if labels.get('com.docker.compose.project') != model['name']:
            return 'container belongs to another project'
        if Path(labels.get('com.docker.compose.project.working_dir', '/')).resolve() != self.repo.resolve():
            return 'container belongs to another Template checkout'
        if container['Image'] != plan['local_id']:
            return 'running image changed since scan'
        definition = model['services'][service]
        if definition.get('build') or service == 'security-monitor':
            return 'locally built image'
        if container['State'].get('Health', {}).get('Status') != 'healthy':
            return 'missing healthcheck or current app is unhealthy'
        env = dict(item.split('=', 1) for item in container['Config']['Env'])
        if any(env.get(key) != str(value) for key, value in definition.get('environment', {}).items()):
            return 'environment differs from the running app'
        actual = {m['Destination']: m['Source'] for m in container['Mounts']}
        if any(actual.get(m['target']) != m.get('source') for m in definition.get('volumes', [])):
            return 'volume configuration differs from the running app'
        for other in self.live():
            mode = other['HostConfig'].get('NetworkMode', '')
            if mode == 'container:' + container['Id'] or mode == 'container:' + container['Name'].lstrip('/'):
                return 'other containers depend on this network namespace'
            if other['Id'] == container['Id']:
                continue
            other_labels = other['Config'].get('Labels', {})
            if (other_labels.get('com.docker.compose.service') == 'backup' and
                    other_labels.get('com.docker.compose.project') == model['name'] and
                    other['Config'].get('Entrypoint') == ['media-backup']):
                # apply() holds Backup's run.lock, preventing concurrent backup runs.
                continue
            for source in self.appdata_sources(container):
                # Broad host mounts in operator tools are not dedicated App data writers.
                if any(m['RW'] and Path(m['Source']).resolve().is_relative_to(self.appdata) and
                       (Path(m['Source']).resolve() == source or
                                   source.is_relative_to(Path(m['Source']).resolve()) or
                                   Path(m['Source']).resolve().is_relative_to(source))
                       for m in other['Mounts']):
                    return 'App data is shared with another running container'
        if any(m['RW'] and m['Type'] != 'bind' for m in container['Mounts']):
            return 'App data in a named volume requires manual review'
        self.appdata_sources(container)  # Validate snapshot paths even without other containers.
        return None

    def appdata_sources(self, container):
        sources = []
        for mount in container['Mounts']:
            source = Path(mount['Source']).resolve()
            if not mount['RW'] or not source.is_relative_to(self.appdata):
                continue
            if source == self.appdata or source == self.state.resolve() or self.state.resolve().is_relative_to(source):
                raise RuntimeError('Unsafe App data snapshot root')
            if not source.is_dir() or source.stat().st_dev != self.transactions.stat().st_dev:
                raise RuntimeError('App data snapshot needs a directory on the state filesystem')
            sources.append(source)
        return sorted(set(sources))

    def healthy(self, service, image_id):
        deadline, since = time.monotonic() + self.timeout, None
        while time.monotonic() < deadline:
            try:
                container = self.container(service)
            except RuntimeError:
                return False
            state = container['State']
            if container['Image'] != image_id or not state.get('Running') or state.get('OOMKilled'):
                return False
            status = state.get('Health', {}).get('Status')
            if status in ('unhealthy', None):
                return False
            if status == 'healthy':
                since = since or time.monotonic()
                if time.monotonic() - since >= self.stable:
                    return True
            else:
                since = None
            time.sleep(min(2, max(0.1, self.stable / 2)))
        return False

    def old_pin(self, container):
        ref = container['Config']['Image'].split('@', 1)[0]
        if '@' in container['Config']['Image']:
            return container['Config']['Image']
        image = self.inspect(container['Image'])
        repo = ref.rsplit(':', 1)[0]
        for digest in image.get('RepoDigests', []):
            if digest.split('@', 1)[0] == repo:
                return ref + '@' + digest.split('@', 1)[1]
        # Old local image is retained throughout the transaction; no prune is performed.
        return container['Image']

    def save_pending(self, transaction):
        atomic_json(self.pending, transaction)

    def archive(self, transaction):
        atomic_json(self.transactions / (transaction['id'] + '.json'), transaction)
        self.pending.unlink(missing_ok=True)

    def rollback(self, transaction):
        service = transaction['service']
        self.compose('stop', service)
        if transaction.get('data_may_have_changed'):
            for index, snapshot in enumerate(transaction['snapshots']):
                source, archive = Path(snapshot['source']), Path(snapshot['archive'])
                if not source.resolve().is_relative_to(self.appdata) or source.resolve() == self.appdata:
                    raise RuntimeError('Rollback path outside App data')
                if not archive.is_file() or not archive.resolve().is_relative_to(self.transactions.resolve()):
                    raise RuntimeError('Rollback snapshot missing')
                if source.exists():
                    failed = archive.parent / f'failed-data-{index}-{uuid.uuid4().hex}'
                    source.rename(failed)  # Preserve failed App data for inspection.
                source.mkdir(parents=True, exist_ok=True)
                command(['tar', '--acls', '--xattrs', '--numeric-owner', '-xpf', str(archive), '-C', str(source)])
        pins = copy.deepcopy(transaction['before_pins'])
        pins.setdefault('services', {}).setdefault(service, {})['image'] = transaction['old_pin']
        atomic_json(self.pins, pins)
        self.compose('up', '-d', '--no-deps', '--no-build', '--pull', 'never', '--force-recreate', service)
        if not self.healthy(service, transaction['old_id']):
            raise RuntimeError('Previous image failed recovery healthcheck')
        transaction['status'] = 'rolled_back'
        self.archive(transaction)
        return 'rollback: imagen y datos anteriores restaurados'

    def apply(self, service, plan):
        backup = self.appdata / 'backup'
        if backup.is_dir():
            with (backup / 'run.lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self._apply(service, plan)
        return self._apply(service, plan)

    def _apply(self, service, plan):
        container = self.container(service)
        if container['Image'] != plan['local_id']:
            raise RuntimeError('Running image changed before update')
        candidate = plan['pinned_ref']
        command(['docker', 'pull', '--platform', plan['platform'], candidate])
        image = self.inspect(candidate)
        if image['Id'] != plan['candidate_id']:
            raise RuntimeError('Pulled image differs from verified candidate')
        model = json.loads(self.compose('config', '--format', 'json'))['services'][service]
        if not model.get('healthcheck') and not image['Config'].get('Healthcheck'):
            raise RuntimeError('Candidate has no healthcheck')
        if self.container(service)['Id'] != container['Id']:
            raise RuntimeError('Container changed while the candidate was being pulled')
        transaction = {'id': uuid.uuid4().hex, 'service': service, 'old_id': container['Image'],
            'old_pin': self.old_pin(container), 'candidate_id': image['Id'], 'candidate_ref': candidate,
            'before_pins': json.loads(self.pins.read_text()), 'snapshots': [], 'status': 'prepared'}
        folder = self.transactions / transaction['id']
        folder.mkdir(mode=0o700)
        self.save_pending(transaction)
        try:
            self.compose('stop', service)
            for index, source in enumerate(self.appdata_sources(container)):
                archive = folder / f'appdata-{index}.tar'
                command(['tar', '--acls', '--xattrs', '--numeric-owner', '-cpf', str(archive), '-C', str(source), '.'])
                archive.chmod(0o600)
                transaction['snapshots'].append({'source': str(source), 'archive': str(archive)})
                self.save_pending(transaction)
            transaction['data_may_have_changed'] = True
            transaction['status'] = 'deploying'
            self.save_pending(transaction)
            pins = copy.deepcopy(transaction['before_pins'])
            pins.setdefault('services', {}).setdefault(service, {})['image'] = candidate
            atomic_json(self.pins, pins)
            self.compose('up', '-d', '--no-deps', '--no-build', '--pull', 'never', '--force-recreate', service)
            if not self.healthy(service, image['Id']):
                raise RuntimeError('Candidate failed healthcheck')
            if service == 'wud':
                command(['docker', 'exec', 'security-monitor', 'python3', '-c',
                         'import sys; sys.path.insert(0,"/app"); import main; main.wud_containers()'])
            transaction['status'] = 'updated'
            self.archive(transaction)
            return 'actualizada; comprobación de salud correcta'
        except Exception:
            try:
                return self.rollback(transaction)
            except Exception:
                transaction['status'] = 'rollback_failed'
                self.save_pending(transaction)
                return 'ERROR: rollback incompleto; requiere intervención manual'


def setting(repo, name):
    return command(['python3', str(repo / 'scripts/env_contract.py'), 'get',
                    '--file', str(repo / '.env'), '--name', name], cwd=repo)


def set_setting(repo, name, value):
    command(['python3', str(repo / 'scripts/env_contract.py'), 'set',
             '--file', str(repo / '.env'), '--name', name], cwd=repo, stdin=value)


def notify(message):
    command(['docker', 'exec', '-i', 'security-monitor', 'python3', '-c',
             'import sys; sys.path.insert(0,"/app"); import main; main.telegram(sys.stdin.read())'], stdin=message)


def flush_notifications(state):
    path = state / 'update-notifications.json'
    queued = json.loads(path.read_text()) if path.exists() else []
    while queued:
        notify(queued[0])
        queued.pop(0)
        atomic_json(path, queued)


def run(repo, *, scan=True):
    if setting(repo, 'SECURITY_AUTO_UPDATE') != 'on':
        print('Security auto-updates are off')
        return 0
    appdata = Path(setting(repo, 'APPDATA_ROOT')).resolve()
    state = appdata / 'security-monitor'
    host = Host(repo, state, appdata)
    with (state / 'update.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        flush_notifications(state)
        if host.pending.exists():
            transaction = json.loads(host.pending.read_text())
            committed = host.transactions / (transaction['id'] + '.json')
            if committed.exists() and json.loads(committed.read_text()).get('status') == 'updated':
                host.pending.unlink()
            else:
                host.rollback(transaction)
                notify('NAS Monitor — recuperación completada: ' + transaction['service'])
        if scan:
            # A failed comparison batch must not trigger automatic mutations.
            host.compose('exec', '-T', 'security-monitor', 'python3', '/app/main.py', 'run')
        outcomes = []
        attempted_path = state / 'attempted-updates.json'
        attempted = json.loads(attempted_path.read_text()) if attempted_path.exists() else {}
        for path in sorted((state / 'comparisons').glob('*.json')):
            plan = json.loads(path.read_text())
            if not plan.get('fixed'):
                continue
            reason = manual_reason(plan)
            for name in plan['names']:
                try:
                    container = host.inspect(name)
                except RuntimeError:
                    continue
                labels = container['Config'].get('Labels', {})
                service = labels.get('com.docker.compose.service')
                if not service or container['Image'] != plan['local_id']:
                    continue
                if Path(labels.get('com.docker.compose.project.working_dir', '/')).resolve() != repo.resolve():
                    continue
                key = hashlib.sha256((service + plan.get('candidate_id', '')).encode()).hexdigest()
                if key in attempted:
                    continue
                try:
                    decision = reason or host.eligibility(service, plan)
                    if decision:
                        result = 'manual: ' + decision
                    else:
                        result = host.apply(service, plan)
                except Exception as error:
                    result = 'manual: pre-update check failed (' + type(error).__name__ + ')'
                attempted[key] = {'service': service, 'candidate': plan.get('pinned_ref'), 'result': result}
                atomic_json(attempted_path, attempted)
                outcomes.append(f'{service} → {plan["remote_ref"].rsplit(":", 1)[-1]}: {result}')
                print(outcomes[-1], flush=True)
                if host.pending.exists():
                    break
            if host.pending.exists():
                break
        if outcomes:
            outbox = state / 'update-notifications.json'
            queued = json.loads(outbox.read_text()) if outbox.exists() else []
            queued.append('NAS Monitor — autoactualización de seguridad\n\n' + '\n'.join(outcomes))
            atomic_json(outbox, queued)
            flush_notifications(state)
        return 1 if host.pending.exists() or any(': rollback:' in line or ': ERROR:' in line for line in outcomes) else 0


def install(repo):
    if os.geteuid() != 0:
        raise RuntimeError('Installation requires root')
    if not Path('/run/systemd/system').exists():
        raise RuntimeError('Host installation requires systemd')
    catalog = json.loads((repo / 'env/catalog.json').read_text())
    cron_value = setting(repo, 'SECURITY_SCAN_CRON') or catalog['SECURITY_SCAN_CRON']['scopes']['instance']['default']
    cron = cron_value.split()
    if len(cron) != 5 or cron[2:] != ['*', '*', '*'] or not cron[0].isdigit() or not cron[1].isdigit():
        raise RuntimeError('Auto-update timer requires a daily SECURITY_SCAN_CRON')
    minute, hour = int(cron[0]), int(cron[1])
    if minute > 59 or hour > 23:
        raise RuntimeError('Invalid daily scan time')
    zone = setting(repo, 'TZ')
    if not re.fullmatch(r'[A-Za-z0-9_+./-]+', zone):
        raise RuntimeError('Invalid timezone')
    state = Path(setting(repo, 'APPDATA_ROOT')).resolve() / 'security-monitor'
    state.mkdir(parents=True, exist_ok=True)
    pins = state / 'images.compose.json'
    if not pins.exists():
        atomic_json(pins, {'services': {}})
    compose_files = setting(repo, 'COMPOSE_FILE')
    if not compose_files:
        compose_files = 'compose.yaml'
        if (repo / 'compose.override.yaml').exists():
            compose_files += ':compose.override.yaml'
    paths = compose_files.split(':')
    if str(pins) not in paths:
        paths.append(str(pins))
    set_setting(repo, 'COMPOSE_FILE', ':'.join(paths))
    command(['docker', 'compose', 'config', '--quiet'], cwd=repo)
    path = str(repo / 'scripts/security-update.sh').replace('%', '%%').replace('\\', '\\\\').replace('"', '\\"')
    service = '[Unit]\nDescription=Verified media-stack security updates\nAfter=docker.service network-online.target\nRequires=docker.service\nStartLimitIntervalSec=1h\nStartLimitBurst=3\n\n[Service]\nType=oneshot\n'
    service += f'ExecStart=/usr/bin/bash "{path}" run\nTimeoutStartSec=4h\nUMask=0077\nRestart=on-failure\nRestartSec=5min\n\n[Install]\nWantedBy=multi-user.target\n'
    timer = '[Unit]\nDescription=Daily verified media-stack security updates\n\n[Timer]\n'
    timer += f'OnCalendar=*-*-* {hour:02d}:{minute:02d}:00 {zone}\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n'
    system = Path('/etc/systemd/system')
    (system / 'media-stack-security-updates.service').write_text(service)
    (system / 'media-stack-security-updates.timer').write_text(timer)
    command(['systemd-analyze', 'verify', str(system / 'media-stack-security-updates.service'),
             str(system / 'media-stack-security-updates.timer')])
    command(['systemctl', 'daemon-reload'])
    previous = setting(repo, 'SECURITY_AUTO_UPDATE')
    try:
        # One host cycle owns scanning and updating. Internal scanner cron stays idle.
        set_setting(repo, 'SECURITY_AUTO_UPDATE', 'on')
        command(['docker', 'compose', 'up', '-d', '--no-deps', 'security-monitor'], cwd=repo)
        command(['systemctl', 'enable', 'media-stack-security-updates.service'])
        command(['systemctl', 'enable', '--now', 'media-stack-security-updates.timer'])
    except Exception:
        set_setting(repo, 'SECURITY_AUTO_UPDATE', previous)
        command(['docker', 'compose', 'up', '-d', '--no-deps', 'security-monitor'], cwd=repo)
        raise
    print(f'Security auto-updates enabled: {hour:02d}:{minute:02d} {zone}; major changes stay manual')


def main():
    repo = Path(__file__).resolve().parents[3]
    mode = sys.argv[1] if len(sys.argv) > 1 else 'run'
    if mode == 'install':
        install(repo)
        return 0
    if mode == 'run':
        return run(repo)
    if mode == 'apply-verified':
        return run(repo, scan=False)
    if mode == 'disable':
        active = command(['systemctl', 'show', 'media-stack-security-updates.service', '-p', 'ActiveState', '--value']).strip()
        if active in ('active', 'activating', 'deactivating'):
            raise RuntimeError('Wait for the current update before disabling its timer')
        command(['systemctl', 'disable', '--now', 'media-stack-security-updates.timer'])
        command(['systemctl', 'disable', 'media-stack-security-updates.service'])
        set_setting(repo, 'SECURITY_AUTO_UPDATE', 'off')
        command(['docker', 'compose', 'up', '-d', '--no-deps', 'security-monitor'], cwd=repo)
        print('Auto-updates disabled; verified security notifications remain enabled')
        return 0
    raise ValueError('Usage: security-update.sh install|run|apply-verified|disable')


if __name__ == '__main__':
    os.umask(0o077)
    try:
        sys.exit(main())
    except Exception as error:
        print('Security updater failed (' + type(error).__name__ + '); state retained for recovery', file=sys.stderr)
        sys.exit(1)
