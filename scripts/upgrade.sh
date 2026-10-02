#!/usr/bin/env bash
# Upgrade an Instance through published stable Template releases.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
# sudo is needed by init.sh; trust only this explicitly selected clone.
git() { command git -c safe.directory="$REPO" "$@"; }
STATE="$(git rev-parse --absolute-git-dir)/media-stack-upgrade"
API=https://api.github.com/repos/alberba/media-stack/releases
ENV_FILE="$REPO/.env"
export ENV_FILE
DRY=0
MODE=upgrade
TARGET=""
ASSUME=""
VERIFY_ATTEMPTS="${VERIFY_ATTEMPTS:-24}"
VERIFY_INTERVAL="${VERIFY_INTERVAL:-5}"
die() { echo "error: $*" >&2; exit 1; }
confirm() {
  local answer
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
deploy() {
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
  isolate_compose_env
  deploy || return
  record "$version"
  rm -f "$STATE/previous-commit" "$STATE/previous-version" "$STATE/pending" "$STATE/attempted"
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
      line="$(grep -E "^$key=" .env.example | tail -n 1)"
      printf '%s (Enter keeps example default): ' "$key"
      IFS= read -r value || return 1
      # Store a literal Compose value, never execute shell input.
      if [ -n "$value" ]; then
        [[ "$value" != *\'* ]] || { echo 'Single quotes are not supported here; use setup.sh.' >&2; return 1; }
        line="$key='$value'"
      fi
      printf '\n%s\n' "$line" >> "$ENV_FILE"
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
  git fetch origin --tags || die 'Could not fetch release tags.'
  git fetch origin main:refs/remotes/origin/main || die 'Could not fetch Template main.'
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
      --version) MODE=version ;;
      --list) MODE=list ;;
      --rollback) MODE=rollback ;;
      --assume-version) shift; [ "$#" -gt 0 ] || die 'Missing assumed version.'; ASSUME="$1" ;;
      --help) echo 'Usage: scripts/upgrade.sh [vX.Y.Z] [--dry-run|--list|--version|--rollback] [--assume-version vX.Y.Z]'; return ;;
      v*) [ -z "$TARGET" ] || die 'Only one target allowed.'; TARGET="$1" ;;
      *) die "Unknown argument $1" ;;
    esac
    shift
  done
  [[ "$VERIFY_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || die 'VERIFY_ATTEMPTS must be positive.'
  [ "$DRY" = 0 ] || [ "$MODE" = upgrade ] || die '--dry-run is only supported for upgrades.'
  if [ "$MODE" = version ] && [ -f "$STATE/installed" ] && [ -z "$ASSUME" ]; then
    cat "$STATE/installed"; return
  fi
  clean
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
  touch "$STATE/pending"
  record "$BASE"
  previous="$BASE"
  for release in "${PLAN[@]}"; do
    if ! apply_release "$release" "$previous"; then
      echo "Upgrade failed at $release. Recovery: scripts/upgrade.sh --rollback" >&2
      if confirm 'Roll back code and images now?'; then rollback || echo 'Rollback failed; recovery state retained.' >&2; fi
      return 1
    fi
    previous="$release"
  done
  rm -f "$STATE/pending" "$STATE/attempted"
  echo "Upgrade verified: $TARGET. Previous checkout retained for --rollback."
}
main "$@"
