#!/usr/bin/env bash
# Integration test for the Wiring against the real apps, at the versions the Template
# pins. No VPN: a plain container stands in for gluetun's shared network. Pulls ~3 GB of
# images and takes a few minutes; runs in the manual Wiring integration workflow.
# Usage: tests/wire-integration.test.sh   (KEEP=1 leaves the containers up to look at)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO/tests/lib.sh"

P="wire-it-$$"
NET="$P-net"
WIRE_IMAGE="$P-wire:local"
WORK=""
image() { grep -h "image: .*$1:" "$REPO"/stacks/*/compose.yaml | head -n 1 | awk '{print $2}'; }
endpoint() { python3 -B "$REPO/stacks/wire/wire/topology.py" endpoint --caller wire --target "$1"; }
listener() { local port; read -r _ port <<< "$(endpoint "$1")"; printf '%s' "$port"; }

prepare_seerr() {
  # Seerr uses node:node, independently of the Operator's PUID/PGID.
  docker run --rm --network none --user root --entrypoint sh \
    -v "$WORK/appdata:/fixture" "$(image seerr)" -c \
    'mkdir -p /fixture/seerr; chown "$(id -u node):$(id -g node)" /fixture/seerr; chmod 700 /fixture/seerr'
}

up() {
  WORK="$(mktemp -d)"
  mkdir -p "$WORK/appdata/wire" "$WORK/data"
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
  docker build -q -t "$WIRE_IMAGE" "$REPO/stacks/wire" >/dev/null
  docker network create "$NET" >/dev/null
  local common=(--env-file "$ENVFILE" -e PUID="$(id -u)" -e PGID="$(id -g)")
  docker run --rm --name "$P-seed" "${common[@]}" -v "$WORK/appdata:/appdata" -v "$WORK/data:/data" \
    --network none "$WIRE_IMAGE" seed
  prepare_seerr
  # Stands in for gluetun: the apps behind the VPN share its network and names.
  local -a aliases=()
  local service
  while IFS= read -r service; do aliases+=(--network-alias "$service"); done < <(
    PYTHONPATH="$REPO/stacks/wire" python3 -B -c '
from wire.topology import load
print("\n".join(s["key"] for s in load().active({"vo"}) if s["namespace"] == "gluetun" and s["key"] != "gluetun"))')
  docker run -d --name "$P-gw" --network "$NET" "${aliases[@]}" \
    alpine:3.22 sleep infinity >/dev/null
  local behind=(--network "container:$P-gw" "${common[@]}" -v "$WORK/data:/data")
  docker run -d --name "$P-qbittorrent" "${behind[@]}" -e WEBUI_PORT="$(listener qbittorrent)" -v "$WORK/appdata/qbittorrent:/config" "$(image qbittorrent)" >/dev/null
  docker run -d --name "$P-prowlarr" "${behind[@]}" -v "$WORK/appdata/prowlarr:/config" "$(image prowlarr)" >/dev/null
  local key kind port setting
  while read -r key kind port setting; do
    docker run -d --name "$P-$key" "${behind[@]}" -e "$setting=$port" \
      -v "$WORK/appdata/$key:/config" "$(image "$kind")" >/dev/null
  done < <(PYTHONPATH="$REPO/stacks/wire" python3 -B -c '
from wire.topology import load
for s in load().managers({"vo"}):
    kind = s["manager"]["kind"]
    print(s["key"], kind, s["port"], kind.upper() + "__SERVER__PORT")')
  docker run -d --name "$P-flaresolverr" --network "container:$P-gw" "$(image flaresolverr)" >/dev/null
  docker run -d --name "$P-bazarr" "${behind[@]}" -v "$WORK/appdata/bazarr:/config" "$(image bazarr)" >/dev/null
  docker run -d --name "$P-jellyfin" --network "$NET" --network-alias jellyfin --user "$(id -u):$(id -g)" \
    -v "$WORK/appdata/jellyfin:/config" -v "$WORK/data/media:/data/media" "$(image jellyfin)" >/dev/null
  docker run -d --name "$P-seerr" --network "$NET" --network-alias seerr --init \
    -e PORT="$(listener seerr)" \
    -e API_KEY="$(grep ^SEERR_API_KEY= "$ENVFILE" | cut -d= -f2)" -v "$WORK/appdata/seerr:/app/config" "$(image seerr)" >/dev/null
}

redact_logs() {
  python3 -c '
import pathlib, sys
p = pathlib.Path(sys.argv[1])
secrets = []
if p.is_file():
    for line in p.read_text().splitlines():
        key, sep, value = line.partition("=")
        if sep and value and (key.endswith("_API_KEY") or key.endswith("_PASSWORD")):
            secrets.append(value)
for line in sys.stdin:
    for value in sorted(secrets, key=len, reverse=True):
        line = line.replace(value, "<REDACTED>")
    sys.stdout.write(line)
' "${ENVFILE:-/dev/null}"
}

diagnostics() {
  local report containers container
  report="$(mktemp -d "${TMPDIR:-/tmp}/wire-it-diagnostics.XXXXXX")"
  docker ps -a --filter "name=^$P-" --format '{{.Names}} {{.Status}}' > "$report/containers.log"
  containers="$(docker ps -aq --filter "name=^$P-")"
  for container in $containers; do
    {
      docker inspect --format '{{.Name}} status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} error={{.State.Error}}' "$container"
      docker logs --tail 100 "$container" 2>&1 || true
    } | redact_logs > "$report/$container.log"
  done
  if [ -d "$WORK/appdata/seerr" ]; then
    stat -c 'Seerr fixture owner=%u:%g mode=%a' "$WORK/appdata/seerr" > "$report/ownership.log"
  fi
  echo "Wiring failed; redacted container diagnostics: $report" >&2
  cat "$report"/*.log >&2
}

down() {
  [ -n "${KEEP:-}" ] && { echo "left running: docker ps --filter name=$P"; return; }
  local containers
  containers="$(docker ps -aq --filter "name=^$P-")" || containers=""
  if [ -n "$containers" ]; then
    printf '%s\n' "$containers" | xargs docker rm -f >/dev/null 2>&1 || true
  fi
  docker network rm "$NET" >/dev/null 2>&1 || true
  docker image rm "$WIRE_IMAGE" >/dev/null 2>&1 || true
  if [ -n "$WORK" ]; then
    rm -rf "$WORK" 2>/dev/null || docker run --rm -v "$WORK:/w" alpine:3.22 rm -rf /w/appdata /w/data
  fi
}

wire_run() {
  OUTPUT="$(docker run --rm --name "$P-wire" --network "$NET" --env-file "$ENVFILE" \
    -v "$WORK/appdata:/appdata:ro" -v "$WORK/appdata/wire:/config" "$WIRE_IMAGE" wire 2>&1)"
  STATUS=$?
}

api() { docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS -H "X-Api-Key: $2" "$1"; }

wires_a_fresh_instance_and_a_second_run_changes_nothing() {
  wire_run
  printf '    | %s\n' "${OUTPUT//$'\n'/$'\n'    | }"
  assert_status 0
  assert_output_contains "ok   every app is wired"
  local radarr_key; radarr_key="$(grep ^RADARR_API_KEY= "$ENVFILE" | cut -d= -f2)"
  api "http://radarr:$(listener radarr)/api/v3/downloadclient" "$radarr_key" | grep -q '"movies"' || fail "no qBittorrent in Radarr"
  api "http://radarr:$(listener radarr)/api/v3/qualityprofile" "$radarr_key" | grep -q '"Media Stack"' || fail "no quality profile"
  api "http://seerr:$(listener seerr)/api/v1/settings/radarr" "$(grep ^SEERR_API_KEY= "$ENVFILE" | cut -d= -f2)" | grep -q radarr-vo \
    || fail "no Radarr VO in Seerr"
  wire_run
  assert_status 0
  assert_output_not_contains " added"
  assert_output_not_contains "created"
}

cleanup() {
  local exit_status=$?
  if [ "$exit_status" != 0 ]; then diagnostics || true; fi
  down
  exit "$exit_status"
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
  test_wires_a_fresh_instance_and_a_second_run_changes_nothing() {
    wires_a_fresh_instance_and_a_second_run_changes_nothing
  }
  trap cleanup EXIT
  up
  run_tests
fi
