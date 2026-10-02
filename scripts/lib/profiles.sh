# shellcheck shell=bash
# The Profiles of the Template: the one place that says which Profiles exist and what
# each one needs on the host. Sourced by init.sh and setup.sh; it runs nothing itself.
#
# The services a Profile adds are not listed here: compose declares them (`profiles:` in
# each stack), and tests/template.test.sh checks that the names agree.

# The names in the COMPOSE_PROFILES value $1, one per line: comma separated, spaces around
# a name ignored, empty items dropped.
_profile_items() {
  local item
  local -a items
  IFS=, read -r -a items <<< "$1"
  for item in "${items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [ -z "$item" ] || printf '%s\n' "$item"
  done
}

# True when Profile $1 is listed in the COMPOSE_PROFILES value $2 (names are case sensitive).
profile_on() {
  local item
  while IFS= read -r item; do
    [ "$item" = "$1" ] && return 0
  done < <(_profile_items "$2")
  return 1
}

# Profiles, in the order the wizard asks about them and writes them to COMPOSE_PROFILES.
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

# Folders under APPDATA_ROOT that each Profile's services write to, as "<owner> <folder>"
# lines. Owners: app = PUID:PGID; root = root; private = root, and not readable by others
# (services that keep secrets there: certificates, the Tailscale node key).
declare -A PROFILE_DIRS=(
  [backup]="root backup"
  [vo]=$'app radarr-vo\napp sonarr-vo'
  [jackett]="app jackett"
  [seeding]=$'app qui\napp cleanuparr'
  [cleanup]="app maintainerr"
  [dashboard]=$'app homarr\napp dockge'
  [monitoring]=$'app beszel/data\napp beszel/socket\napp beszel/agent\napp wud'
  [proxy]=$'private npm/data\nprivate npm/letsencrypt'
  [remote]="private tailscale"
  [extras]=$'app mousehole\napp filebrowser/config\napp filebrowser/database'
  [transcode]=$'app tdarr/server\napp tdarr/configs\napp tdarr/logs\napp tdarr/cache'
)

# Settings in .env that a Profile cannot run without, space separated. Which values are
# valid is init.sh's business, not this module's.
declare -A PROFILE_REQUIRES=(
  [backup]="RESTIC_PASSWORD"
  [dashboard]="HOMARR_SECRET_KEY"
  [monitoring]="WUD_ADMIN_PASSWORD"
  [remote]="TAILSCALE_AUTHKEY"
  [extras]="MOUSEHOLE_AUTH_PASSWORD"
)

# The Profiles' names, one per line.
profiles_all() { printf '%s\n' "${PROFILES[@]}"; }

profile_exists() { [ -n "${PROFILE_HELP[$1]+set}" ]; }

# What the Profile gives an Operator, in one line.
profile_help() { profile_exists "$1" && printf '%s\n' "${PROFILE_HELP[$1]}"; }

# The Profile's folders as "<owner> <folder>" lines.
profile_dirs() { profile_exists "$1" && printf '%s\n' "${PROFILE_DIRS[$1]}"; }

# The settings the Profile requires, one per line (none for most Profiles).
profile_requires() {
  profile_exists "$1" || return 1
  local setting
  for setting in ${PROFILE_REQUIRES[$1]:-}; do printf '%s\n' "$setting"; done
  return 0
}

# The names in the COMPOSE_PROFILES value $1 that are not Profiles, one per line.
profiles_unknown() {
  local item
  while IFS= read -r item; do
    profile_exists "$item" || printf '%s\n' "$item"
  done < <(_profile_items "$1")
  return 0
}
