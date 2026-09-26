# shellcheck shell=bash
# Minimal test runner: every function named test_* is a test, run in a subshell
# between setup and teardown. Sourced by tests/*.test.sh.

fail() { echo "    $*" >&2; exit 1; }

assert_status() {
  [ "$STATUS" = "$1" ] || fail "expected exit status $1, got $STATUS. Output:
$OUTPUT"
}
assert_output_contains() {
  [[ "$OUTPUT" == *"$1"* ]] || fail "expected output to contain '$1'. Output:
$OUTPUT"
}
assert_output_not_contains() {
  [[ "$OUTPUT" != *"$1"* ]] || fail "expected output not to contain '$1'. Output:
$OUTPUT"
}
assert_dir() { [ -d "$1" ] || fail "expected directory $1"; }
assert_owner() {
  local actual
  actual="$(stat -c '%u:%g' "$1")"
  [ "$actual" = "$2" ] || fail "expected $1 owned by $2, got $actual"
}
assert_file_contains() { grep -qF -- "$2" "$1" 2>/dev/null || fail "expected $1 to contain '$2'"; }
assert_file_not_contains() { ! grep -qF -- "$2" "$1" 2>/dev/null || fail "expected $1 not to contain '$2'"; }

run_tests() {
  local failed=0 passed=0 name
  for name in $(declare -F | awk '{print $3}' | grep '^test_'); do
    if (
      declare -F setup >/dev/null && setup
      trap 'declare -F teardown >/dev/null && teardown' EXIT
      "$name"
    ); then
      passed=$((passed + 1)); echo "ok   $name"
    else
      failed=$((failed + 1)); echo "FAIL $name"
    fi
  done
  echo "$passed passed, $failed failed"
  [ "$failed" = 0 ]
}
