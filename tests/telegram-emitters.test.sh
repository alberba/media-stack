#!/usr/bin/env bash
# Static guard: the backup is the only place in this repo that talks to Telegram, and
# only the backup and issue-automator publish to the hub ingest. A new Telegram emitter
# would bypass the hub's notification policy, so it has to fail here, not in review.
# The scan uses grep and find (no git) so it runs the same in the test container and in CI.
# Each check takes the root to scan, so every test also runs it against an altered copy
# of the tree and requires that the violation is caught. Usage: tests/telegram-emitters.test.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/tests/lib.sh"

BACKUP_SCRIPT="stacks/backup/media-backup.sh"
BACKUP_COMPOSE="stacks/backup/compose.yaml"
ISSUE_AUTOMATOR="stacks/extras/issue-automator/main.py"

setup() { WORK="$(mktemp -d)"; }
teardown() { rm -rf "$WORK"; }

# scan_files ROOT NEEDLE [GREP_FLAG [PRUNE_DIR...]]
# Prints, sorted and relative to ROOT, the text files that contain NEEDLE. Directories
# that hold history, docs, tests, dependencies or leftovers of test runs are not scanned.
scan_files() {
  local root="$1" needle="$2" flag="${3:--F}" file
  shift $(($# < 3 ? $# : 3))
  local prune=(-name '.*' -o -name docs -o -name tests -o -name node_modules)
  local dir
  for dir in "$@"; do prune+=(-o -name "$dir"); done
  while IFS= read -r file; do
    echo "${file#"$root"/}"
  done < <(find "$root" -mindepth 1 -type d \( "${prune[@]}" \) -prune -o -type f -print0 \
    | xargs -0 -r grep -lI "$flag" -- "$needle" 2>/dev/null) | LC_ALL=C sort
}

# compose_files ROOT: the compose files an Instance, Worker or apps server can load.
compose_files() {
  local root="$1" file
  for file in "$root"/compose*.yaml "$root"/stacks/*/compose*.yaml \
    "$root"/apps-server/compose*.yaml "$root"/worker/compose*.yaml; do
    [ -f "$file" ] && echo "${file#"$root"/}"
  done
  return 0
}

# files_in_compose ROOT NEEDLE [GREP_FLAG]: compose files that contain NEEDLE.
files_in_compose() {
  local root="$1" needle="$2" flag="${3:--F}" file
  while IFS= read -r file; do
    grep -qI "$flag" -- "$needle" "$root/$file" && echo "$file"
  done < <(compose_files "$root") | LC_ALL=C sort
  return 0
}

# expect_exactly LABEL ACTUAL EXPECTED...: fails with a diff unless ACTUAL is the sorted EXPECTED list.
expect_exactly() {
  local label="$1" actual="$2" want
  shift 2
  want="$(printf '%s\n' "$@" | LC_ALL=C sort)"
  [ "$actual" = "$want" ] && return 0
  printf '%s: expected exactly:\n%s\nfound:\n%s\n' "$label" "${want:-<none>}" "${actual:-<none>}"
  return 1
}

# tree_copy: a copy of the repo without history or leftovers, to alter and rescan.
tree_copy() {
  COPY="$WORK/tree"
  rm -rf "$COPY"
  mkdir -p "$COPY"
  tar -C "$REPO" --exclude=.git --exclude='.security-update-test-*' --exclude=node_modules -cf - . \
    | tar -C "$COPY" -xf -
}

check_api_telegram_only_in_backup() {
  expect_exactly "api.telegram.org" "$(scan_files "$1" 'api.telegram.org')" "$BACKUP_SCRIPT"
}

check_telegram_credentials_only_reach_backup() {
  expect_exactly "compose files with TELEGRAM_" "$(files_in_compose "$1" 'TELEGRAM_')" "$BACKUP_COMPOSE"
}

check_no_wud_trigger_variables() {
  expect_exactly "files with WUD_TRIGGER_" "$(scan_files "$1" 'WUD_TRIGGER_')"
}

check_telegram_catalog_is_instance_only() {
  python3 - "$1/env/catalog.json" <<'PY'
import json, sys
catalog = json.load(open(sys.argv[1]))
bad = []
for key in ("TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID"):
    scopes = sorted(catalog.get(key, {}).get("scopes", {}))
    if scopes != ["instance"]:
        bad.append(f"{key} has scopes {scopes}, expected ['instance']")
if bad:
    print("\n".join(bad))
    sys.exit(1)
PY
}

check_compose_outside_backup_does_not_mention_telegram() {
  local found
  found="$(files_in_compose "$1" 'telegram' -iF | grep -vF "$BACKUP_COMPOSE")"
  expect_exactly "compose files outside the backup mentioning Telegram" "$found"
}

check_only_two_producers_use_the_ingest() {
  # Generated examples, env templates and docs only describe the variable.
  expect_exactly "code and compose files with NOTIFY_INGEST_URL" \
    "$(scan_files "$1" 'NOTIFY_INGEST_URL' -F env examples | grep -vE '(^|/)\.env\.example$|\.template$')" \
    "$BACKUP_SCRIPT" "$BACKUP_COMPOSE" "stacks/extras/compose.yaml" "$ISSUE_AUTOMATOR"
}

# must_pass / must_fail run a check on a root and turn its verdict into the test's.
must_pass() { local out; out="$("$1" "$2")" || fail "$out"; }
must_fail() {
  "$1" "$2" >/dev/null && fail "$3 was not detected"
  return 0
}

test_api_telegram_org_only_in_backup() {
  must_pass check_api_telegram_only_in_backup "$REPO"
  tree_copy
  echo '# curl https://api.telegram.org/bot/sendMessage' >> "$COPY/stacks/extras/issue-automator/main.py"
  must_fail check_api_telegram_only_in_backup "$COPY" "api.telegram.org in a second file"
}

test_telegram_credentials_only_reach_backup() {
  must_pass check_telegram_credentials_only_reach_backup "$REPO"
  tree_copy
  echo '      TELEGRAM_BOT_TOKEN: dummy' >> "$COPY/stacks/extras/compose.yaml"
  must_fail check_telegram_credentials_only_reach_backup "$COPY" "TELEGRAM_BOT_TOKEN in a non-backup compose"
}

test_no_wud_trigger_variables() {
  must_pass check_no_wud_trigger_variables "$REPO"
  tree_copy
  echo '      WUD_TRIGGER_TELEGRAM_X: y' >> "$COPY/stacks/monitoring/compose.yaml"
  must_fail check_no_wud_trigger_variables "$COPY" "a WUD_TRIGGER_ variable"
}

test_telegram_catalog_is_instance_only() {
  must_pass check_telegram_catalog_is_instance_only "$REPO"
  tree_copy
  python3 - "$COPY/env/catalog.json" <<'PY'
import json, sys
path = sys.argv[1]
catalog = json.load(open(path))
catalog["TELEGRAM_CHAT_ID"]["scopes"]["apps-server"] = {"default": "", "required": False}
json.dump(catalog, open(path, "w"))
PY
  must_fail check_telegram_catalog_is_instance_only "$COPY" "TELEGRAM_CHAT_ID in the apps-server scope"
}

test_compose_outside_backup_does_not_mention_telegram() {
  must_pass check_compose_outside_backup_does_not_mention_telegram "$REPO"
  tree_copy
  echo '# notifies TELEGRAM on change' >> "$COPY/stacks/arr/compose.yaml"
  must_fail check_compose_outside_backup_does_not_mention_telegram "$COPY" "a Telegram mention in a non-backup compose"
  tree_copy
  echo '# notifies telegram on change' >> "$COPY/stacks/vpn/compose.yaml"
  must_fail check_compose_outside_backup_does_not_mention_telegram "$COPY" "a lowercase Telegram mention"
}

test_only_two_producers_use_the_ingest() {
  must_pass check_only_two_producers_use_the_ingest "$REPO"
  tree_copy
  echo '      NOTIFY_INGEST_URL: dummy' >> "$COPY/stacks/monitoring/compose.yaml"
  must_fail check_only_two_producers_use_the_ingest "$COPY" "a third compose using the ingest"
  tree_copy
  echo '# POST to NOTIFY_INGEST_URL' >> "$COPY/scripts/setup.sh"
  must_fail check_only_two_producers_use_the_ingest "$COPY" "a third script using the ingest"
}

# The checks above also pass on an empty tree, so prove they are looking at the real emitters.
test_the_guard_is_not_vacuous() {
  assert_file_contains "$REPO/$BACKUP_SCRIPT" 'api.telegram.org'
  assert_file_contains "$REPO/$BACKUP_COMPOSE" 'TELEGRAM_BOT_TOKEN'
  assert_file_contains "$REPO/$BACKUP_SCRIPT" 'NOTIFY_INGEST_URL'
  assert_file_contains "$REPO/$ISSUE_AUTOMATOR" 'NOTIFY_INGEST_URL'
  # And the scanner finds the files it is told to look for.
  [ "$(scan_files "$REPO" 'api.telegram.org')" = "$BACKUP_SCRIPT" ] || fail "scan_files does not see the backup script"
  [ -n "$(compose_files "$REPO")" ] || fail "compose_files found no compose file"
}

run_tests
