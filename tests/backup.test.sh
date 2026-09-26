#!/usr/bin/env bash
# Tests for stacks/backup/media-backup.sh. restic, curl and supercronic are fakes on
# PATH; sqlite3 is the real one, so the database copies are real online backups.
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
  cat > "$SANDBOX/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl ${*//$'\n'/ }" >> "$FAKE_LOG"
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

test_failed_backup_alerts_on_telegram() {
  FAKE_BACKUP_STATUS=3 run_backup run
  assert_status 1
  local call; call="$(calls | grep '^curl')" || fail "no Telegram alert"
  [[ "$call" == *"api.telegram.org/bot123:abc/sendMessage"* ]] || fail "wrong bot URL: $call"
  [[ "$call" == *"chat_id=42"* ]] || fail "wrong chat: $call"
  [[ "$call" == *"restic backup"* ]] || fail "alert does not say what failed: $call"
  grep -q '^failed' "$STATE_DIR/last-status" || fail "last-status is not failed"
}

test_failed_retention_alerts() {
  FAKE_FORGET_STATUS=1 run_backup run
  assert_status 1
  calls | grep -q '^curl' || fail "no alert when forget/prune fails"
}

test_missing_password_fails_and_alerts() {
  RESTIC_PASSWORD="" run_backup run
  assert_status 1
  assert_output_contains "RESTIC_PASSWORD"
  calls | grep -q '^curl' || fail "no alert"
  restic_call backup && fail "backed up without a password"
  return 0
}

test_failure_without_telegram_still_fails() {
  TELEGRAM_BOT_TOKEN="" FAKE_BACKUP_STATUS=1 run_backup run
  assert_status 1
  calls | grep -q '^curl' && fail "curl called without a bot token"
  return 0
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
