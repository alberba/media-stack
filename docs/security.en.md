# Security checklist

[Español](security.md)

What to expose, and how. An Instance has two kinds of apps:

- **For Viewers**: Jellyfin and Seerr. They have their own user accounts and are built
  to face the internet.
- **For the Operator**: everything else (Radarr, Sonarr, Bazarr, Prowlarr, qBittorrent,
  Homarr, Dockge, NPM's admin UI…). They control the Instance and hold your indexer
  and VPN secrets.

## Ways in

| Way | For | What it takes |
| --- | --- | --- |
| LAN only | everything | nothing: the default |
| Tailscale (`remote` Profile) | the Operator, from anywhere | the [remote](profiles.md#remote) Profile; no ports opened |
| Internet, through NPM (`proxy` Profile) | Viewers; optionally some Operator apps | ports 80/443, a domain, the steps below |

**Tailscale is the safest way to reach the Operator apps** from outside: nothing is open
to the internet. Publish Operator apps through NPM only if you need them without Tailscale.

## Checklist

- [ ] The router forwards **only 80 and 443**, to the Instance. Never 81 (NPM admin),
      never an app's own port.
- [ ] Every proxy host in NPM has a Let's Encrypt certificate and **Force SSL**.
- [ ] NPM's default login is changed.
- [ ] Jellyfin and Seerr: strong admin passwords; Viewers get their own non-admin users.
- [ ] Every Operator app has its **own login on**: Radarr/Sonarr/Prowlarr
      (Settings > General > Authentication `Forms`), Bazarr (Settings > General >
      Security), qBittorrent (WebUI password), Homarr (a user, and boards not public).
- [ ] Any Operator app published through NPM also has an **Access List** (below).
- [ ] Dockge, File Browser, NPM's admin UI, Beszel and What's Up Docker are **never**
      published: they reach the Docker socket or the whole disk.
- [ ] `scripts/verify.sh` passes: qBittorrent's public IP is the VPN's. If gluetun
      drops, the apps behind it lose their network instead of leaking your IP.
- [ ] `.env` and `APPDATA_ROOT` are only readable by you; `.env` is never committed.

## Publishing Viewer apps

In NPM (`http://<host>:81`), one proxy host each:

- `watch.example.com` → `http` `jellyfin` `8096`, **Websockets support** on.
- `request.example.com` → `http` `seerr` `5055`.

In Jellyfin, Dashboard > Networking: add `npm` as a known proxy.

## Publishing Operator apps (Radarr, Sonarr, Bazarr, Homarr)

These apps sit behind the VPN (except Homarr), so NPM forwards to their name and port:

| App | Forward to |
| --- | --- |
| Radarr | `http` `radarr` `7878` |
| Sonarr | `http` `sonarr` `8989` |
| Bazarr | `http` `bazarr` `6767` |
| Homarr | `http` `homarr` `7575`, **Websockets support** on |

Use two layers:

1. **The app's own login** (required). Without it, anyone with the URL controls the app.
2. **An NPM Access List** (recommended). In NPM > Access Lists, create one with a user
   and password (Authorization) and, if your IP is stable, an Allow rule for it. Attach
   it to each of these proxy hosts.

Why the Access List: the *arr login pages have no rate limit or 2FA, these apps have had
authentication bypasses before, and bots scan for them. With the Access List, a request
stops at NPM before it reaches the app. The cost: you log in twice, and mobile apps
(nzb360, LunaSea…) need the Basic Auth user set as well as the API key. Without it, keep
every app updated and use long, unique passwords.
