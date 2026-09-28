# media-stack

A self-hosted media server (download automation, requests, playback) as a Docker
Compose Template you can deploy on any Linux machine with Docker.

## Core

Every Instance runs these services:

| Service | Role | Port | Behind the VPN |
| --- | --- | --- | --- |
| gluetun | VPN gateway (any provider gluetun supports) | — | — |
| qBittorrent | Torrent client | 8080 | yes |
| Prowlarr | Indexer manager | 9696 | yes |
| FlareSolverr | Cloudflare solver for Prowlarr (`http://localhost:8191`) | — | yes |
| Radarr | Movies | 7878 | yes |
| Sonarr | Series | 8989 | yes |
| Bazarr | Subtitles | 6767 | yes |
| Jellyfin | Media server | 8096 | no |
| Seerr | Request portal | 5055 | no |

## Profiles

Optional groups of services on top of the Core, turned on with `COMPOSE_PROFILES` in
`.env` (comma separated). Setup for each: [docs/profiles.md](docs/profiles.md).

| Profile | What it adds |
| --- | --- |
| `backup` | Nightly encrypted copy of the App data to Google Drive, with restore. See [docs/backup.md](docs/backup.md) ([español](docs/backup.es.md)). |
| `vo` | A second Radarr and Sonarr for an original-version library. |
| `jackett` | Jackett, as a Torznab bridge for indexers Prowlarr lacks. |
| `seeding` | qui (qBittorrent web UI) and cleanuparr (download cleanup). |
| `cleanup` | Maintainerr: removes library items by rules. |
| `dashboard` | Homarr (start page) and Dockge (compose UI). |
| `monitoring` | Beszel (metrics and alerts) and What's Up Docker (image updates). |
| `proxy` | Nginx Proxy Manager, to publish only Jellyfin and Seerr on the internet. |
| `remote` | Tailscale, with the LAN as an optional subnet route. |
| `extras` | issue-automator (acts on Seerr issues), mousehole, a Tor proxy and File Browser. |
| `transcode` | Tdarr server, for a Worker with a GPU to re-encode large files that are no longer seeding. See [docs/transcode.md](docs/transcode.md). |

Hardware transcoding with the host's GPU (`/dev/dri`) for Jellyfin and Tdarr is an
override, `compose.gpu.yaml`, turned on with `COMPOSE_FILE` in `.env`.

## Quickstart

Requirements: Linux, Docker Engine with Compose 2.20 or newer, `/dev/net/tun`, and a VPN
account.

```sh
git clone https://github.com/alberba/media-stack.git && cd media-stack
cp .env.example .env      # fill it in: paths, PUID/PGID, TZ, VPN provider
sudo scripts/init.sh      # checks the host and .env, creates folders and the network
docker compose up -d
scripts/verify.sh         # every service healthy, qBittorrent egress IP is the VPN's
```

`DATA_ROOT` holds both `torrents/` and `media/`, so Radarr and Sonarr import with
hardlinks instead of copies. In qBittorrent, set the default save path to
`/data/torrents`. App data lives under `APPDATA_ROOT`, outside this repo.

## Layout

```
compose.yaml            includes every stack
compose.gpu.yaml        optional override: host GPU for Jellyfin and Tdarr
stacks/<stack>/         one compose file per stack (Core or Profile)
worker/                 Tdarr node for a Linux Worker, and the Windows node's config
scripts/init.sh         host checks + folders + network
scripts/verify.sh       post-start health and VPN check
docs/                   guides (Profiles, backup and restore, transcoding)
.env.example            every setting, commented
```

## Contributing

Nothing specific to an Instance may be committed (see `docs/adr/0001`). The
`.gitignore` is a whitelist, and gitleaks scans every commit and every push.

```sh
git config core.hooksPath .githooks   # gitleaks pre-commit hook (gitleaks or Docker)
tests/template.test.sh && tests/init.test.sh && tests/verify.test.sh && tests/hooks.test.sh
tests/issue-automator.test.sh && tests/tdarr-plugin.test.sh   # need python3, and node or Docker
tests/backup.test.sh && tests/backup-image.test.sh   # needs sqlite3 and Docker
```

Image versions are pinned; [Renovate](https://github.com/apps/renovate) opens PRs to bump
them.

## License

MIT
