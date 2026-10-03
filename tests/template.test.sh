#!/usr/bin/env bash
# Policy tests for the Template itself: the compose model, pinned images and the
# whitelist .gitignore. Needs Docker Compose (no containers are started).
# Usage: tests/template.test.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/tests/lib.sh"
. "$REPO/scripts/lib/profiles.sh"

TOPOLOGY="$REPO/stacks/wire/wire/topology.py"
CORE_SERVICES="$(python3 -B "$TOPOLOGY" services | sort | xargs)" || exit 1
BEHIND_VPN="$(PYTHONPATH="$REPO/stacks/wire" python3 -B -c '
from wire.topology import load
print(" ".join(s["key"] for s in load().active() if s["namespace"] != s["key"] and s["namespace"] != "none"))')" || exit 1

# What each Profile adds on top of the Core.
declare -A PROFILE_SERVICES=(
  [backup]="backup"
  [vo]="$(PYTHONPATH="$REPO/stacks/wire" python3 -B -c '
from wire.topology import load
print(" ".join(s["key"] for s in load().active({"vo"}) if s.get("profile") == "vo"))')"
  [jackett]="jackett"
  [seeding]="cleanuparr qui"
  [cleanup]="maintainerr"
  [dashboard]="dockge homarr"
  [monitoring]="beszel beszel-agent wud"
  [proxy]="npm"
  [remote]="tailscale"
  [extras]="filebrowser issue-automator mousehole tor"
  [transcode]="tdarr"
)
# Profile services that talk to trackers or indexers, and the port gluetun publishes for each.
declare -A VPN_PORTS=([jackett]=9117 [mousehole]=5010)
# The only service that needs to write through the Docker socket (it manages stacks).
SOCKET_WRITERS="dockge"

setup() {
  SANDBOX="$(mktemp -d)"
  python3 "$REPO/scripts/env_contract.py" fixture > "$SANDBOX/.env"
}
teardown() { rm -rf "$SANDBOX"; }

compose() { docker compose --project-directory "$REPO" --env-file "$SANDBOX/.env" "$@"; }
# The Worker's own project, with worker/.env.example filled in the same way.
worker_compose() {
  python3 "$REPO/scripts/env_contract.py" fixture --scope worker > "$SANDBOX/worker.env"
  docker compose --project-directory "$REPO/worker" --env-file "$SANDBOX/worker.env" "$@"
}

# Prints a Python expression evaluated over the model (`s` = the services dict) of
# `compose --profile '*' <extra args> config`.
all_profiles_json() { compose --profile '*' "$@" config --format json; }
query() {
  local expr="$1"; shift
  python3 -c '
import json, sys
s = json.load(sys.stdin)["services"]
args = sys.argv[2:]
r = eval(sys.argv[1])
print(r if isinstance(r, str) else json.dumps(r))' "$expr" "$@"
}

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
  done < <(compose --profile '*' config --images; worker_compose config --images)
  worker_compose config --images | grep -q tdarr_node || fail "the Worker's image was not checked"
}

test_backup_profile_is_valid_and_adds_only_the_backup_service() {
  local services
  OUTPUT="$(compose --profile backup config -q 2>&1)"; STATUS=$?
  assert_status 0
  services="$(compose --profile backup config --services | sort | xargs)"
  [ "$services" = "backup $CORE_SERVICES" ] || fail "expected 'backup $CORE_SERVICES', got '$services'"
}

test_every_profile_is_valid_and_adds_exactly_its_services() {
  local profile services expected
  for profile in "${!PROFILE_SERVICES[@]}"; do
    OUTPUT="$(compose --profile "$profile" config -q 2>&1)"; STATUS=$?
    [ "$STATUS" = 0 ] || fail "Profile $profile is invalid: $OUTPUT"
    services="$(compose --profile "$profile" config --services | sort | xargs)"
    expected="$(echo "${PROFILE_SERVICES[$profile]} $CORE_SERVICES" | xargs -n1 | sort | xargs)"
    [ "$services" = "$expected" ] || fail "Profile $profile: expected '$expected', got '$services'"
  done
}

test_the_profile_module_and_compose_agree_on_the_profiles() {
  local in_module in_compose in_table
  in_module="$(profiles_all | sort | xargs)"
  in_compose="$(compose config --profiles | sort | xargs)"
  in_table="$(printf '%s\n' "${!PROFILE_SERVICES[@]}" | sort | xargs)"
  [ "$in_module" = "$in_compose" ] || fail "scripts/lib/profiles.sh lists '$in_module', compose declares '$in_compose'"
  [ "$in_table" = "$in_compose" ] || fail "PROFILE_SERVICES lists '$in_table', compose declares '$in_compose'"
}

# Prose may be reworded freely; the names are what must not drift.
test_docs_and_env_example_describe_every_profile() {
  local in_module in_docs in_env
  in_module="$(profiles_all | sort | xargs)"
  # shellcheck disable=SC2016  # the backticks in the pattern are literal
  in_docs="$(grep -oE '^\| `[a-z]+` \|' "$REPO/docs/profiles.md" | tr -d '|` ' | sort | xargs)"
  in_env="$(awk '/^# Profiles$/ {on=1} /^COMPOSE_PROFILES=/ {on=0} on && /^#   [a-z]+ / {print $2}' "$REPO/.env.example" | sort | xargs)"
  [ "$in_docs" = "$in_module" ] || fail "docs/profiles.md table has '$in_docs', the Profile module has '$in_module'"
  [ "$in_env" = "$in_module" ] || fail ".env.example lists '$in_env', the Profile module has '$in_module'"
}

test_core_and_all_profiles_are_valid_together() {
  OUTPUT="$(compose --profile '*' config -q 2>&1)"; STATUS=$?
  assert_status 0
  OUTPUT="$(COMPOSE_PROFILES="$(IFS=,; echo "${!PROFILE_SERVICES[*]}")" \
    docker compose --project-directory "$REPO" --env-file "$SANDBOX/.env" config --services | wc -l)"
  local expected
  expected="$(echo "$CORE_SERVICES ${PROFILE_SERVICES[*]}" | wc -w)"
  [ "$OUTPUT" = "$expected" ] || fail "COMPOSE_PROFILES with every Profile gives $OUTPUT services, expected $expected"
}

test_profile_services_that_reach_trackers_go_through_the_vpn() {
  local json service
  json="$(all_profiles_json)"
  for service in "${!VPN_PORTS[@]}"; do
    [ "$(query 's[args[0]].get("network_mode","")' "$service" <<< "$json")" = "service:gluetun" ] \
      || fail "$service is not behind the VPN"
    query 'any(str(p.get("published")) == args[0] for p in s["gluetun"]["ports"])' "${VPN_PORTS[$service]}" <<< "$json" | grep -q true \
      || fail "gluetun does not publish $service's port ${VPN_PORTS[$service]}"
    query 'args[0] in s["gluetun"]["networks"]["media"]["aliases"]' "$service" <<< "$json" | grep -q true \
      || fail "gluetun has no network alias for $service"
  done
}

test_core_and_vo_compose_match_the_shared_topology() {
  local profile json data_root
  data_root="$(sed -n 's/^DATA_ROOT=//p' "$SANDBOX/.env")"
  for profile in '' vo; do
    json="$(COMPOSE_PROFILES="$profile" compose config --format json)" || fail "could not resolve Compose"
    python3 -B "$REPO/tests/topology-compose.py" --profiles "$profile" --data-root "$data_root" <<< "$json" \
      || fail "Compose disagrees with the shared topology ($profile)"
  done
}

test_docker_socket_is_read_only_unless_write_is_needed() {
  local json offenders
  json="$(all_profiles_json)"
  offenders="$(query '" ".join(sorted(n for n, v in s.items()
      for m in v.get("volumes", []) if m.get("source") == "/var/run/docker.sock"
      and not m.get("read_only") and n not in args[0].split()))' "$SOCKET_WRITERS" <<< "$json")" \
    || fail "could not read the model"
  [ -z "$offenders" ] || fail "Docker socket mounted read-write in: $offenders"
  query 'sum(m.get("source") == "/var/run/docker.sock" for v in s.values() for m in v.get("volumes", []))' <<< "$json" \
    | grep -qx '[1-9][0-9]*' || fail "no service mounts the Docker socket: the check above tests nothing"
}

test_tdarr_server_has_no_internal_node_and_ships_the_nvenc_plugin() {
  local json
  json="$(all_profiles_json)"
  [ "$(query 's["tdarr"]["environment"]["internalNode"]' <<< "$json")" = false ] || fail "Tdarr runs an internal node"
  query 'any(m["target"].endswith("/Plugins/Local/Tdarr_Plugin_custom_NVENC_HEVC_Compress.js") and m.get("read_only")
      for m in s["tdarr"]["volumes"])' <<< "$json" | grep -q true || fail "the NVENC plugin is not mounted into Tdarr"
}

test_gpu_override_gives_jellyfin_and_tdarr_the_render_device() {
  local json service
  json="$(all_profiles_json -f "$REPO/compose.yaml" -f "$REPO/compose.gpu.yaml")"
  for service in jellyfin tdarr; do
    query 'any(d == "/dev/dri:/dev/dri" or (isinstance(d, dict) and d.get("source") == "/dev/dri")
      for d in s[args[0]].get("devices", []))' "$service" <<< "$json" | grep -q true \
      || fail "$service has no /dev/dri"
    [ "$(query 's[args[0]].get("group_add")' "$service" <<< "$json")" = '["dummy"]' ] || fail "$service is not in the render group"
  done
}

test_gpu_override_is_turned_on_from_the_env() {
  grep -q '^# *COMPOSE_FILE=compose.yaml:compose.gpu.yaml' "$REPO/.env.example" || fail ".env.example does not show how to turn on the GPU override"
  echo "COMPOSE_FILE=compose.yaml:compose.gpu.yaml" >> "$SANDBOX/.env"
  compose config --format json | query '"/dev/dri" in json.dumps(s["jellyfin"].get("devices", []))' | grep -q true \
    || fail "COMPOSE_FILE in .env does not apply the GPU override"
}

test_issue_automator_is_built_locally_with_no_config_file() {
  local json
  json="$(all_profiles_json)"
  query '"build" in s["issue-automator"]' <<< "$json" | grep -q true || fail "issue-automator is not built locally"
  [ "$(query 's["issue-automator"].get("volumes", [])' <<< "$json")" = "[]" ] || fail "issue-automator mounts files"
  [ "$(query 's["issue-automator"]["environment"]["SEERR_API_KEY"]' <<< "$json")" = dummy ] || fail "issue-automator does not take SEERR_API_KEY from .env"
}

test_instance_specific_values_come_from_the_env() {
  local json
  json="$(all_profiles_json)"
  [ "$(query 's["tailscale"]["environment"]["TS_ROUTES"]' <<< "$json")" = dummy ] || fail "Tailscale routes do not come from .env"
  [ "$(query 's["mousehole"]["environment"]["MOUSEHOLE_ALLOWED_HOSTS"]' <<< "$json")" = dummy ] || fail "mousehole allowed host does not come from .env"
  [ "$(query 's["homarr"]["environment"]["SECRET_ENCRYPTION_KEY"]' <<< "$json")" = dummy ] || fail "homarr key does not come from .env"
  [ "$(query 's["wud"]["environment"]["WUD_AUTH_ADMIN_PASSWORD"]' <<< "$json")" = dummy ] || fail "WUD login does not come from .env"
  [ "$(query 's["wud"]["environment"]["WUD_TRIGGER_TELEGRAM_TELEGRAM_BOTTOKEN"]' <<< "$json")" = dummy ] || fail "WUD alerts do not use TELEGRAM_BOT_TOKEN"
}

test_tailscale_state_is_kept_in_the_app_data() {
  query 'any(m["target"] == "/var/lib/tailscale" and m["source"] == "/opt/media-stack/appdata/tailscale"
      for m in s["tailscale"]["volumes"])' < <(all_profiles_json) | grep -q true || fail "Tailscale state is not under APPDATA_ROOT"
}

test_worker_compose_is_valid_and_matches_the_server_version() {
  local server node
  OUTPUT="$(worker_compose config -q 2>&1)"; STATUS=$?
  assert_status 0
  node="$(worker_compose config --images)"
  server="$(compose --profile transcode config --images | grep tdarr)"
  [ "${node##*:}" = "${server##*:}" ] || fail "Worker node $node and server $server versions differ"
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
    # jellyfin and gluetun ship a HEALTHCHECK in their images; the Wiring runs once and exits.
    case "$service" in jellyfin|gluetun|wire|wire-seed) continue ;; esac
    python3 -c 'import json,sys; s=json.load(sys.stdin)["services"][sys.argv[1]]; sys.exit(0 if s.get("healthcheck",{}).get("test") else 1)' "$service" <<< "$json" \
      || fail "$service has no healthcheck"
  done
}

test_the_wiring_runs_once_and_the_apps_wait_for_its_seed() {
  local json service
  json="$(all_profiles_json)"
  for service in wire wire-seed; do
    [ "$(query 's[args[0]].get("restart")' "$service" <<< "$json")" = no ] || fail "$service must not restart"
  done
  for service in qbittorrent prowlarr radarr sonarr bazarr radarr-vo sonarr-vo; do
    [ "$(query 's[args[0]]["depends_on"]["wire-seed"]["condition"]' "$service" <<< "$json")" = service_completed_successfully ] \
      || fail "$service does not wait for wire-seed"
  done
  [ "$(query 's["wire-seed"].get("network_mode")' <<< "$json")" = none ] || fail "wire-seed needs no network"
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
      stacks/arr/compose.override.yaml examples/.env worker/.env worker/configs/Tdarr_Node_Config.json \
      stacks/extras/issue-automator/config.json; do
    gitignored "$path" || fail "$path is not ignored"
  done
}

test_gitignore_allows_template_files() {
  local path
  for path in compose.yaml compose.gpu.yaml stacks/arr/compose.yaml .env.example scripts/init.sh scripts/lib/profiles.sh \
      scripts/env_contract.sh scripts/env_contract.py \
      env/catalog.json env/instance.example.template env/worker.example.template docs/install.md \
      stacks/extras/issue-automator/Dockerfile stacks/extras/issue-automator/main.py stacks/extras/tor/Dockerfile \
      stacks/transcode/plugins/Tdarr_Plugin_custom_NVENC_HEVC_Compress.js worker/compose.yaml worker/.env.example \
      worker/Tdarr_Node_Config.windows.json.example \
      stacks/backup/Dockerfile stacks/backup/media-backup.sh docs/backup.en.md \
      tests/lib.sh tests/topology-compose.py stacks/wire/wire/topology.json stacks/wire/wire/topology.py \
      .github/workflows/ci.yml .githooks/pre-commit README.md LICENSE renovate.json \
      .gitleaks.toml .gitignore; do
    gitignored "$path" && fail "$path is ignored"
  done
  return 0
}

run_tests
