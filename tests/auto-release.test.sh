#!/usr/bin/env bash
# Automatic releases tag compatible changes only and leave majors to the maintainer.
# shellcheck disable=SC1091,SC2034,SC2016
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/tests/lib.sh"
setup() {
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/repo/scripts" "$SANDBOX/repo/docs/releases" "$SANDBOX/repo/stacks/arr" "$SANDBOX/repo/worker"
  cp "$REPO/scripts/auto-release.sh" "$SANDBOX/repo/scripts/"
  cd "$SANDBOX/repo" || exit 1
  git init -q -b main; git config user.name Test; git config user.email test@example.invalid; git config core.hooksPath /dev/null
  printf 'KEEP=1\n' > .env.example
  printf 'services:\n  radarr:\n    image: lscr.io/linuxserver/radarr:6.4.4.10685-ls320\n  radarr-vo:\n    image: lscr.io/linuxserver/radarr:6.4.4.10685-ls320\n' > stacks/arr/compose.yaml
  printf 'services:\n  node:\n    image: ghcr.io/haveagitgat/tdarr_node:2.94.02\n' > worker/compose.yaml
  echo 'Breaking changes: no' > docs/releases/v1.0.0.md
  git add .; git commit -qm initial; git tag -a v1.0.0 -m v1.0.0
}
teardown() { cd "$REPO" || exit 1; rm -rf "$SANDBOX"; }
run_release() { OUTPUT="$(scripts/auto-release.sh 2>&1)"; STATUS=$?; }
bump() { sed -i "s|radarr:6.4.4.10685-ls320|radarr:$1|" stacks/arr/compose.yaml; git commit -qam "$2"; }
test_nothing_new_creates_no_release() {
  run_release
  assert_status 0
  assert_output_contains 'No changes since v1.0.0'
  [ "$(git tag | wc -l)" = 1 ] || fail 'tagged without changes'
}
test_compatible_image_bump_becomes_a_minor_release() {
  bump 6.5.0.10800-ls330 'chore(deps): update radarr'
  git commit -q --allow-empty -m 'fix: something visible'
  export GITHUB_OUTPUT="$SANDBOX/output"
  run_release
  assert_status 0
  [ "$(git describe --tags --exact-match)" = v1.1.0 ] || fail 'expected v1.1.0 on the release commit'
  assert_file_contains docs/releases/v1.1.0.md 'Breaking changes: no'
  assert_file_contains docs/releases/v1.1.0.md '`lscr.io/linuxserver/radarr`: `6.4.4.10685-ls320` -> `6.5.0.10800-ls330`'
  assert_file_contains docs/releases/v1.1.0.md '- fix: something visible'
  assert_file_not_contains docs/releases/v1.1.0.md 'chore(deps)'
  for heading in 'Images bumped' 'New settings' 'New Profiles' Fixes 'Manual steps'; do
    grep -qFx "## $heading" docs/releases/v1.1.0.md || fail "missing $heading"
  done
  assert_file_contains "$GITHUB_OUTPUT" 'version=v1.1.0'
}
test_fix_only_becomes_a_patch_release() {
  echo fix > fix.txt; git add fix.txt; git commit -qm 'fix: small'
  run_release
  assert_status 0
  [ "$(git describe --tags --exact-match)" = v1.0.1 ] || fail 'expected v1.0.1'
}
test_major_image_bump_stays_manual() {
  bump 7.0.0.1-ls1 'chore(deps): update radarr to v7'
  run_release
  assert_status 0
  assert_output_contains 'major update of lscr.io/linuxserver/radarr'
  [ "$(git tag | wc -l)" = 1 ] || fail 'tagged a major update'
}
test_renovate_major_branch_stays_manual() {
  git commit -q --allow-empty -m 'Merge pull request #1 from owner/renovate/major-something'
  run_release
  assert_output_contains 'major image update merged'
  [ "$(git tag | wc -l)" = 1 ] || fail 'tagged a major merge'
}
test_worker_change_stays_manual() {
  sed -i 's/2.94.02/2.95.00/' worker/compose.yaml; git commit -qam 'chore(deps): update tdarr'
  run_release
  assert_output_contains 'Worker changed'
  [ "$(git tag | wc -l)" = 1 ] || fail 'tagged a Worker change'
}
test_new_setting_is_listed_with_a_manual_step() {
  echo 'NEW_ONE=x' >> .env.example; git commit -qam 'feat: new setting'
  run_release
  assert_status 0
  assert_file_contains docs/releases/v1.1.0.md '- NEW_ONE'
  assert_file_contains docs/releases/v1.1.0.md 'Unattended upgrades wait'
}
run_tests
