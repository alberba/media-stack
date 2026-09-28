# Profiles

A Profile is an optional group of services on top of the Core. Turn Profiles on by
listing them in `COMPOSE_PROFILES` in `.env`, fill in the variables of their section of
`.env`, then:

```sh
sudo scripts/init.sh    # checks what the Profiles need, creates their App data folders
docker compose up -d
```

Turning a Profile off again (removing it from `COMPOSE_PROFILES`) leaves its App data in
place. Stop its containers with `docker compose --profile <name> down <service>...` or
`docker compose up -d --remove-orphans`.

| Profile | Services | Ports | Guide |
| --- | --- | --- | --- |
| `backup` | backup | — | [backup.md](backup.md) |
| `vo` | radarr-vo, sonarr-vo (behind the VPN) | 7879, 8990 | [below](#vo) |
| `jackett` | jackett (behind the VPN) | 9117 | [below](#jackett) |
| `seeding` | qui, cleanuparr | 7476, 11011 | [below](#seeding) |
| `cleanup` | maintainerr | 6246 | [below](#cleanup) |
| `dashboard` | homarr, dockge | 7575, 5001 | [below](#dashboard) |
| `monitoring` | beszel, beszel-agent, wud | 8090, 3000 | [below](#monitoring) |
| `proxy` | npm (Nginx Proxy Manager) | 80, 443, 81 | [below](#proxy) |
| `remote` | tailscale | — | [below](#remote) |
| `extras` | issue-automator, mousehole (behind the VPN), tor, filebrowser | 5056, 5010, 8085 | [below](#extras) |
| `transcode` | tdarr (server only) | 8265, 8266 | [transcode.md](transcode.md) |

Services behind the VPN share gluetun's network: gluetun publishes their ports, other
containers reach them by name (`http://radarr-vo:7879`), and they reach each other, and
Prowlarr, at `http://localhost:<port>`.

## vo

A second Radarr and Sonarr for an original-version library, next to the Core ones. They
use the same `DATA_ROOT`, so imports are still hardlinks.

1. In each, add a root folder of its own: `/data/media/movies-vo` and `/data/media/tv-vo`.
2. In qBittorrent, give them their own categories (e.g. `radarr-vo`, `tv-vo`) so each
   manager only imports its own downloads.
3. In Prowlarr > Settings > Apps, add them at `http://localhost:7879` and
   `http://localhost:8990`. In Bazarr, add them as extra Radarr/Sonarr servers.
4. In Seerr > Settings > Services, add them as a second Radarr and Sonarr server.

## jackett

Jackett is only a Torznab bridge for indexers Prowlarr has no definition for; Prowlarr
stays the one place Radarr and Sonarr get indexers from.

1. Open Jackett at `http://<host>:9117`, set an admin password, and set FlareSolverr to
   `http://localhost:8191` (Jackett shares the VPN's network with it).
2. Add the indexer in Jackett and copy its **Torznab feed** URL and Jackett's API key.
3. In Prowlarr, add an indexer of type **Generic Torznab** with that URL, replacing the
   host with `localhost:9117`, and the API key.

The indexers, their logins and cookies live in `APPDATA_ROOT/jackett` (covered by the
`backup` Profile), never in this repo.

## seeding

- **qui** (`http://<host>:7476`): a faster web UI for qBittorrent. Add qBittorrent at
  `http://qbittorrent:8080`.
- **cleanuparr** (`http://<host>:11011`): removes stalled, slow or unwanted downloads
  and can clean up torrents whose files no longer have a hardlink in the library. Add
  qBittorrent at `http://qbittorrent:8080` and Radarr/Sonarr at `http://radarr:7878` and
  `http://sonarr:8989`. It sees downloads at `/data/torrents`, the same path as
  qBittorrent.

## cleanup

Maintainerr (`http://<host>:6246`) deletes library items by rules you write (e.g. watched
by everyone and older than a year). Connect Jellyfin (`http://jellyfin:8096`), Seerr
(`http://seerr:5055`), Radarr and Sonarr by name.

## dashboard

- **Homarr** (`http://<host>:7575`): a start page. Set `HOMARR_SECRET_KEY` first
  (`openssl rand -hex 32`) and keep it in your password manager: Homarr encrypts its
  integrations with it.
- **Dockge** (`http://<host>:5001`): a web UI for compose stacks. `DOCKGE_STACKS_DIR` is
  the folder it manages; point it at the folder that holds this clone to see the
  Instance as a stack. Edits made in Dockge to the Template's files show up in `git status`.

Only Dockge mounts the Docker socket read-write, because it starts and stops stacks.
Homarr, Beszel and What's Up Docker mount it read-only. Note that `:ro` only protects
the socket file: whoever can reach the socket can still call the whole Docker API. Keep
these UIs off the internet (see [proxy](#proxy)).

## monitoring

- **Beszel** (`http://<host>:8090`): host and container metrics, with alerts.
  1. Start the Profile, open Beszel and create the admin account.
  2. **Add system**: any name, and `/beszel_socket/beszel.sock` as host. Copy the public
     key and the token it shows into `BESZEL_AGENT_KEY` and `BESZEL_AGENT_TOKEN`.
  3. `docker compose up -d beszel-agent`. The agent keeps restarting until then.
- **What's Up Docker** (`http://<host>:3000`): lists containers with a newer image, and
  sends a Telegram message when it finds one (with `TELEGRAM_BOT_TOKEN` and
  `TELEGRAM_CHAT_ID`). Log in with `WUD_ADMIN_USER` and `WUD_ADMIN_PASSWORD`; it checks at
  `WUD_CRON`. The Template's own images are bumped by Renovate; this one shows what your
  Instance actually runs.

## proxy

Nginx Proxy Manager is the Instance's HTTPS entry point from the internet. **Publish only
Jellyfin and Seerr**: they are made for Viewers, have their own logins and are built to
face the internet. Everything else (the *arr apps, qBittorrent, the dashboards, NPM's
own admin UI) is for the Operator and stays on the LAN or behind the `remote` Profile.

1. Forward ports 80 and 443 (never 81) from your router to the Instance, and point two
   DNS names at your public IP, e.g. `watch.example.com` and `request.example.com`.
2. Open the admin UI at `http://<host>:81` and change the default login.
3. Add two proxy hosts, each with a Let's Encrypt certificate and **Force SSL**:
   - `watch.example.com` → `http` `jellyfin` `8096`, with **Websockets support** on.
   - `request.example.com` → `http` `seerr` `5055`.
4. In Jellyfin, Dashboard > Networking: add the proxy as a known proxy (`npm`), so it
   sees Viewers' real IPs.

## remote

Tailscale lets you reach the Instance from your own devices without opening ports. With
`TAILSCALE_ROUTES` it is also a subnet router for the rest of your LAN.

1. Create an auth key at https://login.tailscale.com/admin/settings/keys and set
   `TAILSCALE_AUTHKEY`. Set `TAILSCALE_HOSTNAME` to the name you want in the tailnet.
2. Optional: set `TAILSCALE_ROUTES` to your LAN subnet (check it with `ip route`; e.g.
   `192.168.1.0/24`), turn on forwarding on the host
   (`echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-tailscale.conf && sudo sysctl --system`)
   and approve the route in the admin console.

The node's state (its identity and login) lives in `APPDATA_ROOT/tailscale`, so it
survives restarts and reinstalls, and a restored backup brings back the same node.

**Moving an existing node here** (keeps its name and tailnet IP):

```sh
docker stop <old-tailscale-container>      # the same node must never run twice
sudo mkdir -p "$APPDATA_ROOT/tailscale"
sudo cp -a <old-state-folder>/. "$APPDATA_ROOT/tailscale/"   # holds tailscaled.state
```

Keep the old `TAILSCALE_HOSTNAME`. With the state in place, `scripts/init.sh` does not
ask for an auth key. If `TAILSCALE_ROUTES` differs from what the old node advertised
(check that it is the subnet your LAN really uses), approve the new route in the admin
console and remove the old one.

## extras

Small services the author's Instance uses, turned on together.

- **issue-automator** (port 5056): when a Viewer reports an issue in Seerr, it
  blocklists the release in Radarr/Sonarr and searches for another (video and audio
  issues), asks Bazarr for subtitles (subtitle issues), comments on the issue and sends a
  Telegram message. Its messages are in Spanish.
  1. Set `SEERR_API_KEY`, `RADARR_API_KEY` and `SONARR_API_KEY` (each app's Settings >
     General), and optionally `BAZARR_API_KEY` and the Telegram variables.
  2. With the `vo` Profile, also set `RADARR_VO_API_KEY`/`SONARR_VO_API_KEY`, and
     `SEERR_RADARR_VO_SERVER_ID`/`SEERR_SONARR_VO_SERVER_ID` to the id Seerr gives the VO
     servers (the first server in Seerr > Settings > Services is 0, the next 1).
  3. In Seerr > Settings > Notifications > Webhook: URL
     `http://issue-automator:5056/webhook`, notification type **Issue Reported**, and
     the default JSON payload.

  It checks its settings when it starts and stops with a message naming what is missing.
- **mousehole** (`http://<host>:5010`): keeps MyAnonamouse's record of your seedbox IP
  up to date. It runs behind the VPN, so the IP it reports is the VPN's. Set
  `MOUSEHOLE_AUTH_PASSWORD`, and `MOUSEHOLE_ALLOWED_HOSTS` to the address you open it at
  (e.g. `192.168.1.10:5010` or your Tailscale IP with the port).
- **tor**: a SOCKS5 proxy through Tor, for indexers only reachable that way. In
  Prowlarr > Settings > Indexers, add a **Socks5** proxy at host `tor`, port `9150`,
  with a tag, and put that tag on those indexers only.
- **File Browser** (`http://<host>:8085`): a web file manager for all of `DATA_ROOT`. On
  first start it prints the admin password in its log (`docker logs filebrowser`). Files
  it creates belong to `PUID:PGID`, like the rest of the library.
