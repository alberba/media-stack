#!/usr/bin/env bash
# Compare the wizard's advertised providers/types with validation in the pinned image.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="$(awk '/image:.*gluetun:/ { print $2; exit }' "$REPO/stacks/vpn/compose.yaml")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# Invalid settings exit before establishing any VPN connection. NET_ADMIN is needed
# because the image checks iptables before validating its settings.
docker run --rm --cap-add NET_ADMIN -e VPN_SERVICE_PROVIDER=invalid "$IMAGE" > "$WORK/providers" 2>&1 || true
docker run --rm --cap-add NET_ADMIN -e VPN_SERVICE_PROVIDER=cyberghost -e VPN_TYPE=wireguard "$IMAGE" > "$WORK/wireguard" 2>&1 || true
python3 - "$REPO/scripts/setup.sh" "$WORK" <<'PY'
import pathlib,re,shlex,sys
wizard=pathlib.Path(sys.argv[1]).read_text()
work=pathlib.Path(sys.argv[2])
def image_choices(name):
    match=re.search(r'must be one of (.+)',(work/name).read_text())
    if not match: raise SystemExit(f'FAIL could not read provider validation from pinned image ({name})')
    return set(re.split(r', | or ',match[1])) - {'custom','pia'}
providers=set(shlex.split(re.search(r'VPN_PROVIDERS=\((.*?)\)',wizard,re.S)[1]))
wireguard=set(re.search(r'WIREGUARD_PROVIDERS="(.*?)"',wizard)[1].strip('|').split('|'))
for name,expected in [('providers',providers),('wireguard',wireguard)]:
    actual=image_choices(name)
    if actual != expected:
        raise SystemExit(f'FAIL {name} differs from pinned image: wizard only {expected-actual}, image only {actual-expected}')
    print(f'ok   wizard {name} matches pinned Gluetun image')
PY
