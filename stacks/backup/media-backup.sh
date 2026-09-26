#!/usr/bin/env bash
# Backup Profile: copies every SQLite database consistently while the services run,
# then sends the App data to an encrypted restic repository (Google Drive via rclone).
# Runs inside the backup container; see docs/backup.md.
#
# Usage:
#   media-backup schedule           run `media-backup run` on BACKUP_SCHEDULE (the default)
#   media-backup run                one backup now: databases, restic backup, retention
#   media-backup restore DIR [ID]   restore snapshot ID (default: the latest) into DIR
#   media-backup summary DIR        movies, series, indexers and Jellyfin users found in DIR
#   anything else                   run as is, e.g. `restic snapshots` or `rclone config`
set -uo pipefail

SOURCE_DIR="${SOURCE_DIR:-/source}"      # the App data, as mounted
DB_DIR="${DB_DIR:-/databases}"           # consistent copies of its databases, same layout
STATE_DIR="${STATE_DIR:-/config}"        # rclone.conf, restic cache, last status
CRONTAB_FILE="${CRONTAB_FILE:-/tmp/crontab}"
BACKUP_HOST="${BACKUP_HOST:-media-stack}"
BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-0 4 * * *}"

# Never backed up because it can be regenerated: caches, artwork and metadata, extracted
# subtitles, logs and the apps' own zip backups. A pattern without "/" matches a file or
# folder name anywhere; one with "/" matches a path under the source.
DEFAULT_EXCLUDES=(cache Cache transcodes metadata MediaCover data/subtitles logs '*.log' '*.log.[0-9]*' 'logs.db*' Backups)
DB_NAMES=('*.db' '*.db3' '*.sqlite' '*.sqlite3')

errors=()
# --exclude flags for the exact paths of the raw databases copied (and the state folder).
# Flags, not an --exclude-file: restic expands $VARs and skips "#" lines in those.
path_excludes=()
add_error() { errors+=("$1"); log "error: $1"; }
log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }
die() { log "error: $*"; exit 1; }

excludes() {
  local extra pattern
  printf '%s\n' "${DEFAULT_EXCLUDES[@]}"
  IFS=',' read -r -a extra <<< "${BACKUP_EXCLUDE:-}"
  for pattern in "${extra[@]}"; do
    pattern="${pattern#"${pattern%%[![:space:]]*}"}"
    pattern="${pattern%"${pattern##*[![:space:]]}"}"
    [ -n "$pattern" ] && printf '%s\n' "$pattern"
  done
}

# Excludes one exact path, escaping glob characters so restic matches it literally.
exclude_path() {
  local path="${1//\\/\\\\}"
  path="${path//\*/\\*}" path="${path//\?/\\?}" path="${path//\[/\\[}" path="${path//\]/\\]}"
  path_excludes+=(--exclude "$path")
}

# Prints "state<TAB>path" for the state folder when it lives inside the source, and
# "db<TAB>path" for every candidate database outside the excluded folders.
scan_source() {
  local pattern name
  local -a prune=() dbs=()
  while IFS= read -r pattern; do
    [ "${#prune[@]}" -gt 0 ] && prune+=(-o)
    if [[ "$pattern" == */* ]]; then
      prune+=(-path "$SOURCE_DIR/$pattern" -o -path "$SOURCE_DIR/*/$pattern")
    else
      prune+=(-name "$pattern")
    fi
  done < <(excludes)
  for name in "${DB_NAMES[@]}"; do
    [ "${#dbs[@]}" -gt 0 ] && dbs+=(-o)
    dbs+=(-name "$name")
  done
  find "$SOURCE_DIR" \( -samefile "$(realpath "$STATE_DIR")" -printf 'state\t%p\n' -prune \) \
    -o \( "${prune[@]}" \) -prune \
    -o -type f \( "${dbs[@]}" \) -printf 'db\t%p\n'
}

# Gives DST the owner and mode of SRC, so a restore hands every file back to its app.
same_owner_and_mode() { chown --reference="$1" "$2" && chmod --reference="$1" "$2"; }

# Creates DB_DIR/REL's parent folders, each one mirroring its counterpart in the source.
make_parents() {
  local rel="$1" dir="" part
  local -a parts
  IFS=/ read -r -a parts <<< "$(dirname "$rel")"
  for part in "${parts[@]}"; do
    [ "$part" = . ] && continue
    dir="${dir:+$dir/}$part"
    [ -d "$DB_DIR/$dir" ] && continue
    mkdir "$DB_DIR/$dir"
    same_owner_and_mode "$SOURCE_DIR/$dir" "$DB_DIR/$dir"
  done
}

is_sqlite() { [ "$(head -c 15 -- "$1" 2>/dev/null)" = "SQLite format 3" ]; }

# SQLite online backup of every database into DB_DIR. The raw files it copied (and their
# -wal/-shm/-journal) are excluded; a database that cannot be copied keeps its raw file in
# the backup and fails the run.
copy_databases() {
  local kind path rel suffix copied=0
  rm -rf "$DB_DIR" && mkdir -p "$DB_DIR"
  same_owner_and_mode "$SOURCE_DIR" "$DB_DIR"
  while IFS=$'\t' read -r kind path; do
    if [ "$kind" = state ]; then
      exclude_path "$path"
      continue
    fi
    is_sqlite "$path" || continue
    rel="${path#"$SOURCE_DIR"/}"
    make_parents "$rel"
    # Written to a fixed name first: the .backup argument cannot hold arbitrary quotes.
    if sqlite3 -bail -cmd ".timeout 60000" "$path" ".backup '$DB_DIR/.copy'" \
        && [ "$(sqlite3 "$DB_DIR/.copy" 'PRAGMA quick_check' 2>/dev/null)" = ok ]; then
      mv "$DB_DIR/.copy" "$DB_DIR/$rel"
      same_owner_and_mode "$path" "$DB_DIR/$rel"
      for suffix in "" -wal -shm -journal; do exclude_path "$path$suffix"; done
      copied=$((copied + 1))
    else
      rm -f "$DB_DIR/.copy"
      add_error "could not copy $rel consistently; its raw file is backed up instead"
    fi
  done < <(scan_source)
  log "$copied databases copied"
}

ensure_repository() {
  local status
  restic cat config >/dev/null 2>&1
  status=$?
  case "$status" in
    0) return 0 ;;
    10)
      log "No repository at $RESTIC_REPOSITORY yet, creating it"
      restic init || { add_error "restic init failed"; return 1; } ;;
    *) add_error "cannot open the repository $RESTIC_REPOSITORY (restic exit $status)"; return 1 ;;
  esac
}

alert() {
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    log "Telegram is not configured, no alert sent"
    return
  fi
  curl -fsS --max-time 20 -o /dev/null \
    --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=$1" \
    "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    || log "could not send the Telegram alert"
}

finish() {
  if [ "${#errors[@]}" -eq 0 ]; then
    echo "ok $(date -Iseconds)" > "$STATE_DIR/last-status"
    log "Backup finished"
    return 0
  fi
  echo "failed $(date -Iseconds)" > "$STATE_DIR/last-status"
  alert "$(printf 'Backup of %s FAILED:\n' "$BACKUP_HOST"; printf -- '- %s\n' "${errors[@]}")"
  return 1
}

cmd_run() {
  local pattern status
  local -a flags=()
  mkdir -p "$STATE_DIR"
  # One run at a time: a manual run and the scheduled one would share DB_DIR.
  exec 9> "$STATE_DIR/run.lock"
  flock -n 9 || die "another backup is already running"
  log "Backup of $SOURCE_DIR to $RESTIC_REPOSITORY started"
  if [ -z "${RESTIC_REPOSITORY:-}" ] || [ -z "${RESTIC_PASSWORD:-}" ]; then
    add_error "RESTIC_REPOSITORY and RESTIC_PASSWORD must be set in .env"
    finish; return
  fi
  ensure_repository || { finish; return; }
  copy_databases

  while IFS= read -r pattern; do
    if [[ "$pattern" == */* ]]; then
      flags+=(--exclude "$SOURCE_DIR/$pattern" --exclude "$SOURCE_DIR/**/$pattern")
    else
      flags+=(--exclude "$pattern")
    fi
  done < <(excludes)
  restic backup --host "$BACKUP_HOST" --exclude-caches "${path_excludes[@]}" "${flags[@]}" \
    "$SOURCE_DIR" "$DB_DIR"
  status=$?
  rm -rf "$DB_DIR"
  if [ "$status" -ne 0 ]; then
    add_error "restic backup failed (exit $status)"
  else
    restic forget --host "$BACKUP_HOST" --prune \
      --keep-daily "${BACKUP_KEEP_DAILY:-7}" --keep-weekly "${BACKUP_KEEP_WEEKLY:-4}" \
      --keep-monthly "${BACKUP_KEEP_MONTHLY:-6}" \
      || add_error "restic forget/prune failed (exit $?)"
  fi
  finish
}

cmd_schedule() {
  printf '%s media-backup run\n' "$BACKUP_SCHEDULE" > "$CRONTAB_FILE"
  supercronic -test "$CRONTAB_FILE" >/dev/null || die "BACKUP_SCHEDULE '$BACKUP_SCHEDULE' is not a valid cron expression"
  log "Backups run on '$BACKUP_SCHEDULE' (${TZ:-UTC})"
  exec supercronic "$CRONTAB_FILE"
}

cmd_restore() {
  local target="${1:-}" snapshot="${2:-}"
  [ -d "$target" ] || die "usage: media-backup restore DIR [SNAPSHOT], DIR must exist"
  if [ -z "$snapshot" ]; then
    snapshot="$(restic snapshots --host "$BACKUP_HOST" --latest 1 --json \
      | grep -o '"short_id":"[0-9a-f]*"' | tail -n1 | cut -d'"' -f4)"
    [ -n "$snapshot" ] || die "no snapshots of host $BACKUP_HOST in $RESTIC_REPOSITORY"
  fi
  log "Restoring snapshot $snapshot into $target"
  restic restore "$snapshot:$SOURCE_DIR" --target "$target" || die "restoring the files failed"
  # Then the consistent database copies, moved over the files at the same paths. A -wal or
  # -shm left there by the old database would not match the restored one, so it goes.
  local staging="$target/.media-backup-databases" db
  rm -rf "$staging"
  restic restore "$snapshot:$DB_DIR" --target "$staging" || die "restoring the databases failed"
  while IFS= read -r db; do
    rm -f "$target/$db-wal" "$target/$db-shm" "$target/$db-journal"
    mkdir -p "$target/$(dirname "$db")"
    mv -f "$staging/$db" "$target/$db"
  done < <(cd "$staging" && find . -type f | sed 's|^\./||')
  rm -rf "$staging"
  log "Restored. What the restored App data holds:"
  cmd_summary "$target"
}

cmd_summary() {
  local dir="${1:-}" db table label count uri
  [ -d "$dir" ] || die "usage: media-backup summary DIR"
  while IFS= read -r db; do
    case "$(basename "$db")" in
      radarr.db) table=Movies label=movies ;;
      sonarr.db) table=Series label=series ;;
      prowlarr.db) table=Indexers label=indexers ;;
      jellyfin.db) table=Users label="Jellyfin users" ;;
    esac
    # A restored copy is opened immutable, so SQLite leaves no root-owned -wal/-shm behind
    # for the app to trip over. A live database (it has a -wal) is read normally.
    uri="file:$db?immutable=1"
    [ -e "$db-wal" ] && uri="file:$db?mode=ro"
    count="$(sqlite3 "$uri" "SELECT COUNT(*) FROM $table" 2>/dev/null)" || count="unreadable"
    echo "${db#"$dir"/}: $count $label"
  done < <(find "$dir" -type f \( -name radarr.db -o -name sonarr.db -o -name prowlarr.db -o -name jellyfin.db \) | sort)
}

case "${1:-schedule}" in
  schedule) cmd_schedule ;;
  run) cmd_run ;;
  restore) shift; cmd_restore "$@" ;;
  summary) shift; cmd_summary "$@" ;;
  *) exec "$@" ;;
esac
