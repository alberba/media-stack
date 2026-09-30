#!/usr/bin/env bash
# Integration test for the Wiring against the real apps, at the versions the Template
# pins. No VPN: a plain container stands in for gluetun's shared network. Pulls ~3 GB of
# images and takes a few minutes, so it is not part of CI.
# Usage: tests/wire-integration.test.sh   (KEEP=1 leaves the containers up to look at)
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/tests/lib.sh"

P=wire-it
NET="$P-net"
image() { grep -h "image: .*$1:" "$REPO"/stacks/*/compose.yaml | head -n 1 | awk '{print $2}'; }

up() {
  WORK="$(mktemp -d)"
  mkdir -p "$WORK/appdata/wire" "$WORK/data/media/movies" "$WORK/data/media/tv" "$WORK/data/torrents"
  chmod -R 777 "$WORK"
  ENVFILE="$WORK/env"
  # Throwaway keys and passwords, one random value each.
  {
    printf 'TZ=Etc/UTC\nPUID=%s\nPGID=%s\nCOMPOSE_PROFILES=vo\nQBITTORRENT_USER=admin\nJELLYFIN_ADMIN_USER=ana\n' "$(id -u)" "$(id -g)"
    printf 'QUALITIES=Bluray-2160p,WEB 2160p,Bluray-1080p,WEB 1080p\nWIRE_WAIT_SECONDS=300\n'
    local var
    for var in RADARR SONARR RADARR_VO SONARR_VO PROWLARR BAZARR SEERR; do
      printf '%s_API_KEY=%s\n' "$var" "$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    done
    for var in QBITTORRENT JELLYFIN_ADMIN; do
      printf '%s_PASSWORD=%s\n' "$var" "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
    done
  } > "$ENVFILE"
  docker build -q -t media-stack-wire:local "$REPO/stacks/wire" >/dev/null
  docker network create "$NET" >/dev/null
  local common=(--env-file "$ENVFILE" -e PUID="$(id -u)" -e PGID="$(id -g)")
  docker run --rm --name "$P-seed" "${common[@]}" -v "$WORK/appdata:/appdata" -v "$WORK/data:/data" \
    --network none media-stack-wire:local seed
  # Stands in for gluetun: the apps behind the VPN share its network and names.
  docker run -d --name "$P-gw" --network "$NET" \
    --network-alias qbittorrent --network-alias prowlarr --network-alias radarr --network-alias sonarr \
    --network-alias radarr-vo --network-alias sonarr-vo --network-alias bazarr --network-alias flaresolverr \
    alpine:3.22 sleep infinity >/dev/null
  local behind=(--network "container:$P-gw" "${common[@]}" -v "$WORK/data:/data")
  docker run -d --name "$P-qbittorrent" "${behind[@]}" -e WEBUI_PORT=8080 -v "$WORK/appdata/qbittorrent:/config" "$(image qbittorrent)" >/dev/null
  docker run -d --name "$P-prowlarr" "${behind[@]}" -v "$WORK/appdata/prowlarr:/config" "$(image prowlarr)" >/dev/null
  docker run -d --name "$P-radarr" "${behind[@]}" -v "$WORK/appdata/radarr:/config" "$(image radarr)" >/dev/null
  docker run -d --name "$P-sonarr" "${behind[@]}" -v "$WORK/appdata/sonarr:/config" "$(image sonarr)" >/dev/null
  docker run -d --name "$P-radarr-vo" "${behind[@]}" -e RADARR__SERVER__PORT=7879 -v "$WORK/appdata/radarr-vo:/config" "$(image radarr)" >/dev/null
  docker run -d --name "$P-sonarr-vo" "${behind[@]}" -e SONARR__SERVER__PORT=8990 -v "$WORK/appdata/sonarr-vo:/config" "$(image sonarr)" >/dev/null
  docker run -d --name "$P-flaresolverr" --network "container:$P-gw" "$(image flaresolverr)" >/dev/null
  docker run -d --name "$P-bazarr" "${behind[@]}" -v "$WORK/appdata/bazarr:/config" "$(image bazarr)" >/dev/null
  docker run -d --name "$P-jellyfin" --network "$NET" --network-alias jellyfin --user "$(id -u):$(id -g)" \
    -v "$WORK/appdata/jellyfin:/config" -v "$WORK/data/media:/data/media" "$(image jellyfin)" >/dev/null
  docker run -d --name "$P-seerr" --network "$NET" --network-alias seerr --init \
    -e API_KEY="$(grep ^SEERR_API_KEY= "$ENVFILE" | cut -d= -f2)" -v "$WORK/appdata/seerr:/app/config" "$(image seerr)" >/dev/null
}

down() {
  [ -n "${KEEP:-}" ] && { echo "left running: docker ps --filter name=$P"; return; }
  docker ps -aq --filter "name=^$P-" | xargs docker rm -f >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
  rm -rf "$WORK" 2>/dev/null || docker run --rm -v "$WORK:/w" alpine:3.22 rm -rf /w/appdata /w/data
}

wire_run() {
  OUTPUT="$(docker run --rm --name "$P-wire" --network "$NET" --env-file "$ENVFILE" \
    -v "$WORK/appdata:/appdata:ro" -v "$WORK/appdata/wire:/config" media-stack-wire:local wire 2>&1)"
  STATUS=$?
}

api() { docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS -H "X-Api-Key: $2" "$1"; }

test_wires_a_fresh_instance_and_a_second_run_changes_nothing() {
  wire_run
  printf '    | %s\n' "${OUTPUT//$'\n'/$'\n'    | }"
  assert_status 0
  assert_output_contains "ok   every app is wired"
  local radarr_key; radarr_key="$(grep ^RADARR_API_KEY= "$ENVFILE" | cut -d= -f2)"
  api http://radarr:7878/api/v3/downloadclient "$radarr_key" | grep -q '"movies"' || fail "no qBittorrent in Radarr"
  api http://radarr:7878/api/v3/qualityprofile "$radarr_key" | grep -q '"Media Stack"' || fail "no quality profile"
  api http://seerr:5055/api/v1/settings/radarr "$(grep ^SEERR_API_KEY= "$ENVFILE" | cut -d= -f2)" | grep -q radarr-vo \
    || fail "no Radarr VO in Seerr"
  wire_run
  assert_status 0
  assert_output_not_contains " added"
  assert_output_not_contains "created"
}

up
trap down EXIT
run_tests
