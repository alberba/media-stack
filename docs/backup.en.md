# Backup and restore

[Español](backup.md)

The `backup` Profile keeps an encrypted, off-site copy of your Instance's App data, so
that losing the machine loses nothing but the Media library, which the apps can
download again from what the App data remembers.

- **What**: everything under `BACKUP_SOURCE` (default: `APPDATA_ROOT`). Each SQLite
  database is copied with SQLite's online backup while the services keep running.
  Left out, because it can be regenerated: caches, artwork and metadata, Jellyfin's
  extracted subtitles, logs and the apps' own zip backups, plus whatever you add in
  `BACKUP_EXCLUDE`.
- **Where**: a [restic](https://restic.net) repository, encrypted with your password,
  on Google Drive (the free 15 GB are plenty) through [rclone](https://rclone.org).
- **When**: every night at 04:00 (`BACKUP_SCHEDULE`, in `TZ`). Keeps 7 daily, 4 weekly
  and 6 monthly snapshots and prunes the rest.
- **Alerts**: a Telegram message when a run fails, and the `backup` container turns
  unhealthy until the next run succeeds.

## What to keep in your password manager

Without the first two the backup cannot be read, and without the third you rebuild your
settings by hand. Keep them in 1Password (or your password manager), not on the machine
being backed up:

| Item | Where it lives on the Instance | What to store |
| --- | --- | --- |
| Restic password | `RESTIC_PASSWORD` in `.env` | The password itself |
| rclone config | `APPDATA_ROOT/backup/rclone.conf` | The whole file, as a document or attached file |
| `.env` | The Template clone (not in the backup) | The whole file: VPN keys, paths, Profiles, Telegram |

In 1Password, one item per Instance works well: a Password item named
"media-stack backup (<instance>)", the restic password in its password field, and
`rclone.conf` and `.env` attached. Update the attachments whenever you run
`rclone config` again or change `.env`.

## Setup

### 1. Turn the Profile on

In `.env`:

```sh
COMPOSE_PROFILES=backup          # or e.g. "vo,backup"
RESTIC_PASSWORD=...              # generate one: openssl rand -base64 32
TELEGRAM_BOT_TOKEN=...           # optional: reuse the bot you already have for alerts
TELEGRAM_CHAT_ID=...
```

Then run `sudo scripts/init.sh` again: it checks the password and creates
`APPDATA_ROOT/backup`.

### 2. Connect Google Drive

Google asks for a browser login once, so this is done in two places.

1. Build the image: `docker compose build backup`
2. Start rclone's setup inside it:
   `docker compose run --rm backup rclone config`
   - `n` (new remote), name it `gdrive` (it must match `RESTIC_REPOSITORY`)
   - Storage: `drive`
   - `client_id` / `client_secret`: leave empty to use rclone's, or
     [create your own](https://rclone.org/drive/#making-your-own-client-id) for better
     limits. With your own, set the Google app's publishing status to **In production**:
     in "Testing" Google revokes the token after 7 days and backups stop.
   - Scope: `drive.file` (rclone only sees the files it creates)
   - Leave the rest empty; `Use web browser to automatically authenticate?` → `n`
3. rclone prints a command like `rclone authorize "drive" "..."`. Run it on any
   computer with a browser and rclone installed, log in to Google, and paste the token
   it prints back into the prompt.
4. Finish with `n` (not a shared drive), `y`, `q`. The file is now in
   `APPDATA_ROOT/backup/rclone.conf`. **Save it and the password in 1Password now.**

### 3. Start it and run the first backup

```sh
docker compose up -d backup
docker compose exec backup media-backup run      # first run: creates the repository
docker compose exec backup restic snapshots      # the snapshot is there
```

The first run uploads everything; later runs only send what changed. The container
mounts the App data read-write, because SQLite needs its lock files to copy a database
in use (and restores write there), but a backup run writes nothing else to it.

### Backing up App data that is not in the Template layout yet

If your services still keep their data somewhere else (for example before moving an
existing Instance to the Template), point the Profile there. It only needs the folder
that holds every service's configuration and databases:

```sh
BACKUP_SOURCE=/path/to/your/old/stack
BACKUP_EXCLUDE=.git,some/big/folder     # anything else you do not need back
```

Only the `backup` service has to run: `docker compose up -d --build backup`. The Core
variables in `.env` still need values, because Compose reads the whole file.

## Checking it

- `docker compose ps backup`: `healthy` unless the last run failed. Telegram only hears
  about runs that fail; if the container is stopped nothing runs and nothing is sent, so
  let your monitoring watch its health too.
- `docker compose logs backup`: the output of every run.
- `docker compose exec backup restic snapshots`: every snapshot kept.
- `docker compose exec backup media-backup summary /source`: movies, series, indexers
  and Jellyfin users in your live App data. Note it down before a restore drill.

## Restore

Use this to recover a lost machine, and once in a while as a drill on a spare VM, so
you know it works before you need it.

1. On the new machine, install Docker, clone the Template and fill in `.env` with the
   **same** `RESTIC_PASSWORD`, `RESTIC_REPOSITORY` and `BACKUP_HOST`, plus
   `COMPOSE_PROFILES=backup` (add the rest of your Profiles too).
2. `sudo scripts/init.sh`
3. Put `rclone.conf` from 1Password in `APPDATA_ROOT/backup/rclone.conf`
   (`chmod 600` it).
4. See what is there:
   ```sh
   docker compose build backup
   docker compose run --rm backup restic snapshots
   ```
5. If you restore over App data that services were using (same machine), stop them
   first: `docker compose down`. Then restore the latest snapshot into the App data
   folder (or add a snapshot ID after
   `/source` to pick another):
   ```sh
   docker compose run --rm backup restore /source
   ```
   Files and databases come back with their original owners, and any `-wal`/`-shm`
   left next to a restored database is removed. The command ends with the
   summary of what it restored: compare it with the one you noted.
6. Start the Instance and check it:
   ```sh
   docker compose up -d
   scripts/verify.sh
   ```
   Then in the web UIs: Radarr and Sonarr list your library, Prowlarr's indexers pass
   **Test All**, and every Jellyfin user can log in.

The Media library is not in the backup: Radarr and Sonarr show the files as missing
until they are downloaded again (**Search All Missing**).

**If `PUID`/`PGID` changed** on the new machine, give the restored folders to the new
owner: `sudo chown -R PUID:PGID APPDATA_ROOT/<service>` (Seerr stays `1000:1000`).

**Restoring an old layout** (backed up with a custom `BACKUP_SOURCE`): restore into an
empty folder instead, then move each service's folder to `APPDATA_ROOT/<service>`:

```sh
mkdir /tmp/restore
docker compose run --rm -v /tmp/restore:/restore backup restore /restore
```
