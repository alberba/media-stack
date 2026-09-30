# Wiring the apps

[Español](wiring.md)

After the [install](install.en.md), the Core services run but don't know about each
other. Do this once, in this order. Replace `<host>` with the Instance's LAN IP.

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

Each *arr app's API key is in its Settings > General.

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

## 1. qBittorrent (`http://<host>:8080`)

1. The first login's temporary password is in `docker logs qbittorrent`. Change it in
   Options > WebUI.
2. Options > Downloads: **Default save path** `/data/torrents`.
3. Add two categories: `radarr` → `/data/torrents/movies` and `sonarr` → `/data/torrents/tv`.

## 2. Radarr (`:7878`) and Sonarr (`:8989`)

In each one:

1. Settings > General: **Authentication** `Forms`, with a user and password.
2. Settings > Media Management: **Root folder** `/data/media/movies` (Radarr) or
   `/data/media/tv` (Sonarr). Leave **Use Hardlinks instead of Copy** on.
3. Settings > Download Clients: add **qBittorrent**, host `localhost`, port `8080`, your
   qBittorrent login, category `radarr` or `sonarr`.

## 3. Prowlarr (`:9696`)

1. Settings > Indexers: add a **FlareSolverr** proxy at `http://localhost:8191` with a
   tag (e.g. `flaresolverr`). Put that tag only on indexers behind Cloudflare.
2. Settings > Apps: add **Radarr** and **Sonarr**. Prowlarr server `http://localhost:9696`,
   Radarr server `http://localhost:7878` (Sonarr `http://localhost:8989`), and each API key.
3. Add your indexers. Prowlarr syncs them to Radarr and Sonarr: don't add indexers
   there by hand.

## 4. Bazarr (`:6767`)

1. Settings > Languages: create a language profile, and set it as the default for
   movies and series.
2. Settings > Radarr and Settings > Sonarr: turn them on, address `localhost`, port
   `7878` / `8989`, and each API key.
3. Settings > Providers: add subtitle providers (e.g. OpenSubtitles.com).

## 5. Jellyfin (`:8096`)

1. Run the first-start wizard and create the admin user.
2. Add two libraries: **Movies** at `/data/media/movies` and **Shows** at `/data/media/tv`.

## 6. Seerr (`:5055`)

1. **Sign in with Jellyfin**: address `jellyfin`, port `8096`, and the Jellyfin admin.
   Pick the libraries to sync.
2. Settings > Services: add a **Radarr** server (`radarr`, `7878`, API key, root folder
   `/data/media/movies`, quality profile) and a **Sonarr** server (`sonarr`, `8989`,
   `/data/media/tv`). Mark both as default.
3. Settings > Users: import Jellyfin users, so Viewers log in with their Jellyfin account.

Test it: request a movie in Seerr. It should show up in Radarr, download in qBittorrent
under `/data/torrents/movies`, get imported into `/data/media/movies` and appear in Jellyfin.

For the Profiles' own wiring (VO managers, Jackett, cleanuparr…) see [profiles.md](profiles.md).
