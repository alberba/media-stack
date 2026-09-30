# Checklist de seguridad

[English](security.en.md)

Qué exponer y cómo. Una Instancia tiene dos tipos de apps:

- **Para Espectadores**: Jellyfin y Seerr. Tienen sus propias cuentas de usuario y están
  hechas para estar en internet.
- **Para el Operador**: todo lo demás (Radarr, Sonarr, Bazarr, Prowlarr, qBittorrent,
  Homarr, Dockge, la administración de NPM…). Controlan la Instancia y guardan los
  secretos de tus indexers y de la VPN.

## Formas de entrar

| Forma | Para | Qué hace falta |
| --- | --- | --- |
| Solo LAN | todo | nada: es lo de por defecto |
| Tailscale (Perfil `remote`) | el Operador, desde cualquier sitio | el Perfil [remote](profiles.md#remote); sin abrir puertos |
| Internet, por NPM (Perfil `proxy`) | Espectadores; opcionalmente algunas apps del Operador | puertos 80/443, un dominio y los pasos de abajo |

**Tailscale es la forma más segura de llegar a las apps del Operador** desde fuera: no
hay nada abierto a internet. Publícalas por NPM solo si las necesitas sin Tailscale.

## Checklist

- [ ] El router redirige **solo 80 y 443** a la Instancia. Nunca el 81 (administración de
      NPM) ni el puerto propio de una app.
- [ ] Cada proxy host de NPM tiene certificado Let's Encrypt y **Force SSL**.
- [ ] El login por defecto de NPM está cambiado.
- [ ] Jellyfin y Seerr: contraseñas de admin fuertes; los Espectadores tienen usuarios
      propios sin permisos de admin.
- [ ] Cada app del Operador tiene **su propio login activado**: Radarr/Sonarr/Prowlarr
      (Settings > General > Authentication `Forms`), Bazarr (Settings > General >
      Security), qBittorrent (contraseña de la WebUI), Homarr (un usuario y tableros no públicos).
- [ ] Toda app del Operador publicada por NPM tiene además una **Access List** (abajo).
- [ ] Dockge, File Browser, la administración de NPM, Beszel y What's Up Docker **nunca**
      se publican: llegan al socket de Docker o a todo el disco.
- [ ] `scripts/verify.sh` pasa: la IP pública de qBittorrent es la de la VPN. Si gluetun
      cae, las apps de detrás se quedan sin red en vez de filtrar tu IP.
- [ ] `.env` y `APPDATA_ROOT` solo los puedes leer tú; `.env` nunca se sube al repo.

## Publicar las apps de Espectadores

En NPM (`http://<host>:81`), un proxy host para cada una:

- `watch.example.com` → `http` `jellyfin` `8096`, con **Websockets support**.
- `request.example.com` → `http` `seerr` `5055`.

En Jellyfin, Dashboard > Networking: añade `npm` como proxy conocido.

## Publicar apps del Operador (Radarr, Sonarr, Bazarr, Homarr)

Estas apps van detrás de la VPN (salvo Homarr), así que NPM apunta a su nombre y puerto:

| App | Destino |
| --- | --- |
| Radarr | `http` `radarr` `7878` |
| Sonarr | `http` `sonarr` `8989` |
| Bazarr | `http` `bazarr` `6767` |
| Homarr | `http` `homarr` `7575`, con **Websockets support** |

Usa dos capas:

1. **El login de la propia app** (obligatorio). Sin él, cualquiera con la URL controla la app.
2. **Una Access List de NPM** (recomendada). En NPM > Access Lists, crea una con usuario y
   contraseña (Authorization) y, si tu IP es fija, una regla Allow para ella. Asígnala a
   cada uno de estos proxy hosts.

Por qué la Access List: los logins de las *arr no limitan intentos ni tienen 2FA, estas
apps ya han tenido fallos que saltaban la autenticación, y hay bots que las buscan. Con la
Access List, la petición se queda en NPM antes de llegar a la app. El coste: entras dos
veces, y las apps móviles (nzb360, LunaSea…) necesitan el usuario de Basic Auth además de
la API key. Sin ella, mantén todas las apps actualizadas y usa contraseñas largas y únicas.
