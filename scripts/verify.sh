#!/usr/bin/env bash
# Checks a running Instance: every active Core/vo service is healthy, the Wiring connected the
# apps, and qBittorrent's traffic leaves through the VPN (its public IP differs from
# the host's).
#
# Usage: scripts/verify.sh   (after `docker compose up -d` and a minute or two)
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO/.env}"
TOPOLOGY="$REPO/stacks/wire/wire/topology.py"
IP_URL="https://ipinfo.io/ip"
failed=0

if ! command -v python3 >/dev/null; then
  echo "FAIL Python 3 not found. Install python3 on the host." >&2
  exit 1
fi
# Compose resolves enabled Profiles from the Instance's .env and environment.
if ! active_services="$(docker compose --project-directory "$REPO" --env-file "$ENV_FILE" config --services)"; then
  echo "FAIL cannot resolve the Instance's active services with docker compose config." >&2
  exit 1
fi
if ! expectations="$(python3 -B "$TOPOLOGY" verification --active-services <<< "$active_services")"; then
  exit 1
fi

while read -r service expected; do
  if [ "$expected" = completed ]; then
    status="$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$service" 2>/dev/null)" || status="missing"
    case "$status" in
      "exited 0") echo "ok   $service completed" ;;
      running*) echo "FAIL $service is still connecting or preparing the apps: run this again in a minute"; failed=1 ;;
      missing) echo "FAIL $service never ran: docker compose up -d"; failed=1 ;;
      *) echo "FAIL $service could not complete ($status): docker compose logs $service"; failed=1 ;;
    esac
    continue
  fi
  status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$service" 2>/dev/null)" \
    || status="missing"
  if [ "$status" = "healthy" ]; then
    echo "ok   $service"
  else
    echo "FAIL $service is $status"
    failed=1
  fi
done <<< "$expectations"

host_ip="$(curl -fsS --max-time 10 "$IP_URL" 2>/dev/null)"
vpn_ip="$(docker exec qbittorrent curl -fsS --max-time 10 "$IP_URL" 2>/dev/null)"
if [ -z "$host_ip" ]; then
  echo "FAIL cannot get the host's public IP from $IP_URL to compare with"
  failed=1
elif [ -z "$vpn_ip" ]; then
  echo "FAIL qBittorrent cannot reach the internet"
  failed=1
elif [ "$vpn_ip" = "$host_ip" ]; then
  echo "FAIL qBittorrent egress IP $vpn_ip is the host's: traffic is NOT going through the VPN"
  failed=1
else
  echo "ok   qBittorrent egress IP $vpn_ip (host: $host_ip)"
fi

exit "$failed"
