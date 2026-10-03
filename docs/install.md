# Instalación

[English](install.en.md)

De una máquina Linux vacía a una Instancia funcionando, con las apps ya conectadas entre sí. Después: [lo que queda a mano](wiring.md#lo-que-queda-a-mano)
y lee la [checklist de seguridad](security.md) antes de exponer nada.

## Requisitos

- **Linux** (cualquier distribución; vale un NAS con Docker). Windows y macOS no están
  soportados: gluetun necesita `/dev/net/tun` y los hardlinks, un sistema de ficheros Linux.
- **Docker Engine** con **Compose 2.20** o superior (`docker compose version`).
- **Python 3.7** o superior en el host (`python3 --version`), sin paquetes adicionales.
- `/dev/net/tun` en el host (`ls -l /dev/net/tun`).
- Una **cuenta de VPN** de un proveedor [soportado por gluetun](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers),
  con su clave WireGuard o sus credenciales OpenVPN.
- Un único sistema de ficheros con sitio para descargas y Biblioteca (`DATA_ROOT`), y una
  carpeta para los Datos de las apps (`APPDATA_ROOT`), fuera del clon.

## Pasos

```sh
git clone https://github.com/alberba/media-stack.git && cd media-stack
scripts/setup.sh          # hace preguntas, escribe .env y ofrece ejecutar init.sh
docker compose up -d
scripts/verify.sh         # todo healthy, y la IP de salida de qBittorrent es la de la VPN
```

1. **`scripts/setup.sh`** pregunta las rutas, `PUID`/`PGID` (`id -u`, `id -g`), la zona
   horaria, el proveedor y credenciales de la VPN, qué Perfiles activar, el admin de
   Jellyfin y las calidades a descargar; genera las API keys de las apps. Escribe `.env` y
   ofrece ejecutar `scripts/init.sh`, que comprueba el host y crea las carpetas de
   `DATA_ROOT` y `APPDATA_ROOT` y la red de Docker. Puedes volver a ejecutarlo cuando
   quieras: propone los valores actuales y conserva lo que no pregunta.
2. **`docker compose up -d`** arranca el Núcleo y los Perfiles de `COMPOSE_PROFILES`, y
   el contenedor `wire` [conecta las apps](wiring.md) entre sí.
3. **`scripts/verify.sh`** comprueba, un par de minutos después de arrancar, que todos los
   servicios del Núcleo y de `vo` (si está activo) están healthy, que `wire-seed` y `wire` terminaron correctamente y que la IP pública de qBittorrent es la de la VPN,
   no la tuya.

Sin el asistente: copia `.env.example` a `.env`, rellénalo y ejecuta `scripts/init.sh`.
La validación usa los mismos valores que Compose, incluidas las variables exportadas en
tu shell. `init.sh` pide privilegios solo al preparar carpetas. Para usar otro archivo,
ejecuta `ENV_FILE=/ruta/instancia.env scripts/init.sh` y después el comando Compose
con `--env-file` que imprime `init.sh`.

Transcodificación por hardware con la GPU del host: pon
`COMPOSE_FILE=compose.yaml:compose.gpu.yaml` y `RENDER_GID` en `.env` (ver `.env.example`).

## Problemas frecuentes

| Síntoma | Qué mirar |
| --- | --- |
| gluetun unhealthy, las apps de detrás no arrancan | `docker logs gluetun`: clave/credenciales mal, o falta `WIREGUARD_ADDRESSES` para tu proveedor. |
| `verify.sh` dice que la IP de salida es la tuya | No uses la Instancia; revisa los logs de gluetun. Sin él, las apps de detrás no tienen red. |
| Permission denied al escribir en `/data` | `PUID`/`PGID` deben ser dueños de `DATA_ROOT` y `APPDATA_ROOT` (`sudo chown -R`). |
| Las importaciones son copias, no hardlinks | `DATA_ROOT` debe ser un único sistema de ficheros; ver [conexión](wiring.md#data-y-hardlinks). |
| Una app de detrás de la VPN no llega a la LAN | Pon tu subred en `VPN_OUTBOUND_SUBNETS`. |

## Actualizar

`git pull && docker compose pull && docker compose up -d`. Las versiones de las imágenes
están fijadas en la Plantilla y Renovate las sube.
