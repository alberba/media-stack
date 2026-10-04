# Optional Jellyfin customizations

The theme and plugins the author's Instance uses. None of this is needed. Nothing is
written inside the Jellyfin image: everything lives in Jellyfin's App data, so it
survives image updates and is covered by the `backup` Profile.

For SyncPlay on Android with an integrated or external player preference, see the
optional [web player compatibility image](syncplay.md). It selects the web player
automatically while joining a group and retains the normal playback preference.

## Automatic (the Wiring)

`scripts/setup.sh` asks whether to enable Abyss and writes the choice to `.env`:

| `.env` | What the Wiring does on the next `docker compose up` |
| --- | --- |
| `JELLYFIN_ABYSS=on` | Abyss theme, dark theme and home order for every user, Spotlight banner |

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

Then, in the Catalog, install:

- **File Transformation**: lets other plugins change the served web client without
  touching its files (the image's `jellyfin-web` is read-only for Jellyfin's user).
- **JavaScript Injector**: runs custom scripts in the web client; Spotlight's loader.

Restart Jellyfin (`docker compose restart jellyfin`) after installing plugins.

### Removing SeerrReporter from an existing Instance

Jellyfin Enhanced already provides Seerr issue reporting. To remove the duplicate:

1. In Dashboard > Plugins > My Plugins, open **Seerr Reporter** and uninstall it.
2. In Dashboard > Plugins > Repositories, remove the **Seerr Reporter** repository.
3. Restart Jellyfin and reload Jellyfin Web with Ctrl+F5.
4. Remove `JELLYFIN_SEERR_REPORTER` from the Instance's `.env` if present; the
   Template no longer uses this setting.

Keep File Transformation: Abyss and other plugins can still use it. The Wiring
only installs missing customizations and does not uninstall existing plugins.
