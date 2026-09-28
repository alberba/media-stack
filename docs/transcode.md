# Transcoding with a Worker

The `transcode` Profile re-encodes the largest files of the Media library to HEVC to
save space. The Instance only runs the Tdarr **server**, which schedules the work and
has no internal node, so it never transcodes itself. The transcoding is done by a
**Worker**: a PC with an NVIDIA GPU that runs a Tdarr **node** and reads and writes the
library over an SMB share. The Instance works the same with no Worker; files simply wait.

```
Instance                                   Worker (Linux or Windows)
┌───────────────────────────┐              ┌──────────────────────────────┐
│ tdarr server  :8265 UI    │◄── :8266 ────│ tdarr node  (NVENC)          │
│   /data/media  (library)  │              │   /data/media  or  M:\       │
│   /temp  (cache setting)  │── SMB share ─►   SMB mount of the library   │
└───────────────────────────┘              │   transcode cache: local disk│
                                           └──────────────────────────────┘
```

## What gets transcoded

Only files that are **large** and **no longer seeding**. The Template ships one Tdarr
plugin, `Tdarr_Plugin_custom_NVENC_HEVC_Compress`
([stacks/transcode/plugins](../stacks/transcode/plugins)), mounted read-only into the
server, which hands it to every node. For each file it:

1. skips anything that is not video;
2. skips files under **`minSizeGB`** (input, default 10 GB);
3. skips files with **more than one hardlink**. Radarr and Sonarr import with hardlinks,
   so while the torrent is still in qBittorrent the library file has two links.
   Re-encoding it would break the torrent and use the space twice. Once the torrent is
   removed (by hand, by its seeding limits or by cleanuparr), the file has one link and
   is encoded on the next scan;
4. re-encodes the video with NVENC HEVC at **`quality`** (input, qp, default 24),
   copying every audio and subtitle track, into MKV, and replaces the original.

To change it, edit the file in the Template (not in Tdarr's UI) and restart `tdarr`.

## 1. The Instance

1. Add `transcode` to `COMPOSE_PROFILES`, run `sudo scripts/init.sh` and
   `docker compose up -d`. Tdarr's UI is at `http://<instance>:8265`.
2. Optional, for Jellyfin's own hardware transcoding (and Tdarr's) with the Instance's
   Intel/AMD GPU: set `COMPOSE_FILE=compose.yaml:compose.gpu.yaml` and `RENDER_GID`
   (`getent group render | cut -d: -f3`) in `.env`, then `docker compose up -d`. This
   adds `/dev/dri` and the render group to both. In Jellyfin, turn on hardware
   acceleration (VA-API or QSV) in Dashboard > Playback.
3. **Share the library over SMB**: share `DATA_ROOT/media` read-write (on a NAS, from its
   UI; on a plain Linux host, with Samba), for an SMB user whose files belong to
   `PUID:PGID`. Files the Worker replaces are written by that user, so anything else
   makes the library's owner drift.
4. **Library in Tdarr** (Libraries > Library +):
   - Source: `/data/media` (or `/data/media/movies` and `/data/media/tv` as two
     libraries). Turn on folder watch or schedule scans as you like.
   - Transcode cache: `/temp`. Each Worker maps this to a folder on its own disk.
   - Transcode options > Classic plugin stack: only
     `Tdarr_Plugin_custom_NVENC_HEVC_Compress` (it is under Local plugins), with the
     inputs you want.
   - Health checks: Quick, or off. Like transcodes, they run on the Worker's node.

## 2a. A Linux Worker (Docker)

Requirements: Docker with Compose, the NVIDIA driver and the
[NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html).

1. Mount the share, e.g. in `/etc/fstab` (credentials in a root-only file with
   `username=` and `password=` lines):

   ```
   //<instance>/media  /mnt/media-stack/media  cifs  credentials=/root/.smb-media-stack,uid=1000,gid=1000,vers=3.0,iocharset=utf8,_netdev,x-systemd.automount  0 0
   ```

   with `uid`/`gid` set to the Worker's `PUID`/`PGID`.
2. Get the Worker's compose file from the Template and fill in its `.env`:

   ```sh
   git clone https://github.com/alberba/media-stack.git && cd media-stack/worker
   cp .env.example .env    # TDARR_SERVER_IP, TDARR_NODE_NAME (e.g. pc-3070-linux), paths
   docker compose up -d
   ```

**Path translators: none.** The container sees the share at `/data/media` and its cache
at `/temp`, the same paths as the server.

## 2b. A Windows Worker (native node)

Requirements: the NVIDIA driver.

1. Map the share as a network drive, e.g. `M:` → `\\<instance>\media`, with
   **Reconnect at sign-in**, as the Windows user that will run the node.
2. Download Tdarr from https://tdarr.io/download, run `Tdarr_Updater.exe`, and make sure
   the node's version is **the same as the server's** (the image tag in
   `stacks/transcode/compose.yaml`).
3. Copy [`worker/Tdarr_Node_Config.windows.json.example`](../worker/Tdarr_Node_Config.windows.json.example)
   to `Tdarr_Node\configs\Tdarr_Node_Config.json` (after running the node once, or
   instead of the file it creates) and set:
   - `nodeName`: unique, e.g. `pc-3070-win`;
   - `serverURL` and `serverIP`: the Instance's address;
   - `pathTranslators`: `/data/media` → the mapped drive (`M:/`), and `/temp` → a
     folder on a fast local disk (`D:/tdarr-cache`), created beforehand.
4. Start `Tdarr_Node\Tdarr_Node.exe` (or `Tdarr_Node_Tray.exe` to keep it in the tray).

## Node names

Give every node its own name, and the same PC a different one per OS (`pc-3070-linux`,
`pc-3070-win`): each OS has its own node config, paths and ffmpeg, and the server tracks
nodes by name. With a shared name the server mixes up their settings and history.

## Check it before letting it run

1. The node shows up in Tdarr's **Nodes** panel, with the GPU in its transcode workers.
   Set its GPU transcode workers to 1 and CPU workers to 0.
2. **Hardlinks are visible through the share.** Queue a large file that is still seeding
   and open its job report: the plugin must say it has 2 hardlinks and skip it. If it
   reports 1, the share does not pass link counts (Samba does by default), and the
   plugin would re-encode seeding files: stop the node until that is fixed.
3. Queue one large file that is not seeding and check the result plays in Jellyfin
   before letting the whole library go through.

The node's version must always match the server's: Renovate bumps `tdarr` and
`tdarr_node` together. Update the Windows node with `Tdarr_Updater.exe` at the same time.
