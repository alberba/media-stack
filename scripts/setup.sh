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

# shellcheck source=scripts/lib/profiles.sh
. "$REPO/scripts/lib/profiles.sh"

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

# Qualities the wizard offers for the Wiring's quality profile, best first (the names
# stacks/wire/wire/quality.py knows), and the ones ticked by default.
QUALITY_NAMES=("Remux-2160p" "Bluray-2160p" "WEB 2160p" "HDTV-2160p" "Remux-1080p" "Bluray-1080p"
  "WEB 1080p" "HDTV-1080p" "Bluray-720p" "WEB 720p" "HDTV-720p" "Bluray-576p" "Bluray-480p"
  "WEB 480p" "DVD" "SDTV" "Raw-HD" "BR-DISK")
QUALITY_DEFAULTS="Remux-2160p,Bluray-2160p,WEB 2160p,HDTV-2160p,Remux-1080p,Bluray-1080p,WEB 1080p,HDTV-1080p,Bluray-720p,WEB 720p"

WORK=""
EXISTING=0
PROFILES_CHOSEN=""

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
  local current profile default chosen=""
  current="$(get_env COMPOSE_PROFILES)"
  for profile in $(profiles_all); do
    default=n
    if profile_on "$profile" "$current"; then default=y; fi
    if [ "$profile" = vo ]; then
      echo "  vo keeps dubbed and original-version copies as separate files, each with its own"
      echo "  language rules: one Radarr/Sonarr cannot hold two copies of the same title. Only"
      echo "  say yes if you want both; if you watch in one language, one manager is enough."
    fi
    if confirm "  $profile: $(profile_help "$profile")?" "$default"; then
      chosen+="${chosen:+,}$profile"
    fi
  done
  PROFILES_CHOSEN="$chosen"
  set_env COMPOSE_PROFILES "$chosen"
}

profile_chosen() { profile_on "$1" "$PROFILES_CHOSEN"; }

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

# --- App connections (the Wiring) ------------------------------------------

# Generates KEY unless it is set, or the app already has App data (then the Wiring
# reads the key the app really uses from there).
generate_key() {
  local key="$1" file
  file="$(get_env APPDATA_ROOT)/$2"
  [ -z "$(get_env "$key")" ] || return 0
  [ ! -e "$file" ] || return 0
  set_env "$key" "$(random_hex 16)"
}

ask_qualities() {
  echo "Qualities Radarr and Sonarr may download (higher in the list is preferred)."
  echo "Remux and BR-DISK are full-size disc copies (40-80 GB per 4K film); 2160p needs 4K screens."
  local current i n chosen="" on
  current="$(get_env QUALITIES)"
  [ -n "$current" ] || current="$QUALITY_DEFAULTS"
  on=",$(printf '%s' "$current" | sed 's/ *, */,/g'),"
  while true; do
    for i in "${!QUALITY_NAMES[@]}"; do
      if [[ "$on" == *",${QUALITY_NAMES[$i]},"* ]]; then n=x; else n=" "; fi
      printf '  %2d [%s] %s\n' "$((i + 1))" "$n" "${QUALITY_NAMES[$i]}"
    done
    printf 'Numbers to tick or untick, separated by spaces (Enter = accept): '
    read_answer ""
    if [ -z "$ANSWER" ]; then
      [ "$on" != "," ] && break
      echo "  Tick at least one quality."
      [ "$EOF_HIT" = 0 ] || die "input ended with no quality ticked."
      continue
    fi
    for n in $ANSWER; do
      if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt "${#QUALITY_NAMES[@]}" ]; then
        echo "  '$n' is not in the list."
        continue
      fi
      i="${QUALITY_NAMES[$((n - 1))]}"
      if [[ "$on" == *",$i,"* ]]; then on="${on/,$i,/,}"; else on+="$i,"; fi
    done
    [ "$EOF_HIT" = 0 ] || break
  done
  for i in "${QUALITY_NAMES[@]}"; do
    [[ "$on" != *",$i,"* ]] || chosen+="${chosen:+,}$i"
  done
  set_env QUALITIES "$chosen"
}

ask_app_connections() {
  section "App connections"
  echo "The wire container connects the apps on every start; nothing to copy by hand."
  generate_key RADARR_API_KEY radarr/config.xml
  generate_key SONARR_API_KEY sonarr/config.xml
  generate_key PROWLARR_API_KEY prowlarr/config.xml
  generate_key BAZARR_API_KEY bazarr/config/config.yaml
  generate_key SEERR_API_KEY seerr/settings.json
  if profile_chosen vo; then
    generate_key RADARR_VO_API_KEY radarr-vo/config.xml
    generate_key SONARR_VO_API_KEY sonarr-vo/config.xml
  fi
  if [ -z "$(get_env QBITTORRENT_PASSWORD)" ]; then
    if [ -e "$(get_env APPDATA_ROOT)/qbittorrent/qBittorrent/qBittorrent.conf" ]; then
      echo "qBittorrent is already set up: its password lets Radarr and Sonarr log in."
      ask QBITTORRENT_PASSWORD "qBittorrent web UI password (optional)" "" "" secret
    else
      set_env QBITTORRENT_PASSWORD "$(random_hex 16)"
      echo "  Generated qBittorrent login: $(get_env QBITTORRENT_USER) / $(get_env QBITTORRENT_PASSWORD)"
    fi
  fi
  if [ -e "$(get_env APPDATA_ROOT)/jellyfin/config/data" ]; then
    echo "Jellyfin is already set up: its admin login lets Seerr sign in (Enter skips)."
    ask JELLYFIN_ADMIN_USER "Jellyfin admin user" "" '^[^[:space:]]+$'
    ask JELLYFIN_ADMIN_PASSWORD "Jellyfin admin password" "" "" secret
  else
    echo "Jellyfin's admin account, created on its first start. It is also your Seerr login."
    ask JELLYFIN_ADMIN_USER "Jellyfin admin user" "admin" '^[^[:space:]]+$'
    ask_or_generate JELLYFIN_ADMIN_PASSWORD "Jellyfin admin password"
  fi
  ask_qualities
}

# Optional Jellyfin customizations (docs/jellyfin-customizations.md): the Wiring applies them.
ask_jellyfin_extras() {
  section "Jellyfin customizations (optional)"
  local key label default
  for key in JELLYFIN_ABYSS JELLYFIN_SEERR_REPORTER; do
    case "$key" in
      JELLYFIN_ABYSS) label="Apply the Abyss theme to Jellyfin (dark, Spotlight home banner)?" ;;
      JELLYFIN_SEERR_REPORTER) label="Install SeerrReporter (Viewers report playback problems as Seerr issues)?" ;;
    esac
    default=n
    [ "$(get_env "$key")" != on ] || default=y
    if confirm "$label" "$default"; then set_env "$key" on; else set_env "$key" off; fi
  done
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
  ask_app_connections
  ask_jellyfin_extras
  ask_telegram
  finish
  hand_off
}

main "$@"
