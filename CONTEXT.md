# Media Stack

A self-hosted media server (download automation, requests, playback) packaged as a template that anyone can deploy on their own Linux machine with Docker.

## Language

**Template**:
This repository: the reusable definition of the stack, with no secrets or personal data.
_Avoid_: plantilla personal, fork, "my setup"
_ES_: Plantilla

**Instance**:
One concrete server deployed from the Template, with its own `.env`, app data and media (e.g. the author's NAS, a friend's mini-PC).
_Avoid_: install, deployment, server (when referring to a specific one)
_ES_: Instancia

**Operator**:
The person who installs and maintains an Instance.
_Avoid_: user, admin
_ES_: Operador

**Viewer**:
A person who watches content or makes requests on an Instance (in Jellyfin, Seerr) without maintaining it.
_Avoid_: user, client, end user
_ES_: Espectador

**Core**:
The set of services every Instance runs: VPN gateway, torrent client, indexer manager, movie and series managers, subtitles, media server and request portal.
_Avoid_: base, minimal stack
_ES_: Núcleo

**Profile**:
An optional group of services an Operator can turn on for their Instance on top of the Core (e.g. `backup`, `vo`, `proxy`, `remote`, `transcode`).
_Avoid_: addon, module, plugin
_ES_: Perfil

**App data**:
The configuration and databases each service writes for an Instance. It is what makes an Instance unique, and it is backed up off-site.
_Avoid_: config (alone), appdata folder, volumes
_ES_: Datos de las apps

**Media library**:
The movies and series files an Instance serves. They are not backed up, because they can be re-downloaded from what the App data remembers.
_Avoid_: data, content
_ES_: Biblioteca

**Worker**:
A machine outside the Instance that lends it compute (e.g. a desktop PC with a GPU transcoding for the NAS). An Instance works without any Worker.
_Avoid_: node (except for Tdarr's own term), remote server, slave
_ES_: Worker

"User" is reserved for accounts inside the apps (a Jellyfin user, a Seerr user).
