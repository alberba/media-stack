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

Optional Profiles on top of the Core are turned on with `COMPOSE_PROFILES` in `.env`.

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
stacks/<stack>/         one compose file per stack
scripts/init.sh         host checks + folders + network
scripts/verify.sh       post-start health and VPN check
.env.example            every setting, commented
```

## Contributing

Nothing specific to an Instance may be committed (see `docs/adr/0001`). The
`.gitignore` is a whitelist, and gitleaks scans every commit and every push.

```sh
git config core.hooksPath .githooks   # gitleaks pre-commit hook (gitleaks or Docker)
tests/template.test.sh && tests/init.test.sh && tests/verify.test.sh && tests/hooks.test.sh
```

Image versions are pinned; [Renovate](https://github.com/apps/renovate) opens PRs to bump
them.

## License

MIT
