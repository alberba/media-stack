#!/usr/bin/env bash
# Prepare the next automatic Template release on main: notes, commit and annotated tag.
# Only compatible changes qualify. Major image updates, breaking changes and Worker
# changes stay manual (scripts/release.sh), because they need the Operator.
# Writes version=vX.Y.Z to $GITHUB_OUTPUT when a release was prepared.
# shellcheck disable=SC2016 # Backticks in notes and the inline Python are literal.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
git() { command git -c safe.directory="$REPO" "$@"; }
die() { echo "error: $*" >&2; exit 1; }
manual() { echo "Manual release required: $*"; exit 0; }
[ "$(git branch --show-current)" = main ] || die 'Release from main.'
[ -z "$(git status --porcelain)" ] || die 'Dirty working tree.'
LATEST="$(git tag --list 'v[0-9]*' --sort=-version:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)"
[ -n "$LATEST" ] || die 'No release yet: publish the first one with scripts/release.sh.'
git merge-base --is-ancestor "$LATEST" HEAD || die "$LATEST is outside main."
[ -n "$(git rev-list "$LATEST..HEAD")" ] || { echo "No changes since $LATEST."; exit 0; }

git log --format=%B "$LATEST..HEAD" | grep -q 'renovate/major-' && manual 'major image update merged'
git log --format=%B "$LATEST..HEAD" | grep -qE '^BREAKING[ -]CHANGE' && manual 'breaking change'
git diff --quiet "$LATEST" HEAD -- worker/ || manual 'the Worker changed and must be updated with the Instance'
[ -z "$(git diff --name-only --diff-filter=A "$LATEST" HEAD -- docs/releases/)" ] ||
  manual 'release notes are already being prepared'

# Image tags before and after, one line per repository: "repo old new".
IMAGES="$(git diff -U0 "$LATEST" HEAD -- '*.yaml' '*.yml' | python3 -c '
import re, sys
old, new = {}, {}
for line in sys.stdin:
    match = re.match(r"([-+])\s+image:\s*[\"\x27]?([^\s\"\x27]+)", line)
    if not match or "${" in match[2]:
        continue
    name = match[2].split("@", 1)[0]
    repo, tag = name.rsplit(":", 1) if ":" in name.rsplit("/", 1)[-1] else (name, "")
    (old if match[1] == "-" else new)[repo] = tag
for repo in sorted(new):
    if repo in old and old[repo] != new[repo]:
        print(repo, old[repo], new[repo])
')"
while read -r repo old new; do
  [ -n "$repo" ] || continue
  major_old="$(grep -oE '^v?[0-9]+' <<< "$old" | tr -d v || true)"
  major_new="$(grep -oE '^v?[0-9]+' <<< "$new" | tr -d v || true)"
  [ "$major_old" = "$major_new" ] || manual "major update of $repo ($old -> $new)"
done <<< "$IMAGES"

SETTINGS="$(git diff -U0 "$LATEST" HEAD -- .env.example | sed -nE 's/^\+([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p' |
  while read -r key; do git show "$LATEST:.env.example" | grep -qE "^$key=" || echo "$key"; done)"
STACKS="$(git diff --name-only --diff-filter=A "$LATEST" HEAD -- 'stacks/*/compose.yaml')"
FIXES="$(git log --no-merges --format=%s "$LATEST..HEAD" | grep -vE '^chore\((deps|release)\)' || true)"

IFS=. read -r major minor patch <<< "${LATEST#v}"
if [ -n "$IMAGES" ] || [ -n "$SETTINGS" ] || [ -n "$STACKS" ]; then
  VERSION="v$major.$((minor + 1)).0"
else
  VERSION="v$major.$minor.$((patch + 1))"
fi
NOTES="docs/releases/$VERSION.md"
list() {
  local line
  [ -n "$1" ] || { echo '- None'; return; }
  while IFS= read -r line; do echo "- $2$line"; done <<< "$1"
}
{
  echo "# $VERSION"
  echo 'Breaking changes: no'
  echo
  echo '## Images bumped'
  if [ -n "$IMAGES" ]; then
    while read -r repo old new; do echo "- \`$repo\`: \`$old\` -> \`$new\`"; done <<< "$IMAGES"
  else
    echo '- None'
  fi
  echo
  echo '## New settings'
  list "$SETTINGS" ''
  echo
  echo '## New Profiles'
  list "$STACKS" 'New stack: '
  echo
  echo '## Fixes'
  list "$FIXES" ''
  echo
  echo '## Manual steps'
  if [ -n "$SETTINGS" ]; then
    echo '- Fill the new settings: `sudo scripts/upgrade.sh` asks for them. Unattended upgrades wait for this.'
  else
    echo '- None. Automatic release: compatible changes only.'
  fi
} > "$NOTES"
git add "$NOTES"
git commit -q -m "chore(release): $VERSION"
git tag -a "$VERSION" -F "$NOTES"
echo "Prepared $VERSION from $LATEST."
[ -z "${GITHUB_OUTPUT:-}" ] || echo "version=$VERSION" >> "$GITHUB_OUTPUT"
