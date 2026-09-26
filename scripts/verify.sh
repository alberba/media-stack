#!/usr/bin/env bash
# Checks a running Instance: every Core service is healthy, and qBittorrent's
# traffic leaves through the VPN (its public IP differs from the host's).
#
# Usage: scripts/verify.sh   (after `docker compose up -d` and a minute or two)
set -uo pipefail

CORE_SERVICES=(gluetun qbittorrent prowlarr flaresolverr radarr sonarr bazarr jellyfin seerr)
IP_URL="https://ipinfo.io/ip"
failed=0

for service in "${CORE_SERVICES[@]}"; do
  status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$service" 2>/dev/null)" \
    || status="missing"
  if [ "$status" = "healthy" ]; then
    echo "ok   $service"
  else
    echo "FAIL $service is $status"
    failed=1
  fi
done

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
