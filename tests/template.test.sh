#!/usr/bin/env bash
# Policy tests for the Template itself: the compose model, pinned images and the
# whitelist .gitignore. Needs Docker Compose (no containers are started).
# Usage: tests/template.test.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/tests/lib.sh"

CORE_SERVICES="bazarr flaresolverr gluetun jellyfin prowlarr qbittorrent radarr seerr sonarr"
BEHIND_VPN="bazarr flaresolverr prowlarr qbittorrent radarr sonarr"

setup() {
  SANDBOX="$(mktemp -d)"
  # .env.example with every empty value filled, as an Operator would (BACKUP_SOURCE
  # stays empty: it falls back to APPDATA_ROOT).
  sed -E '/^(COMPOSE_PROFILES|BACKUP_SOURCE)=/!s/^([A-Z_]+)=$/\1=dummy/' "$REPO/.env.example" > "$SANDBOX/.env"
}
teardown() { rm -rf "$SANDBOX"; }

compose() { docker compose --project-directory "$REPO" --env-file "$SANDBOX/.env" "$@"; }

test_core_config_is_valid() {
  OUTPUT="$(compose config -q 2>&1)"; STATUS=$?
  assert_status 0
}

test_core_has_exactly_the_core_services() {
  local services
  services="$(compose config --services | sort | xargs)"
  [ "$services" = "$CORE_SERVICES" ] || fail "expected '$CORE_SERVICES', got '$services'"
}

test_every_image_is_pinned() {
  local image
  while read -r image; do
    [[ "$image" == *:* ]] || fail "$image has no tag"
    [[ "$image" != *:latest ]] || fail "$image uses :latest"
  done < <(compose --profile '*' config --images)
}

test_backup_profile_is_valid_and_adds_only_the_backup_service() {
  local services
  OUTPUT="$(compose --profile backup config -q 2>&1)"; STATUS=$?
  assert_status 0
  services="$(compose --profile backup config --services | sort | xargs)"
  [ "$services" = "backup $CORE_SERVICES" ] || fail "expected 'backup $CORE_SERVICES', got '$services'"
}

test_backup_profile_backs_up_the_app_data_by_default() {
  local source
  source="$(compose --profile backup config --format json | python3 -c '
import json, sys
volumes = json.load(sys.stdin)["services"]["backup"]["volumes"]
print(next(v["source"] for v in volumes if v["target"] == "/source"))')"
  [ "$source" = "/opt/media-stack/appdata" ] || fail "backup source is '$source', expected APPDATA_ROOT"
}

test_core_services_are_language_neutral() {
  compose config --services | grep -E -- '-(es|vo|en)$' && fail "language suffix in a Core service name"
  return 0
}

test_download_side_goes_through_the_vpn() {
  local json service mode
  json="$(compose config --format json)"
  for service in $BEHIND_VPN; do
    mode="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["services"][sys.argv[1]].get("network_mode",""))' "$service" <<< "$json")"
    [ "$mode" = "service:gluetun" ] || fail "$service network_mode is '$mode', expected service:gluetun"
  done
}

test_every_core_service_has_a_healthcheck() {
  local json service
  json="$(compose config --format json)"
  for service in $CORE_SERVICES; do
    # jellyfin and gluetun ship a HEALTHCHECK in their images.
    case "$service" in jellyfin|gluetun) continue ;; esac
    python3 -c 'import json,sys; s=json.load(sys.stdin)["services"][sys.argv[1]]; sys.exit(0 if s.get("healthcheck",{}).get("test") else 1)' "$service" <<< "$json" \
      || fail "$service has no healthcheck"
  done
}

test_profiles_come_from_the_root_env() {
  grep -q '^COMPOSE_PROFILES=' "$REPO/.env.example" || fail ".env.example lacks COMPOSE_PROFILES"
}

test_required_variables_fail_loudly() {
  sed -E 's/^(APPDATA_ROOT)=.*/\1=/' "$SANDBOX/.env" > "$SANDBOX/.env.broken"
  OUTPUT="$(docker compose --project-directory "$REPO" --env-file "$SANDBOX/.env.broken" config -q 2>&1)"; STATUS=$?
  [ "$STATUS" != 0 ] || fail "compose accepted an empty APPDATA_ROOT"
  assert_output_contains "APPDATA_ROOT"
}

gitignored() { git -C "$REPO" check-ignore -q --no-index "$1"; }

test_gitignore_blocks_instance_files() {
  local path
  for path in .env .env.local appdata/radarr/radarr.db stacks/arr/config/config.xml notes.txt secrets.json compose.override.yaml \
      stacks/arr/compose.override.yaml examples/.env; do
    gitignored "$path" || fail "$path is not ignored"
  done
}

test_gitignore_allows_template_files() {
  local path
  for path in compose.yaml stacks/arr/compose.yaml .env.example scripts/init.sh docs/install.md \
      stacks/backup/Dockerfile stacks/backup/media-backup.sh docs/backup.es.md \
      tests/lib.sh .github/workflows/ci.yml .githooks/pre-commit README.md LICENSE renovate.json \
      .gitleaks.toml .gitignore; do
    gitignored "$path" && fail "$path is ignored"
  done
  return 0
}

run_tests
