#!/usr/bin/env bash
# End-to-end test of the backup Profile image: builds it, backs up a fake App data
# folder (with a database being written to) through rclone into a local restic
# repository, restores it into an empty folder and checks what came back.
# Needs Docker. Usage: tests/backup-image.test.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/tests/lib.sh"
IMAGE="media-stack-backup:test"

docker build -q -t "$IMAGE" "$REPO/stacks/backup" >/dev/null || { echo "FAIL image build"; exit 1; }

setup() {
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/state" "$SANDBOX/repo" "$SANDBOX/target"
  # rclone remote "drive" is a local folder here; on an Instance it is Google Drive.
  printf '[drive]\ntype = local\n' > "$SANDBOX/state/rclone.conf"

  local src="$SANDBOX/source"
  mkdir -p "$src/radarr/MediaCover/1" "$src/radarr/logs" "$src/jellyfin/config/data/subtitles" \
    "$src/jellyfin/config/metadata" "$src/jellyfin/cache" "$src/.git"
  echo "<Config/>" > "$src/radarr/config.xml"
  echo poster > "$src/radarr/MediaCover/1/poster.jpg"
  echo log > "$src/radarr/logs/radarr.txt"
  echo srt > "$src/jellyfin/config/data/subtitles/a.srt"
  echo art > "$src/jellyfin/config/metadata/art.jpg"
  echo tmp > "$src/jellyfin/cache/x"
  echo git > "$src/.git/HEAD"
  echo keep > "$src/jellyfin/config/system.xml"
  sqlite3 "$src/jellyfin/config/data/jellyfin.db" "CREATE TABLE Users (Id INTEGER PRIMARY KEY); INSERT INTO Users VALUES (1),(2);"
  # Owned by an app user, as on an Instance; the container runs as root.
  docker run --rm --entrypoint chown -v "$src:/src" "$IMAGE" -R 1234:5678 /src/jellyfin
  sqlite3 "$src/radarr/radarr.db" "PRAGMA journal_mode=WAL;" "CREATE TABLE Movies (Id INTEGER PRIMARY KEY); INSERT INTO Movies VALUES (1);" >/dev/null
}
teardown() {
  # Restored files belong to root; remove them from inside a container.
  docker run --rm --entrypoint rm -v "$SANDBOX:/sandbox" "$IMAGE" -rf /sandbox/source /sandbox/state /sandbox/repo /sandbox/target
  rm -rf "$SANDBOX"
}

backup() {
  # shellcheck disable=SC2086 # EXTRA_DOCKER_ARGS holds several words on purpose
  OUTPUT="$(docker run --rm ${EXTRA_DOCKER_ARGS:-} \
    -e RESTIC_REPOSITORY=rclone:drive:/repo -e RESTIC_PASSWORD=test-password \
    -e BACKUP_EXCLUDE=".git" -e RCLONE_CONFIG=/config/rclone.conf -e RESTIC_CACHE_DIR=/config/cache \
    -v "$SANDBOX/source:/source" -v "$SANDBOX/state:/config" -v "$SANDBOX/repo:/repo" \
    -v "$SANDBOX/target:/target" "$IMAGE" "$@" 2>&1)"
  STATUS=$?
}

test_backup_and_restore_round_trip() {
  # A writer keeps radarr.db open with rows that exist only in its -wal file.
  { printf 'PRAGMA wal_autocheckpoint=0;\nINSERT INTO Movies VALUES (2),(3);\n'; sleep 60; } \
    | sqlite3 "$SANDBOX/source/radarr/radarr.db" >/dev/null &
  local writer=$!
  sleep 1
  backup run
  kill "$writer" 2>/dev/null; wait "$writer" 2>/dev/null
  assert_status 0

  backup restore /target
  assert_status 0
  assert_output_contains "radarr/radarr.db: 3 movies"
  assert_output_contains "jellyfin/config/data/jellyfin.db: 2 Jellyfin users"

  local t="$SANDBOX/target" path
  [ -f "$t/radarr/config.xml" ] || fail "config.xml not restored"
  [ -f "$t/jellyfin/config/system.xml" ] || fail "system.xml not restored"
  for path in radarr/MediaCover radarr/logs jellyfin/config/data/subtitles jellyfin/config/metadata jellyfin/cache .git; do
    [ ! -e "$t/$path" ] || fail "$path should have been excluded"
  done
  [ ! -e "$t/radarr/radarr.db-wal" ] || fail "a raw -wal file was restored"
  [ "$(sqlite3 "$t/radarr/radarr.db" 'PRAGMA integrity_check')" = ok ] || fail "restored radarr.db is corrupt"
  for path in jellyfin jellyfin/config jellyfin/config/data jellyfin/config/data/jellyfin.db; do
    assert_owner "$t/$path" "1234:5678"
  done
}

test_retention_forgets_and_prunes() {
  # Keeping one of each makes the second run of the day replace the first.
  EXTRA_DOCKER_ARGS="-e BACKUP_KEEP_DAILY=1 -e BACKUP_KEEP_WEEKLY=1 -e BACKUP_KEEP_MONTHLY=1"
  backup run && backup run
  assert_status 0
  backup restic snapshots --json
  [ "$(grep -o '"short_id"' <<< "$OUTPUT" | wc -l)" = 1 ] || fail "expected 1 snapshot after two runs today. Output:
$OUTPUT"
}

run_tests
