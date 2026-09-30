# Optional Jellyfin customizations

The theme and plugins the author's Instance uses. None of this is needed. Nothing is
written inside the Jellyfin image: everything lives in Jellyfin's App data, so it
survives image updates and is covered by the `backup` Profile.

## Automatic (the Wiring)

`scripts/setup.sh` asks two questions and writes them to `.env`:

| `.env` | What the Wiring does on the next `docker compose up` |
| --- | --- |
| `JELLYFIN_ABYSS=on` | Abyss theme, dark theme and home order for every user, Spotlight banner |
| `JELLYFIN_SEERR_REPORTER=on` | installs SeerrReporter and points it at Seerr |

It signs in with `JELLYFIN_ADMIN_USER`/`JELLYFIN_ADMIN_PASSWORD`, adds the plugin
repositories, installs what is missing and restarts Jellyfin once to load new plugins.
Reruns only add what is missing: a Viewer created later gets the theme on the next
`docker compose up wire`, and a Viewer who changed their home keeps it. Its log:
`docker compose logs wire`.

Turning an option `off` does not uninstall anything; remove it by hand as below.

## By hand

### Theme: Abyss

[Abyss](https://github.com/AumGupta/abyss-jellyfin) is a dark theme loaded as custom CSS.
The Wiring pins a release (`ABYSS_VERSION` in `stacks/wire/wire/extras.py`, bumped by
Renovate); use the same tag here instead of `main`.

1. Dashboard > General > **Custom CSS code**:

   ```css
   @import url('https://cdn.jsdelivr.net/gh/AumGupta/abyss-jellyfin@v1.2.3/abyss.css');
   ```

2. Settings > Display: **Theme** Dark. Settings > Home: Continue Watching, Next Up,
   My Media, Recently Added. These are per user.
3. Spotlight (home banner): copy `spotlight-loader.js`, `spotlight.html` and
   `spotlight.css` from the release's `scripts/spotlight/` into
   `APPDATA_ROOT/jellyfin/ui` (mounted as `jellyfin-web/ui`), install **JavaScript
   Injector** (below) and add a script that appends
   `<script src="ui/spotlight-loader.js" data-abyss-spotlight>` to the page.

Its variables and optional overrides (Lite, per-plugin) are listed in its README.

### Plugins

Dashboard > Plugins > Repositories > **+**, add:

| Name | URL |
| --- | --- |
| File Transformation | `https://www.iamparadox.dev/jellyfin/plugins/manifest.json` |
| JavaScript Injector | `https://raw.githubusercontent.com/n00bcodr/jellyfin-plugins/main/12/manifest.json` |
| SeerrReporter | `https://raw.githubusercontent.com/alberba/jellyfin-plugin-seerr-reporter/main/manifest.json` |

Then, in the Catalog, install:

- **File Transformation**: lets other plugins change the served web client without
  touching its files (the image's `jellyfin-web` is read-only for Jellyfin's user).
- **JavaScript Injector**: runs custom scripts in the web client; Spotlight's loader.
- **SeerrReporter** ([repo](https://github.com/alberba/jellyfin-plugin-seerr-reporter)):
  Viewers report a problem with an item from Jellyfin, and it becomes an issue in Seerr.
  In its settings, Seerr URL `http://seerr:5055` and Seerr's API key. With the `extras`
  Profile, the issue-automator then acts on it.

Restart Jellyfin (`docker compose restart jellyfin`) after installing plugins.
