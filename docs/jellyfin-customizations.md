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

### Requests inside Jellyfin Web

This is a manual customization, separate from automatic Wiring. The Operator
confirmed access through Plugin Pages on 2026-10-04. Choose plugin builds compatible
with the Jellyfin version in [Compose](../stacks/jellyfin/compose.yaml).

1. Add the Enhanced repository
   `https://raw.githubusercontent.com/n00bcodr/jellyfin-plugins/main/12/manifest.json`
   for Jellyfin 12. Install **Jellyfin Enhanced**, **File Transformation** and
   **Plugin Pages**. The latter two use the IAmParadox repository listed above.
   Restart Jellyfin. [Enhanced installation](https://n00bcodr.github.io/Jellyfin-Enhanced/installation/installation/),
   [Plugin Pages installation](https://github.com/IAmParadox27/jellyfin-plugin-pages#installation).
2. In Seerr, enable **Settings → Users → Enable Jellyfin Sign-In**, then import
   the intended Jellyfin accounts from **Users → Import Jellyfin Users**.
   In **Dashboard → Plugins → Jellyfin Enhanced → Seerr Settings**, enter
   `http://seerr:5055` and the key from Seerr's **Settings → General → API Key**.
   Use **Test Connection**, then save.
   [Connection setup](https://n00bcodr.github.io/Jellyfin-Enhanced/seerr/seerr-settings/#setup).
3. In that same tab, select **Enable Requests Page** and **Use Plugin Pages**.
   Enable **Show Downloads in Requests Page** if wanted; configure Radarr/Sonarr
   URLs and API keys in Enhanced's *arr settings for that section.
   [Download prerequisites](https://n00bcodr.github.io/Jellyfin-Enhanced/seerr/seerr-settings/#show-downloads-section).
4. Save, restart Jellyfin and reload Jellyfin Web (`Ctrl+F5` or `Cmd+Shift+R`).
   In Jellyfin 12, open **Requests** from the user profile menu. The direct route is
   `/web/index.html#!/jellyfinenhanced/requests`.
   [Requests setup and access](https://n00bcodr.github.io/Jellyfin-Enhanced/seerr/seerr-features/#requests-page).

If the link is missing, check Plugin Pages is loaded, **Use Plugin Pages** is
saved and Jellyfin restarted. If requests are missing, test the Seerr connection
and check the Viewer has a linked Seerr account. Keep `DownloadsFilterByUserRequests`
enabled for personal download filtering. Before relying on personal visibility,
test two Viewers without Seerr's `REQUEST_VIEW`/`MANAGE_REQUESTS` permissions;
that isolation test is still pending. This recipe covers Jellyfin Web; native TV
and mobile clients need separate verification. See the
[research and validation status](research/viewer-request-status.md).

### Removing SeerrReporter from an existing Instance

Jellyfin Enhanced already provides Seerr issue reporting. To remove the duplicate:

1. In Dashboard > Plugins > My Plugins, open **Seerr Reporter** and uninstall it.
2. In Dashboard > Plugins > Repositories, remove the **Seerr Reporter** repository.
3. Restart Jellyfin and reload Jellyfin Web with Ctrl+F5.
4. Remove `JELLYFIN_SEERR_REPORTER` from the Instance's `.env` if present; the
   Template no longer uses this setting.

Keep File Transformation: Abyss and other plugins can still use it. The Wiring
only installs missing customizations and does not uninstall existing plugins.
