# Conectar las apps

[English](wiring.en.md)

Tras la [instalación](install.md), los servicios del Núcleo funcionan pero no se conocen
entre sí. Hazlo una vez, en este orden. Cambia `<host>` por la IP de la Instancia en tu LAN.

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

La API key de cada app *arr está en su Settings > General.

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

## 1. qBittorrent (`http://<host>:8080`)

1. La contraseña temporal del primer login está en `docker logs qbittorrent`. Cámbiala en
   Options > WebUI.
2. Options > Downloads: **Default save path** `/data/torrents`.
3. Crea dos categorías: `radarr` → `/data/torrents/movies` y `sonarr` → `/data/torrents/tv`.

## 2. Radarr (`:7878`) y Sonarr (`:8989`)

En cada uno:

1. Settings > General: **Authentication** `Forms`, con usuario y contraseña.
2. Settings > Media Management: **Root folder** `/data/media/movies` (Radarr) o
   `/data/media/tv` (Sonarr). Deja activado **Use Hardlinks instead of Copy**.
3. Settings > Download Clients: añade **qBittorrent**, host `localhost`, puerto `8080`, tu
   login de qBittorrent y la categoría `radarr` o `sonarr`.

## 3. Prowlarr (`:9696`)

1. Settings > Indexers: añade un proxy **FlareSolverr** en `http://localhost:8191` con una
   etiqueta (p. ej. `flaresolverr`). Pon esa etiqueta solo a los indexers tras Cloudflare.
2. Settings > Apps: añade **Radarr** y **Sonarr**. Prowlarr server `http://localhost:9696`,
   Radarr server `http://localhost:7878` (Sonarr `http://localhost:8989`) y cada API key.
3. Añade tus indexers. Prowlarr los sincroniza con Radarr y Sonarr: no los añadas allí a mano.

## 4. Bazarr (`:6767`)

1. Settings > Languages: crea un perfil de idiomas y ponlo por defecto para películas y series.
2. Settings > Radarr y Settings > Sonarr: actívalos, dirección `localhost`, puerto
   `7878` / `8989` y cada API key.
3. Settings > Providers: añade proveedores de subtítulos (p. ej. OpenSubtitles.com).

## 5. Jellyfin (`:8096`)

1. Completa el asistente inicial y crea el usuario administrador.
2. Añade dos bibliotecas: **Películas** en `/data/media/movies` y **Series** en `/data/media/tv`.

## 6. Seerr (`:5055`)

1. **Sign in with Jellyfin**: dirección `jellyfin`, puerto `8096` y el admin de Jellyfin.
   Elige las bibliotecas a sincronizar.
2. Settings > Services: añade un servidor **Radarr** (`radarr`, `7878`, API key, root
   folder `/data/media/movies`, perfil de calidad) y uno **Sonarr** (`sonarr`, `8989`,
   `/data/media/tv`). Márcalos como predeterminados.
3. Settings > Users: importa los usuarios de Jellyfin, para que los Espectadores entren
   con su cuenta de Jellyfin.

Pruébalo: pide una película en Seerr. Debe aparecer en Radarr, descargarse en qBittorrent
en `/data/torrents/movies`, importarse a `/data/media/movies` y salir en Jellyfin.

La conexión de los Perfiles (gestores VO, Jackett, cleanuparr…) está en
[profiles.md](profiles.md) (solo en inglés).
