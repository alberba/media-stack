# Conectar las apps

[English](wiring.en.md)

Las conexiones entre las apps las hace **el contenedor `wire`** (la Conexión de las apps)
en cada `docker compose up`: arranca, conecta lo que falte y termina. **Solo añade lo que
no existe y nunca cambia lo que configuraste tú** ([ADR-0002](adr/0002-wiring-only-seeds.md)),
así que puedes tocar cualquier ajuste en las interfaces sin que lo deshaga.

Mira qué hizo con `docker compose logs wire`, y `scripts/verify.sh` avisa si falló.

## Qué hace solo

Antes de que arranquen las apps, `wire-seed` escribe en sus Datos (solo si aún no existen)
las API keys y contraseñas que `scripts/setup.sh` generó en `.env`. Nadie tiene que copiar
ninguna API key. Después, `wire`:

| App | Lo que conecta |
| --- | --- |
| Jellyfin | Completa el asistente: admin `JELLYFIN_ADMIN_USER`, bibliotecas **Películas** (`/data/media/movies`) y **Series** (`/data/media/tv`). |
| Radarr, Sonarr | Root folder y qBittorrent como cliente de descarga, con categoría `movies` / `tv`. |
| Prowlarr | Radarr y Sonarr como apps (sincroniza los indexers) y FlareSolverr como proxy con la etiqueta `flaresolverr`. |
| Calidad | Un perfil **Media Stack** en Radarr y Sonarr con las calidades elegidas en `setup.sh` (`QUALITIES`) y los custom formats de las [TRaSH Guides](https://trash-guides.info), vía [Recyclarr](https://recyclarr.dev). Prefiere audio en castellano. |
| Seerr | Inicia sesión con el admin de Jellyfin, activa sus bibliotecas y añade Radarr y Sonarr (perfil Media Stack) como servidores por defecto. |
| Bazarr | Conectado a Radarr y Sonarr. |
| qBittorrent | Login `QBITTORRENT_USER` / `QBITTORRENT_PASSWORD` y descargas en `/data/torrents`. |

Con el Perfil `vo`, los gestores VO se conectan igual, con sus propias carpetas
(`/data/media/movies-vo`, `/data/media/tv-vo`) y categorías, en las mismas bibliotecas de
Jellyfin, y en Seerr como segundo servidor (no por defecto). Su perfil de calidad prefiere
el idioma original.

El perfil **Media Stack** es de la Plantilla: sus calidades, su orden y el corte solo se
escriben al crearlo, así que puedes cambiarlos en Radarr/Sonarr. En cada arranque solo se
actualizan los custom formats y sus puntuaciones. Tus otros perfiles no se tocan.

## Lo que queda a mano

1. **Radarr, Sonarr, Prowlarr, Bazarr**: al abrirlos por primera vez piden crear un
   usuario (Settings > General > Authentication `Forms`).
2. **Prowlarr**: añade tus indexers; se sincronizan solos con Radarr y Sonarr. A los que
   estén tras Cloudflare ponles la etiqueta `flaresolverr`.
3. **Bazarr**: Settings > Languages (un perfil de idiomas por defecto) y Settings >
   Providers (p. ej. OpenSubtitles.com).
4. **Seerr**: Settings > Users > importa los usuarios de Jellyfin, para que los
   Espectadores entren con su cuenta.

Pruébalo: pide una película en Seerr. Debe aparecer en Radarr, descargarse en qBittorrent
en `/data/torrents/movies`, importarse a `/data/media/movies` y salir en Jellyfin.

Una app que ya estaba configurada antes de `wire` (por ejemplo, al migrar una Instancia)
se queda como está: `wire` lee su API key de sus Datos y solo añade lo que le falte. Si le
falta una credencial (`QBITTORRENT_PASSWORD`, `JELLYFIN_ADMIN_*`), lo dice en su log con
`WARN` y se salta ese paso.

## Cómo se llaman los servicios entre sí

qBittorrent, Prowlarr, FlareSolverr, Radarr, Sonarr y Bazarr van **detrás de la VPN**:
comparten la red de gluetun, así que **entre ellos** la dirección es siempre
`localhost:<puerto>`. Jellyfin y Seerr están fuera de la VPN y llegan a los demás **por
nombre** en la red del stack (`http://radarr:7878`, `http://jellyfin:8096`).

| Desde | Hacia | Dirección |
| --- | --- | --- |
| Radarr, Sonarr | qBittorrent | `localhost` `8080` |
| Prowlarr | Radarr, Sonarr | `http://localhost:7878`, `http://localhost:8989` |
| Prowlarr | FlareSolverr | `http://localhost:8191` |
| Bazarr | Radarr, Sonarr | `localhost` `7878`, `localhost` `8989` |
| Seerr | Jellyfin | `jellyfin` `8096` |
| Seerr | Radarr, Sonarr | `radarr` `7878`, `sonarr` `8989` |

## `/data` y hardlinks

Todos los contenedores ven el mismo `DATA_ROOT` en `/data`:

```
/data
├── torrents/          qBittorrent descarga y sigue compartiendo desde aquí
│   ├── movies/
│   └── tv/
└── media/             la Biblioteca que sirve Jellyfin
    ├── movies/
    └── tv/
```

Como `torrents/` y `media/` están en el mismo sistema de ficheros, Radarr y Sonarr
**importan con un hardlink**: el fichero aparece en la Biblioteca sin copiarse, no ocupa
más y sigue compartiéndose. Usa siempre estas rutas `/data/...` dentro de las apps.
Para comprobar una importación: `stat -c %h <fichero>` en `DATA_ROOT/media` da `2` o más.

La conexión del resto de Perfiles (Jackett, cleanuparr…) está en
[profiles.md](profiles.md) (solo en inglés).
