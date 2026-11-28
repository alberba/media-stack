#!/usr/bin/env bash
# Tests for stacks/backup/media-backup.sh. restic, curl and supercronic are fakes on
# PATH; sqlite3 is the real one, so the database copies are real online backups. The
# signature of every event published to the hub is checked against an independent HMAC
# oracle written in Python.
# Usage: tests/backup.test.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP="$REPO/stacks/backup/media-backup.sh"
. "$REPO/tests/lib.sh"

setup() {
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/bin" "$SANDBOX/capture"
  export SOURCE_DIR="$SANDBOX/source" DB_DIR="$SANDBOX/databases" STATE_DIR="$SANDBOX/state"
  export CRONTAB_FILE="$SANDBOX/crontab"
  export RESTIC_REPOSITORY="rclone:gdrive:media-stack" RESTIC_PASSWORD="correct horse"
  export TELEGRAM_BOT_TOKEN="123:abc" TELEGRAM_CHAT_ID="42"
  export NOTIFY_INGEST_URL="http://hub.test/api/notifications/ingest"
  export NOTIFY_INGEST_SECRET="ingest-test-secret-0123456789abcdef" NOTIFY_INGEST_HOST_ID="nas-home"
  export INGEST_RETRY_DELAYS="0 0 0" FAKE_INGEST_CODES="202"
  export DIRECT_NOTICE_PREFIX="DIRECT-NOTICE-PREFIX"
  export BACKUP_EXCLUDE="" BACKUP_SCHEDULE=""
  export FAKE_LOG="$SANDBOX/calls.log" CAPTURE="$SANDBOX/capture"
  export FAKE_CAT_CONFIG_STATUS=0 FAKE_BACKUP_STATUS=0 FAKE_FORGET_STATUS=0
  unset BACKUP_KEEP_DAILY BACKUP_KEEP_WEEKLY BACKUP_KEEP_MONTHLY BACKUP_HOST

  # restic: logs every call; `backup` saves the staged databases and the exclude
  # file as they were at that moment.
  cat > "$SANDBOX/bin/restic" <<'EOF'
#!/usr/bin/env bash
echo "restic $*" >> "$FAKE_LOG"
case "$1" in
  cat) exit "$FAKE_CAT_CONFIG_STATUS" ;;
  backup)
    cp -a "$DB_DIR" "$CAPTURE/databases" 2>/dev/null
    exit "$FAKE_BACKUP_STATUS" ;;
  forget) exit "$FAKE_FORGET_STATUS" ;;
  snapshots) echo '[{"short_id":"0dd111"},{"short_id":"ae2222"}]' ;;
  restore)
    # Restoring the database copies: put one database where restic would.
    if [[ "$2" == *":$DB_DIR" ]]; then mkdir -p "$4/radarr" && echo restored > "$4/radarr/radarr.db"; fi ;;
esac
exit 0
EOF
  # curl: logs every call. A call that reads a config from stdin (-K) is the direct
  # Telegram notice; one that sends --data-binary is a hub ingest request. Each is saved
  # as $CAPTURE/telegram-N.* or $CAPTURE/ingest-N.*; the HTTP code of ingest request N is
  # the Nth word of FAKE_INGEST_CODES (the last one repeats), and 000 is a network failure.
  cat > "$SANDBOX/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl ${*//$'\n'/ }" >> "$FAKE_LOG"
args=("$@"); kind=other; headers=(); want_code=0
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    -K) kind=telegram ;;
    --data-binary) kind=ingest ;;
    -H) headers+=("${args[i+1]}") ;;
    -w) want_code=1 ;;
  esac
done
next() { local n=1; while [ -e "$CAPTURE/$1-$n.args" ]; do n=$((n + 1)); done; echo "$n"; }
case "$kind" in
  telegram)
    n="$(next telegram)"
    printf '%s\n' "$@" > "$CAPTURE/telegram-$n.args"
    cat > "$CAPTURE/telegram-$n.stdin"
    exit "${FAKE_TELEGRAM_STATUS:-0}" ;;
  ingest)
    n="$(next ingest)"
    printf '%s\n' "$@" > "$CAPTURE/ingest-$n.args"
    printf '%s\n' "${headers[@]}" > "$CAPTURE/ingest-$n.headers"
    cat > "$CAPTURE/ingest-$n.body"
    read -ra codes <<< "${FAKE_INGEST_CODES:-202}"
    code="${codes[n-1]:-${codes[${#codes[@]}-1]}}"
    [ "$want_code" = 1 ] && printf '%s' "$code"
    [ "$code" = 000 ] && exit 7
    exit 0 ;;
esac
exit 0
EOF
  cat > "$SANDBOX/bin/supercronic" <<'EOF'
#!/usr/bin/env bash
echo "supercronic $*" >> "$FAKE_LOG"
EOF
  chmod +x "$SANDBOX/bin/"*
  export PATH="$SANDBOX/bin:$PATH"

  mkdir -p "$SOURCE_DIR/radarr/MediaCover/1" "$SOURCE_DIR/jellyfin/config/data/subtitles" \
    "$SOURCE_DIR/jellyfin/cache" "$SOURCE_DIR/seerr/db"
  echo "<Config/>" > "$SOURCE_DIR/radarr/config.xml"
  make_db "$SOURCE_DIR/radarr/radarr.db" Movies 3
  make_db "$SOURCE_DIR/seerr/db/db.sqlite" user 2
  make_db "$SOURCE_DIR/jellyfin/cache/cache.db" Things 1
}
teardown() { rm -rf "$SANDBOX"; }

# make_db FILE TABLE ROWS: a real SQLite database with ROWS rows in TABLE.
make_db() {
  sqlite3 "$1" "CREATE TABLE \"$2\" (Id INTEGER PRIMARY KEY);" \
    "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i < $3) INSERT INTO \"$2\" SELECT i FROM n;"
}

run_backup() { OUTPUT="$("$BACKUP" "$@" 2>&1)"; STATUS=$?; }
calls() { cat "$FAKE_LOG" 2>/dev/null; }
assert_excluded() {
  [[ "$(restic_call backup)" == *"--exclude $1 "* ]] || fail "--exclude $1 missing: $(restic_call backup)"
}
assert_not_excluded() {
  [[ "$(restic_call backup)" != *"$1"* ]] || fail "$1 is excluded: $(restic_call backup)"
}
restic_call() { grep "^restic $1" "$FAKE_LOG" 2>/dev/null; }

# --- the hub ingest and the direct Telegram notice --------------------------
count_captured() { find "$CAPTURE" -maxdepth 1 -name "$1-*.args" | wc -l; }
ingest_count() { count_captured ingest; }
telegram_count() { count_captured telegram; }
assert_ingest_count() { [ "$(ingest_count)" = "$1" ] || fail "expected $1 ingest requests, got $(ingest_count)"; }
assert_telegram_count() { [ "$(telegram_count)" = "$1" ] || fail "expected $1 direct notices, got $(telegram_count)"; }
header_value() { sed -n "s/^$2: //p" "$CAPTURE/ingest-$1.headers"; }
event_id_of() { jq -r .eventId "$CAPTURE/ingest-$1.body"; }
# The independent oracle: HMAC-SHA256 over "<timestamp>.<body>" computed by Python.
oracle_signature() {
  python3 -I - "$CAPTURE/ingest-$1.body" "$(header_value "$1" X-Ingest-Timestamp)" <<'PY'
import hashlib, hmac, os, sys
body = open(sys.argv[1], "rb").read()
key = os.environ["NOTIFY_INGEST_SECRET"].encode()
print(hmac.new(key, sys.argv[2].encode() + b"." + body, hashlib.sha256).hexdigest())
PY
}
assert_signed_request() {
  local n="$1" timestamp signature
  timestamp="$(header_value "$n" X-Ingest-Timestamp)"
  signature="$(header_value "$n" X-Ingest-Signature)"
  [[ "$timestamp" =~ ^[0-9]{10}$ ]] || fail "request $n: timestamp is not 10 digits: '$timestamp'"
  [[ "$signature" =~ ^v1=[0-9a-f]{64}$ ]] || fail "request $n: malformed signature: '$signature'"
  [ "${signature#v1=}" = "$(oracle_signature "$n")" ] \
    || fail "request $n: the signature differs from the oracle's"
}

# --- run: databases ---------------------------------------------------------

test_run_copies_every_sqlite_database_before_backing_up() {
  run_backup run
  assert_status 0
  [ "$(sqlite3 "$CAPTURE/databases/radarr/radarr.db" 'SELECT COUNT(*) FROM Movies')" = 3 ] \
    || fail "radarr.db was not staged with its rows"
  [ "$(sqlite3 "$CAPTURE/databases/seerr/db/db.sqlite" 'SELECT COUNT(*) FROM user')" = 2 ] \
    || fail "db.sqlite was not staged with its rows"
}

test_run_copies_a_wal_database_with_uncheckpointed_writes() {
  sqlite3 "$SOURCE_DIR/radarr/radarr.db" "PRAGMA journal_mode=WAL;" >/dev/null
  # A writer keeps the database open, so the new rows live only in the -wal file.
  { printf 'PRAGMA wal_autocheckpoint=0;\nINSERT INTO Movies VALUES (10),(11);\n'; sleep 5; } \
    | sqlite3 "$SOURCE_DIR/radarr/radarr.db" >/dev/null &
  local writer=$!
  local _; for _ in $(seq 50); do
    [ "$(sqlite3 "$SOURCE_DIR/radarr/radarr.db" 'SELECT COUNT(*) FROM Movies')" = 5 ] && break
    sleep 0.1
  done
  [ -s "$SOURCE_DIR/radarr/radarr.db-wal" ] || fail "test setup: no -wal file"
  run_backup run
  kill "$writer" 2>/dev/null; wait "$writer" 2>/dev/null
  assert_status 0
  [ "$(sqlite3 "$CAPTURE/databases/radarr/radarr.db" 'SELECT COUNT(*) FROM Movies')" = 5 ] \
    || fail "the staged copy misses the rows still in the -wal file"
}

test_run_copies_keep_the_owner_and_mode_of_the_originals() {
  chmod 640 "$SOURCE_DIR/seerr/db/db.sqlite"
  chmod 750 "$SOURCE_DIR/seerr/db"
  chmod 705 "$SOURCE_DIR/seerr"
  run_backup run
  local path
  for path in seerr seerr/db seerr/db/db.sqlite; do
    [ "$(stat -c '%u:%g %a' "$CAPTURE/databases/$path")" = "$(stat -c '%u:%g %a' "$SOURCE_DIR/$path")" ] \
      || fail "$path: copy is $(stat -c '%u:%g %a' "$CAPTURE/databases/$path"), original $(stat -c '%u:%g %a' "$SOURCE_DIR/$path")"
  done
  [ "$(stat -c '%u:%g %a' "$CAPTURE/databases")" = "$(stat -c '%u:%g %a' "$SOURCE_DIR")" ] \
    || fail "the staging root does not mirror the source root"
}

test_run_excludes_the_raw_database_files_it_copied() {
  run_backup run
  assert_excluded "$SOURCE_DIR/radarr/radarr.db"
  assert_excluded "$SOURCE_DIR/radarr/radarr.db-wal"
  assert_excluded "$SOURCE_DIR/radarr/radarr.db-shm"
  assert_excluded "$SOURCE_DIR/seerr/db/db.sqlite"
}

test_run_ignores_files_that_only_look_like_databases() {
  echo "not sqlite" > "$SOURCE_DIR/radarr/Thumbs.db"
  run_backup run
  assert_status 0
  [ ! -e "$CAPTURE/databases/radarr/Thumbs.db" ] || fail "Thumbs.db was treated as a database"
  assert_not_excluded "Thumbs.db"
}

test_run_does_not_copy_databases_in_excluded_folders() {
  run_backup run
  [ ! -e "$CAPTURE/databases/jellyfin/cache/cache.db" ] || fail "a cache database was copied"
}

test_run_keeps_the_raw_file_and_fails_when_a_database_cannot_be_copied() {
  printf 'SQLite format 3\0garbage garbage garbage' > "$SOURCE_DIR/radarr/broken.db"
  run_backup run
  assert_status 1
  assert_output_contains "broken.db"
  assert_not_excluded "broken.db"
  [ -e "$CAPTURE/databases/radarr/radarr.db" ] || fail "the other databases were not copied"
  restic_call backup >/dev/null || fail "the backup did not run"
}

test_run_excludes_odd_paths_literally() {
  mkdir -p "$SOURCE_DIR/odd"
  make_db "$SOURCE_DIR/odd/\$HOME [1].db" Things 1
  run_backup run
  assert_status 0
  assert_excluded "$SOURCE_DIR/odd/\$HOME \\[1\\].db"
}

test_run_refuses_to_start_while_another_run_is_going() {
  mkdir -p "$STATE_DIR"
  flock "$STATE_DIR/run.lock" sleep 5 &
  local holder=$!
  sleep 0.5
  run_backup run
  kill "$holder" 2>/dev/null
  assert_status 1
  assert_output_contains "already running"
  restic_call backup && fail "backed up while another run held the lock"
  return 0
}

test_run_empties_the_staging_folder_afterwards() {
  run_backup run
  [ -z "$(ls -A "$DB_DIR" 2>/dev/null)" ] || fail "staged databases were left behind"
}

# --- run: restic ------------------------------------------------------------

test_run_backs_up_the_source_and_the_database_copies() {
  run_backup run
  local call; call="$(restic_call backup)"
  [[ "$call" == *" $SOURCE_DIR "* || "$call" == *" $SOURCE_DIR" ]] || fail "source not backed up: $call"
  [[ "$call" == *"$DB_DIR"* ]] || fail "database copies not backed up: $call"
  [[ "$call" == *"--host media-stack"* ]] || fail "no fixed host: $call"
}

test_run_excludes_caches_metadata_and_logs() {
  run_backup run
  local call pattern; call="$(restic_call backup)"
  for pattern in cache metadata MediaCover logs; do
    [[ "$call" == *"--exclude $pattern "* ]] || fail "--exclude $pattern missing: $call"
  done
  [[ "$call" == *"--exclude $SOURCE_DIR/**/data/subtitles"* ]] || fail "Jellyfin subtitles not excluded: $call"
}

test_run_adds_the_extra_excludes_from_env() {
  export BACKUP_EXCLUDE=".git, seerr/db"
  run_backup run
  local call; call="$(restic_call backup)"
  [[ "$call" == *"--exclude .git "* ]] || fail ".git not excluded: $call"
  [[ "$call" == *"--exclude $SOURCE_DIR/seerr/db "* ]] || fail "seerr/db not excluded: $call"
  [ ! -e "$CAPTURE/databases/seerr/db/db.sqlite" ] || fail "a database in an excluded folder was copied"
}

test_run_excludes_its_own_state_folder_when_it_is_inside_the_source() {
  mkdir -p "$SOURCE_DIR/backup"
  export STATE_DIR="$SANDBOX/state-link"
  ln -s "$SOURCE_DIR/backup" "$STATE_DIR"
  make_db "$SOURCE_DIR/backup/staged.db" Things 1
  run_backup run
  assert_status 0
  assert_excluded "$SOURCE_DIR/backup"
  [ ! -e "$CAPTURE/databases/backup/staged.db" ] || fail "the state folder was scanned"
}

test_run_initialises_the_repository_when_it_does_not_exist() {
  FAKE_CAT_CONFIG_STATUS=10 run_backup run
  assert_status 0
  restic_call init >/dev/null || fail "restic init not called"
}

test_run_does_not_initialise_an_existing_repository() {
  run_backup run
  restic_call init && fail "restic init called on an existing repository"
  return 0
}

test_run_fails_when_the_repository_cannot_be_opened() {
  FAKE_CAT_CONFIG_STATUS=12 run_backup run
  assert_status 1
  restic_call backup && fail "backed up despite the repository error"
  return 0
}

test_run_applies_retention_and_prunes() {
  run_backup run
  local call; call="$(restic_call forget)"
  for flag in "--keep-daily 7" "--keep-weekly 4" "--keep-monthly 6" "--prune" "--host media-stack"; do
    [[ "$call" == *"$flag"* ]] || fail "'$flag' missing: $call"
  done
}

test_retention_comes_from_env() {
  BACKUP_KEEP_DAILY=3 BACKUP_KEEP_WEEKLY=2 BACKUP_KEEP_MONTHLY=12 run_backup run
  local call; call="$(restic_call forget)"
  [[ "$call" == *"--keep-daily 3 --keep-weekly 2 --keep-monthly 12"* ]] || fail "retention from env ignored: $call"
}

test_run_skips_retention_when_the_backup_fails() {
  FAKE_BACKUP_STATUS=1 run_backup run
  restic_call forget && fail "forget ran after a failed backup"
  return 0
}

# --- run: outcome -----------------------------------------------------------

test_success_sends_no_alert_and_records_ok() {
  run_backup run
  assert_status 0
  calls | grep -q '^curl' && fail "an alert was sent on success"
  grep -q '^ok' "$STATE_DIR/last-status" || fail "last-status is not ok"
}

test_failed_backup_publishes_a_signed_event_and_skips_telegram() {
  FAKE_BACKUP_STATUS=3 run_backup run
  assert_status 1
  assert_ingest_count 1
  assert_telegram_count 0
  assert_signed_request 1
  jq -e --arg host "$NOTIFY_INGEST_HOST_ID" \
    '.v == 1 and .source == "backup" and .hostId == $host and .key == "backup-failed"
     and .state == "open" and (.eventId | test("^backup-failed:[0-9]+$"))
     and (.data.errors | any(contains("restic backup")))' "$CAPTURE/ingest-1.body" >/dev/null \
    || fail "unexpected event: $(cat "$CAPTURE/ingest-1.body")"
  grep -q '^failed' "$STATE_DIR/last-status" || fail "last-status is not failed"
}

test_failed_retention_publishes_to_the_hub() {
  FAKE_FORGET_STATUS=1 run_backup run
  assert_status 1
  assert_ingest_count 1
}

test_missing_password_fails_and_publishes_to_the_hub() {
  RESTIC_PASSWORD="" run_backup run
  assert_status 1
  assert_output_contains "RESTIC_PASSWORD"
  assert_ingest_count 1
  restic_call backup && fail "backed up without a password"
  return 0
}

# The text of the direct notice, as curl received it (--data-urlencode text=...).
# The text is the last argument, so it runs from its "text=" line to the end of the file.
direct_notice_text() { sed -n '/^text=/,$p' "$CAPTURE/telegram-$1.args" | sed '1s/^text=//'; }
assert_direct_notice() {
  local n="$1" text
  [ "$(telegram_count)" -ge "$n" ] || fail "no direct notice $n"
  text="$(direct_notice_text "$n")"
  [[ "$text" == *"$DIRECT_NOTICE_PREFIX"* ]] || fail "the notice lacks the fixed prefix: $text"
  [[ "$text" == *"nas-test"* ]] || fail "the notice lacks the host: $text"
  [[ "$text" == *"restic backup"* ]] || fail "the notice lacks the errors: $text"
  # The token reaches curl only through the config on stdin, never through its arguments.
  grep -qF "$TELEGRAM_BOT_TOKEN" "$CAPTURE/telegram-$n.args" && fail "the bot token is in curl's arguments"
  grep -qF "$TELEGRAM_BOT_TOKEN" "$FAKE_LOG" && fail "the bot token is in the logged call"
  grep -qF "bot$TELEGRAM_BOT_TOKEN/sendMessage" "$CAPTURE/telegram-$n.stdin" \
    || fail "the bot token is not in curl's stdin config"
  grep -qF "chat_id=$TELEGRAM_CHAT_ID" "$CAPTURE/telegram-$n.args" || fail "the notice is not for the chat"
}

test_a_retry_reuses_the_event_and_a_late_2xx_sends_no_direct_notice() {
  FAKE_INGEST_CODES="500 502 202" FAKE_BACKUP_STATUS=3 run_backup run
  assert_status 1
  assert_ingest_count 3
  assert_telegram_count 0
  local n
  for n in 1 2 3; do assert_signed_request "$n"; done
  [ "$(event_id_of 1)" = "$(event_id_of 2)" ] && [ "$(event_id_of 2)" = "$(event_id_of 3)" ] \
    || fail "the event id changed between attempts: $(event_id_of 1) $(event_id_of 2) $(event_id_of 3)"
  [ "$(cat "$CAPTURE/ingest-1.body")" = "$(cat "$CAPTURE/ingest-3.body")" ] || fail "the body changed between attempts"
}

test_a_duplicate_confirmation_counts_as_confirmed() {
  FAKE_INGEST_CODES="200" FAKE_BACKUP_STATUS=3 run_backup run
  assert_ingest_count 1
  assert_telegram_count 0
}

test_without_any_2xx_the_backup_sends_one_direct_notice() {
  local codes
  for codes in "500 500 500" "401 401 401" "409 409 409" "422 422 422" "000 000 000" "302 500 404"; do
    rm -f "$CAPTURE"/ingest-* "$CAPTURE"/telegram-*
    BACKUP_HOST=nas-test FAKE_INGEST_CODES="$codes" FAKE_BACKUP_STATUS=3 run_backup run
    assert_status 1
    assert_ingest_count 3
    assert_telegram_count 1
    assert_direct_notice 1
  done
}

test_the_retries_wait_the_configured_delays() {
  local sleeps="$SANDBOX/sleeps"
  cat > "$SANDBOX/bin/sleep" <<'EOF'
#!/usr/bin/env bash
echo "$1" >> "$SLEEP_LOG"
EOF
  chmod +x "$SANDBOX/bin/sleep"
  export SLEEP_LOG="$sleeps"
  INGEST_RETRY_DELAYS="0 7 11" FAKE_INGEST_CODES="500" FAKE_BACKUP_STATUS=3 run_backup run
  [ "$(paste -sd, "$sleeps")" = "0,7,11" ] || fail "unexpected waits: $(paste -sd, "$sleeps")"
  assert_ingest_count 3
}

test_the_default_retry_schedule_is_three_attempts_over_about_two_minutes() {
  grep -q 'INGEST_RETRY_DELAYS:-0 30 60' "$BACKUP" || fail "the default retry delays changed"
}

test_without_ingest_a_failed_backup_sends_one_direct_notice() {
  NOTIFY_INGEST_URL="" BACKUP_HOST=nas-test FAKE_BACKUP_STATUS=3 run_backup run
  assert_status 1
  assert_ingest_count 0
  assert_telegram_count 1
  assert_direct_notice 1
}

test_a_partly_configured_ingest_counts_as_not_configured() {
  NOTIFY_INGEST_SECRET="" BACKUP_HOST=nas-test FAKE_BACKUP_STATUS=3 run_backup run
  assert_ingest_count 0
  assert_telegram_count 1
}

test_failure_without_ingest_or_telegram_still_fails_and_says_so() {
  NOTIFY_INGEST_URL="" TELEGRAM_BOT_TOKEN="" FAKE_BACKUP_STATUS=1 run_backup run
  assert_status 1
  calls | grep -q '^curl' && fail "curl called with no ingest and no bot token"
  assert_output_contains "no direct notice sent"
  grep -q '^failed' "$STATE_DIR/last-status" || fail "last-status is not failed"
}

test_a_failed_direct_notice_does_not_change_the_exit_status() {
  NOTIFY_INGEST_URL="" FAKE_TELEGRAM_STATUS=22 FAKE_BACKUP_STATUS=3 run_backup run
  assert_status 1
  assert_telegram_count 1
}

test_a_successful_backup_never_notifies_anyone() {
  FAKE_INGEST_CODES="500" run_backup run
  assert_status 0
  assert_ingest_count 0
  assert_telegram_count 0
  calls | grep -q '^curl' && fail "curl called on a successful backup"
  return 0
}

test_error_text_cannot_break_or_extend_the_event() {
  # shellcheck disable=SC2016  # the $(...) in the name must stay literal
  printf 'SQLite format 3\0garbage' > "$SOURCE_DIR/radarr/"'q"b\s {"k":"x"} $(id).db'
  FAKE_BACKUP_STATUS=3 run_backup run
  assert_ingest_count 1
  assert_signed_request 1
  jq -e '(keys == ["data","eventId","hostId","key","source","state","v"])
         and (.data | keys) == ["errors"]
         and (.data.errors | any(contains("q\"b\\s {\"k\":\"x\"} $(id).db")))' \
    "$CAPTURE/ingest-1.body" >/dev/null || fail "unexpected event: $(cat "$CAPTURE/ingest-1.body")"
}

test_the_event_carries_at_most_five_errors_of_two_hundred_characters() {
  local i long; long="$(printf 'x%.0s' $(seq 220))"
  for i in 1 2 3 4 5 6 7; do
    printf 'SQLite format 3\0garbage' > "$SOURCE_DIR/radarr/$long-$i.db"
  done
  FAKE_BACKUP_STATUS=3 run_backup run
  assert_ingest_count 1
  jq -e '(.data.errors | length) == 5 and (.data.errors | all(length <= 200))' "$CAPTURE/ingest-1.body" >/dev/null \
    || fail "the errors are not capped: $(cat "$CAPTURE/ingest-1.body")"
}

# --- notify-test ------------------------------------------------------------

test_notify_test_ingest_opens_and_closes_a_test_incident() {
  run_backup notify-test ingest
  assert_status 0
  assert_ingest_count 2
  assert_telegram_count 0
  assert_signed_request 1
  assert_signed_request 2
  [ "$(jq -r .state "$CAPTURE/ingest-1.body")" = open ] || fail "the first event is not open"
  [ "$(jq -r .state "$CAPTURE/ingest-2.body")" = resolved ] || fail "the second event is not resolved"
  [ "$(event_id_of 1)" != "$(event_id_of 2)" ] || fail "open and resolved share an event id"
  jq -e '.eventId | test("^backup-failed:test-[0-9]+:(open|resolved)$")' "$CAPTURE/ingest-2.body" >/dev/null \
    || fail "the test event id has an unexpected form: $(event_id_of 2)"
  [ "$(jq -r .key "$CAPTURE/ingest-2.body")" = backup-failed ] || fail "the test event is not a backup-failed event"
}

test_notify_test_ingest_fails_when_the_hub_does_not_confirm() {
  FAKE_INGEST_CODES="202 500" run_backup notify-test ingest
  assert_status 1
  FAKE_INGEST_CODES="500" run_backup notify-test ingest
  assert_status 1
  assert_telegram_count 0
}

test_notify_test_ingest_needs_the_ingest_settings() {
  NOTIFY_INGEST_SECRET="" run_backup notify-test ingest
  assert_status 1
  assert_ingest_count 0
}

test_notify_test_fallback_sends_a_direct_notice_only() {
  run_backup notify-test fallback
  assert_status 0
  assert_ingest_count 0
  assert_telegram_count 1
  [[ "$(direct_notice_text 1)" == *"$DIRECT_NOTICE_PREFIX"* ]] || fail "the test notice lacks the fixed prefix"
  [[ "$(direct_notice_text 1)" == *"notify-test"* ]] || fail "the test notice is not marked as a test"
  grep -qF "$TELEGRAM_BOT_TOKEN" "$CAPTURE/telegram-1.args" && fail "the bot token is in curl's arguments"
  return 0
}

test_notify_test_fallback_fails_without_telegram() {
  TELEGRAM_BOT_TOKEN="" run_backup notify-test fallback
  assert_status 1
  assert_telegram_count 0
}

test_notify_test_rejects_a_missing_or_unknown_mode() {
  run_backup notify-test
  assert_status 2
  run_backup notify-test everything
  assert_status 2
  assert_output_contains "usage"
  [ "$(ingest_count)" = 0 ] && [ "$(telegram_count)" = 0 ] || fail "a wrong mode sent something"
}

# --- schedule ---------------------------------------------------------------

test_schedule_runs_nightly_at_four_by_default() {
  run_backup schedule
  assert_status 0
  assert_file_contains "$CRONTAB_FILE" "0 4 * * * media-backup run"
  calls | grep -q "^supercronic .*$CRONTAB_FILE" || fail "supercronic not started"
}

test_schedule_comes_from_env() {
  BACKUP_SCHEDULE="30 2 * * 1" run_backup schedule
  assert_file_contains "$CRONTAB_FILE" "30 2 * * 1 media-backup run"
}

# --- restore ----------------------------------------------------------------

test_restore_puts_files_and_database_copies_into_the_target() {
  mkdir -p "$SANDBOX/target"
  run_backup restore "$SANDBOX/target"
  assert_status 0
  local restores; restores="$(restic_call restore)"
  [ "$(sed -n 1p <<< "$restores")" = "restic restore ae2222:$SOURCE_DIR --target $SANDBOX/target" ] \
    || fail "files not restored first from the latest snapshot: $restores"
  [[ "$(sed -n 2p <<< "$restores")" == "restic restore ae2222:$DB_DIR --target $SANDBOX/target/"* ]] \
    || fail "database copies not restored next: $restores"
  [ "$(cat "$SANDBOX/target/radarr/radarr.db")" = restored ] || fail "the database copy was not moved into place"
  [ -z "$(find "$SANDBOX/target" -mindepth 1 -maxdepth 1 -name '.*')" ] || fail "temporary folder left in the target"
}

test_restore_drops_stale_wal_files_next_to_restored_databases() {
  mkdir -p "$SANDBOX/target/radarr"
  echo old > "$SANDBOX/target/radarr/radarr.db-wal"
  echo old > "$SANDBOX/target/radarr/radarr.db-shm"
  echo keep > "$SANDBOX/target/radarr/other.db-wal"
  run_backup restore "$SANDBOX/target"
  assert_status 0
  [ ! -e "$SANDBOX/target/radarr/radarr.db-wal" ] || fail "a stale -wal was left next to the restored database"
  [ ! -e "$SANDBOX/target/radarr/radarr.db-shm" ] || fail "a stale -shm was left next to the restored database"
  [ -e "$SANDBOX/target/radarr/other.db-wal" ] || fail "an unrelated -wal was removed"
}

test_restore_a_given_snapshot() {
  mkdir -p "$SANDBOX/target"
  run_backup restore "$SANDBOX/target" 0dd111
  restic_call "restore 0dd111:$SOURCE_DIR" >/dev/null || fail "snapshot 0dd111 not used"
  restic_call snapshots && fail "looked up latest although a snapshot was given"
  return 0
}

test_restore_needs_an_existing_target() {
  run_backup restore "$SANDBOX/nope"
  assert_status 1
  restic_call restore && fail "restored into a missing folder"
  return 0
}

# --- summary ----------------------------------------------------------------

test_summary_counts_library_indexers_and_users() {
  mkdir -p "$SOURCE_DIR/sonarr" "$SOURCE_DIR/prowlarr" "$SOURCE_DIR/jellyfin/config/data"
  make_db "$SOURCE_DIR/sonarr/sonarr.db" Series 4
  make_db "$SOURCE_DIR/prowlarr/prowlarr.db" Indexers 5
  make_db "$SOURCE_DIR/jellyfin/config/data/jellyfin.db" Users 2
  run_backup summary "$SOURCE_DIR"
  assert_status 0
  assert_output_contains "radarr/radarr.db: 3 movies"
  assert_output_contains "sonarr/sonarr.db: 4 series"
  assert_output_contains "prowlarr/prowlarr.db: 5 indexers"
  assert_output_contains "jellyfin/config/data/jellyfin.db: 2 Jellyfin users"
}

# --- other commands ---------------------------------------------------------

test_other_commands_run_as_is() {
  run_backup restic snapshots
  restic_call snapshots >/dev/null || fail "restic snapshots was not passed through"
}

run_tests
