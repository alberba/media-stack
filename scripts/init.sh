#!/usr/bin/env bash
# Validates the host and .env, then prepares an Instance: app data folders,
# the /data layout and the shared Docker network. Safe to run again at any time.
#
# Usage: scripts/init.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO/.env}"
TUN_DEVICE="${TUN_DEVICE:-/dev/net/tun}"
MIN_COMPOSE="2.20.0"

REQUIRED_VARS=(APPDATA_ROOT DATA_ROOT PUID PGID TZ VPN_SERVICE_PROVIDER VPN_TYPE)
DEFAULT_NETWORK="media-network"

# Folders under APPDATA_ROOT owned by PUID:PGID.
APPDATA_DIRS=(gluetun qbittorrent prowlarr radarr sonarr bazarr jellyfin/config jellyfin/cache)
# Seerr runs as the image's fixed `node` user.
SEERR_OWNER="1000:1000"
# TRaSH-style layout: downloads and library on the same filesystem, so imports are hardlinks.
DATA_DIRS=(torrents/movies torrents/tv media/movies media/tv)

errors=()
add_error() { errors+=("$1"); }

# Reads KEY=value lines from the .env without executing it.
load_env() {
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    if [[ "$value" =~ ^\"([^\"]*)\" || "$value" =~ ^\'([^\']*)\' ]]; then
      value="${BASH_REMATCH[1]}"
    else
      value="${value%%[[:space:]]#*}"
      value="${value%"${value##*[![:space:]]}"}"
    fi
    printf -v "ENV_$key" '%s' "$value"
  done < "$ENV_FILE"
}

env_get() { local name="ENV_$1"; printf '%s' "${!name:-}"; }

# True when Profile $1 is listed in COMPOSE_PROFILES.
profile_on() { [[ ",$(env_get COMPOSE_PROFILES | tr -d '[:space:]')," == *",$1,"* ]]; }

# True when version $1 >= version $2 (both "X.Y.Z", optional leading "v").
version_ge() {
  local IFS=.
  local -a a b
  read -r -a a <<< "${1#v}"
  read -r -a b <<< "${2#v}"
  local i
  for i in 0 1 2; do
    local x="${a[i]:-0}" y="${b[i]:-0}"
    x="${x%%[!0-9]*}" y="${y%%[!0-9]*}"
    (( 10#${x:-0} > 10#${y:-0} )) && return 0
    (( 10#${x:-0} < 10#${y:-0} )) && return 1
  done
  return 0
}

check_compose() {
  local version
  if ! version="$(docker compose version --short 2>/dev/null)"; then
    add_error "Docker Compose v2 not found. Install Docker Engine with the compose plugin."
    return
  fi
  version_ge "$version" "$MIN_COMPOSE" \
    || add_error "Docker Compose $version is too old: $MIN_COMPOSE or newer is needed (for 'include')."
}

check_tun() {
  [ -e "$TUN_DEVICE" ] \
    || add_error "$TUN_DEVICE not found: the VPN gateway needs it. Load the module with 'modprobe tun'."
}

check_root() {
  [ "$(id -u)" = 0 ] || add_error "Run as root (sudo scripts/init.sh): it sets folder owners with chown."
}

check_vars() {
  local var
  for var in "${REQUIRED_VARS[@]}"; do
    [ -n "$(env_get "$var")" ] || add_error "$var is empty in $ENV_FILE."
  done
  case "$(env_get VPN_TYPE)" in
    wireguard)
      [ -n "$(env_get WIREGUARD_PRIVATE_KEY)" ] || add_error "WIREGUARD_PRIVATE_KEY is empty (needed with VPN_TYPE=wireguard)."
      ;;
    openvpn)
      [ -n "$(env_get OPENVPN_USER)" ] || add_error "OPENVPN_USER is empty (needed with VPN_TYPE=openvpn)."
      [ -n "$(env_get OPENVPN_PASSWORD)" ] || add_error "OPENVPN_PASSWORD is empty (needed with VPN_TYPE=openvpn)."
      ;;
    "") ;;
    *) add_error "VPN_TYPE must be 'wireguard' or 'openvpn', got '$(env_get VPN_TYPE)'." ;;
  esac
  if profile_on backup; then
    [ -n "$(env_get RESTIC_PASSWORD)" ] || add_error "RESTIC_PASSWORD is empty (needed by the backup Profile)."
    local source; source="$(env_get BACKUP_SOURCE)"
    [ -z "$source" ] || [ -d "$source" ] || add_error "BACKUP_SOURCE $source does not exist: the backup would be empty."
  fi
}

# Creates a folder a service writes to and gives it to its owner. Parent folders
# (APPDATA_ROOT, DATA_ROOT...) are created if missing but their owner is left alone.
make_owned_dir() {
  local dir="$1" owner="$2"
  mkdir -p "$dir"
  chown "$owner" "$dir"
}

prepare_folders() {
  local owner root dir
  owner="$(env_get PUID):$(env_get PGID)"
  root="$(env_get APPDATA_ROOT)"
  for dir in "${APPDATA_DIRS[@]}"; do make_owned_dir "$root/$dir" "$owner"; done
  make_owned_dir "$root/seerr" "$SEERR_OWNER"
  # The backup container runs as root to read every service's files.
  if profile_on backup; then make_owned_dir "$root/backup" "0:0"; fi

  root="$(env_get DATA_ROOT)"
  for dir in "${DATA_DIRS[@]}"; do make_owned_dir "$root/$dir" "$owner"; done
  echo "App data ready in $(env_get APPDATA_ROOT), library layout ready in $root."
}

prepare_network() {
  local network
  network="$(env_get MEDIA_NETWORK)"
  network="${network:-$DEFAULT_NETWORK}"
  if docker network inspect "$network" >/dev/null 2>&1; then
    echo "Network $network already exists."
  else
    docker network create "$network" >/dev/null
    echo "Network $network created."
  fi
}

main() {
  if [ ! -f "$ENV_FILE" ]; then
    echo "No $ENV_FILE found. Copy .env.example to .env and fill it in first." >&2
    exit 1
  fi
  load_env
  check_root
  check_compose
  check_tun
  check_vars
  if [ "${#errors[@]}" -gt 0 ]; then
    printf 'error: %s\n' "${errors[@]}" >&2
    exit 1
  fi
  prepare_folders
  prepare_network
  echo "Done. Start the Instance with: docker compose up -d"
}

main "$@"
