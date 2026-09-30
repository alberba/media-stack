# Wiring the apps

[Español](wiring.md)

The connections between the apps are made by **the `wire` container** (the Wiring) on
every `docker compose up`: it starts, connects whatever is missing and exits. **It only
adds what does not exist and never changes what you configured**
([ADR-0002](adr/0002-wiring-only-seeds.md)), so you can change any setting in the web UIs
and it will not undo it.

See what it did with `docker compose logs wire`; `scripts/verify.sh` tells you if it failed.

## What it does on its own

Before the apps start, `wire-seed` writes into their App data (only if not there yet) the
API keys and passwords `scripts/setup.sh` generated into `.env`. Nobody copies an API key.
Then `wire`:

| App | What it connects |
| --- | --- |
| Jellyfin | Finishes the startup wizard: admin `JELLYFIN_ADMIN_USER`, libraries **Películas** (`/data/media/movies`) and **Series** (`/data/media/tv`). |
| Radarr, Sonarr | Root folder, and qBittorrent as download client with category `movies` / `tv`. |
| Prowlarr | Radarr and Sonarr as apps (indexer sync), and FlareSolverr as proxy with the tag `flaresolverr`. |
| Quality | A **Media Stack** profile in Radarr and Sonarr with the qualities picked in `setup.sh` (`QUALITIES`) and the [TRaSH Guides](https://trash-guides.info) custom formats, through [Recyclarr](https://recyclarr.dev). It prefers Spanish audio. |
| Seerr | Signs in with the Jellyfin admin, enables its libraries and adds Radarr and Sonarr (Media Stack profile) as default servers. |
| Bazarr | Connected to Radarr and Sonarr. |
| qBittorrent | Login `QBITTORRENT_USER` / `QBITTORRENT_PASSWORD`, downloads in `/data/torrents`. |

With the `vo` Profile the VO managers are wired the same way, with their own folders
(`/data/media/movies-vo`, `/data/media/tv-vo`) and categories, in the same Jellyfin
libraries, and in Seerr as a second, non-default server. Their quality profile prefers
the original language.

The **Media Stack** profile belongs to the Template: its qualities, their order and the
cutoff are only written when it is created, so change them in Radarr/Sonarr as you like.
Each start only refreshes the custom formats and their scores. Your other profiles are
never touched.

## What is left to you

1. **Radarr, Sonarr, Prowlarr, Bazarr**: the first time you open them they ask you to
   create a login (Settings > General > Authentication `Forms`).
2. **Prowlarr**: add your indexers; they sync to Radarr and Sonarr on their own. Tag the
   ones behind Cloudflare with `flaresolverr`.
3. **Bazarr**: Settings > Languages (a default language profile) and Settings >
   Providers (e.g. OpenSubtitles.com).
4. **Seerr**: Settings > Users > import the Jellyfin users, so Viewers sign in with
   their own account.

Try it: request a film in Seerr. It should show up in Radarr, download in qBittorrent to
`/data/torrents/movies`, import to `/data/media/movies` and appear in Jellyfin.

An app that was configured before `wire` (for example, when moving an existing Instance)
is left as it is: `wire` reads its API key from its App data and only adds what it lacks.
If a credential is missing (`QBITTORRENT_PASSWORD`, `JELLYFIN_ADMIN_*`), its log says so
with `WARN` and that step is skipped.

## How the services reach each other

qBittorrent, Prowlarr, FlareSolverr, Radarr, Sonarr and Bazarr run **behind the VPN**:
they share gluetun's network, so **between them** the address is always
`localhost:<port>`. Jellyfin and Seerr are outside the VPN and reach the others **by
name** on the media network (`http://radarr:7878`, `http://jellyfin:8096`).

| From | To | Address |
| --- | --- | --- |
| Radarr, Sonarr | qBittorrent | `localhost` `8080` |
| Prowlarr | Radarr, Sonarr | `http://localhost:7878`, `http://localhost:8989` |
| Prowlarr | FlareSolverr | `http://localhost:8191` |
| Bazarr | Radarr, Sonarr | `localhost` `7878`, `localhost` `8989` |
| Seerr | Jellyfin | `jellyfin` `8096` |
| Seerr | Radarr, Sonarr | `radarr` `7878`, `sonarr` `8989` |

## `/data` and hardlinks

Every container sees the same `DATA_ROOT` at `/data`:

```
/data
├── torrents/          qBittorrent downloads and seeds from here
│   ├── movies/
│   └── tv/
└── media/             the Media library Jellyfin serves
    ├── movies/
    └── tv/
```

Because `torrents/` and `media/` are on one filesystem, Radarr and Sonarr **import with a
hardlink**: the file appears in the library without a copy, takes no extra space, and
keeps seeding. Always use these `/data/...` paths inside the apps, never other mounts.
To check an import: `stat -c %h <file>` in `DATA_ROOT/media` prints `2` or more.

Wiring for the other Profiles (Jackett, cleanuparr…) is in [profiles.md](profiles.md).
