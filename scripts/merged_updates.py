#!/usr/bin/env python3
"""Follow CI-approved Template releases independently on each execution host."""
import argparse
import copy
import datetime
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import subprocess
import sys
import time
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'stacks/monitoring/security-monitor'))
import updater  # noqa: E402


def version(tag):
    return tuple(map(int, tag[1:].split('.')))


def stable_releases(items):
    return sorted({r['tag_name'] for r in items if not r['draft'] and not r['prerelease']
                   and re.fullmatch(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', r['tag_name'])}, key=version)


def file_hash(path):
    digest = hashlib.sha256()
    if path.is_file():
        digest.update(path.read_bytes())
    elif path.is_dir():
        for item in sorted(path.rglob('*')):
            if '.git' not in item.parts and '__pycache__' not in item.parts and item.is_file():
                digest.update(str(item.relative_to(path)).encode())
                digest.update(item.read_bytes())
    return digest.hexdigest()


def signatures(model, root, profiles):
    result = {}
    for name, service in model['services'].items():
        if service.get('profiles') and not set(service['profiles']) & profiles:
            continue
        if service.get('restart', 'no') == 'no':
            continue  # One-shot Wiring is not a running app.
        definition = copy.deepcopy(service)
        code = {}
        build = service.get('build')
        if build:
            context = Path(build['context'])
            if not context.resolve().is_relative_to(root.resolve()):
                raise RuntimeError('Build context outside Template checkout')
            code[str(context)] = file_hash(context)
        for mount in service.get('volumes', []):
            source = Path(mount.get('source', '/'))
            if mount.get('type') == 'bind' and mount.get('read_only') and source.resolve().is_relative_to(root.resolve()):
                code[str(source)] = file_hash(source)
        result[name] = {'definition': definition, 'code': code}
    return result


def changed_services(before, after):
    changed = {name for name in before.keys() | after.keys() if before.get(name) != after.get(name)}
    # A new VPN namespace needs all its consumers recreated against its new ID.
    while True:
        expanded = changed | {name for name, value in after.items()
                              if value['definition'].get('network_mode', '').removeprefix('service:') in changed}
        if expanded == changed:
            return sorted(changed)
        changed = expanded


class Deployment:
    def __init__(self, root, apps=False):
        self.root = Path(root).resolve()
        self.apps = apps
        self.scope = 'apps-server' if apps else 'instance'
        self.project = self.root / 'apps-server' if apps else self.root
        spec = importlib.util.spec_from_file_location('deployment_env', self.root / 'scripts/env_contract.py')
        self.contract = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.contract)
        self.env = self.contract.values(self.project / '.env', self.scope, file_only=True)
        configured = Path(self.env['APPDATA_ROOT'])
        if not configured.is_absolute() or configured.resolve() == Path('/'):
            raise RuntimeError('APPDATA_ROOT must be an absolute application directory')
        self.appdata = configured.resolve()
        self.state = self.appdata / 'security-monitor' / 'merged-releases'
        self.state.mkdir(parents=True, mode=0o700, exist_ok=True)
        self.journal = self.state / 'pending.json'
        self.installed = self.state / 'installed.json'
        self.host = updater.Host(self.project, self.appdata / 'security-monitor', self.appdata)
        self.host.compose = self.compose
        self.unit = 'media-stack-apps-merged-updates' if apps else 'media-stack-merged-updates'
        self.timeout = 300

    def git(self, *args):
        argv = ['git', '-c', 'safe.directory=' + str(self.root), *args]
        owner = pwd.getpwuid(self.root.stat().st_uid)
        if os.geteuid() == 0 and owner.pw_uid != 0:
            argv = ['runuser', '-u', owner.pw_name, '--', 'env', 'HOME=' + owner.pw_dir, *argv]
        return updater.command(argv, cwd=self.root)

    def compose_environment(self):
        # A timer's environment must never override the Operator's file.
        clean = os.environ.copy()
        for name in set(self.contract.CATALOG) | set(self.contract.file_names(self.project / '.env')) | self.contract.interpolation_names(self.project / '.env'):
            clean.pop(name, None)
        for name in ('COMPOSE_FILE', 'COMPOSE_PROFILES', 'COMPOSE_PROJECT_NAME', 'COMPOSE_ENV_FILES', 'COMPOSE_DISABLE_ENV_FILE'):
            clean.pop(name, None)
        return clean

    def compose(self, *args):
        return updater.command(['docker', 'compose', *args], cwd=self.project, env=self.compose_environment())

    def model(self):
        return json.loads(self.compose('config', '--format', 'json'))

    def signature(self):
        model = self.model()
        for service in model['services'].values():
            if service.get('image'):
                try:
                    service['image'] = self.host.inspect(service['image'])['Id']
                except RuntimeError:
                    pass  # A new tag will be resolved after the selective pull/build.
        profiles = {p.strip() for p in self.env.get('COMPOSE_PROFILES', '').split(',')}
        return signatures(model, self.root, profiles)

    def releases(self):
        result = []
        for page in range(1, 100):
            url = f'https://api.github.com/repos/alberba/media-stack/releases?per_page=100&page={page}'
            with urllib.request.urlopen(url, timeout=30) as response:
                items = json.load(response)
            result += stable_releases(items)
            if len(items) < 100:
                return sorted(set(result), key=version)
        raise RuntimeError('Too many release pages')

    def notify(self, message):
        # Persistent outbox, same notification transport as verified security updates.
        path = self.state / 'notifications.json'
        queue = json.loads(path.read_text()) if path.exists() else []
        if message:
            queue.append((self.env.get('MONITOR_NAME') or self.scope) + ' — ' + message)
            updater.atomic_json(path, queue)
        while queue:
            try:
                updater.notify(queue[0])
            except Exception:
                print('Notification pending; deployment state is retained')
                return
            queue.pop(0)
            updater.atomic_json(path, queue)

    def initialize(self, persist=True):
        tags = self.releases()
        if not tags:
            raise RuntimeError('No published release baseline')
        if persist and not self.installed.exists():
            updater.atomic_json(self.installed, {'release': tags[-1], 'commit': self.git('rev-parse', 'HEAD').strip(),
                                                 'bootstrap': True})
        return tags

    def manifest(self, tag):
        try:
            data = json.loads(self.git('show', f'{tag}:docs/releases/{tag}.deploy.json'))
        except (RuntimeError, ValueError):
            return None
        if data.get('schema') != 1 or data.get('approved_merge') is not True:
            return None
        if self.scope not in data.get('roles', []):
            return None
        source = data.get('source_commit', '')
        if not re.fullmatch('[a-f0-9]{40}', source):
            raise RuntimeError('Invalid release source identity')
        self.git('merge-base', '--is-ancestor', tag, 'refs/remotes/origin/main')
        self.git('merge-base', '--is-ancestor', source, tag)
        return data

    def restore(self, transaction):
        # Stop possible migrated processes before touching either code or App data.
        for name in transaction['changed'] if transaction.get('apps_stopped') else []:
            ids = self.compose('ps', '-a', '-q', name).split()
            if ids:
                updater.command(['docker', 'stop', *ids])
        if transaction.get('data_may_have_changed'):
            for snapshot in transaction['snapshots']:
                source, archive = Path(snapshot['source']), Path(snapshot['archive'])
                if not source.resolve().is_relative_to(self.appdata) or source == self.appdata:
                    raise RuntimeError('Unsafe restore path')
                if not archive.resolve().is_relative_to(self.state) or not archive.is_file():
                    raise RuntimeError('Missing release snapshot')
                if source.exists():
                    source.rename(archive.parent / ('failed-' + uuid.uuid4().hex))
                source.mkdir(parents=True, exist_ok=True)
                updater.command(['tar', '--acls', '--xattrs', '--numeric-owner', '-xpf', str(archive), '-C', str(source)])
        for image in transaction.get('images', {}).values():
            ref = image['reference']
            if '@' not in ref and not ref.startswith('sha256:'):
                updater.command(['docker', 'tag', image['id'], ref])
        self.git('checkout', '--detach', transaction['previous_commit'])
        shutil.copy2(transaction['environment'], self.project / '.env')
        if transaction['pins'] is None:
            self.host.pins.unlink(missing_ok=True)
        else:
            updater.atomic_json(self.host.pins, transaction['pins'])
        if transaction['changed'] and transaction.get('apps_stopped'):
            self.compose('up', '-d', '--no-deps', '--no-build', '--pull', 'never', '--force-recreate', *transaction['changed'])
            self.check(transaction['changed'])
        updater.atomic_json(self.installed, transaction['previous_installed'])
        transaction['status'] = 'rolled_back'
        updater.atomic_json(Path(transaction['folder']) / 'result.json', transaction)
        self.journal.unlink(missing_ok=True)

    def check(self, services):
        deadline = time.monotonic() + self.timeout
        for name in services:
            while True:
                inspect = self.host.container(name)
                state = inspect['State']
                if state.get('Running') and not state.get('OOMKilled'):
                    if state.get('Health', {}).get('Status') == 'healthy':
                        break
                    if name == 'security-monitor':
                        try:
                            self.compose('exec', '-T', name, 'python3', '/app/healthcheck.py')
                            break
                        except RuntimeError:
                            pass
                if time.monotonic() >= deadline:
                    raise RuntimeError('Release healthcheck failed: ' + name)
                time.sleep(2)
        if not self.apps:
            deadline = time.monotonic() + self.timeout
            while True:
                try:
                    updater.command(['bash', str(self.root / 'scripts/verify.sh')], cwd=self.root,
                                    env=self.compose_environment())
                    break
                except RuntimeError:
                    if time.monotonic() >= deadline:
                        raise RuntimeError('Instance verification failed after release') from None
                    time.sleep(2)
        elif 'seerr' in services:
            # Startup alone is not enough: test its persisted database and NAS APIs.
            settings = json.loads((self.appdata / 'seerr/settings.json').read_text())
            address = self.env.get('APPS_BIND_IP') or '127.0.0.1'
            if address == '0.0.0.0':
                address = '127.0.0.1'
            headers = {'X-Api-Key': settings['main']['apiKey'], 'Content-Type': 'application/json'}
            checks = [('request?take=1', None), ('settings/jellyfin/users', None)]
            for kind in ('radarr', 'sonarr'):
                checks += [('settings/' + kind + '/test', v) for v in settings.get(kind, [])]
            deadline = time.monotonic() + self.timeout
            while True:
                try:
                    for path, body in checks:
                        data = json.dumps(body).encode() if body is not None else None
                        req = urllib.request.Request(f'http://{address}:5055/api/v1/{path}', headers=headers, data=data)
                        with urllib.request.urlopen(req, timeout=20) as response:
                            json.load(response)
                    break
                except (OSError, ValueError):
                    if time.monotonic() >= deadline:
                        raise RuntimeError('Seerr database or NAS integration check failed') from None
                    time.sleep(2)

    def apply(self, tag):
        before = self.signature()
        previous = json.loads(self.installed.read_text())
        folder = self.state / uuid.uuid4().hex
        folder.mkdir(mode=0o700)
        shutil.copy2(self.project / '.env', folder / 'environment')
        transaction = {'release': tag, 'previous_commit': self.git('rev-parse', 'HEAD').strip(),
                       'previous_installed': previous, 'folder': str(folder), 'environment': str(folder / 'environment'),
                       'pins': json.loads(self.host.pins.read_text()) if self.host.pins.exists() else None,
                       'changed': [], 'snapshots': [], 'status': 'preparing'}
        updater.atomic_json(self.journal, transaction)
        try:
            self.git('checkout', '--detach', tag)
            if not (self.project / 'compose.yaml').is_file():
                raise RuntimeError('Release does not support this host role')
            self.contract.CATALOG = json.loads((self.root / 'env/catalog.json').read_text())
            if not self.contract.validate(self.project / '.env', self.scope):
                raise RuntimeError('Release needs environment settings')
            updater.release_pins(self.project)
            after = self.signature()
            changed = changed_services(before, after)
            if set(after) != set(before):
                raise RuntimeError('Service topology change needs initial setup')
            transaction['changed'] = changed
            updater.atomic_json(self.journal, transaction)
            if changed:
                live = {name: self.host.container(name) for name in changed}
                transaction['images'] = {name: {'id': c['Image'], 'reference': c['Config']['Image']} for name, c in live.items()}
                updater.atomic_json(self.journal, transaction)
                # Fetch/build first: failure here leaves the running apps untouched.
                self.compose('pull', '--ignore-buildable', *changed)
                self.compose('build', *changed)
                # Equivalent tags/digest pins must not restart unchanged applications.
                changed = changed_services(before, self.signature())
                transaction['changed'] = changed
                updater.atomic_json(self.journal, transaction)
            if changed:
                transaction['apps_stopped'] = True
                updater.atomic_json(self.journal, transaction)
                self.compose('stop', *changed)
                sources = set()
                for name in changed:
                    container = live[name]
                    if name == 'security-monitor':
                        continue  # Own transaction/journal state must never restore over itself.
                    # Backup legitimately mounts all App data; snapshot only its own config.
                    if name == 'backup' and container['Config'].get('Entrypoint') == ['media-backup']:
                        container = copy.deepcopy(container)
                        container['Mounts'] = [m for m in container['Mounts'] if Path(m['Source']).resolve() != self.appdata]
                    sources.update(self.host.appdata_sources(container))
                for index, source in enumerate(sorted(sources)):
                    archive = folder / f'appdata-{index}.tar'
                    updater.command(['tar', '--acls', '--xattrs', '--numeric-owner', '-cpf', str(archive), '-C', str(source), '.'])
                    archive.chmod(0o600)
                    transaction['snapshots'].append({'source': str(source), 'archive': str(archive)})
                    updater.atomic_json(self.journal, transaction)
                transaction['data_may_have_changed'] = True
                transaction['status'] = 'deploying'
                updater.atomic_json(self.journal, transaction)
                self.compose('up', '-d', '--no-deps', '--no-build', '--pull', 'never', '--force-recreate', *changed)
                self.check(changed)
            updater.atomic_json(self.installed, {'release': tag, 'commit': self.git('rev-parse', 'HEAD').strip()})
            transaction['status'] = 'updated'
            updater.atomic_json(folder / 'result.json', transaction)
            self.journal.unlink()
            if changed:
                self.notify(f'{tag} aplicada y verificada; servicios: ' + ', '.join(changed))
            print(tag + ': ' + (', '.join(changed) or 'no affected services'))
        except Exception:
            self.restore(transaction)
            self.notify(f'{tag} falló; restaurados código, imágenes y datos anteriores')
            raise

    def configuration_key(self):
        digest = hashlib.sha256((self.project / '.env').read_bytes())
        current = self.contract.values(self.project / '.env', self.scope, file_only=True)
        for name in current.get('COMPOSE_FILE', '').split(':'):
            path = Path(name)
            if path.is_absolute() and path.is_file() and path.resolve() != self.host.pins.resolve():
                digest.update(file_hash(path).encode())
        return digest.hexdigest()

    def run(self, dry=False):
        # Deployment and security updates use the same lock and backup exclusion.
        with (self.host.state / 'update.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with (self.appdata / 'backup' / 'run.lock').open('a') if (self.appdata / 'backup').is_dir() else open(os.devnull) as backup:
                if backup.name != os.devnull:
                    fcntl.flock(backup, fcntl.LOCK_EX | fcntl.LOCK_NB)
                if self.host.pending.exists():
                    raise RuntimeError('Security update recovery is pending')
                if self.journal.exists():
                    if dry:
                        raise RuntimeError('Release recovery is pending')
                    self.restore(json.loads(self.journal.read_text()))
                if self.git('status', '--porcelain').strip():
                    raise RuntimeError('Template checkout has uncommitted changes')
                tags = self.initialize(persist=not dry)
                baseline = json.loads(self.installed.read_text())['release'] if self.installed.exists() else tags[-1]
                self.git('fetch', '--quiet', 'https://github.com/alberba/media-stack.git', '--tags', '+main:refs/remotes/origin/main')
                for tag in tags:
                    if version(tag) <= version(baseline):
                        continue
                    if not self.manifest(tag):
                        print(tag + ': awaiting CI-approved deployment manifest')
                        continue
                    print('Merged release ready: ' + tag)
                    if not dry:
                        failed = self.state / 'failed-release.json'
                        attempted = json.loads(failed.read_text()) if failed.exists() else {}
                        if attempted.get('release') == tag and attempted.get('configuration') == self.configuration_key():
                            print(tag + ': previous deployment failed; waiting for a newer release')
                            continue
                        try:
                            self.apply(tag)
                        except Exception:
                            updater.atomic_json(failed, {'release': tag, 'configuration': self.configuration_key()})
                            raise
                if not dry:
                    self.notify(None)

    def install(self):
        if os.geteuid() != 0:
            raise RuntimeError('Installation requires root')
        if self.git('status', '--porcelain').strip():
            raise RuntimeError('Template checkout has uncommitted changes')
        self.initialize()  # Never roll an ahead-of-release bootstrap back to an old tag.
        zone = self.env['TZ']
        if not re.fullmatch(r'[A-Za-z0-9_+./-]+', zone):
            raise RuntimeError('Invalid timezone')
        script = str(self.root / 'scripts/upgrade.sh').replace('%', '%%').replace(chr(92), chr(92)*2).replace(chr(34), chr(92)+chr(34))
        role = ' --apps-server' if self.apps else ''
        service = f'''[Unit]
Description=Deploy merged media-stack releases ({self.scope})
After=docker.service network-online.target
Requires=docker.service
[Service]
Type=oneshot
ExecStart=/usr/bin/bash "{script}" --follow-merges{role}
TimeoutStartSec=4h
UMask=0077
'''
        timer = f'''[Unit]
Description=Check CI-approved media-stack releases every five minutes ({self.scope})
[Timer]
OnBootSec=3min
OnUnitInactiveSec=5min
Persistent=true
[Install]
WantedBy=timers.target
'''
        system = Path('/etc/systemd/system')
        (system / (self.unit + '.service')).write_text(service)
        (system / (self.unit + '.timer')).write_text(timer)
        updater.command(['systemd-analyze', 'verify', str(system / (self.unit + '.service')), str(system / (self.unit + '.timer'))])
        updater.command(['systemctl', 'daemon-reload'])
        if not self.apps and (system / 'media-stack-upgrade.timer').exists():
            updater.command(['systemctl', 'disable', '--now', 'media-stack-upgrade.timer'])
        updater.command(['systemctl', 'enable', '--now', self.unit + '.timer'])
        print('Merged releases enabled: ' + self.unit + '.timer')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--follow-merges', action='store_true', required=True)
    parser.add_argument('--apps-server', action='store_true')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('mode', nargs='?', default='run', choices=('run', 'install'))
    args = parser.parse_args()
    deployment = Deployment(ROOT, args.apps_server)
    if args.mode == 'install':
        deployment.install()
    else:
        deployment.run(args.dry_run)


if __name__ == '__main__':
    os.umask(0o077)
    try:
        main()
    except Exception as error:
        # Docker/Compose responses and settings can contain credentials.
        detail = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print('Merged release deployment failed: ' + detail + '; recovery state retained', file=sys.stderr)
        sys.exit(1)
