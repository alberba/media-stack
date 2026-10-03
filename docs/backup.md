# Copia de seguridad y restauración

[English](backup.en.md)

El Perfil `backup` guarda una copia cifrada y fuera de la máquina de los Datos de las
apps de tu Instancia. Así, si pierdes la máquina solo pierdes la Biblioteca, que las
apps pueden volver a descargar a partir de lo que recuerdan sus datos.

- **Qué**: todo lo que hay en `BACKUP_SOURCE` (por defecto, `APPDATA_ROOT`). Cada base
  de datos SQLite se copia con el backup en caliente de SQLite, sin parar los
  servicios. Se deja fuera lo que se puede regenerar: cachés, carátulas y metadatos,
  los subtítulos extraídos por Jellyfin, logs y los zip de backup de las propias apps,
  además de lo que añadas en `BACKUP_EXCLUDE`.
- **Dónde**: un repositorio de [restic](https://restic.net), cifrado con tu contraseña,
  en Google Drive (los 15 GB gratis sobran) a través de [rclone](https://rclone.org).
- **Cuándo**: cada noche a las 04:00 (`BACKUP_SCHEDULE`, en tu `TZ`). Conserva 7
  copias diarias, 4 semanales y 6 mensuales, y borra el resto.
- **Avisos**: un mensaje de Telegram si una copia falla, y el contenedor `backup` pasa
  a `unhealthy` hasta que la siguiente salga bien.

## Qué guardar en el gestor de contraseñas

Sin las dos primeras la copia no se puede leer, y sin la tercera tendrás que rehacer tu
configuración a mano. Guárdalas en 1Password (o tu gestor de contraseñas), no en la
máquina de la que haces copia:

| Elemento | Dónde está en la Instancia | Qué guardar |
| --- | --- | --- |
| Contraseña de restic | `RESTIC_PASSWORD` en `.env` | La contraseña |
| Configuración de rclone | `APPDATA_ROOT/backup/rclone.conf` | El fichero entero, como documento o adjunto |
| `.env` | El clon de la Plantilla (no está en la copia) | El fichero entero: claves de VPN, rutas, Perfiles, Telegram |

En 1Password funciona bien un elemento por Instancia: un elemento de tipo Contraseña
llamado "media-stack backup (<instancia>)", la contraseña de restic en su campo de
contraseña, y `rclone.conf` y `.env` adjuntos. Actualiza los adjuntos cada vez que
vuelvas a ejecutar `rclone config` o cambies `.env`.

## Puesta en marcha

### 1. Activa el Perfil

En `.env`:

```sh
COMPOSE_PROFILES=backup          # o por ejemplo "vo,backup"
RESTIC_PASSWORD=...              # genera una: openssl rand -base64 32
TELEGRAM_BOT_TOKEN=...           # opcional: reutiliza el bot que ya uses para avisos
TELEGRAM_CHAT_ID=...
```

Después vuelve a ejecutar `scripts/init.sh`: comprueba la contraseña y crea
`APPDATA_ROOT/backup`.

### 2. Conecta Google Drive

Google pide iniciar sesión en un navegador una vez, así que se hace en dos sitios.

1. Construye la imagen: `docker compose build backup`
2. Abre la configuración de rclone dentro de ella:
   `docker compose run --rm backup rclone config`
   - `n` (nuevo remoto), llámalo `gdrive` (tiene que coincidir con `RESTIC_REPOSITORY`)
   - Almacenamiento: `drive`
   - `client_id` / `client_secret`: déjalos vacíos para usar los de rclone, o
     [crea los tuyos](https://rclone.org/drive/#making-your-own-client-id) para tener
     mejores límites. Si usas los tuyos, pon el estado de publicación de la app de
     Google en **En producción**: en "Prueba" Google revoca el token a los 7 días y
     las copias dejan de funcionar.
   - Scope: `drive.file` (rclone solo ve los ficheros que crea él)
   - Deja el resto vacío; a `Use web browser to automatically authenticate?` → `n`
3. rclone muestra un comando como `rclone authorize "drive" "..."`. Ejecútalo en
   cualquier ordenador con navegador y rclone instalado, inicia sesión en Google y pega
   en el prompt el token que imprime.
4. Termina con `n` (no es una unidad compartida), `y`, `q`. El fichero queda en
   `APPDATA_ROOT/backup/rclone.conf`. **Guárdalo junto con la contraseña en 1Password
   ahora.**

### 3. Arráncalo y haz la primera copia

```sh
docker compose up -d backup
docker compose exec backup media-backup run      # la primera vez crea el repositorio
docker compose exec backup restic snapshots      # ahí está la copia
```

La primera copia lo sube todo; las siguientes solo envían lo que ha cambiado. El
contenedor monta los Datos de las apps en lectura-escritura, porque SQLite necesita sus
ficheros de bloqueo para copiar una base de datos en uso (y la restauración escribe
ahí), pero una copia no escribe nada más.

### Copiar datos que aún no siguen la estructura de la Plantilla

Si tus servicios todavía guardan sus datos en otro sitio (por ejemplo, antes de pasar
una Instancia existente a la Plantilla), apunta el Perfil ahí. Solo necesita la carpeta
que contiene la configuración y las bases de datos de todos los servicios:

```sh
BACKUP_SOURCE=/ruta/a/tu/stack/antiguo
BACKUP_EXCLUDE=.git,alguna/carpeta/grande     # lo que no necesites recuperar
```

Solo hace falta el servicio `backup`: `docker compose up -d --build backup`. Las
variables del Núcleo en `.env` tienen que tener valor igualmente, porque Compose lee el
fichero entero.

## Comprobarlo

- `docker compose ps backup`: `healthy` salvo que la última copia fallara. Telegram solo
  se entera de las copias que fallan; si el contenedor está parado no se ejecuta nada y
  no llega ningún aviso, así que vigila también su estado con tu monitorización.
- `docker compose logs backup`: la salida de cada copia.
- `docker compose exec backup restic snapshots`: todas las copias conservadas.
- `docker compose exec backup media-backup summary /source`: películas, series,
  indexers y usuarios de Jellyfin en tus datos actuales. Apúntalo antes de un simulacro
  de restauración.

## Restaurar

Sirve para recuperar una máquina perdida y, de vez en cuando, como simulacro en una VM
de pruebas, para saber que funciona antes de necesitarlo.

1. En la máquina nueva, instala Docker, clona la Plantilla y rellena `.env` con los
   **mismos** `RESTIC_PASSWORD`, `RESTIC_REPOSITORY` y `BACKUP_HOST`, además de
   `COMPOSE_PROFILES=backup` (y el resto de tus Perfiles).
2. `scripts/init.sh`
3. Copia `rclone.conf` desde 1Password a `APPDATA_ROOT/backup/rclone.conf`
   (con `chmod 600`).
4. Mira qué copias hay:
   ```sh
   docker compose build backup
   docker compose run --rm backup restic snapshots
   ```
5. Si restauras sobre datos que los servicios estaban usando (misma máquina), páralos
   antes: `docker compose down`. Después restaura la última copia en la carpeta de datos (o añade un ID de copia después de
   `/source` para elegir otra):
   ```sh
   docker compose run --rm backup restore /source
   ```
   Ficheros y bases de datos vuelven con sus dueños originales, y se borra cualquier
   `-wal`/`-shm` que quedara junto a una base de datos restaurada. El comando termina con
   el resumen de lo restaurado: compáralo con el que apuntaste.
6. Arranca la Instancia y compruébala:
   ```sh
   docker compose up -d
   scripts/verify.sh
   ```
   Después, en las interfaces web: Radarr y Sonarr muestran tu biblioteca, los
   indexers de Prowlarr pasan **Test All** y todos los usuarios de Jellyfin pueden
   iniciar sesión.

La Biblioteca no está en la copia: Radarr y Sonarr marcan los ficheros como ausentes
hasta que se vuelvan a descargar (**Search All Missing**).

**Si `PUID`/`PGID` cambian** en la máquina nueva, da las carpetas restauradas al nuevo
dueño: `sudo chown -R PUID:PGID APPDATA_ROOT/<servicio>` (Seerr sigue en `1000:1000`).

**Restaurar una estructura antigua** (copiada con un `BACKUP_SOURCE` propio): restaura
en una carpeta vacía y después mueve la carpeta de cada servicio a
`APPDATA_ROOT/<servicio>`:

```sh
mkdir /tmp/restore
docker compose run --rm -v /tmp/restore:/restore backup restore /restore
```
