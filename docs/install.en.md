# Install

[Español](install.md)

From an empty Linux machine to a running Instance, with the apps already wired to each other. Next: [what is left to you](wiring.en.md#what-is-left-to-you)
and read the [security checklist](security.en.md) before exposing anything.

## Requirements

- **Linux** (any distribution; a NAS with Docker works). Windows and macOS are not
  supported: gluetun needs `/dev/net/tun` and hardlinks need a Linux filesystem.
- **Docker Engine** with **Compose 2.20** or newer (`docker compose version`).
- **Python 3.7** or newer on the host (`python3 --version`), with no additional packages.
- `/dev/net/tun` on the host (`ls -l /dev/net/tun`).
- A **VPN account** with a provider [gluetun supports](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers),
  and its WireGuard key or OpenVPN credentials.
- One filesystem with room for downloads and the library (`DATA_ROOT`), and a folder
  for the App data (`APPDATA_ROOT`), outside the clone.

## Steps

```sh
git clone https://github.com/alberba/media-stack.git && cd media-stack
scripts/setup.sh          # asks questions, writes .env, offers to run init.sh
docker compose up -d
scripts/verify.sh         # every service healthy, qBittorrent egress IP is the VPN's
```

1. **`scripts/setup.sh`** asks for the paths, `PUID`/`PGID` (`id -u`, `id -g`), time zone,
   VPN provider and credentials, which Profiles to turn on, the Jellyfin admin and the
   qualities to download, and generates the apps' API keys. It writes `.env` and
   offers to run `sudo scripts/init.sh`, which checks the host, creates the folders
   under `DATA_ROOT` and `APPDATA_ROOT` and the Docker network. Run it again at any time:
   it offers the current values as defaults and keeps what it does not ask about.
2. **`docker compose up -d`** starts the Core and the Profiles in `COMPOSE_PROFILES`, and
   the `wire` container [wires the apps](wiring.en.md) to each other.
3. **`scripts/verify.sh`** checks, a minute or two after starting, that every Core service and active `vo` service is healthy, that `wire-seed` and `wire` completed successfully, and that
   qBittorrent's public IP is the VPN's, not yours.

Without the wizard: copy `.env.example` to `.env`, fill it in, and run `sudo scripts/init.sh`.

Hardware transcoding with the host's GPU: set `COMPOSE_FILE=compose.yaml:compose.gpu.yaml`
and `RENDER_GID` in `.env` (see `.env.example`).

## Troubleshooting

| Symptom | Check |
| --- | --- |
| gluetun unhealthy, the apps behind it don't start | `docker logs gluetun`: wrong key/credentials, or `WIREGUARD_ADDRESSES` missing for your provider. |
| `verify.sh` says the egress IP is yours | Don't use the Instance; check gluetun's logs. The apps behind the VPN have no network without it. |
| Permission denied writing to `/data` | `PUID`/`PGID` must own `DATA_ROOT` and `APPDATA_ROOT` (`sudo chown -R`). |
| Imports are copies, not hardlinks | `DATA_ROOT` must be one filesystem; see [wiring](wiring.en.md#data-and-hardlinks). |
| An app behind the VPN can't reach the LAN | Set `VPN_OUTBOUND_SUBNETS` to your LAN subnet. |

## Updating

`git pull && docker compose pull && docker compose up -d`. Image versions are pinned in
the Template and bumped by Renovate.
