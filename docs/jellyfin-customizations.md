# Optional Jellyfin customizations

The theme and plugins the author's Instance uses. None of this is needed; the Template
does not apply it for you (tracked in #11). Everything lives in Jellyfin's App data, so
it survives image updates and is covered by the `backup` Profile.

## Theme: Abyss

[Abyss](https://github.com/AumGupta/abyss-jellyfin) is a dark theme loaded as custom CSS,
without editing `jellyfin-web`.

1. Dashboard > General > **Custom CSS code**:

   ```css
   @import url('https://cdn.jsdelivr.net/gh/AumGupta/abyss-jellyfin@main/abyss.css');
   ```

2. Save and reload. Its variables and optional overrides (Lite, per-plugin) are listed in
   its README. Its Spotlight add-on changes `index.html`: follow the project's
   [SETUP](https://github.com/AumGupta/abyss-jellyfin/blob/main/SETUP.md) Docker section
   if you want it.

## Plugins

Dashboard > Plugins > Repositories > **+**, add:

| Name | URL |
| --- | --- |
| File Transformation | `https://www.iamparadox.dev/jellyfin/plugins/manifest.json` |
| SeerrReporter | `https://raw.githubusercontent.com/alberba/jellyfin-plugin-seerr-reporter/main/manifest.json` |

Then, in the Catalog, install:

- **File Transformation**: lets other plugins change the web client without touching its
  files. Needed by plugins that add UI.
- **SeerrReporter** ([repo](https://github.com/alberba/jellyfin-plugin-seerr-reporter)):
  Viewers report a problem with an item from Jellyfin, and it becomes an issue in Seerr.
  In its settings, Seerr URL `http://seerr:5055` and Seerr's API key. With the `extras`
  Profile, the issue-automator then acts on it.

Restart Jellyfin (`docker compose restart jellyfin`) after installing plugins.
