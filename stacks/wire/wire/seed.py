"""Seeds the files the apps read on their first start, so the keys and passwords in
.env are the ones they use. Runs before the apps start. A file that already exists is
never touched: that App data belongs to an Instance that is already set up.
"""

import base64
import hashlib
import os

from . import config


class Seeder:
    def __init__(self, environ, appdata="/appdata", data="/data"):
        self.environ = environ
        self.appdata = appdata
        self.data = data
        self.uid = int(config.get(environ, "PUID") or 1000)
        self.gid = int(config.get(environ, "PGID") or 1000)
        self.log = []

    def env(self, name):
        return config.get(self.environ, name)

    def chown(self, path):
        try:
            os.chown(path, self.uid, self.gid)
        except PermissionError:
            pass  # not root (tests): the files stay the current user's

    def makedirs(self, path):
        parts = []
        while not os.path.isdir(path):
            parts.append(path)
            path = os.path.dirname(path)
        for p in reversed(parts):
            os.mkdir(p)
            self.chown(p)

    def write(self, relpath, content, secret=False):
        """Writes APPDATA/relpath unless it exists. True when written."""
        path = os.path.join(self.appdata, relpath)
        if os.path.exists(path):
            self.log.append(f"kept {relpath} (already there)")
            return False
        self.makedirs(os.path.dirname(path))
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        os.chmod(path, 0o600 if secret else 0o644)
        self.chown(path)
        self.log.append(f"seeded {relpath}")
        return True

    def run(self):
        for m in config.managers(self.environ):
            self.arr(m.key, m.env)
        for folder in config.TOPOLOGY.folders(config.profiles(self.environ)):
            self.makedirs(os.path.join(self.data, folder))
        self.arr("prowlarr", "PROWLARR")
        self.bazarr()
        self.qbittorrent()
        return self.log

    def arr(self, key, env_name):
        api_key = self.env(f"{env_name}_API_KEY")
        if api_key:
            self.write(f"{key}/config.xml", f"<Config>\n  <ApiKey>{api_key}</ApiKey>\n</Config>\n", secret=True)

    def bazarr(self):
        keys = [self.env(n) for n in ("BAZARR_API_KEY", "RADARR_API_KEY", "SONARR_API_KEY")]
        if not all(keys):
            return
        bazarr, radarr, sonarr = keys
        radarr_host, radarr_port = config.TOPOLOGY.endpoint("bazarr", "radarr")
        sonarr_host, sonarr_port = config.TOPOLOGY.endpoint("bazarr", "sonarr")
        # Bazarr runs behind the VPN with Radarr and Sonarr, so they are on localhost.
        self.write("bazarr/config/config.yaml", f"""auth:
  apikey: {bazarr}
general:
  use_radarr: true
  use_sonarr: true
radarr:
  ip: {radarr_host}
  port: {radarr_port}
  base_url: ''
  apikey: {radarr}
sonarr:
  ip: {sonarr_host}
  port: {sonarr_port}
  base_url: ''
  apikey: {sonarr}
""", secret=True)

    def qbittorrent(self):
        password = self.env("QBITTORRENT_PASSWORD")
        if not password:
            return
        user = self.env("QBITTORRENT_USER") or "admin"
        # gluetun hands the forwarded port to qBittorrent from localhost, without a login.
        localhost_auth = "false" if self.env("VPN_PORT_FORWARDING") == "on" else "true"
        self.write("qbittorrent/qBittorrent/qBittorrent.conf", f"""[BitTorrent]
Session\\DefaultSavePath=/data/torrents/

[LegalNotice]
Accepted=true

[Preferences]
WebUI\\Username={user}
WebUI\\Password_PBKDF2="{pbkdf2(password)}"
WebUI\\LocalHostAuth={localhost_auth}
""", secret=True)


def pbkdf2(password, salt=None):
    """qBittorrent's WebUI password format: PBKDF2-HMAC-SHA512, 100000 rounds."""
    salt = salt or os.urandom(16)
    digest = hashlib.pbkdf2_hmac("sha512", password.encode(), salt, 100000, 64)
    return f"@ByteArray({base64.b64encode(salt).decode()}:{base64.b64encode(digest).decode()})"
