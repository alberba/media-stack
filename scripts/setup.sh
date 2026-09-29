#!/usr/bin/env bash
# Interactive wizard that writes .env for an Instance, then hands off to init.sh.
# It starts from the existing .env (or .env.example) and only changes the settings it
# asks about, so re-running it offers your current values as defaults and never wipes
# comments or settings it does not know. Nothing is written until the last question is
# answered. At any prompt: Enter keeps the value in brackets, "-" clears it.
#
# Usage: scripts/setup.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO/.env}"
EXAMPLE_FILE="${EXAMPLE_FILE:-$REPO/.env.example}"
INIT_SCRIPT="${INIT_SCRIPT:-$REPO/scripts/init.sh}"
DRI_DEVICE="${DRI_DEVICE:-/dev/dri}"

# Profiles, in the order they are asked and written to COMPOSE_PROFILES.
PROFILES=(backup vo jackett seeding cleanup dashboard monitoring proxy remote extras transcode)
declare -A PROFILE_HELP=(
  [backup]="nightly encrypted copy of the App data"
  [vo]="second Radarr/Sonarr for an original-version library"
  [jackett]="Jackett, for indexers Prowlarr lacks"
  [seeding]="qui and cleanuparr, around qBittorrent"
  [cleanup]="Maintainerr, removes library items by rules"
  [dashboard]="Homarr and Dockge"
  [monitoring]="Beszel and What's Up Docker"
  [proxy]="Nginx Proxy Manager, HTTPS entry point from the internet"
  [remote]="Tailscale"
  [extras]="issue-automator, mousehole, Tor proxy, File Browser"
  [transcode]="Tdarr server, for a Worker to transcode with"
)

# VPN provider data, checked against the gluetun image pinned in stacks/vpn/compose.yaml
# (v3.41.3): its provider list and the config errors it reports at startup. Re-check it
# when that image is bumped. Providers typed that are not listed here still work: the
# wizard then asks everything.
VPN_PROVIDERS=(airvpn cyberghost expressvpn fastestvpn giganews hidemyass ipvanish ivpn mullvad
  nordvpn "perfect privacy" "private internet access" privado privatevpn protonvpn purevpn
  slickvpn surfshark torguard vpnsecure "vpn unlimited" vyprvpn windscribe)
# Providers that accept WireGuard (the other listed ones are OpenVPN only).
WIREGUARD_PROVIDERS="|airvpn|fastestvpn|ivpn|mullvad|nordvpn|protonvpn|surfshark|windscribe|"
# Providers where the wizard offers WireGuard only: airvpn's OpenVPN needs a client
# certificate and key, not a user and password.
WIREGUARD_ONLY_PROVIDERS="|airvpn|"
# Providers that need the WireGuard interface address on top of the private key.
ADDRESS_PROVIDERS="|airvpn|fastestvpn|ivpn|mullvad|surfshark|windscribe|"
# Providers whose OpenVPN needs a client certificate and key on top of user and password.
CLIENT_CERT_PROVIDERS="|airvpn|cyberghost|vpnsecure|vpn unlimited|"
# Providers whose WireGuard also needs a preshared key.
PRESHARED_KEY_PROVIDERS="|airvpn|"
# Providers whose port forwarding gluetun can request.
PORT_FORWARDING_PROVIDERS="|perfect privacy|private internet access|privatevpn|protonvpn|"

WORK=""
EXISTING=0

die() { echo "error: $*" >&2; exit 1; }

# --- The .env being edited ----------------------------------------------------

# Current value of $1 in the working file (last active line wins), unquoted.
get_env() {
  local line value
  line="$(grep -E "^$1=" "$WORK" | tail -n 1 || true)"
  value="${line#*=}"
  if [[ "$value" =~ ^\"([^\"]*)\" || "$value" =~ ^\'([^\']*)\' ]]; then
    value="${BASH_REMATCH[1]}"
  else
    value="${value%%[[:space:]]#*}"
    value="${value%"${value##*[![:space:]]}"}"
  fi
  printf '%s' "$value"
}

# Quotes a value only when compose would otherwise misread it.
quote_value() {
  local v="$1"
  if [[ "$v" =~ [[:space:]\#\'\"\$\\] ]]; then
    if [[ "$v" != *\'* ]]; then
      printf "'%s'" "$v"
    else
      v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; v="${v//\$/\\\$}"
      printf '"%s"' "$v"
    fi
  else
    printf '%s' "$v"
  fi
}

# Sets KEY=value in place: replaces the active line, else uncomments the example line,
# else appends.
set_env() {
  local key="$1" value tmp
  value="$(quote_value "$2")"
  tmp="$(mktemp)"
  if grep -qE "^$key=" "$WORK"; then
    K="$key" V="$value" awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"] }
      index($0, k "=") == 1 { print k "=" v; next } { print }' "$WORK" > "$tmp"
  elif grep -qE "^# $key=" "$WORK"; then
    K="$key" V="$value" awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"] }
      !done && index($0, "# " k "=") == 1 { print k "=" v; done = 1; next } { print }' "$WORK" > "$tmp"
  else
    { cat "$WORK"; printf '%s=%s\n' "$key" "$value"; } > "$tmp"
  fi
  cat "$tmp" > "$WORK"
  rm -f "$tmp"
}

# Turns an active KEY=value line back into the commented example.
comment_out_env() { sed -i "s|^$1=|# $1=|" "$WORK"; }

# --- Prompts ------------------------------------------------------------------

# Reads one answer into ANSWER. EOF_HIT is 1 when stdin has ended.
read_answer() {
  EOF_HIT=0
  ANSWER=""
  IFS= read -r ${1:+-s} ANSWER || { [ -n "$ANSWER" ] || EOF_HIT=1; }
  [ -z "$1" ] || echo
}

# Default for KEY: the current value when re-running, else the detected one.
default_for() {
  local cur; cur="$(get_env "$1")"
  if [ "$EXISTING" = 1 ] && [ -n "$cur" ]; then printf '%s' "$cur"; else printf '%s' "${2:-$cur}"; fi
}

# ask KEY "label" [detected] [regex the answer must match] [secret]
ask() {
  local key="$1" label="$2" detected="${3:-}" pattern="${4:-}" secret="${5:-}"
  local def shown
  def="$(default_for "$key" "$detected")"
  shown="$def"
  if [ -n "$secret" ]; then shown="${def:+keep current}"; fi
  while true; do
    printf '%s [%s]: ' "$label" "$shown"
    read_answer "$secret"
    [ -n "$ANSWER" ] || ANSWER="$def"
    [ "$ANSWER" != "-" ] || ANSWER=""
    if [ -n "$pattern" ] && [ -n "$ANSWER" ] && ! [[ "$ANSWER" =~ $pattern ]]; then
      echo "  '$ANSWER' is not valid here."
      [ "$EOF_HIT" = 0 ] || die "input ended with an invalid value for $key."
      continue
    fi
    set_env "$key" "$ANSWER"
    return
  done
}

# confirm "question" y|n: true for yes. Enter takes the default; EOF too.
confirm() {
  local hint="y/N"
  [ "$2" != y ] || hint="Y/n"
  printf '%s [%s] ' "$1" "$hint"
  read_answer ""
  [ -n "$ANSWER" ] || ANSWER="$2"
  [[ "$ANSWER" =~ ^[Yy] ]]
}

# 32 hex characters per 16 bytes.
random_hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }

# A secret the Operator may type, keep or have generated. Generated values are printed
# once, because the Operator needs them to log in.
ask_or_generate() {
  local key="$1" label="$2" cur
  cur="$(get_env "$key")"
  printf '%s (Enter = %s): ' "$label" "$([ -n "$cur" ] && echo keep current || echo generate one)"
  read_answer 1
  if [ -n "$ANSWER" ]; then
    set_env "$key" "$ANSWER"
  elif [ -z "$cur" ]; then
    set_env "$key" "$(random_hex 16)"
    echo "  Generated $key=$(get_env "$key"): save it in your password manager."
  fi
}

# --- Detection ----------------------------------------------------------------

detect_tz() {
  local tz=""
  tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  [ -n "$tz" ] || { [ ! -r /etc/timezone ] || tz="$(head -n 1 /etc/timezone)"; }
  [ -n "$tz" ] || { tz="$(readlink /etc/localtime 2>/dev/null || true)"; tz="${tz#*zoneinfo/}"; }
  printf '%s' "$tz"
}

# The owner of the files is the person who ran sudo, not root. Plain root detects
# nothing, so the example's 1000 stays the default instead of running services as root.
detect_uid() { local id="${SUDO_UID:-$(id -u)}"; [ "$id" = 0 ] || printf '%s' "$id"; }
detect_gid() { local id="${SUDO_GID:-$(id -g)}"; [ "$id" = 0 ] || printf '%s' "$id"; }

# First directly connected IPv4 subnet that is not a container or VPN interface.
detect_subnet() {
  ip -o -4 route show scope link 2>/dev/null \
    | awk '$3 !~ /^(docker|br-|veth|virbr|tailscale|tun|wg)/ { print $1; exit }' || true
}

detect_render_gid() { getent group render 2>/dev/null | cut -d: -f3 || true; }

# --- Sections -----------------------------------------------------------------

section() { printf '\n== %s ==\n' "$1"; }

ask_paths() {
  section "Paths, owner and time zone"
  ask APPDATA_ROOT "App data folder (every service's config; keep it outside this repo)" "" '^/'
  ask DATA_ROOT "Media folder, mounted as /data (downloads and library on the same filesystem)" "" '^/'
  ask TZ "Time zone" "$(detect_tz)" '^[A-Za-z0-9_+/-]+$'
  ask PUID "User id that owns the files" "$(detect_uid)" '^[0-9]+$'
  ask PGID "Group id that owns the files" "$(detect_gid)" '^[0-9]+$'
}

ask_vpn() {
  section "VPN"
  local list; list="$(printf '%s, ' "${VPN_PROVIDERS[@]}")"
  echo "Providers gluetun supports: ${list%, }" | fold -s -w 78
  local provider
  while true; do
    ask VPN_SERVICE_PROVIDER "VPN provider" "" '^[A-Za-z0-9 ]+$'
    provider="$(get_env VPN_SERVICE_PROVIDER | tr '[:upper:]' '[:lower:]')"
    [ -n "$provider" ] && break
    echo "  A provider is required."
    [ "$EOF_HIT" = 0 ] || die "input ended without a VPN provider."
  done
  set_env VPN_SERVICE_PROVIDER "$provider"

  local known=0 p
  for p in "${VPN_PROVIDERS[@]}"; do [ "$p" != "$provider" ] || known=1; done

  local type
  if [ "$known" = 1 ] && [[ "$WIREGUARD_ONLY_PROVIDERS" == *"|$provider|"* ]]; then
    type=wireguard
  elif [ "$known" = 1 ] && [[ "$WIREGUARD_PROVIDERS" != *"|$provider|"* ]]; then
    type=openvpn
  else
    ask VPN_TYPE "Connection type (wireguard or openvpn)" "wireguard" '^(wireguard|openvpn)$'
    type="$(get_env VPN_TYPE)"
  fi
  set_env VPN_TYPE "$type"
  echo "  Connection type: $type"

  if [ "$type" = wireguard ]; then
    ask WIREGUARD_PRIVATE_KEY "WireGuard private key (from your provider's config file)" "" "" secret
    if [ "$known" = 0 ] || [[ "$ADDRESS_PROVIDERS" == *"|$provider|"* ]]; then
      ask WIREGUARD_ADDRESSES "WireGuard interface address, e.g. 10.64.222.21/32" "" '^[0-9a-fA-F:.,/ ]+$'
    fi
    if [[ "$PRESHARED_KEY_PROVIDERS" == *"|$provider|"* ]]; then
      ask WIREGUARD_PRESHARED_KEY "WireGuard preshared key (from your provider's config file)" "" "" secret
    fi
  else
    ask OPENVPN_USER "OpenVPN user (often not your account login)"
    ask OPENVPN_PASSWORD "OpenVPN password" "" "" secret
    if [[ "$CLIENT_CERT_PROVIDERS" == *"|$provider|"* ]]; then
      echo "  $provider also needs your client certificate and key: save them as client.crt and"
      echo "  client.key in $(get_env APPDATA_ROOT)/gluetun (init.sh creates that folder)."
    fi
  fi

  ask VPN_SERVER_COUNTRIES "Server countries, comma separated (optional)"

  if [ "$known" = 0 ] || [[ "$PORT_FORWARDING_PROVIDERS" == *"|$provider|"* ]]; then
    local current; current="$(get_env VPN_PORT_FORWARDING)"
    local default=n; [ "$current" != on ] || default=y
    if confirm "Use VPN port forwarding (better seeding)?" "$default"; then
      set_env VPN_PORT_FORWARDING on
      echo "  qBittorrent needs \"Bypass authentication for clients on localhost\" (Options > WebUI)."
    else
      set_env VPN_PORT_FORWARDING off
    fi
  else
    set_env VPN_PORT_FORWARDING off
    echo "  $provider has no port forwarding gluetun can use: it stays off."
  fi
}

ask_profiles() {
  section "Profiles"
  echo "Optional groups of services on top of the Core (docs/profiles.md)."
  PROFILES_ON=","
  local current profile default chosen=""
  current=",$(get_env COMPOSE_PROFILES | tr -d '[:space:]'),"
  for profile in "${PROFILES[@]}"; do
    default=n
    if [[ "$current" == *",$profile,"* ]]; then default=y; fi
    if confirm "  $profile: ${PROFILE_HELP[$profile]}?" "$default"; then
      chosen+="${chosen:+,}$profile"
      PROFILES_ON+="$profile,"
    fi
  done
  set_env COMPOSE_PROFILES "$chosen"
}

profile_chosen() { [[ "$PROFILES_ON" == *",$1,"* ]]; }

ask_gpu() {
  section "Hardware transcoding"
  local current default=n
  current="$(get_env COMPOSE_FILE)"
  [[ "$current" != *compose.gpu.yaml* ]] || default=y
  if [ -z "$(ls -A "$DRI_DEVICE" 2>/dev/null)" ]; then
    echo "$DRI_DEVICE not found or empty: no GPU to offer. Current setting kept."
    return
  fi
  [ "$EXISTING" = 1 ] || default=y
  if confirm "Use this host's GPU ($DRI_DEVICE) for Jellyfin and Tdarr (compose.gpu.yaml)?" "$default"; then
    set_env COMPOSE_FILE "compose.yaml:compose.gpu.yaml"
    ask RENDER_GID "Render group id" "$(detect_render_gid)" '^[0-9]+$'
  else
    comment_out_env COMPOSE_FILE
  fi
}

ask_profile_settings() {
  if profile_chosen backup; then
    section "Profile backup"
    echo "Keep RESTIC_PASSWORD and APPDATA_ROOT/backup/rclone.conf: without them the backup cannot be read."
    ask_or_generate RESTIC_PASSWORD "RESTIC_PASSWORD"
    ask RESTIC_REPOSITORY "Restic repository (an rclone remote and folder)"
  fi
  if profile_chosen dashboard; then
    if ! [[ "$(get_env HOMARR_SECRET_KEY)" =~ ^[0-9a-fA-F]{64}$ ]]; then
      set_env HOMARR_SECRET_KEY "$(random_hex 32)"
      echo "Homarr key generated: it is in .env, keep it (Homarr cannot read its database without it)."
    fi
  fi
  if profile_chosen monitoring; then
    section "Profile monitoring"
    ask WUD_ADMIN_USER "What's Up Docker user"
    ask_or_generate WUD_ADMIN_PASSWORD "What's Up Docker password"
  fi
  if profile_chosen extras; then
    section "Profile extras"
    ask_or_generate MOUSEHOLE_AUTH_PASSWORD "mousehole web UI password"
  fi
  if profile_chosen remote; then
    section "Profile remote (Tailscale)"
    ask TAILSCALE_AUTHKEY "Tailscale auth key (login.tailscale.com/admin/settings/keys)" "" "" secret
    ask TAILSCALE_ROUTES "LAN subnet to advertise (optional)" "$(detect_subnet)" '^[0-9a-fA-F:.]+/[0-9]{1,3}(,[0-9a-fA-F:.]+/[0-9]{1,3})*$'
  fi
  if profile_chosen proxy; then
    section "Profile proxy"
    ask PROXY_DOMAIN "Public domain Jellyfin and Seerr are reached at (optional)" "" '^[A-Za-z0-9.-]+$'
  fi
}

ask_telegram() {
  section "Telegram notifications (optional)"
  echo "Alerts from backup, What's Up Docker and issue-automator. Enter skips."
  ask TELEGRAM_BOT_TOKEN "Bot token from @BotFather" "" "" secret
  [ -z "$(get_env TELEGRAM_BOT_TOKEN)" ] || ask TELEGRAM_CHAT_ID "Chat id that receives the alerts"
}

# --- Main ---------------------------------------------------------------------

finish() {
  if [ -f "$ENV_FILE" ]; then
    cp "$ENV_FILE" "$ENV_FILE.bak"
    echo "Previous $ENV_FILE saved as $ENV_FILE.bak."
  fi
  cat "$WORK" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "Wrote $ENV_FILE."
  if profile_chosen proxy && [ -n "$(get_env PROXY_DOMAIN)" ]; then
    echo "Next for the proxy Profile: point $(get_env PROXY_DOMAIN) at this host, open port 81 and add proxy hosts for jellyfin:8096 and seerr:5055."
  fi
}

hand_off() {
  section "Prepare the Instance"
  if ! confirm "Run scripts/init.sh now (validates, creates folders and the network)?" y; then
    echo "Later: sudo scripts/init.sh"
    return
  fi
  if [ "$(id -u)" = 0 ]; then
    "$INIT_SCRIPT"
  else
    sudo "$INIT_SCRIPT"
  fi
}

main() {
  if [ -f "$ENV_FILE" ]; then
    EXISTING=1
    echo "Found $ENV_FILE: its values are the defaults."
    WORK="$(mktemp)"; cp "$ENV_FILE" "$WORK"
  else
    [ -f "$EXAMPLE_FILE" ] || die "no $EXAMPLE_FILE to start from."
    WORK="$(mktemp)"; cp "$EXAMPLE_FILE" "$WORK"
  fi
  trap 'rm -f "$WORK"' EXIT

  ask_paths
  ask_vpn
  ask_profiles
  ask_gpu
  ask_profile_settings
  ask_telegram
  finish
  hand_off
}

main "$@"
