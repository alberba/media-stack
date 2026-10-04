# Investigación: auto-wiring de apps en el primer arranque (#9)

**Estado: investigación histórica, sustituida por la implementación.** Los
endpoints, variables y categorías siguientes describen la propuesta del
2026-09-30; no son un contrato vigente. Para modificar Wiring, empieza por
[el mapa de navegación](../agents/navigation.md), [la guía actual](../wiring.md),
[steps.py](../../stacks/wire/wire/steps.py) y [ADR-0002](../adr/0002-wiring-only-seeds.md).

Fecha: 2026-09-30. Solo fuentes primarias (código fuente en GitHub, READMEs oficiales, API de releases de GitHub). Las rutas de código apuntan a la rama por defecto en la fecha indicada; los números de línea pueden desplazarse.

## 1. Jellyfin: asistente de inicio por API

Controlador: [`Jellyfin.Api/Controllers/StartupController.cs`](https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Api/Controllers/StartupController.cs). Todo el controlador lleva `[Authorize(Policy = Policies.FirstTimeSetupOrElevated)]` (L18): sin autenticación mientras el asistente no está completado; después exige admin.

Secuencia sin intervención:

1. `POST /Startup/Configuration` con `{ServerName, UICulture, MetadataCountryCode, PreferredMetadataLanguage}` (L74). Marcado `[Obsolete]`, pero sigue existiendo.
2. `GET /Startup/User` (L109): inicializa y devuelve el primer usuario (lo crea el servidor, no hace falta crearlo).
3. `POST /Startup/User` con `{Name, Password}` (L133): renombra el primer usuario y le pone contraseña. Devuelve `403 Forbid` si ese usuario ya tiene contraseña y `400` si la contraseña está vacía. Esto sirve de protección natural contra la sobrescritura.
4. Bibliotecas: `POST /Library/VirtualFolders?name=Películas&collectionType=movies&paths=/data/media/movies&refreshLibrary=false` ([`LibraryStructureController.cs`](https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Api/Controllers/LibraryStructureController.cs) L31-L90; `name`, `collectionType` y `paths` (separados por comas) van en la query). Esa ruta tiene la misma política `FirstTimeSetupOrElevated` (L32), así que se puede llamar antes de completar el asistente. Para tv: `collectionType=tvshows`. Para no duplicar, se lista antes con `GET /Library/VirtualFolders` (L64).
5. `POST /Startup/RemoteAccess` con `{EnableRemoteAccess: true}` (L93), opcional.
6. `POST /Startup/Complete` (L40): pone `IsStartupWizardCompleted = true`.
7. API key: `POST /Auth/Keys?app=media-stack`, que exige `RequiresElevation` y devuelve 204 sin cuerpo; después `GET /Auth/Keys` para leerla ([`ApiKeyController.cs`](https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Api/Controllers/ApiKeyController.cs) L36-L60). Hace falta un token de admin, que se obtiene con `POST /Users/AuthenticateByName` usando el usuario/contraseña del paso 3. Para no crear claves duplicadas en cada ejecución, se busca en `GET /Auth/Keys` una con `AppName == "media-stack"`.

Cómo saber si ya está completado: `GET /System/Info/Public` (sin autenticación) devuelve `StartupWizardCompleted` ([`PublicSystemInfo.cs`](https://github.com/jellyfin/jellyfin/blob/master/MediaBrowser.Model/System/PublicSystemInfo.cs) L53). Si vale `true`, se omiten los pasos 1-6.

## 2. Seerr: configuración sin asistente

Repositorio: [seerr-team/seerr](https://github.com/seerr-team/seerr) (rama `develop`).

- **Fichero de settings**: `${CONFIG_DIRECTORY}/settings.json`, y si esa variable no está definida, `config/settings.json` ([`server/lib/settings/index.ts`](https://github.com/seerr-team/seerr/blob/develop/server/lib/settings/index.ts) L396-L398). `public.initialized` empieza en `false` (L467).
- **API key fijable por entorno**: si existe la variable `API_KEY`, sustituye a `main.apiKey` (L853-L861). Si no, la genera. **Así el wiring script conoce la clave de Seerr de antemano, sin leerla.**
- **Autenticación por API**: en el middleware, la cabecera `X-API-Key` igual a `settings.main.apiKey` autentica como admin ([`server/middleware/auth.ts`](https://github.com/seerr-team/seerr/blob/develop/server/middleware/auth.ts) L13). `/api/v1/settings/*` exige `Permission.ADMIN` ([`server/routes/index.ts`](https://github.com/seerr-team/seerr/blob/develop/server/routes/index.ts) L156).
- **Primer admin y Jellyfin**: `POST /api/v1/auth/jellyfin` con `{username, password, hostname, port, urlBase, useSsl, email, serverType}` ([`server/routes/auth.ts`](https://github.com/seerr-team/seerr/blob/develop/server/routes/auth.ts) L246 y siguientes). Si no hay Jellyfin configurado y no hay usuarios, inicia sesión en Jellyfin, crea el admin de Seerr, **crea él mismo una API key en Jellyfin (`createApiToken('Seerr')`)** y guarda `settings.jellyfin.{ip,port,urlBase,useSsl,apiKey}` (L360-L430). Si ya hay hostname configurado, responde "Jellyfin hostname already configured" (L274-L277). `serverType` es el enum `MediaServerType` (JELLYFIN).
- **Bibliotecas**: `POST /api/v1/settings/jellyfin/library/sync`, y después `PUT /api/v1/settings/jellyfin/library/:libraryId` con `{enabled:true}` ([`server/routes/settings/index.ts`](https://github.com/seerr-team/seerr/blob/develop/server/routes/settings/index.ts) ~L365-L400).
- **Radarr/Sonarr**: `GET/POST /api/v1/settings/radarr`, `PUT /api/v1/settings/radarr/:id` ([`server/routes/settings/radarr.ts`](https://github.com/seerr-team/seerr/blob/develop/server/routes/settings/radarr.ts) L9, L15, L77), y lo mismo para `/sonarr`. `GET /settings/radarr/:id/profiles` (L111) da los perfiles de calidad. Los campos (`hostname, port, apiKey, useSsl, baseUrl, activeProfileId, activeProfileName, activeDirectory, is4k, isDefault, …`) se pueden consultar en la interfaz `RadarrSettings` de `server/lib/settings/index.ts`.
- **Cerrar el asistente**: `POST /api/v1/settings/initialize` (admin) pone `public.initialized = true` (settings/index.ts L871-L880).
- **Detección**: `GET /api/v1/settings/public` (sin autenticación, routes/index.ts L113) devuelve `initialized`.
- **Alternativa**: pre-escribir `settings.json`. Se puede, porque se lee con `JSON.parse` y se completan `apiKey` y `clientId` si faltan (L850-L865), pero hay que replicar el esquema completo y nos acoplamos a él. Solo sembraríamos si el fichero no existe. Por API es más robusto.

## 3. API keys y credenciales predefinidas

### Radarr / Sonarr / Prowlarr
- `Bootstrap.cs` construye la configuración con `.AddXmlFile(config.xml)` seguido de `.AddEnvironmentVariables()` ([Radarr `src/NzbDrone.Host/Bootstrap.cs`](https://github.com/Radarr/Radarr/blob/develop/src/NzbDrone.Host/Bootstrap.cs) L262-L265) y enlaza `AuthOptions` a la sección `Radarr:Auth` (L114). En variables de entorno, `:` se escribe `__`, así que queda **`RADARR__AUTH__APIKEY`**, `SONARR__AUTH__APIKEY` y `PROWLARR__AUTH__APIKEY`.
- `ConfigFileProvider.ApiKey` devuelve `_authOptions.ApiKey ?? GetValue("ApiKey", GenerateApiKey())` ([Radarr L189-L199](https://github.com/Radarr/Radarr/blob/develop/src/NzbDrone.Core/Configuration/ConfigFileProvider.cs); [Sonarr L190](https://github.com/Sonarr/Sonarr/blob/main/src/NzbDrone.Core/Configuration/ConfigFileProvider.cs); en Prowlarr el mismo patrón). `AuthOptions` también expone `Enabled`, `Method`, `Required` y `TrustCgnatIpAddresses` ([AuthOptions.cs](https://github.com/Radarr/Radarr/blob/develop/src/NzbDrone.Common/Options/AuthOptions.cs)).
- Versión en que se introdujo:
  - Radarr: commit [7f03a91](https://github.com/Radarr/Radarr/commit/7f03a916f1ba011d25107d37a3fa6f83ccc679e9) (#9985), release [v5.5.3.8819](https://github.com/Radarr/Radarr/releases/tag/v5.5.3.8819) (2024-05-12).
  - Sonarr: commit [d051dac](https://github.com/Sonarr/Sonarr/commit/d051dac12c8b797761a0d1f3b4aa84cff47ed13d) (2024-04-28). Figura en las notas de las releases v4.0.4.1572 a v4.0.5.1710 (abril-mayo 2024).
  - Prowlarr: commit [04bb0c5](https://github.com/Prowlarr/Prowlarr/commit/04bb0c51b1b45fcc7f99d07ad4723ef7a55ca89b), release [v1.17.2.4511](https://github.com/Prowlarr/Prowlarr/releases/tag/v1.17.2.4511).

  Las tres versiones del stack (radarr 6.3, sonarr 4.0.19, prowlarr 2.x) ya lo incluyen.
- Alternativa equivalente: pre-sembrar `config.xml` con `<ApiKey>`. Se lee como fuente XML y, si la clave existe, no se regenera (ConfigFileProvider L193).

### Bazarr
- `config.yaml` usa Dynaconf con validadores. `auth.apikey` tiene como valor por defecto `hexlify(os.urandom(16))` (32 hex) **solo si falta** ([`bazarr/app/config.py`](https://github.com/morpheus65535/bazarr/blob/master/bazarr/app/config.py) L185). Un valor pre-sembrado se respeta.
- En el mismo fichero están las claves de conexión: `general.use_sonarr`/`use_radarr` (L113-L114), `sonarr.ip/port/base_url/apikey` (L214-L220) y `radarr.ip/port/base_url/apikey` (L238-L244). **Por tanto Bazarr se conecta a Radarr/Sonarr solo pre-sembrando `config.yaml`**, sin API REST. Solo hay que escribirlo si no existe; si existe, basta con rellenar las claves vacías.

### qBittorrent (linuxserver)
- README de linuxserver: al arrancar se imprime en el log una contraseña temporal para `admin`, y si no se cambia **se genera otra en cada arranque** ([README L68-L70](https://github.com/linuxserver/docker-qbittorrent/blob/master/README.md)).
- Fijarla: `WebUI\Password_PBKDF2="@ByteArray(<salt_b64>:<hash_b64>)"` en `qBittorrent.conf`, con PBKDF2-HMAC-SHA512, 100 000 iteraciones, salt de 16 bytes y hash de 64 bytes ([`src/base/utils/password.cpp`](https://github.com/qbittorrent/qBittorrent/blob/master/src/base/utils/password.cpp) L50-L53, L93-L111). Se puede calcular con `hashlib.pbkdf2_hmac('sha512', pw, salt, 100000, 64)`. `WebUI\Username` define el usuario. El formato `@ByteArray(...)` es la serialización de QSettings.
- Bypass de autenticación ([`src/base/preferences.cpp`](https://github.com/qbittorrent/qBittorrent/blob/master/src/base/preferences.cpp) L789-L830):
  - `WebUI\LocalHostAuth=false` quita la autenticación para 127.0.0.1. No sirve entre contenedores porque las peticiones no llegan desde localhost.
  - `WebUI\AuthSubnetWhitelistEnabled=true` + `WebUI\AuthSubnetWhitelist=172.x.0.0/16` quita la autenticación para la subred de la red Docker. Así Radarr y Sonarr se conectan sin credenciales.

## 4. Endpoints de wiring

Todas las apps *arr autentican con la cabecera `X-Api-Key`. Radarr y Sonarr usan `/api/v3`; Prowlarr, `/api/v1`. Los recursos "provider" (download clients, applications, indexer proxies) siguen el patrón `ProviderControllerBase`: `GET /schema` da la plantilla de campos, y `POST` crea (admite `?forceSave=true` para saltarse el test de conexión).

| Qué | Endpoint | Cuerpo clave | Fuente |
|---|---|---|---|
| qBittorrent en Radarr | `POST /api/v3/downloadclient` | `implementation:"QBittorrent"`, `configContract:"QBittorrentSettings"`, `fields: host, port, username, password, movieCategory:"radarr"` | [DownloadClientController.cs](https://github.com/Radarr/Radarr/blob/develop/src/Radarr.Api.V3/DownloadClient/DownloadClientController.cs); [QBittorrentSettings.cs](https://github.com/Radarr/Radarr/blob/develop/src/NzbDrone.Core/Download/Clients/QBittorrent/QBittorrentSettings.cs) |
| qBittorrent en Sonarr | `POST /api/v3/downloadclient` | igual, con `tvCategory:"tv-sonarr"` | [QBittorrentSettings.cs](https://github.com/Sonarr/Sonarr/blob/main/src/NzbDrone.Core/Download/Clients/QBittorrent/QBittorrentSettings.cs) |
| Root folders | `GET/POST /api/v3/rootfolder` | `{path:"/data/media/movies"}` | [RootFolderController.cs](https://github.com/Radarr/Radarr/blob/develop/src/Radarr.Api.V3/RootFolders/RootFolderController.cs) |
| Radarr/Sonarr en Prowlarr | `POST /api/v1/applications` | `implementation:"Radarr"`/`"Sonarr"`, `syncLevel:"fullSync"`, `fields: prowlarrUrl, baseUrl, apiKey` | [ApplicationController.cs](https://github.com/Prowlarr/Prowlarr/blob/develop/src/Prowlarr.Api.V1/Applications/ApplicationController.cs) (`[V1ApiController("applications")]`) |
| Tag para FlareSolverr | `GET/POST /api/v1/tag` | `{label:"flaresolverr"}` | [TagController](https://github.com/Prowlarr/Prowlarr/tree/develop/src/Prowlarr.Api.V1/Tags) |
| FlareSolverr como proxy | `POST /api/v1/indexerProxy` | `implementation:"FlareSolverr"`, `fields: host:"http://flaresolverr:8191/", requestTimeout`, `tags:[id]` | [IndexerProxyController.cs](https://github.com/Prowlarr/Prowlarr/blob/develop/src/Prowlarr.Api.V1/IndexerProxies/IndexerProxyController.cs) |
| Bazarr ↔ Radarr/Sonarr | pre-sembrar `config.yaml` (ver §3) | `general.use_radarr: true`, `radarr.ip: radarr`, `radarr.apikey` | [config.py](https://github.com/morpheus65535/bazarr/blob/master/bazarr/app/config.py) L113-L244 |

Idempotencia: cada paso lista primero (`GET`) y compara por nombre, ruta o `implementation`. Si ya existe, lo deja como está, porque el requisito de #9 es no sobrescribir nunca.

## 5. Recyclarr y alternativas

**Recyclarr, en breve**: es una herramienta CLI que lee un YAML y sincroniza en Radarr/Sonarr los ajustes de calidad recomendados por las [TRaSH Guides]: custom formats, quality profiles y tamaños de calidad. Así no hay que copiarlos a mano desde la web. Solo gestiona la calidad; no toca download clients, indexers ni root folders. Repo: [recyclarr/recyclarr](https://github.com/recyclarr/recyclarr) ("Automatically sync TRaSH Guides to your Sonarr and Radarr instances"). Último release: **v8.7.2 (2026-09-03)**; activo.

| Herramienta | ¿Wiring? | Último release | Estado |
|---|---|---|---|
| [Configarr](https://github.com/raydak-labs/configarr) | **Sí**: además de TRaSH/calidad tiene módulos `src/downloadClients`, `src/rootFolder`, `src/delayProfiles`, `src/remotePaths` y `src/prowlarr` (`applicationSync.ts`, `indexerProxySync.ts`, `tagSync.ts`) ([árbol del repo](https://github.com/raydak-labs/configarr/tree/main/src)). Ojo: incluye lógica para borrar clientes no gestionados (`unmanagedToDelete` en `downloadClientBase.ts`); habría que verificar que quede desactivada. | v1.33.0 (2026-09-29) | Muy activo |
| [Profilarr](https://github.com/Dictionarry-Hub/profilarr) | No: plataforma de gestión de perfiles y custom formats con UI | v2.2.0 (2026-08-17) | Activo |
| [Buildarr](https://github.com/buildarr/buildarr) | Sí en teoría: configura el stack completo, con plugins para Sonarr, Radarr y Prowlarr | v0.7.1 (2023-11-13); último push 2024-05-04; plugin prowlarr v0.5.3 (2024-04-28) | **Abandonado de facto** |
| [Flemmarr](https://github.com/Flemmarr/Flemmarr) | Sí, de forma genérica: aplica un YAML a la API de cualquier *arr ([README](https://github.com/Flemmarr/Flemmarr/blob/master/README.md)) | Sin releases en GitHub; último push 2024-01-26 | **Inactivo** |

Fechas obtenidas de la API de GitHub (`/releases/latest`, `pushed_at`) el 2026-09-30.

## Implicaciones para #9

1. **Cero API keys para el Operador en las *arr**: el asistente de `.env` genera aleatoriamente `RADARR__AUTH__APIKEY`, `SONARR__AUTH__APIKEY`, `PROWLARR__AUTH__APIKEY` y el `API_KEY` de Seerr, y los inyecta en cada contenedor y en el contenedor de wiring. Nadie tiene que leer ni copiar claves.
2. **Bazarr**: el wiring (o un init) siembra `config.yaml` con `auth.apikey`, `use_radarr`/`use_sonarr`, host y claves, solo si el fichero no existe o las claves están vacías. Hay que arrancarlo después de la siembra, o reiniciarlo.
3. **qBittorrent**: sembrar `qBittorrent.conf` antes del primer arranque con `WebUI\AuthSubnetWhitelistEnabled=true` y la subred de la red Docker del compose (conviene fijar la subred en el compose). Opcionalmente, también `Password_PBKDF2` a partir de una contraseña generada en `.env`, para no depender de la temporal del log. Si el fichero ya existe, no se toca.
4. **Jellyfin**: si `GET /System/Info/Public` devuelve `StartupWizardCompleted=false`, ejecutar la secuencia `/Startup/*` con admin y contraseña del `.env`, luego crear las bibliotecas movies/tvshows y marcar completado. Si devuelve `true`, no hacer nada. La API key de Jellyfin no hace falta generarla aparte: Seerr la crea en `POST /auth/jellyfin`.
5. **Seerr**: si `GET /api/v1/settings/public` devuelve `initialized=false`, llamar a `POST /auth/jellyfin` con las credenciales admin de Jellyfin, sincronizar y habilitar bibliotecas, `POST /settings/radarr` y `/settings/sonarr` (el perfil se obtiene de `/:id/profiles`) y `POST /settings/initialize`. Mejor por API que pre-escribiendo `settings.json`.
6. **Radarr/Sonarr/Prowlarr**: en cada recurso, `GET` y crear solo lo que falte: root folders, qBittorrent con categoría, apps en Prowlarr con `fullSync`, y el tag `flaresolverr` con el indexer proxy. Los indexers en sí quedan en manos del Operador.
7. **Herramienta**: un script propio pequeño (bash+curl o Python) en un contenedor one-shot (`restart: "no"`) es lo más simple. Por sí solo cumple el requisito de sembrar sin sobrescribir; Configarr lo cubre en parte, pero su modelo es reconciliar el estado (con opción de borrar lo no gestionado), no sembrar una sola vez. Recyclarr o Configarr quedan como posible issue aparte para los perfiles de calidad TRaSH. Buildarr y Flemmarr se descartan por estar abandonados.
8. **Esperas**: el script espera a cada servicio: `/ping` en las *arr, `/System/Info/Public` en Jellyfin y `/api/v1/status` en Seerr. Cada paso tiene que ser idempotente para que volver a ejecutarlo sea seguro.
