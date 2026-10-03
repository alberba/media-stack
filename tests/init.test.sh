#!/usr/bin/env bash
# Tests for scripts/init.sh. Docker is replaced by a fake on PATH, so they run anywhere.
# Usage: tests/init.test.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
INIT="$REPO/scripts/init.sh"
. "$REPO/tests/lib.sh"
. "$REPO/scripts/lib/profiles.sh"

# A sandbox per test: a valid .env, a fake tun device and a fake docker.
setup() {
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/bin"
  touch "$SANDBOX/tun"
  export TUN_DEVICE="$SANDBOX/tun"
  export ENV_FILE="$SANDBOX/.env"
  export FAKE_COMPOSE_VERSION="2.26.1"
  export FAKE_DOCKER_LOG="$SANDBOX/docker.log"
  export FAKE_NETWORK_EXISTS=0
  cat > "$SANDBOX/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_DOCKER_LOG"
case "$*" in
  "compose version --short") echo "$FAKE_COMPOSE_VERSION" ;;
  "network inspect"*) [ "$FAKE_NETWORK_EXISTS" = 1 ] ;;
  "network create"*) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  export FAKE_UID=0
  cat > "$SANDBOX/bin/id" <<'EOF'
#!/usr/bin/env bash
[ "$*" = "-u" ] && { echo "$FAKE_UID"; exit 0; }
exec /usr/bin/id "$@"
EOF
  chmod +x "$SANDBOX/bin/docker" "$SANDBOX/bin/id"
  export PATH="$SANDBOX/bin:$PATH"
  cat > "$ENV_FILE" <<EOF
# comment
COMPOSE_PROFILES=
APPDATA_ROOT=$SANDBOX/appdata
DATA_ROOT=$SANDBOX/data
PUID=1234
PGID=5678
TZ="Europe/Madrid"
MEDIA_NETWORK=media-network
VPN_SERVICE_PROVIDER=protonvpn
VPN_TYPE=wireguard
WIREGUARD_PRIVATE_KEY='abc='
OPENVPN_USER=
OPENVPN_PASSWORD=
RESTIC_PASSWORD=
BACKUP_SOURCE=
RENDER_GID=
HOMARR_SECRET_KEY=
TAILSCALE_AUTHKEY=
MOUSEHOLE_AUTH_PASSWORD=
WUD_ADMIN_PASSWORD=
EOF
}

teardown() { rm -rf "$SANDBOX"; }

set_var() { sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"; }

run_init() { OUTPUT="$("$INIT" 2>&1)"; STATUS=$?; }

test_succeeds_with_a_valid_env() {
  run_init
  assert_status 0
}

test_fails_without_env_file() {
  rm "$ENV_FILE"
  run_init
  assert_status 1
  assert_output_contains ".env.example"
}

test_fails_when_compose_is_older_than_2_20() {
  FAKE_COMPOSE_VERSION="2.19.1" run_init
  assert_status 1
  assert_output_contains "2.20"
}

test_accepts_compose_2_20_exactly_and_v_prefix() {
  FAKE_COMPOSE_VERSION="v2.20.0" run_init
  assert_status 0
}

test_accepts_compose_major_3() {
  FAKE_COMPOSE_VERSION="3.0.0" run_init
  assert_status 0
}

test_fails_without_tun_device() {
  rm "$TUN_DEVICE"
  run_init
  assert_status 1
  assert_output_contains "/tun"
}

test_fails_when_a_required_variable_is_empty() {
  set_var PUID ""
  set_var TZ ""
  run_init
  assert_status 1
  assert_output_contains "PUID"
  assert_output_contains "TZ"
}

test_fails_when_not_root() {
  FAKE_UID=1000 run_init
  assert_status 1
  assert_output_contains "sudo"
}

test_media_network_defaults_when_empty() {
  set_var MEDIA_NETWORK ""
  run_init
  assert_status 0
  assert_file_contains "$FAKE_DOCKER_LOG" "network create media-network"
}

test_does_not_chown_existing_roots() {
  mkdir -p "$SANDBOX/data" && chown 4321:4321 "$SANDBOX/data"
  run_init
  assert_owner "$SANDBOX/data" "4321:4321"
}

test_wireguard_requires_private_key() {
  set_var WIREGUARD_PRIVATE_KEY ""
  run_init
  assert_status 1
  assert_output_contains "WIREGUARD_PRIVATE_KEY"
}

test_openvpn_requires_user_and_password() {
  set_var VPN_TYPE openvpn
  set_var WIREGUARD_PRIVATE_KEY ""
  run_init
  assert_status 1
  assert_output_contains "OPENVPN_USER"
  assert_output_contains "OPENVPN_PASSWORD"
  assert_output_not_contains "WIREGUARD_PRIVATE_KEY"
}

test_rejects_unknown_vpn_type() {
  set_var VPN_TYPE ipsec
  run_init
  assert_status 1
  assert_output_contains "VPN_TYPE"
}

test_quoted_values_keep_hashes_and_unquoted_drop_comments() {
  set_var VPN_TYPE "openvpn   # inline comment"
  set_var OPENVPN_USER "'user'"
  set_var OPENVPN_PASSWORD '"pa ss #1"'
  run_init
  assert_status 0
}

test_creates_app_data_folders_owned_by_puid_pgid() {
  run_init
  assert_status 0
  for dir in gluetun qbittorrent prowlarr radarr sonarr bazarr jellyfin/config jellyfin/cache; do
    assert_dir "$SANDBOX/appdata/$dir"
    assert_owner "$SANDBOX/appdata/$dir" "1234:5678"
  done
}

test_seerr_folder_is_owned_by_its_fixed_uid() {
  run_init
  assert_dir "$SANDBOX/appdata/seerr"
  assert_owner "$SANDBOX/appdata/seerr" "1000:1000"
}

test_creates_data_layout_for_hardlinks() {
  run_init
  for dir in torrents/movies torrents/tv media/movies media/tv; do
    assert_dir "$SANDBOX/data/$dir"
    assert_owner "$SANDBOX/data/$dir" "1234:5678"
  done
}

test_vo_prepares_its_library_and_download_folders() {
  set_var COMPOSE_PROFILES vo
  run_init
  assert_status 0
  for dir in media/movies-vo media/tv-vo torrents/movies-vo torrents/tv-vo; do
    assert_dir "$SANDBOX/data/$dir"
    assert_owner "$SANDBOX/data/$dir" "1234:5678"
  done
}

test_does_not_prepare_vo_folders_when_disabled() {
  run_init
  assert_status 0
  [ ! -e "$SANDBOX/data/media/movies-vo" ] || fail "VO library created without its Profile"
  [ ! -e "$SANDBOX/data/torrents/movies-vo" ] || fail "VO downloads created without their Profile"
}

test_invalid_topology_stops_init_before_side_effects() {
  local checkout="$SANDBOX/checkout"
  mkdir -p "$checkout/scripts/lib" "$checkout/stacks/wire/wire"
  cp "$INIT" "$checkout/scripts/init.sh"
  cp "$REPO/scripts/lib/profiles.sh" "$checkout/scripts/lib/"
  cp "$REPO/stacks/wire/wire/topology.py" "$checkout/stacks/wire/wire/"
  printf '{"services": []}\n' > "$checkout/stacks/wire/wire/topology.json"
  OUTPUT="$("$checkout/scripts/init.sh" 2>&1)"; STATUS=$?
  assert_status 1
  assert_output_contains "topology"
  [ ! -e "$SANDBOX/appdata" ] || fail "appdata created with invalid topology"
  [ ! -e "$SANDBOX/data" ] || fail "library created with invalid topology"
  assert_file_not_contains "$FAKE_DOCKER_LOG" "network create"
}

test_creates_shared_network_when_missing() {
  run_init
  assert_file_contains "$FAKE_DOCKER_LOG" "network create media-network"
}

test_does_not_recreate_existing_network() {
  FAKE_NETWORK_EXISTS=1 run_init
  assert_status 0
  assert_file_not_contains "$FAKE_DOCKER_LOG" "network create"
}

test_backup_profile_requires_a_restic_password() {
  set_var COMPOSE_PROFILES "vo,backup"
  run_init
  assert_status 1
  assert_output_contains "RESTIC_PASSWORD"
}

test_restic_password_is_not_required_without_the_backup_profile() {
  run_init
  assert_status 0
  [ ! -e "$SANDBOX/appdata/backup" ] || fail "backup folder created without the backup Profile"
}

test_backup_profile_creates_its_folder_owned_by_root() {
  set_var COMPOSE_PROFILES backup
  set_var RESTIC_PASSWORD "'long secret'"
  run_init
  assert_status 0
  assert_dir "$SANDBOX/appdata/backup"
  assert_owner "$SANDBOX/appdata/backup" "0:0"
}

test_backup_source_must_exist_when_set() {
  set_var COMPOSE_PROFILES backup
  set_var RESTIC_PASSWORD secret
  set_var BACKUP_SOURCE "$SANDBOX/nowhere"
  run_init
  assert_status 1
  assert_output_contains "BACKUP_SOURCE"
}

# Fills in what each Profile needs, so only the thing under test is missing.
enable_profiles() {
  set_var COMPOSE_PROFILES "$1"
  set_var RESTIC_PASSWORD "long-secret"
  set_var HOMARR_SECRET_KEY "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  set_var TAILSCALE_AUTHKEY "tskey-auth-test"
  set_var MOUSEHOLE_AUTH_PASSWORD "long-password"
  set_var WUD_ADMIN_PASSWORD "another-password"
}

test_every_profile_creates_its_folders_with_the_right_owner() {
  local profile owner dir expected
  enable_profiles "$(profiles_all | paste -sd,)"
  run_init
  assert_status 0
  for profile in $(profiles_all); do
    while read -r owner dir; do
      assert_dir "$SANDBOX/appdata/$dir"
      expected="1234:5678"
      [ "$owner" = app ] || expected="0:0"
      assert_owner "$SANDBOX/appdata/$dir" "$expected"
      [ "$owner" != private ] || [ "$(stat -c %a "$SANDBOX/appdata/$dir")" = 700 ] \
        || fail "$dir is readable by others"
    done < <(profile_dirs "$profile")
  done
}

test_profile_folders_are_not_created_when_the_profile_is_off() {
  enable_profiles vo
  run_init
  assert_status 0
  assert_dir "$SANDBOX/appdata/radarr-vo"
  for dir in jackett tdarr tailscale homarr; do
    [ ! -e "$SANDBOX/appdata/$dir" ] || fail "$dir created without its Profile"
  done
}

test_an_unknown_profile_stops_init_and_lists_the_valid_ones() {
  set_var COMPOSE_PROFILES "vo,transcod"
  run_init
  assert_status 1
  assert_output_contains "transcod"
  assert_output_contains "backup"
  assert_output_contains "transcode"
  [ ! -e "$SANDBOX/appdata" ] || fail "appdata was created despite an unknown Profile"
}

test_an_unknown_profile_does_not_hide_the_other_errors() {
  set_var COMPOSE_PROFILES "backup,transcod"
  run_init
  assert_status 1
  assert_output_contains "transcod"
  assert_output_contains "RESTIC_PASSWORD"
}

test_spaces_around_profile_names_are_ignored() {
  enable_profiles "vo, jackett"
  run_init
  assert_status 0
  assert_dir "$SANDBOX/appdata/radarr-vo"
  assert_dir "$SANDBOX/appdata/jackett"
}

test_tailscale_state_is_private() {
  enable_profiles remote
  run_init
  [ "$(stat -c %a "$SANDBOX/appdata/tailscale")" = 700 ] || fail "tailscale state is readable by others"
}

test_dashboard_profile_requires_a_valid_homarr_key() {
  enable_profiles dashboard
  set_var HOMARR_SECRET_KEY ""
  run_init
  assert_status 1
  assert_output_contains "HOMARR_SECRET_KEY"
  set_var HOMARR_SECRET_KEY "too-short"
  run_init
  assert_status 1
  assert_output_contains "openssl rand -hex 32"
}

test_remote_profile_requires_an_auth_key_for_a_new_node() {
  enable_profiles remote
  set_var TAILSCALE_AUTHKEY ""
  run_init
  assert_status 1
  assert_output_contains "TAILSCALE_AUTHKEY"
}

test_remote_profile_keeps_an_existing_node_without_an_auth_key() {
  enable_profiles remote
  set_var TAILSCALE_AUTHKEY ""
  mkdir -p "$SANDBOX/appdata/tailscale" && echo '{}' > "$SANDBOX/appdata/tailscale/tailscaled.state"
  run_init
  assert_status 0
}

test_remote_routes_must_be_subnets() {
  enable_profiles remote
  echo "TAILSCALE_ROUTES=192.168.0.0" >> "$ENV_FILE"
  run_init
  assert_status 1
  assert_output_contains "TAILSCALE_ROUTES"
  set_var TAILSCALE_ROUTES "192.168.0.0/24,10.0.0.0/8"
  run_init
  assert_status 0
}

test_extras_profile_requires_a_mousehole_password() {
  enable_profiles extras
  set_var MOUSEHOLE_AUTH_PASSWORD ""
  run_init
  assert_status 1
  assert_output_contains "MOUSEHOLE_AUTH_PASSWORD"
}

test_monitoring_profile_requires_a_wud_password() {
  enable_profiles monitoring
  set_var WUD_ADMIN_PASSWORD ""
  run_init
  assert_status 1
  assert_output_contains "WUD_ADMIN_PASSWORD"
}

test_gpu_override_requires_the_render_group() {
  echo "COMPOSE_FILE=compose.yaml:compose.gpu.yaml" >> "$ENV_FILE"
  run_init
  assert_status 1
  assert_output_contains "RENDER_GID"
  set_var RENDER_GID 105
  run_init
  assert_status 0
}

test_is_idempotent() {
  run_init
  run_init
  assert_status 0
}

test_does_not_touch_anything_when_validation_fails() {
  set_var PUID ""
  run_init
  [ ! -e "$SANDBOX/appdata" ] || fail "appdata was created despite invalid .env"
  assert_file_not_contains "$FAKE_DOCKER_LOG" "network create"
}

run_tests
