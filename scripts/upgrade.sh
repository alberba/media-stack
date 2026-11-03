#!/usr/bin/env bash
# Upgrade an Instance through published stable Template releases.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
# Upgrade changes checked-out releases and App data; trust only this selected clone.
# As root (the timer), Git runs as the clone's owner so the Operator keeps a usable clone.
OWNER="$(stat -c %U "$REPO")"
git() {
  if [ "$EUID" = 0 ] && [ "$OWNER" != root ]; then
    runuser -u "$OWNER" -- env HOME="$(getent passwd "$OWNER" | cut -d: -f6)" \
      git -c safe.directory="$REPO" "$@"
  else
    command git -c safe.directory="$REPO" "$@"
  fi
}
STATE="$(git rev-parse --absolute-git-dir)/media-stack-upgrade"
API=https://api.github.com/repos/alberba/media-stack/releases
# Releases are public: fetch over HTTPS so the timer needs no SSH key.
TEMPLATE_GIT="${TEMPLATE_GIT:-https://github.com/alberba/media-stack.git}"
ENV_FILE="$REPO/.env"
export ENV_FILE
DRY=0
UNATTENDED=0
AT=04:30
PINS=""
MODE=upgrade
TARGET=""
ASSUME=""
VERIFY_ATTEMPTS="${VERIFY_ATTEMPTS:-24}"
VERIFY_INTERVAL="${VERIFY_INTERVAL:-5}"
setting() { python3 scripts/env_contract.py get --file "$ENV_FILE" --name "$1" 2>/dev/null || true; }
# Unattended runs report to the Operator's Telegram chat when one is configured.
notify() {
  [ "$UNATTENDED" = 1 ] || return 0
  local token chat
  token="$(setting TELEGRAM_BOT_TOKEN)"
  chat="$(setting TELEGRAM_CHAT_ID)"
  echo "notice: $1"
  [ -n "$token" ] && [ -n "$chat" ] || return 0
  # The token goes through curl's config on stdin, never through argv.
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$token" |
    curl -fsS -o /dev/null --max-time 30 -K - --data-urlencode "chat_id=$chat" \
      --data-urlencode "text=Media Stack — $1" || echo 'warning: Telegram notification failed' >&2
}
die() { echo "error: $*" >&2; notify "actualización automática detenida: $*"; exit 1; }
confirm() {
  local answer
  [ "$UNATTENDED" = 0 ] || return 1
  printf '%s [y/N] ' "$1"
  IFS= read -r answer || return 1
  [[ "$answer" == y || "$answer" == Y ]]
}
clean() {
  [ -z "$(git status --porcelain)" ] || die 'Dirty working tree: commit or stash Template changes first.'
}
record() {
  mkdir -p "$STATE"
  printf '%s\n' "$1" > "$STATE/installed.tmp"
  mv "$STATE/installed.tmp" "$STATE/installed"
}
verify() {
  local attempt
  for ((attempt=1; attempt<=VERIFY_ATTEMPTS; attempt++)); do
    if bash scripts/verify.sh; then return 0; fi
    [ "$attempt" = "$VERIFY_ATTEMPTS" ] || sleep "$VERIFY_INTERVAL"
  done
  return 1
}
# Security pins (scripts/security-update.sh) override Template tags; a release that
# reaches or passes a pinned version replaces the pin.
release_pins() {
  [ -n "$PINS" ] && [ -f stacks/monitoring/security-monitor/updater.py ] || return 0
  bash scripts/security-update.sh release-pins
}
# Shares the security updater's lock: only one of them changes containers at a time.
take_lock() {
  local appdata dir
  appdata="$(setting APPDATA_ROOT)"
  dir="$appdata/security-monitor"
  [ -n "$appdata" ] && [ -d "$dir" ] || return 0
  exec 9>>"$dir/update.lock" || die 'Cannot open the security update lock.'
  flock -n 9 || die 'A security update is running; try again later.'
  [ ! -f "$dir/active-update.json" ] || die 'A security update awaits recovery: run scripts/security-update.sh first.'
  [ ! -f "$dir/images.compose.json" ] || PINS="$dir/images.compose.json"
}
deploy() {
  release_pins || return
  docker compose pull --ignore-buildable || return
  docker compose build || return
  docker compose up -d --remove-orphans || return
  verify
}
rollback() {
  [ -f "$STATE/previous-commit" ] || die 'No previous checkout recorded.'
  local commit version
  commit="$(cat "$STATE/previous-commit")"
  version="$(cat "$STATE/previous-version")"
  echo "Rollback to $version ($commit). App data is not restored; see docs/backup.md."
  git checkout --detach "$commit" || return
  if [ -n "$PINS" ] && [ -f "$STATE/previous-pins.json" ]; then cp "$STATE/previous-pins.json" "$PINS" || return; fi
  isolate_compose_env
  deploy || return
  record "$version"
  rm -f "$STATE/previous-commit" "$STATE/previous-version" "$STATE/previous-pins.json" "$STATE/pending" "$STATE/attempted"
  echo 'Rollback verified.'
}
missing_settings() {
  local line key value missing=()
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    grep -qE "^[[:space:]]*$key=" "$ENV_FILE" || missing+=("$key")
  done < .env.example
  [ "${#missing[@]}" -gt 0 ] || return 0
  printf 'New settings: %s\n' "${missing[*]}"
  if confirm 'Run setup.sh with current values as defaults?'; then
    bash scripts/setup.sh || return
  else
    confirm 'Fill only the missing settings now?' || return 1
    for key in "${missing[@]}"; do
      printf '%s (Enter keeps example default): ' "$key"
      IFS= read -r value || return 1
      if [ -z "$value" ]; then
        value="$(python3 scripts/env_contract.py get --file .env.example --name "$key")" || return 1
      fi
      printf '%s' "$value" | python3 scripts/env_contract.py set --file "$ENV_FILE" --name "$key" || return 1
    done
  fi
  for key in "${missing[@]}"; do
    grep -qE "^[[:space:]]*$key=" "$ENV_FILE" || { echo "Still missing $key; fill .env before retrying." >&2; return 1; }
  done
}
fetch_releases() {
  local page=1 json tags
  RELEASES=()
  while true; do
    json="$(curl -fsSL "$API?per_page=100&page=$page")" || die 'Could not list GitHub Releases.'
    tags="$(python3 -c '
import json,re,sys
items=json.load(sys.stdin)
for r in items:
 if not r["draft"] and not r["prerelease"] and re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)",r["tag_name"]): print(r["tag_name"])
' <<< "$json")" || die 'Invalid release response.'
    while IFS= read -r tag; do [ -z "$tag" ] || RELEASES+=("$tag"); done <<< "$tags"
    [ "$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' <<< "$json")" = 100 ] || break
    page=$((page + 1))
  done
  [ "${#RELEASES[@]}" -gt 0 ] || die 'No stable releases published yet.'
  mapfile -t RELEASES < <(printf '%s\n' "${RELEASES[@]}" | sort -V)
  git fetch -q "$TEMPLATE_GIT" --tags || die 'Could not fetch release tags.'
  git fetch -q "$TEMPLATE_GIT" +main:refs/remotes/origin/main || die 'Could not fetch Template main.'
}
known_release() {
  local release
  for release in "${RELEASES[@]}"; do [ "$release" != "$1" ] || return 0; done
  return 1
}
infer() {
  local exact release
  local matches=()
  BASE=""
  if [ -f "$STATE/installed" ]; then BASE="$(cat "$STATE/installed")"; fi
  if [ -n "$ASSUME" ]; then
    known_release "$ASSUME" || die 'Assumed version is not a published stable release.'
    BASE="$ASSUME"
  elif [ -z "$BASE" ]; then
    git merge-base --is-ancestor HEAD origin/main || die 'Unknown/local history: specify --assume-version vX.Y.Z.'
    for release in "${RELEASES[@]}"; do matches+=(--match "$release"); done
    BASE="$(git describe --tags --abbrev=0 "${matches[@]}" HEAD 2>/dev/null || true)"
    known_release "$BASE" || die 'No reachable release: specify --assume-version vX.Y.Z.'
  fi
  known_release "$BASE" || die "Recorded version $BASE is not a published stable release."
  exact="$(git rev-parse "$BASE^{commit}")"
  echo "Installed: $BASE"
  [ "$(git rev-parse HEAD)" = "$exact" ] || echo 'Instance runs an unreleased commit; using that release as the changelog base.'
}
apply_release() {
  local release="$1" previous="$2" notes
  notes="$(git show "$release:docs/releases/$release.md")" || return
  if [ "${release%%.*}" != "${previous%%.*}" ] || grep -qi '^Breaking changes: yes' <<< "$notes"; then
    echo "Manual steps before $release:"
    echo "$notes"
    confirm "Have you completed $release's manual steps and accepted database rollback limits?" || return 1
  fi
  printf '%s\n' "$release" > "$STATE/attempted"
  git checkout --detach "$release" || return
  isolate_compose_env
  missing_settings || return
  bash scripts/init.sh || return
  deploy || return
  record "$release"
}
# Why a release cannot be applied without the Operator, or nothing when it can.
manual_reason() {
  local release="$1" previous="$2" notes key
  notes="$(git show "$release:docs/releases/$release.md" 2>/dev/null)" || { echo 'missing release notes'; return; }
  if [ "${release%%.*}" != "${previous%%.*}" ]; then echo 'major release'; return; fi
  if grep -qi '^Breaking changes: yes' <<< "$notes"; then echo 'breaking changes'; return; fi
  while IFS= read -r key; do
    grep -qE "^[[:space:]]*$key=" "$ENV_FILE" || { echo "new setting $key"; return; }
  done < <(git show "$release:.env.example" | sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p')
}
install_timer() {
  [ "$EUID" = 0 ] || die 'Installation requires root (sudo).'
  [ -d /run/systemd/system ] || die 'Installation requires systemd.'
  [[ "$AT" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die 'Use --at HH:MM.'
  local zone unit=/etc/systemd/system/media-stack-upgrade
  zone="$(setting TZ)"
  [[ "$zone" =~ ^[A-Za-z0-9_+./-]+$ ]] || die 'Set a valid TZ in .env.'
  cat > "$unit.service" <<UNIT
[Unit]
Description=Unattended media-stack Template upgrades
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/bash "$REPO/scripts/upgrade.sh" --unattended
TimeoutStartSec=4h
UMask=0022
UNIT
  cat > "$unit.timer" <<UNIT
[Unit]
Description=Daily unattended media-stack Template upgrades

[Timer]
OnCalendar=*-*-* $AT:00 $zone
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  systemd-analyze verify "$unit.service" "$unit.timer" || die 'Invalid systemd units.'
  systemctl daemon-reload
  systemctl enable --now media-stack-upgrade.timer
  echo "Unattended upgrades enabled daily at $AT $zone. Disable: systemctl disable --now media-stack-upgrade.timer"
}
isolate_compose_env() {
  local key
  while IFS= read -r key; do
    unset "$key"
  done < <(sed -nE 's/^[[:space:]]*(#[[:space:]]*)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' .env.example)
  unset COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME COMPOSE_ENV_FILES COMPOSE_DISABLE_ENV_FILE
}
main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) DRY=1 ;;
      --unattended) UNATTENDED=1 ;;
      install) MODE=install ;;
      --at) shift; [ "$#" -gt 0 ] || die 'Missing time.'; AT="$1" ;;
      --version) MODE=version ;;
      --list) MODE=list ;;
      --rollback) MODE=rollback ;;
      --assume-version) shift; [ "$#" -gt 0 ] || die 'Missing assumed version.'; ASSUME="$1" ;;
      --help) echo 'Usage: scripts/upgrade.sh [vX.Y.Z] [--dry-run|--list|--version|--rollback|--unattended] [--assume-version vX.Y.Z] | install [--at HH:MM]'; return ;;
      v*) [ -z "$TARGET" ] || die 'Only one target allowed.'; TARGET="$1" ;;
      *) die "Unknown argument $1" ;;
    esac
    shift
  done
  [[ "$VERIFY_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || die 'VERIFY_ATTEMPTS must be positive.'
  [ "$DRY" = 0 ] || [ "$MODE" = upgrade ] || die '--dry-run is only supported for upgrades.'
  if [ "$MODE" = install ]; then install_timer; return; fi
  if [ "$MODE" = version ] && [ -f "$STATE/installed" ] && [ -z "$ASSUME" ]; then
    cat "$STATE/installed"; return
  fi
  clean
  if [ "$MODE" = rollback ] || { [ "$MODE" = upgrade ] && [ "$DRY" = 0 ]; }; then take_lock; fi
  isolate_compose_env
  if [ "$MODE" = rollback ]; then rollback; return; fi
  fetch_releases
  infer
  if [ "$MODE" = version ]; then record "$BASE"; return; fi
  local release start=0 found=0 notes previous
  TARGET="${TARGET:-${RELEASES[${#RELEASES[@]}-1]}}"
  known_release "$TARGET" || die "Target $TARGET is not a published stable release."
  PLAN=()
  for release in "${RELEASES[@]}"; do
    if [ "$release" = "$BASE" ]; then start=1; fi
    if [ "$start" = 1 ] && [ "$release" != "$BASE" ]; then PLAN+=("$release"); fi
    if [ "$release" = "$TARGET" ]; then found="$start"; break; fi
  done
  [ "$found" = 1 ] || die 'Target is older than installed version; use --rollback.'
  echo 'Newer releases:'
  for release in "${PLAN[@]}"; do echo "$release"; done
  previous="$BASE"
  for release in "${PLAN[@]}"; do
    git merge-base --is-ancestor "$previous" "$release" || die "Release $release is not a descendant of $previous."
    previous="$release"
    git merge-base --is-ancestor "$release" origin/main || die "Release $release is outside Template main."
    notes="$(git show "$release:docs/releases/$release.md")" || die "Missing notes for $release."
    echo "$notes"
    echo 'Settings added/changed:'
    git diff "$BASE" "$release" -- .env.example
  done
  local held="" allowed=()
  if [ "$UNATTENDED" = 1 ]; then
    # Stop before the first release that needs the Operator; apply the ones before it.
    previous="$BASE"
    for release in "${PLAN[@]}"; do
      held="$(manual_reason "$release" "$previous")"
      if [ -n "$held" ]; then held="$release: $held"; break; fi
      allowed+=("$release")
      previous="$release"
    done
    PLAN=("${allowed[@]}")
    if [ -n "$held" ]; then
      echo "Held for the Operator: $held"
      # Report each held release once, not on every daily run.
      if [ "$DRY" = 0 ] && [ "$(cat "$STATE/held" 2>/dev/null)" != "$held" ]; then
        mkdir -p "$STATE"; printf '%s\n' "$held" > "$STATE/held"
        notify "$held. Requiere actualización manual: sudo scripts/upgrade.sh (docs/upgrading.md)."
      fi
    fi
  fi
  if [ "$DRY" = 1 ] || [ "$MODE" = list ]; then return; fi
  [ "${#PLAN[@]}" -gt 0 ] || { record "$BASE"; echo 'Already at target.'; return; }
  [ -f "$ENV_FILE" ] || die 'No .env; run setup.sh first.'
  [ ! -f "$STATE/pending" ] || die 'An upgrade already has recovery state: run --rollback first.'
  local enabled_services
  enabled_services="$(docker compose config --services)" || die 'Invalid installed Compose configuration.'
  if grep -qx backup <<< "$enabled_services"; then
    docker compose run --rm --build backup run || die 'Pre-upgrade backup failed; checkout unchanged.'
  else
    echo 'Backup Profile is off. Back up App data first: docs/backup.md (rollback restores code/images only).'
  fi
  mkdir -p "$STATE"
  git rev-parse HEAD > "$STATE/previous-commit"
  printf '%s\n' "$BASE" > "$STATE/previous-version"
  if [ -n "$PINS" ]; then cp "$PINS" "$STATE/previous-pins.json"; else rm -f "$STATE/previous-pins.json"; fi
  touch "$STATE/pending"
  record "$BASE"
  previous="$BASE"
  for release in "${PLAN[@]}"; do
    if ! apply_release "$release" "$previous"; then
      echo "Upgrade failed at $release. Recovery: scripts/upgrade.sh --rollback" >&2
      if [ "$UNATTENDED" = 1 ]; then
        if rollback; then
          notify "falló la actualización a $release; restaurada $BASE (código e imágenes)."
        else
          notify "falló la actualización a $release y también la vuelta atrás. Revisa: sudo scripts/upgrade.sh --rollback"
        fi
        return 1
      fi
      if confirm 'Roll back code and images now?'; then rollback || echo 'Rollback failed; recovery state retained.' >&2; fi
      return 1
    fi
    previous="$release"
  done
  rm -f "$STATE/pending" "$STATE/attempted"
  echo "Upgrade verified: $previous. Previous checkout retained for --rollback."
  notify "actualizado de $BASE a $previous y verificado.${held:+ Pendiente manual: $held.}"
}
main "$@"
