#!/usr/bin/env bash
# Tests for scripts/setup.sh. Answers are piped on stdin; init.sh, ip and getent are
# fakes, so they run anywhere. Usage: tests/setup.test.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$REPO/scripts/setup.sh"
. "$REPO/tests/lib.sh"

setup() {
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/bin" "$SANDBOX/dri"
  touch "$SANDBOX/dri/renderD128"
  export ENV_FILE="$SANDBOX/.env"
  export EXAMPLE_FILE="$REPO/.env.example"
  export DRI_DEVICE="$SANDBOX/dri"
  export INIT_SCRIPT="$SANDBOX/init.sh"
  export SUDO_UID=1234 SUDO_GID=5678
  printf '#!/usr/bin/env bash\necho "init ran"\n' > "$INIT_SCRIPT"
  cat > "$SANDBOX/bin/ip" <<'EOF'
#!/usr/bin/env bash
echo "172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1"
echo "192.168.7.0/24 dev eth0 proto kernel scope link src 192.168.7.10"
EOF
  cat > "$SANDBOX/bin/getent" <<'EOF'
#!/usr/bin/env bash
echo "render:x:105:"
EOF
  chmod +x "$INIT_SCRIPT" "$SANDBOX/bin/ip" "$SANDBOX/bin/getent"
  export PATH="$SANDBOX/bin:$PATH"
}

teardown() { rm -rf "$SANDBOX"; }

# run_setup "answer" "answer"...: one answer per prompt, in order; "" takes the default.
run_setup() {
  OUTPUT="$(printf '%s\n' "$@" | "$SETUP" 2>&1)"
  STATUS=$?
}

# Answers for the paths section, then the ones every test starts a VPN with.
PATHS=("/srv/app" "/srv/data" "Europe/Madrid" "" "")
NO_PROFILES=(n n n n n n n n n n n)
NO_TELEGRAM=("")
# App connections: Jellyfin admin user and password, and the qualities (Enter keeps them),
# then the two Jellyfin customizations (Enter = no).
APPS=("" "" "" "" "")

test_writes_a_valid_env_for_the_core() {
  run_setup "${PATHS[@]}" protonvpn wireguard "wg-key=" "" y "${NO_PROFILES[@]}" n "${APPS[@]}" "${NO_TELEGRAM[@]}" n
  assert_status 0
  assert_file_contains "$ENV_FILE" "VPN_SERVICE_PROVIDER=protonvpn"
  assert_file_contains "$ENV_FILE" "VPN_PORT_FORWARDING=on"
  assert_file_contains "$ENV_FILE" "COMPOSE_PROFILES="
}

test_detects_puid_and_pgid_from_the_sudo_user() {
  run_setup "${PATHS[@]}" nordvpn "" key "" n "${NO_PROFILES[@]}" n "${APPS[@]}" "${NO_TELEGRAM[@]}" n
  assert_status 0
  assert_file_contains "$ENV_FILE" "PUID=1234"
  assert_file_contains "$ENV_FILE" "PGID=5678"
  assert_file_contains "$ENV_FILE" "APPDATA_ROOT=/srv/app"
  assert_file_contains "$ENV_FILE" "TZ=Europe/Madrid"
}

test_asks_only_the_credentials_of_the_chosen_type() {
  # nordvpn: WireGuard chosen -> key asked, no OpenVPN user.
  run_setup "${PATHS[@]}" nordvpn wireguard "wg-key=" "Spain" n "${NO_PROFILES[@]}" n "${APPS[@]}" "${NO_TELEGRAM[@]}" n
  assert_status 0
  assert_file_contains "$ENV_FILE" "VPN_TYPE=wireguard"
  assert_file_contains "$ENV_FILE" "WIREGUARD_PRIVATE_KEY=wg-key="
  assert_file_contains "$ENV_FILE" "VPN_SERVER_COUNTRIES=Spain"
  assert_output_not_contains "OpenVPN user"
}

test_openvpn_only_providers_ask_user_and_password() {
  run_setup "${PATHS[@]}" surfshark openvpn me secret "" "${NO_PROFILES[@]}" n "${APPS[@]}" "${NO_TELEGRAM[@]}" n
  assert_status 0
  assert_file_contains "$ENV_FILE" "VPN_TYPE=openvpn"
  assert_file_contains "$ENV_FILE" "OPENVPN_USER=me"
  assert_file_contains "$ENV_FILE" "OPENVPN_PASSWORD=secret"
  assert_output_not_contains "WireGuard private key"
}

test_provider_without_wireguard_skips_the_type_question() {
  run_setup "${PATHS[@]}" "Private Internet Access" pia-user pia-pass "" y "${NO_PROFILES[@]}" n "${APPS[@]}" "${NO_TELEGRAM[@]}" n
  assert_status 0
  assert_output_not_contains "Connection type (wireguard or openvpn)"
  assert_file_contains "$ENV_FILE" "VPN_SERVICE_PROVIDER='private internet access'"
  assert_file_contains "$ENV_FILE" "VPN_TYPE=openvpn"
  assert_file_contains "$ENV_FILE" "OPENVPN_USER=pia-user"
  assert_file_contains "$ENV_FILE" "OPENVPN_PASSWORD=pia-pass"
  assert_file_contains "$ENV_FILE" "VPN_PORT_FORWARDING=on"
}

test_airvpn_is_offered_wireguard_only_with_address_and_preshared_key() {
  run_setup "${PATHS[@]}" airvpn "wg-key=" "10.0.0.2/32" "psk=" "" "${NO_PROFILES[@]}" n "${APPS[@]}" "${NO_TELEGRAM[@]}" n
  assert_status 0
  assert_output_not_contains "Connection type (wireguard or openvpn)"
  assert_file_contains "$ENV_FILE" "VPN_TYPE=wireguard"
  assert_file_contains "$ENV_FILE" "WIREGUARD_ADDRESSES=10.0.0.2/32"
  assert_file_contains "$ENV_FILE" "WIREGUARD_PRESHARED_KEY=psk="
}

test_openvpn_providers_with_a_client_certificate_say_where_to_put_it() {
  run_setup "${PATHS[@]}" cyberghost u p "" "${NO_PROFILES[@]}" n "${APPS[@]}" "${NO_TELEGRAM[@]}" n
  assert_status 0
  assert_output_contains "client.crt and"
  assert_output_contains "/srv/app/gluetun"
}

test_mullvad_accepts_both_types_and_needs_the_address() {
  run_setup "${PATHS[@]}" mullvad wireguard "wg-key=" "10.64.222.21/32" "" "${NO_PROFILES[@]}" n "${APPS[@]}" "${NO_TELEGRAM[@]}" n
  assert_status 0
  assert_output_contains "Connection type (wireguard or openvpn)"
  assert_file_contains "$ENV_FILE" "WIREGUARD_ADDRESSES=10.64.222.21/32"
}

test_no_port_forwarding_question_for_providers_without_it() {
  run_setup "${PATHS[@]}" cyberghost u p "" "${NO_PROFILES[@]}" n "${APPS[@]}" "${NO_TELEGRAM[@]}" n
  assert_status 0
  assert_output_not_contains "port forwarding (better seeding)"
  assert_file_contains "$ENV_FILE" "VPN_PORT_FORWARDING=off"
}

test_profiles_are_written_to_compose_profiles() {
  # vo, remote and transcode on.
  run_setup "${PATHS[@]}" cyberghost u p "" n y n n n n n n y n y \
    n tskey "" "${APPS[@]}" "" n
  assert_status 0
  assert_file_contains "$ENV_FILE" "COMPOSE_PROFILES=vo,remote,transcode"
}

test_remote_profile_offers_the_detected_lan_subnet() {
  run_setup "${PATHS[@]}" cyberghost u p "" n n n n n n n n y n n \
    n tskey "" "${APPS[@]}" ""
  assert_status 0
  assert_file_contains "$ENV_FILE" "TAILSCALE_AUTHKEY=tskey"
  assert_file_contains "$ENV_FILE" "TAILSCALE_ROUTES=192.168.7.0/24"
}

test_gpu_is_offered_with_the_render_group() {
  run_setup "${PATHS[@]}" cyberghost u p "" "${NO_PROFILES[@]}" y "" "${APPS[@]}" "${NO_TELEGRAM[@]}" n
  assert_status 0
  assert_file_contains "$ENV_FILE" "COMPOSE_FILE=compose.yaml:compose.gpu.yaml"
  assert_file_contains "$ENV_FILE" "RENDER_GID=105"
}

test_gpu_is_not_offered_without_dri() {
  rm "$DRI_DEVICE/renderD128"
  run_setup "${PATHS[@]}" cyberghost u p "" "${NO_PROFILES[@]}" "${APPS[@]}" "${NO_TELEGRAM[@]}" n
  assert_status 0
  assert_output_contains "not found or empty: no GPU to offer"
  ! grep -q '^COMPOSE_FILE=' "$ENV_FILE" || fail "COMPOSE_FILE must stay commented out"
}

test_generates_the_secrets_the_chosen_profiles_need() {
  # backup, dashboard, monitoring, extras on.
  run_setup "${PATHS[@]}" cyberghost u p "" y n n n n y y n n y n \
    n "" "" "" "" "" "" "" "" "" "" ""
  assert_status 0
  local var
  for var in RESTIC_PASSWORD WUD_ADMIN_PASSWORD MOUSEHOLE_AUTH_PASSWORD; do
    grep -qE "^$var=[0-9a-f]{32}$" "$ENV_FILE" || fail "$var was not generated"
  done
  grep -qE "^HOMARR_SECRET_KEY=[0-9a-f]{64}$" "$ENV_FILE" || fail "HOMARR_SECRET_KEY was not generated"
}

test_proxy_profile_stores_the_domain() {
  run_setup "${PATHS[@]}" cyberghost u p "" n n n n n n n y n n n \
    n media.example.com "${APPS[@]}" "${NO_TELEGRAM[@]}" n
  assert_status 0
  assert_file_contains "$ENV_FILE" "PROXY_DOMAIN=media.example.com"
  assert_output_contains "media.example.com"
}

test_telegram_bot_is_optional_and_stored() {
  run_setup "${PATHS[@]}" cyberghost u p "" "${NO_PROFILES[@]}" n "${APPS[@]}" "123:abc" "42" n
  assert_status 0
  assert_file_contains "$ENV_FILE" "TELEGRAM_BOT_TOKEN=123:abc"
  assert_file_contains "$ENV_FILE" "TELEGRAM_CHAT_ID=42"
}

test_generates_the_app_keys_and_the_qbittorrent_password() {
  run_setup "${PATHS[@]}" cyberghost u p "" "${NO_PROFILES[@]}" n "${APPS[@]}" "${NO_TELEGRAM[@]}" n
  assert_status 0
  local var
  for var in RADARR_API_KEY SONARR_API_KEY PROWLARR_API_KEY BAZARR_API_KEY SEERR_API_KEY QBITTORRENT_PASSWORD JELLYFIN_ADMIN_PASSWORD; do
    grep -qE "^$var=[0-9a-f]{32}$" "$ENV_FILE" || fail "$var was not generated"
  done
  assert_file_contains "$ENV_FILE" "JELLYFIN_ADMIN_USER=admin"
  grep -qE "^RADARR_VO_API_KEY=$" "$ENV_FILE" || fail "RADARR_VO_API_KEY is only for the vo Profile"
  assert_output_contains "Generated qBittorrent login: admin / "
}

test_vo_profile_gets_its_keys_and_an_explanation() {
  run_setup "${PATHS[@]}" cyberghost u p "" n y n n n n n n n n n n "${APPS[@]}" "${NO_TELEGRAM[@]}" n
  assert_status 0
  assert_output_contains "one Radarr/Sonarr cannot hold two copies"
  grep -qE "^RADARR_VO_API_KEY=[0-9a-f]{32}$" "$ENV_FILE" || fail "RADARR_VO_API_KEY was not generated"
  grep -qE "^SONARR_VO_API_KEY=[0-9a-f]{32}$" "$ENV_FILE" || fail "SONARR_VO_API_KEY was not generated"
}

test_apps_already_set_up_keep_their_own_keys() {
  mkdir -p "$SANDBOX/app/radarr" "$SANDBOX/app/qbittorrent/qBittorrent"
  touch "$SANDBOX/app/radarr/config.xml" "$SANDBOX/app/qbittorrent/qBittorrent/qBittorrent.conf"
  run_setup "$SANDBOX/app" "/srv/data" "Europe/Madrid" "" "" cyberghost u p "" "${NO_PROFILES[@]}" n \
    "my-qbit-pass" "" "" "" "" "" "${NO_TELEGRAM[@]}" n
  assert_status 0
  grep -qE "^RADARR_API_KEY=$" "$ENV_FILE" || fail "RADARR_API_KEY must stay empty for a Radarr already set up"
  grep -qE "^SONARR_API_KEY=[0-9a-f]{32}$" "$ENV_FILE" || fail "SONARR_API_KEY was not generated"
  assert_file_contains "$ENV_FILE" "QBITTORRENT_PASSWORD=my-qbit-pass"
}

test_a_jellyfin_already_set_up_gets_no_generated_password() {
  mkdir -p "$SANDBOX/app/jellyfin/config/data"
  run_setup "$SANDBOX/app" "/srv/data" "Europe/Madrid" "" "" cyberghost u p "" "${NO_PROFILES[@]}" n \
    "" "" "" "" "" "${NO_TELEGRAM[@]}" n
  assert_status 0
  assert_output_contains "Jellyfin is already set up"
  grep -qE "^JELLYFIN_ADMIN_PASSWORD=$" "$ENV_FILE" || fail "JELLYFIN_ADMIN_PASSWORD must not be generated"
}

test_qualities_start_ticked_and_can_be_toggled() {
  # Untick Remux-2160p (1) and tick DVD (15), then accept.
  run_setup "${PATHS[@]}" cyberghost u p "" "${NO_PROFILES[@]}" n "" "" "1 15" "" "" "" "${NO_TELEGRAM[@]}" n
  assert_status 0
  assert_output_contains " 1 [x] Remux-2160p"
  assert_output_contains " 1 [ ] Remux-2160p"
  assert_file_contains "$ENV_FILE" "QUALITIES='Bluray-2160p,WEB 2160p,HDTV-2160p,Remux-1080p,Bluray-1080p,WEB 1080p,HDTV-1080p,Bluray-720p,WEB 720p,DVD'"
}

test_at_least_one_quality_must_be_ticked() {
  run_setup "${PATHS[@]}" cyberghost u p "" "${NO_PROFILES[@]}" n "" "" "1 2 3 4 5 6 7 8 9 10" "" "18" "" "" "" "${NO_TELEGRAM[@]}" n
  assert_status 0
  assert_output_contains "Tick at least one quality."
  assert_file_contains "$ENV_FILE" "QUALITIES=BR-DISK"
}

test_jellyfin_customizations_are_opt_in_and_kept_on_rerun() {
  run_setup "${PATHS[@]}" cyberghost u p "" "${NO_PROFILES[@]}" n "" "" "" y n "${NO_TELEGRAM[@]}" n
  assert_status 0
  assert_file_contains "$ENV_FILE" "JELLYFIN_ABYSS=on"
  assert_file_contains "$ENV_FILE" "JELLYFIN_SEERR_REPORTER=off"
  run_setup "${PATHS[@]}" cyberghost u p "" "${NO_PROFILES[@]}" n "" "" "" "" "" "${NO_TELEGRAM[@]}" n
  assert_status 0
  assert_output_contains "Apply the Abyss theme to Jellyfin (dark, Spotlight home banner)? [Y/n]"
  assert_file_contains "$ENV_FILE" "JELLYFIN_ABYSS=on"
}

test_plain_root_does_not_default_the_owner_to_root() {
  unset SUDO_UID SUDO_GID
  run_setup "/srv/app" "/srv/data" "Europe/Madrid" "" "" cyberghost u p "" "${NO_PROFILES[@]}" n "${APPS[@]}" "${NO_TELEGRAM[@]}" n
  assert_status 0
  [ "$(id -u)" != 0 ] || assert_file_contains "$ENV_FILE" "PUID=1000"
}

test_hands_off_to_init() {
  run_setup "${PATHS[@]}" cyberghost u p "" "${NO_PROFILES[@]}" n "${APPS[@]}" "${NO_TELEGRAM[@]}" y
  assert_status 0
  assert_output_contains "init ran"
}

test_declining_the_hand_off_prints_the_command() {
  run_setup "${PATHS[@]}" cyberghost u p "" "${NO_PROFILES[@]}" n "${APPS[@]}" "${NO_TELEGRAM[@]}" n
  assert_status 0
  assert_output_not_contains "init ran"
  assert_output_contains "sudo scripts/init.sh"
}

test_rerun_offers_current_values_and_keeps_the_rest() {
  cat > "$ENV_FILE" <<EOF
# my notes
APPDATA_ROOT=/old/app
DATA_ROOT=/old/data
TZ=Asia/Tokyo
PUID=999
PGID=998
VPN_SERVICE_PROVIDER=cyberghost
VPN_TYPE=openvpn
OPENVPN_USER=me
OPENVPN_PASSWORD='p w'
COMPOSE_PROFILES=vo,extras
MOUSEHOLE_AUTH_PASSWORD=keepme
BESZEL_APP_URL=http://x:8090
EOF
  # Enter on everything: nothing changes.
  run_setup "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" ""
  assert_status 0
  assert_file_contains "$ENV_FILE" "# my notes"
  assert_file_contains "$ENV_FILE" "APPDATA_ROOT=/old/app"
  assert_file_contains "$ENV_FILE" "PUID=999"
  assert_file_contains "$ENV_FILE" "OPENVPN_PASSWORD='p w'"
  assert_file_contains "$ENV_FILE" "COMPOSE_PROFILES=vo,extras"
  assert_file_contains "$ENV_FILE" "MOUSEHOLE_AUTH_PASSWORD=keepme"
  assert_file_contains "$ENV_FILE" "BESZEL_APP_URL=http://x:8090"
}

test_rerun_saves_a_backup_of_the_previous_env() {
  printf 'APPDATA_ROOT=/old/app\nVPN_SERVICE_PROVIDER=cyberghost\nVPN_TYPE=openvpn\n' > "$ENV_FILE"
  run_setup "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" ""
  assert_status 0
  assert_file_contains "$ENV_FILE.bak" "APPDATA_ROOT=/old/app"
}

test_an_invalid_answer_is_asked_again() {
  run_setup "relative/path" "${PATHS[@]}" cyberghost u p "" "${NO_PROFILES[@]}" n "${APPS[@]}" "${NO_TELEGRAM[@]}" n
  assert_status 0
  assert_output_contains "'relative/path' is not valid here."
  assert_file_contains "$ENV_FILE" "APPDATA_ROOT=/srv/app"
}

test_nothing_is_written_when_input_ends_early() {
  run_setup "/srv/app"
  [ ! -e "$ENV_FILE" ] || fail "expected no .env after an incomplete run"
}

test_the_written_env_is_readable_only_by_its_owner() {
  run_setup "${PATHS[@]}" cyberghost u p "" "${NO_PROFILES[@]}" n "${APPS[@]}" "${NO_TELEGRAM[@]}" n
  assert_status 0
  [ "$(stat -c '%a' "$ENV_FILE")" = 600 ] || fail "expected mode 600"
}

run_tests
