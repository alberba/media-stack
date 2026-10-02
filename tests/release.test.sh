#!/usr/bin/env bash
# Release command must never tag before its validation gate succeeds.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/tests/lib.sh"
setup() {
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/repo/scripts" "$SANDBOX/repo/tests" "$SANDBOX/repo/docs/releases" "$SANDBOX/repo/worker" "$SANDBOX/bin"
  cp "$REPO/scripts/release.sh" "$SANDBOX/repo/scripts/"
  cd "$SANDBOX/repo" || exit 1
  git init -q -b main; git config user.name Test; git config user.email test@example.invalid; git config core.hooksPath /dev/null
  printf 'COMPOSE_PROFILES=\nAPPDATA_ROOT=/tmp/app\n' > .env.example
  cp .env.example worker/.env.example
  cat > tests/example.test.sh <<'SCRIPT'
#!/usr/bin/env bash
exit "${TEST_FAIL:-0}"
SCRIPT
  cat > "$SANDBOX/bin/docker" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "$*" == *'config --profiles'* ]]; then printf 'backup\nvo\n'; fi
exit "${COMPOSE_FAIL:-0}"
SCRIPT
  chmod +x tests/*.sh "$SANDBOX/bin/docker"
  cat > docs/releases/v1.0.0.md <<'NOTES'
# v1.0.0
Breaking changes: no
## Images bumped
None
## New settings
None
## New Profiles
None
## Fixes
First release
## Manual steps
None
NOTES
  git add .; git commit -qm initial
  export PATH="$SANDBOX/bin:$PATH"
}
teardown() { cd "$REPO" || exit 1; rm -rf "$SANDBOX"; }
run_release() { OUTPUT="$(bash scripts/release.sh v1.0.0 2>&1)"; STATUS=$?; }
test_validation_failure_does_not_create_tag() {
  export TEST_FAIL=1
  run_release
  assert_status 1
  [ -z "$(git tag)" ] || fail 'tagged failing tests'
}
test_success_creates_annotated_local_tag() {
  run_release
  assert_status 0
  [ "$(git cat-file -t v1.0.0)" = tag ] || fail 'tag not annotated'
  assert_output_contains 'git push origin v1.0.0'
}
test_compose_failure_does_not_create_tag() {
  export COMPOSE_FAIL=1
  run_release
  assert_status 1
  [ -z "$(git tag)" ] || fail 'tagged invalid Compose'
}
run_tests
