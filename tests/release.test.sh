#!/usr/bin/env bash
# Release command must never tag before its validation gate succeeds.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/tests/lib.sh"
setup() {
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/repo/scripts" "$SANDBOX/repo/tests" "$SANDBOX/repo/docs/releases" "$SANDBOX/repo/worker" "$SANDBOX/bin"
  cp "$REPO/scripts/release.sh" "$REPO/scripts/check.sh" "$SANDBOX/repo/scripts/"
  mkdir "$SANDBOX/repo/env"
  printf '{}\n' > "$SANDBOX/repo/env/catalog.json"
  cat > "$SANDBOX/repo/scripts/env_contract.py" <<'SCRIPT'
import sys
if sys.argv[1] == "fixture":
    print("COMPOSE_PROFILES=\nAPPDATA_ROOT=/tmp/app")
SCRIPT
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
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/bin/shellcheck"
  chmod +x tests/*.sh "$SANDBOX/bin/docker" "$SANDBOX/bin/shellcheck"
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
test_ci_skips_real_app_wiring_but_runs_other_tests() {
  printf 'exit 37\n' > tests/wire-integration.test.sh
  OUTPUT="$(bash scripts/check.sh ci 2>&1)"; STATUS=$?
  assert_status 0
  export TEST_FAIL=1
  OUTPUT="$(bash scripts/check.sh ci 2>&1)"; STATUS=$?
  assert_status 1
}
test_release_includes_real_app_wiring_and_preserves_failure_status() {
  printf 'exit 37\n' > tests/wire-integration.test.sh
  git add tests/wire-integration.test.sh; git commit -qm 'integration fixture'
  run_release
  assert_status 37
  [ -z "$(git tag)" ] || fail 'tagged failing real-app integration'
}
test_lint_failure_does_not_create_tag() {
  printf '#!/usr/bin/env bash\nexit 13\n' > "$SANDBOX/bin/shellcheck"
  run_release
  assert_status 13
  [ -z "$(git tag)" ] || fail 'tagged failing lint'
}
test_fast_checks_do_not_run_app_tests() {
  export TEST_FAIL=1
  OUTPUT="$(bash scripts/check.sh fast 2>&1)"; STATUS=$?
  assert_status 0
}
test_full_checks_reject_macos_before_running_tests() {
  printf '#!/usr/bin/env bash\nprintf "Darwin\\n"\n' > "$SANDBOX/bin/uname"
  chmod +x "$SANDBOX/bin/uname"
  OUTPUT="$(bash scripts/check.sh ci 2>&1)"; STATUS=$?
  assert_status 1
  assert_output_contains 'require Linux/GNU utilities'
}
run_tests
