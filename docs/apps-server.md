# Servidor de apps

Un servidor de apps puede alojar Seerr sin montar la biblioteca del NAS. Es un proyecto
Compose independiente; no es el Worker de transcodificación. Necesita Linux con
systemd, Python 3, Docker y Compose 2.24.4 o posterior. Usa una red privada entre
servidores, por ejemplo Tailscale. No publiques los puertos de administración en Internet.

## Preparación

Clona este repositorio en el servidor de apps y ejecuta desde su raíz:

```sh
cp apps-server/.env.example apps-server/.env
# Editar APPDATA_ROOT, TZ, APPS_BIND_IP y WUD_ADMIN_PASSWORD.
scripts/apps-server.sh init
cd apps-server
docker compose up -d --build
cd ..
sudo scripts/security-update.sh --apps-server install
sudo systemctl start media-stack-apps-security-updates.service
```

`APPS_BIND_IP` es la dirección privada de este servidor; por defecto solo escucha en
loopback. WUD sigue en loopback con `WUD_BIND_IP`. Configura Telegram para recibir
avisos; sin él los avisos pendientes se conservan para un siguiente intento. Usa
`MONITOR_NAME` para distinguir las notificaciones de cada host.

Seerr se configura desde su interfaz con las direcciones privadas del NAS para
Jellyfin, Radarr y Sonarr. En una migración, para Seerr en el origen, copia todos sus
Datos de las apps a `APPDATA_ROOT/seerr` y conserva UID/GID 1000:1000. Cambia las
conexiones internas y webhooks que dependan de nombres Docker o IP de la LAN.
No arranques dos copias productivas con los mismos trabajos y notificaciones.

## Proxy opcional en el NAS

Añade `SEERR_REMOTE_URL=http://<direccion-privada>:5055` al `.env` de la Instancia.
Incluye `compose.seerr-remote.yaml` después de los archivos habituales y antes de
`APPDATA_ROOT/security-monitor/images.compose.json` en `COMPOSE_FILE`.

Si ya hay un pin `services.seerr.image` del Seerr anterior, guárdalo aparte y retira
solo ese pin antes del cambio. De lo contrario prevalecería sobre la nueva imagen de
nginx. Ejecuta `docker compose config --quiet`, recrea solo `seerr` y reinstala el
actualizador con `sudo scripts/security-update.sh install`. El instalador garantiza
que los futuros pins queden al final. Conserva los datos originales hasta validar
el traslado; el proxy no los monta ni los modifica.

El proxy mantiene `http://seerr:5055`, el puerto publicado y el dominio existente.
Jellyfin, Wiring y el automatizador pueden seguir usando sus conexiones actuales.
Su healthcheck comprueba Seerr a través de la red privada. WUD solo considera tags
nginx con versión y sufijo Alpine, compatibles con la política del actualizador.

## Actualizaciones automáticas

En cada host: WUD descubre candidatos a las 05:00 y el temporizador ejecuta la
comparación de seguridad y la aplicación a las 06:00, en `TZ`. Ajusta ambos horarios
si cambias la hora de la copia externa. Cada ejecución conserva los avisos pendientes,
recupera actualizaciones interrumpidas y usa el mismo actualizador probado del NAS.

Solo se aplican correcciones HIGH/CRITICAL verificadas sin nuevas vulnerabilidades
graves, dentro de una versión mayor estable. Antes de recrear la app, se para y se
copian sus datos. Si la salud falla se restauran imagen y datos, conservando los datos
fallidos para inspección. Los pins sobreviven a posteriores `docker compose up`.

Para una política estricta de solo seguridad, desactiva el temporizador independiente
de releases de la Instancia, si estaba instalado: `sudo systemctl disable --now
media-stack-upgrade.timer`. Publicar releases y aplicarlas es una vía distinta de
las correcciones verificadas; no actives ambos timers si solo deseas estas últimas.

Las versiones mayores, imágenes locales, correcciones no demostrables y apps sin
healthcheck quedan pendientes de revisión. La automatización no sustituye la revisión
del código del repositorio ni reconstruye automáticamente su monitor de seguridad.

```sh
systemctl list-timers media-stack-apps-security-updates.timer
journalctl -u media-stack-apps-security-updates.service
sudo scripts/security-update.sh --apps-server run
sudo scripts/security-update.sh --apps-server disable
```

El NAS usa los comandos habituales, sin `--apps-server`. Los nombres de los timers
son diferentes, incluso si ambos proyectos comparten host. No ejecutes los dos
proyectos en el mismo Docker sin cambiar sus nombres de contenedor y puertos.

## Copias y recuperación

Los snapshots del actualizador sirven para deshacer una actualización; no sustituyen
la copia externa periódica. Incluye los datos de `APPDATA_ROOT/seerr`, el `.env` y los
pins en tu sistema de copias. Para SQLite en marcha usa la API de backup de SQLite,
o para la app antes de copiar. Comprueba una restauración antes de retirar el origen.

Para volver al NAS después de recibir nuevas peticiones: para la app remota, exporta
su última base de datos, restaura esa copia en el NAS, revierte las direcciones de sus
conexiones, retira el override y el pin del proxy y arranca Seerr local. Conserva la
copia remota hasta comprobar el dominio, el login y las peticiones.
