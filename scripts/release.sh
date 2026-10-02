#!/usr/bin/env bash
# Validate a clean main snapshot before creating an annotated local release tag.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
die() { echo "error: $*" >&2; exit 1; }
[ "$#" = 1 ] || die 'Usage: scripts/release.sh vMAJOR.MINOR.PATCH'
VERSION="$1"
[[ "$VERSION" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || die 'Use a stable SemVer tag.'
[ "$(git branch --show-current)" = main ] || die 'Release from main.'
[ -z "$(git status --porcelain)" ] || die 'Dirty working tree.'
! git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null || die 'Tag already exists.'
LATEST="$(git tag --list 'v[0-9]*' --sort=-version:refname | head -n 1)"
if [ -n "$LATEST" ]; then
  [ "$(printf '%s\n' "$LATEST" "$VERSION" | sort -V | tail -n 1)" = "$VERSION" ] || die 'Version must increase.'
  git merge-base --is-ancestor "$LATEST" HEAD || die 'Latest release is outside this main history.'
fi
NOTES="docs/releases/$VERSION.md"
[ -f "$NOTES" ] || die "Missing $NOTES. See docs/upgrading.md."
grep -qE '^Breaking changes: (yes|no)$' "$NOTES" || die 'Notes need Breaking changes: yes|no.'
for heading in 'Images bumped' 'New settings' 'New Profiles' Fixes 'Manual steps'; do
  grep -qFx "## $heading" "$NOTES" || die "Missing release heading: $heading"
done
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
sed -E '/^(COMPOSE_PROFILES|BACKUP_SOURCE)=/!s/^([A-Z_]+)=$/\1=ci-dummy/' .env.example > "$WORK/.env"
sed -E 's/^([A-Z_]+)=$/\1=ci-dummy/' worker/.env.example > "$WORK/worker.env"
# Explicit files and env files isolate validation from ignored Instance settings.
unset COMPOSE_FILE COMPOSE_PROFILES
compose() { docker compose --project-directory "$REPO" --env-file "$WORK/.env" -f compose.yaml "$@"; }
compose config --quiet
PROFILES="$(compose config --profiles)"
while IFS= read -r profile; do
  [ -z "$profile" ] || compose --profile "$profile" config --quiet
done <<< "$PROFILES"
compose --profile '*' config --quiet
compose -f compose.gpu.yaml --profile '*' config --quiet
docker compose --project-directory "$REPO/worker" --env-file "$WORK/worker.env" config --quiet
for test in tests/*.test.sh; do
  echo "Running $test"
  bash "$test"
done
git tag -a "$VERSION" -F "$NOTES"
printf 'Validated local tag %s. Publish explicitly:\ngit push origin %s\ngh release create %s --verify-tag --title %s --notes-file %s\n' "$VERSION" "$VERSION" "$VERSION" "$VERSION" "$NOTES"
