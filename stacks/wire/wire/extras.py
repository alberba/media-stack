"""The Jellyfin customizations the Operator opted into in scripts/setup.sh (#11,
docs/jellyfin-customizations.md): the Abyss theme and Spotlight.

Nothing is written inside the Jellyfin image. The theme's CSS and the Viewers' display
preferences live in Jellyfin's App data; Spotlight's three files are served from a
folder of the App data mounted at jellyfin-web/ui, and its loader is added by the
JavaScript Injector plugin, so image updates keep all of it.

Only what is missing is added (ADR-0002). The one exception is the Abyss block this
module writes into the custom CSS, which follows ABYSS_VERSION when Renovate bumps it.
"""

import os
import re
import time
import urllib.parse
import urllib.request

from .api import Client

# renovate: datasource=github-releases depName=AumGupta/abyss-jellyfin
ABYSS_VERSION = "v1.2.3"
ABYSS_CDN = "https://cdn.jsdelivr.net/gh/AumGupta/abyss-jellyfin@{version}/{path}"
SPOTLIGHT_FILES = ["spotlight-loader.js", "spotlight.html", "spotlight.css"]
CSS_START, CSS_END = "/* ABYSS THEME START */", "/* ABYSS THEME END */"
LOADER_NAME = "Abyss Spotlight"
LOADER = """(function () {
  var s = document.createElement('script');
  s.src = 'ui/spotlight-loader.js';
  s.setAttribute('data-abyss-spotlight', '');
  document.body.appendChild(s);
})();"""
# Abyss's recommended home: Continue Watching, Next Up, My Media, Recently Added.
HOME = ["resume", "nextup", "smalllibrarytiles", "latestmedia"]

FILE_TRANSFORMATION = ("File Transformation", "5e87cc92-571a-4d8d-8d98-d2d4147f9f90",
                       "https://www.iamparadox.dev/jellyfin/plugins/manifest.json")
JS_INJECTOR = ("JavaScript Injector", "f5a34f7b-2e8a-4e6a-a722-3a216a81b374",
               "https://raw.githubusercontent.com/n00bcodr/jellyfin-plugins/main/12/manifest.json")

AUTH = 'MediaBrowser Client="Media Stack Wire", Device="wire", DeviceId="media-stack-wire", Version="1"'


def wanted(cfg):
    return {"abyss": cfg["jellyfin_abyss"]}


def plugins_for(cfg):
    """Abyss's Spotlight changes the served web client through plugins."""
    return [FILE_TRANSFORMATION, JS_INJECTOR] if cfg["jellyfin_abyss"] else []


def sign_in(base, cfg):
    anonymous = Client(base, {"Authorization": AUTH})
    answer = anonymous.post("/Users/AuthenticateByName",
                            {"Username": cfg["jellyfin_user"], "Pw": cfg["jellyfin_password"]})
    return Client(base, {"Authorization": f'{AUTH}, Token="{answer["AccessToken"]}"'})


def abyss_css(css):
    """The custom CSS with the Abyss block at the top, at ABYSS_VERSION."""
    css = re.sub(re.escape(CSS_START) + r".*?" + re.escape(CSS_END) + r"\n?", "", css or "", flags=re.S)
    block = f"{CSS_START}\n@import url('{ABYSS_CDN.format(version=ABYSS_VERSION, path='abyss.css')}');\n{CSS_END}"
    return block + ("\n" + css if css else "")


def theme(client):
    log = []
    branding = client.get("/System/Configuration/branding")
    css = abyss_css(branding.get("CustomCss"))
    if css != (branding.get("CustomCss") or ""):
        branding["CustomCss"] = css
        client.post("/System/Configuration/branding", branding)
        log.append(f"jellyfin: Abyss {ABYSS_VERSION} set as custom CSS")
    # Jellyfin has no server-wide display defaults: every user gets them, and a Viewer
    # added later gets them on the next run.
    for user in client.get("/Users"):
        query = {"userId": user["Id"], "client": "emby"}
        prefs = client.get("/DisplayPreferences/usersettings", **query)
        custom = prefs.setdefault("CustomPrefs", {})
        if custom.get("abyssApplied"):
            continue
        custom.update({"appTheme": "dark", "dashboardTheme": "dark", "abyssApplied": "true"})
        custom.update({f"homesection{i}": HOME[i] if i < len(HOME) else "none" for i in range(10)})
        client.request("POST", "/DisplayPreferences/usersettings", prefs, query)
        log.append(f"jellyfin: dark theme and Abyss home sections set for {user['Name']}")
    return log


def spotlight_files(folder, fetch):
    """Writes Spotlight's files for ABYSS_VERSION into the folder Jellyfin serves as
    jellyfin-web/ui; a marker file keeps reruns from downloading them again."""
    marker = os.path.join(folder, ".version")
    try:
        with open(marker, encoding="utf-8") as f:
            if f.read().strip() == ABYSS_VERSION:
                return []
    except OSError:
        pass
    os.makedirs(folder, exist_ok=True)
    for name in SPOTLIGHT_FILES:
        data = fetch(ABYSS_CDN.format(version=ABYSS_VERSION, path=f"scripts/spotlight/{name}"))
        with open(os.path.join(folder, name), "wb") as f:
            f.write(data)
    with open(marker, "w", encoding="utf-8") as f:
        f.write(ABYSS_VERSION + "\n")
    return [f"jellyfin: Spotlight {ABYSS_VERSION} files written"]


def download(url):
    with urllib.request.urlopen(url, timeout=60) as resp:
        return resp.read()


def install(client, plugins):
    """Adds the plugin repositories and installs the plugins that are missing.
    Returns the log and whether Jellyfin must restart to load them."""
    log = []
    repos = client.get("/Repositories")
    urls = {r["Url"] for r in repos}
    missing = [(name, url) for name, _, url in plugins if url not in urls]
    if missing:
        repos += [{"Name": name, "Url": url, "Enabled": True} for name, url in missing]
        client.post("/Repositories", repos)
        log += [f"jellyfin: plugin repository {name} added" for name, _ in missing]
    installed = {p["Id"].replace("-", "") for p in client.get("/Plugins")}
    restart = False
    for name, guid, url in plugins:
        if guid.replace("-", "") in installed:
            continue
        client.post(f"/Packages/Installed/{urllib.parse.quote(name)}", None, assemblyGuid=guid, repositoryUrl=url)
        log.append(f"jellyfin: plugin {name} installed")
        restart = True
    return log, restart


def wait_installed(client, plugins, timeout=300):
    """Installs run in the background; they are done when Jellyfin lists the plugin."""
    deadline = time.monotonic() + timeout
    guids = {g.replace("-", "") for _, g, _ in plugins}
    while guids - {p["Id"].replace("-", "") for p in client.get("/Plugins")}:
        if time.monotonic() >= deadline:
            raise TimeoutError(f"plugins not installed after {timeout}s")
        time.sleep(3)


def loaded(client, guid):
    """The plugin's entry once Jellyfin runs it (after the restart that loads it)."""
    return next((p for p in client.get("/Plugins")
                 if p["Id"].replace("-", "") == guid.replace("-", "") and p.get("Status") == "Active"), None)


def configure_loader(client):
    if not loaded(client, JS_INJECTOR[1]):
        return ["jellyfin: WARN JavaScript Injector not running yet, Spotlight's loader is added on the next run"]
    path = f"/Plugins/{JS_INJECTOR[1]}/Configuration"
    conf = client.get(path)
    scripts = conf.setdefault("CustomJavaScripts", [])
    if any(s.get("Name") == LOADER_NAME for s in scripts):
        return []
    scripts.append({"Name": LOADER_NAME, "Script": LOADER, "Enabled": True, "RequiresAuthentication": False})
    client.post(path, conf)
    return ["jellyfin: Spotlight loader added to JavaScript Injector"]


def restart(client, wait):
    client.post("/System/Restart")
    time.sleep(10)  # let it go down before waiting for it to answer again
    wait()


def customize(base, cfg, ui_folder, fetch=download, wait=None):
    """Applies the chosen customizations. `wait` blocks until Jellyfin answers again."""
    if not any(wanted(cfg).values()):
        return ["jellyfin: no customizations chosen in .env"]
    if not (cfg["jellyfin_user"] and cfg["jellyfin_password"]):
        return ["jellyfin: WARN no JELLYFIN_ADMIN_USER/PASSWORD in .env, customizations skipped"]
    if not Client(base).get("/System/Info/Public").get("StartupWizardCompleted"):
        return ["jellyfin: WARN setup wizard not finished, customizations skipped"]
    client = sign_in(base, cfg)
    plugins = plugins_for(cfg)
    log, must_restart = install(client, plugins)
    if must_restart:
        wait_installed(client, plugins)
        restart(client, wait)
        client = sign_in(base, cfg)
        log.append("jellyfin: restarted to load the new plugins")
    if cfg["jellyfin_abyss"]:
        log += theme(client)
        log += spotlight_files(ui_folder, fetch)
        log += configure_loader(client)
    return log
