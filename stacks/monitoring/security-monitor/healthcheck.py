"""Check the scheduler and the most recent completed security scan."""
import datetime
import json
import os
from pathlib import Path


def healthy(state, process, now):
    if b'schedule' not in process and b'supercronic' not in process:
        return False
    status = json.loads((state / 'last-status.json').read_text())
    age = now - datetime.datetime.fromisoformat(status['time'])
    return status.get('ok') is True and datetime.timedelta(0) <= age <= datetime.timedelta(hours=48)


if __name__ == '__main__':
    try:
        ok = healthy(Path(os.environ.get('STATE_DIR', '/state')),
                     Path('/proc/1/cmdline').read_bytes(),
                     datetime.datetime.now(datetime.timezone.utc))
    except (OSError, ValueError, KeyError, TypeError):
        ok = False
    raise SystemExit(0 if ok else 1)
