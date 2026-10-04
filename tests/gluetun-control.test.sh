#!/usr/bin/env bash
# Exercise the Template's auth settings against the pinned image in isolation.
# No provider credentials are used and no running Instance containers are touched.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
CONTAINER="media-stack-control-test-$$"
trap 'docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

python3 "$REPO/scripts/env_contract.py" fixture > "$WORK/.env"
CONTROL_TEST_KEY="$(sed -n 's/^GLUETUN_CONTROL_API_KEY=//p' "$WORK/.env")"
docker compose --project-directory "$REPO" --env-file "$WORK/.env" config --format json > "$WORK/compose.json"
IMAGE="$(python3 - "$WORK" <<'PY'
import json, pathlib, sys
work = pathlib.Path(sys.argv[1])
service = json.loads((work / "compose.json").read_text())["services"]["gluetun"]
(work / "control.env").write_text("".join(
    f"{name}={value}\n" for name, value in service["environment"].items()
    if name.startswith("HTTP_CONTROL_SERVER_AUTH_")
))
print(service["image"])
PY
)"
# An old Instance's file must not leave routes open or require a different key.
printf '[[roles]]\nname = "legacy"\nauth = "none"\nroutes = ["GET /v1/publicip/ip"]\n' > "$WORK/legacy.toml"
WIREGUARD_TEST_KEY="$(python3 -c 'import base64; print(base64.b64encode(bytes(32)).decode())')"
docker run -d --name "$CONTAINER" --cap-add NET_ADMIN --device /dev/net/tun \
  --env-file "$WORK/control.env" \
  -v "$WORK/legacy.toml:/gluetun/auth/config.toml:ro" \
  -e VPN_SERVICE_PROVIDER=custom -e VPN_TYPE=wireguard \
  -e WIREGUARD_ENDPOINT_IP=192.0.2.1 -e WIREGUARD_ENDPOINT_PORT=51820 \
  -e WIREGUARD_PUBLIC_KEY="$WIREGUARD_TEST_KEY" \
  -e WIREGUARD_PRIVATE_KEY="$WIREGUARD_TEST_KEY" \
  -e WIREGUARD_ADDRESSES=10.0.0.2/32 "$IMAGE" >/dev/null

status() {
  local response
  response="$(docker exec "$CONTAINER" wget --timeout=3 --tries=1 -S -O /dev/null \
    "$@" 2>&1)" || true
  awk '/HTTP\/1.1 [0-9]+/ {print $2; exit}' <<< "$response"
}

for attempt in {1..30}; do
  [ "$(status http://127.0.0.1:8000/v1/vpn/status)" = 401 ] && break
  if [ "$attempt" = 30 ]; then
    echo 'FAIL Gluetun control server did not start with API key protection' >&2
    exit 1
  fi
  sleep 1
done

# Probe every supported method, without a key and with a wrong key. Unauthorized
# mutation requests must stop before they can restart or reconfigure anything.
while read -r method route; do
  for key in '' wrong; do
    [ "$(status --method="$method" --header="X-API-Key: $key" "http://127.0.0.1:8000$route")" = 401 ] \
      || { echo "FAIL $method $route accepted a missing or wrong key" >&2; exit 1; }
  done
done <<'ROUTES'
GET /openvpn/actions/restart
GET /openvpn/portforwarded
GET /openvpn/settings
GET /unbound/actions/restart
GET /updater/restart
GET /v1/version
GET /v1/vpn/status
PUT /v1/vpn/status
GET /v1/vpn/settings
PUT /v1/vpn/settings
GET /v1/openvpn/status
PUT /v1/openvpn/status
GET /v1/openvpn/portforwarded
GET /v1/openvpn/settings
GET /v1/dns/status
PUT /v1/dns/status
GET /v1/updater/status
PUT /v1/updater/status
GET /v1/publicip/ip
GET /v1/portforward
PUT /v1/portforward
ROUTES
echo 'ok   every control server route rejects missing and wrong API keys'

for route in /v1/vpn/status /v1/dns/status /v1/publicip/ip /v1/vpn/settings; do
  [ "$(status --header="X-API-Key: $CONTROL_TEST_KEY" "http://127.0.0.1:8000$route")" = 200 ] \
    || { echo "FAIL $route did not accept the API key" >&2; exit 1; }
  echo "ok   $route accepts X-API-Key"
done
if docker logs "$CONTAINER" 2>&1 | grep -q 'unprotected by default'; then
  echo 'FAIL Gluetun warned about unprotected routes' >&2
  exit 1
fi
echo 'ok   no unprotected-route warnings, including with a persisted legacy role'
