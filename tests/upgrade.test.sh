#!/usr/bin/env bash
# Public upgrade CLI exercised against a real temporary Git history.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/tests/lib.sh"
setup() {
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/bin" "$SANDBOX/instance/scripts" "$SANDBOX/instance/docs/releases"
  cp "$REPO/scripts/upgrade.sh" "$SANDBOX/instance/scripts/"
  cd "$SANDBOX/instance" || exit 1
  git init -q -b main
  git config user.email test@example.invalid
  git config user.name Test
  git config core.hooksPath /dev/null
  printf '.env\n' > .gitignore
  printf 'COMPOSE_PROFILES=backup\nKEEP=original\n' > .env
  cp .env .env.example
  cat > scripts/init.sh <<'SCRIPT'
#!/usr/bin/env bash
echo "init $(git describe --tags --exact-match)" >> "$CALLS"
SCRIPT
  cat > scripts/verify.sh <<'SCRIPT'
#!/usr/bin/env bash
echo verify >> "$CALLS"
[ "${VERIFY_FAIL:-0}" = 0 ]
SCRIPT
  cat > scripts/setup.sh <<'SCRIPT'
#!/usr/bin/env bash
echo setup >> "$CALLS"
SCRIPT
  chmod +x scripts/*.sh
  echo 'Breaking changes: no' > docs/releases/v1.0.0.md
  git add .; git commit -qm initial; git tag v1.0.0
  echo 'FIRST=one' >> .env.example
  echo 'Breaking changes: no' > docs/releases/v1.1.0.md
  git add .; git commit -qm minor; git tag v1.1.0
  echo 'SECOND=two' >> .env.example
  echo 'Breaking changes: no' > docs/releases/v1.2.0.md
  git add .; git commit -qm minor2; git tag v1.2.0
  git clone -q --bare . "$SANDBOX/remote.git"
  git remote add origin "$SANDBOX/remote.git"
  git checkout -q --detach v1.0.0
  export CALLS="$SANDBOX/calls"
  touch "$CALLS"
  cat > "$SANDBOX/bin/curl" <<'SCRIPT'
#!/usr/bin/env bash
printf '[{"tag_name":"v1.2.0","draft":false,"prerelease":false},{"tag_name":"v1.1.0","draft":false,"prerelease":false},{"tag_name":"v1.0.0","draft":false,"prerelease":false}]'
SCRIPT
  cat > "$SANDBOX/bin/docker" <<'SCRIPT'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
if [[ "$*" == *'config --services'* ]]; then echo backup; fi
if [[ "$*" == *'config --format json'* ]]; then echo '{"services":{"backup":{"profiles":["backup"]}}}'; fi
[ "${DOCKER_FAIL:-}" != "$*" ]
SCRIPT
  chmod +x "$SANDBOX/bin/"*
  export PATH="$SANDBOX/bin:$PATH"
}
teardown() { cd "$REPO" || exit 1; rm -rf "$SANDBOX"; }
run_upgrade() { OUTPUT="$(scripts/upgrade.sh "$@" 2>&1)"; STATUS=$?; }
test_dry_run_lists_every_intermediate_release_without_mutation() {
  run_upgrade --dry-run
  assert_status 0
  assert_output_contains v1.1.0
  assert_output_contains v1.2.0
  [ "$(git describe --tags --exact-match)" = v1.0.0 ] || fail 'checkout changed'
  [ ! -d .git/media-stack-upgrade ] || fail 'dry-run recorded state'
  [ ! -s "$CALLS" ] || fail 'dry-run ran Docker'
  assert_file_not_contains .env FIRST=
}
test_upgrade_applies_all_steps_and_preserves_existing_settings() {
  OUTPUT="$(printf 'n\ny\n\nn\ny\n\n' | scripts/upgrade.sh 2>&1)"; STATUS=$?
  assert_status 0
  assert_file_contains .env KEEP=original
  assert_file_contains .env FIRST=one
  assert_file_contains .env SECOND=two
  assert_file_contains "$CALLS" 'init v1.1.0'
  assert_file_contains "$CALLS" 'init v1.2.0'
  assert_file_contains "$CALLS" 'compose run --rm --build backup run'
  [ "$(head -n 2 "$CALLS" | tail -n 1)" = 'compose run --rm --build backup run' ] || fail 'backup was not first action'
  run_upgrade --version
  assert_status 0
  assert_output_contains v1.2.0
  run_upgrade --rollback
  assert_status 0
  [ "$(git describe --tags --exact-match)" = v1.0.0 ] || fail 'wrong rollback checkout'
  assert_file_contains .env SECOND=two
}
test_dirty_tree_is_refused() {
  echo dirty >> .env.example
  run_upgrade --dry-run
  assert_status 1
  assert_output_contains 'Dirty working tree'
}
test_backup_failure_leaves_checkout_unchanged() {
  export DOCKER_FAIL='compose run --rm --build backup run'
  run_upgrade
  assert_status 1
  assert_output_contains 'backup failed'
  [ "$(git describe --tags --exact-match)" = v1.0.0 ] || fail 'checkout changed'
  [ ! -f .git/media-stack-upgrade/previous-commit ] || fail 'recovery state created'
}
test_verify_failure_offers_retryable_rollback() {
  export VERIFY_FAIL=1 VERIFY_ATTEMPTS=1
  OUTPUT="$(printf 'n\ny\n\nn\n' | scripts/upgrade.sh 2>&1)"; STATUS=$?
  assert_status 1
  assert_output_contains 'Upgrade failed at v1.1.0'
  assert_output_contains 'Roll back'
  [ -f .git/media-stack-upgrade/previous-commit ] || fail 'lost rollback state'
  unset VERIFY_FAIL
  run_upgrade --rollback
  assert_status 0
  [ "$(git describe --tags --exact-match)" = v1.0.0 ] || fail 'wrong rollback checkout'
}
test_local_commit_requires_an_assumed_release() {
  echo local > local.sh; git add local.sh; git commit -qm local
  run_upgrade --dry-run
  assert_status 1
  assert_output_contains --assume-version
  run_upgrade --assume-version v1.0.0 --dry-run
  assert_status 0
  assert_output_contains 'unreleased commit'
}
test_breaking_changes_need_explicit_confirmation() {
  git checkout -q main
  echo 'Breaking changes: yes' > docs/releases/v1.2.0.md
  git add .; git commit -qm breaking; git tag -f v1.2.0 >/dev/null
  git push -q --force origin main refs/tags/v1.2.0
  git checkout -q --detach v1.0.0
  OUTPUT="$(printf 'n\n' | scripts/upgrade.sh 2>&1)"; STATUS=$?
  assert_status 1
  assert_output_contains 'manual steps'
  [ ! -s "$CALLS" ] || fail 'deployment happened without confirmation'
}
run_tests
