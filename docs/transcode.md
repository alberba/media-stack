# Transcodificación con un Worker

El Perfil `transcode` permite recodificar archivos grandes de la Biblioteca a HEVC para ahorrar espacio. La Instancia ejecuta el servidor de Tdarr, que organiza trabajos y tiene el nodo interno desactivado. La recodificación se realiza en un **Worker** con GPU NVIDIA, cuyo nodo de Tdarr lee y escribe la Biblioteca mediante SMB. Sin Worker, los trabajos quedan esperando.

El servidor expone la interfaz en el puerto **8265** y la conexión de los Workers en el **8266**. La Biblioteca se ve como `/data/media` y la caché como `/temp`; cada Worker usa un disco local para la caché.

## Qué se comprime

El plugin selecciona **vídeos grandes con un único hardlink**. Esto es un indicio indirecto, no una consulta a qBittorrent. Las [reglas de compresión y protección](transcode-rules.md) explican todas las condiciones y sus excepciones. Las normas de [SeedCore](seedcore.md) y [Torrenteros](torrenteros.md) distinguen las obligaciones de descarga y publicación.

La Plantilla monta en modo de solo lectura el plugin [`Tdarr_Plugin_custom_NVENC_HEVC_Compress`](../stacks/transcode/plugins/Tdarr_Plugin_custom_NVENC_HEVC_Compress.js). El servidor lo entrega a los nodos. Para cada archivo:

1. Omite lo que Tdarr no identifica como vídeo.
2. Omite tamaños inferiores a `minSizeGB`, cuyo valor predeterminado es **10 GiB**.
3. Omite archivos cuyo contador de hardlinks no pueda leer o sea mayor que uno. Borrar la entrada del torrent no elimina necesariamente el archivo de descarga ni su enlace. Las copias independientes y los contadores incorrectos por SMB pueden eludir esta protección.
4. Solicita recodificar el vídeo con NVENC HEVC, `quality` 24 por defecto, copiando audio y subtítulos a MKV. Tdarr gestiona el reemplazo del original.

Para cambiar la implementación, editar el plugin en la Plantilla y reiniciar `tdarr`. Para cambiar tamaño mínimo o calidad, editar sus inputs en la biblioteca de Tdarr. Simular otro mínimo en un dry-run no cambia esos ajustes.

## 1. Preparar la Instancia

1. Añadir `transcode` a `COMPOSE_PROFILES`, ejecutar `scripts/init.sh` y `docker compose up -d`. Abrir `http://<instancia>:8265`.
2. Opcionalmente, para exponer la GPU Intel/AMD de la Instancia a Jellyfin y Tdarr, definir `COMPOSE_FILE=compose.yaml:compose.gpu.yaml` y `RENDER_GID` en `.env`. Obtener el grupo con `getent group render | cut -d: -f3` y ejecutar `docker compose up -d`. El override añade `/dev/dri` y su grupo. En Jellyfin, activar VA-API o QSV en Dashboard > Playback. **Esto no sustituye la GPU NVIDIA que requiere el plugin NVENC.**
3. Compartir `DATA_ROOT/media` mediante SMB con lectura y escritura. Usar una cuenta SMB cuyos archivos pertenezcan a `PUID:PGID`, para conservar la propiedad de los archivos reemplazados por el Worker.
4. Crear una biblioteca en Libraries > Library +:
   - Fuente: `/data/media`, o carpetas separadas de películas y series. Para comprimir solo películas, seleccionar sus carpetas concretas.
   - Caché: `/temp`; cada Worker la traduce a su disco local.
   - En Transcode options, elegir explícitamente **Classic Plugins** o **Flows**. Para Classic, seleccionar únicamente el plugin local `Tdarr_Plugin_custom_NVENC_HEVC_Compress`. Para Flows, seguir la configuración de la siguiente sección; crear o asignar un Flow no cambia por sí solo el método seleccionado.
   - Comprobaciones de salud: Quick o desactivadas. También las ejecuta el Worker.
   - Activar vigilancia de carpetas o escaneos programados cuando se haya validado el funcionamiento.

## Classic Plugins y Flows: seleccionar el método

**Classic Plugins** ejecuta el stack de plugins de la biblioteca. **Flows** ejecuta
el diagrama seleccionado, que puede incluir un plugin clásico mediante
`Run Classic Transcode Plugin`. Ambas modalidades pueden coexistir como opciones
configuradas, pero el método seleccionado determina qué ejecuta cada trabajo.

Para una biblioteca con varias ramas de encoder, Flows permite poner la protección
común antes de elegir GPU. La Plantilla incluye el plugin NVENC, pero **no crea ni
activa automáticamente un Flow**, ni incluye el plugin VAAPI personalizado usado
en la sesión de validación. Una rama VAAPI requiere un plugin compatible instalado
por el Operador; el override de GPU por sí solo no lo proporciona.

### Comprobar hardlinks en el Flow

El plugin comunitario oficial
[`Check For Hardlinks`](https://github.com/HaveAGitGat/Tdarr_Plugins/blob/master/FlowPluginsTs/CommunityFlowPlugins/file/checkForHardlinks/1.0.0/index.ts)
consulta `stat` sobre el archivo de trabajo. Colocarlo **antes de codificar, copiar
el archivo a caché o dividir las ramas de GPU**, para comprobar el original y
proteger todos los encoders:

```text
Input File → Check File Size → Check For Hardlinks
                                ├─ 1: varios enlaces → Terminar sin comprimir
                                └─ 2: un enlace → Elegir encoder → Codificar → Replace Original File
```

La salida 1 también puede conectarse a `Replace Original File` en este punto:
si el archivo de trabajo conserva la misma ruta y tamaño que el original, el
plugin no realiza el reemplazo. No usar esa conexión como protección después de
haber modificado o copiado el archivo. Una salida terminal sin codificación expresa
más claramente la intención de omitirlo.

Los filtros de tamaño del Flow y los inputs del plugin clásico son independientes:
ajustar ambos si se desea cambiar el mínimo. La simulación con 5 GiB no cambió el
mínimo configurado de 10 GiB. Comprobar las unidades y las desigualdades del plugin
`Check File Size`; su condición no tiene por qué coincidir exactamente con la del
plugin clásico en el límite del tamaño.

### Evitar comprimir otra vez el mismo resultado

El plugin clásico NVENC fuerza la recodificación incluso de HEVC y no guarda una
marca de «ya comprimido». `reQueueAfter: false` no protege una nueva ejecución del
Flow. Añadir los plugins comunitarios oficiales
[`Check Skiplist`](https://github.com/HaveAGitGat/Tdarr_Plugins/blob/master/FlowPluginsTs/CommunityFlowPlugins/tools/processedCheck/1.0.0/index.ts)
y
[`Add To Skiplist`](https://github.com/HaveAGitGat/Tdarr_Plugins/blob/master/FlowPluginsTs/CommunityFlowPlugins/tools/processedAdd/1.0.0/index.ts):

```text
Input File → Check File Size → Check For Hardlinks → Check Skiplist
                                                      ├─ 2: registrado → Terminar
                                                      └─ 1: nuevo → Elegir encoder
                                                                      ↓
                                                                  Codificar
                                                                      ↓
                                                              Check File Changed
                                                      ├─ 2: sin cambios → Terminar
                                                      └─ 1: cambiado → Replace Original File
                                                                      ↓
                                                               Add To Skiplist
```

Las salidas de tamaño excluido y de varios hardlinks también terminan sin
codificar. Configurar **Check Type = `fileHash`** en ambos pasos de Skiplist y
**File To Add = `workingFile`** en `Add To Skiplist`. Se registra el contenido del
resultado después del reemplazo; una descarga diferente con la misma ruta sigue
siendo candidata. `Check File Changed` evita registrar como comprimido un archivo
que el plugin clásico omitió. Compartir estos pasos entre todas las ramas de GPU.

La huella SHA-256 requiere leer el archivo completo desde el Worker. Por eso la
consulta se coloca después de los filtros de tamaño y hardlinks. Los registros
persisten en los Datos de las apps de Tdarr y se consultan en Libraries → Skiplist;
borrarlos permite procesar de nuevo ese contenido. El Flow debe configurarse en
cada Instancia: Wiring no lo crea automáticamente.

La protección no registra retroactivamente los resultados anteriores. Antes de
añadirlos, contrastar el historial de transcodificación correcta con el tamaño y
la fecha de modificación actuales, y registrar la huella del resultado existente.
Estar en HEVC o figurar como «Not required» no demuestra que se haya comprimido.

Validación en Tdarr 2.94.02: una prueba aislada del grafo activo, usando los plugins
reales de Skiplist y un encoder simulado, reprodujo dos codificaciones antes del
cambio y una después. Las ramas NVENC y VAAPI verificaron que una descarga diferente vuelve a ser
candidata y que los originales omitidos no entran en Skiplist. No sustituye la
verificación de un trabajo completo en el Worker.

### Revisar los archivos omitidos cuando desaparezca otro hardlink

Un archivo omitido por hardlinks puede quedar en «Not required» aunque después
se elimine el archivo de descarga. `Find New` no garantiza que vuelva a ejecutar
el Flow para ese archivo. El script
[`recheck.py`](../stacks/transcode/recheck-hardlinks/recheck.py) revisa estos casos
desde la Instancia, con acceso local a la Biblioteca y los Datos de las apps:

- Selecciona vídeos de la biblioteca indicada en «Not required», con varios
  enlaces registrados y al menos 10 GiB, por defecto.
- Guarda las omisiones confirmadas por el último informe en
  `hardlink-omissions.json`, dentro de los Datos de las apps, incluso mientras
  siguen compartidas. La evidencia queda ligada a la biblioteca, revisión,
  tamaño y fecha del archivo, y permite revisarlo aunque Tdarr purgue el informe.
  Si no existe ni informe ni evidencia previamente guardada, no lo encola.
- Consulta `stat` localmente. Solo acepta archivos con un enlace, todavía por
  encima del mínimo y con tamaño y fecha de modificación iguales a los registrados.
- Comprueba otra vez el estado y que el archivo no esté en staging antes de cambiar
  únicamente `TranscodeDecisionMaker` a `Queued` mediante la
  [API de Tdarr](https://tdarr.readme.io/reference/post_cruddb).

El script lee SQLite en modo de solo lectura y consulta metadatos del sistema de
archivos; no lee el contenido de los vídeos ni vuelve a escanear toda la Biblioteca.
Antes de actuar, recorre las conexiones del Flow: exige hardlinks y Skiplist por
`fileHash` antes de cada encoder, comprobación de cambio antes del reemplazo y
registro del resultado `workingFile` después. Rechaza conexiones que eviten estas
protecciones, ciclos, pasos desactivados y plugins o versiones que no reconoce.
El Worker ejecutará el Flow habitual al recibir el trabajo, incluida su protección
de hardlinks y Skiplist. Los archivos ya comprimidos no se seleccionan para esta
revisión. Una descarga que haya cambiado el tamaño o la fecha requiere su escaneo
normal, porque el historial anterior ya no demuestra por qué se omitió.

Ejecutar primero sin `--apply` para obtener los contadores sin cambiar la cola:

```sh
python3 stacks/transcode/recheck-hardlinks/recheck.py \
  --tdarr-data-root /ruta/appdata/tdarr/server/Tdarr \
  --media-root /ruta/data/media \
  --library-id ID_DE_LA_BIBLIOTECA
```

`--server-media-root` vale `/data/media`; `--api-url` vale
`http://127.0.0.1:8265`. Si la API exige autenticación, proporcionar
`TDARR_API_KEY` mediante el entorno. Ajustar `--min-size-gib` cuando cambie el
mínimo del Flow.

Para programarlo cada hora, adaptar las rutas y el ID en el
[servicio de ejemplo](../examples/tdarr/hardlink-recheck.service.example), copiarlo
a `/etc/systemd/system/media-stack-tdarr-hardlinks.service` y copiar el
[timer](../examples/tdarr/hardlink-recheck.timer.example) a
`/etc/systemd/system/media-stack-tdarr-hardlinks.timer`. Después:

```sh
sudo systemctl daemon-reload
sudo systemctl start media-stack-tdarr-hardlinks.service
sudo systemctl enable --now media-stack-tdarr-hardlinks.timer
systemctl list-timers media-stack-tdarr-hardlinks.timer
journalctl -u media-stack-tdarr-hardlinks.service -n 10
```

El timer también revisa cinco minutos después de arrancar. Un bloqueo evita
ejecuciones simultáneas. Las escrituras de evidencia son atómicas y solo se realizan
con `--apply`; la simulación conserva el estado. Este mecanismo revisa archivos ya conocidos; la vigilancia
de carpetas o `Find New` siguen siendo necesarios para descubrir descargas nuevas.

### Dónde se ejecuta cada paso

Los pasos los ejecuta el Worker del nodo que recibe el trabajo, con sus rutas y su
vista del sistema de archivos. En un Worker remoto, `stat` consulta a través del
montaje SMB. No hace falta comparar el número de inode entre NAS y Worker para
comprobar `nlink`, pero sí verificar que el recurso transmite correctamente el
contador. Un nodo sin acceso al original no sirve para esta comprobación inicial.

Tdarr permite dirigir etapas a nodos mediante
[`Tags: Worker Type`](https://docs.tdarr.io/docs/plugins/flow-plugins/index/tools/Tags-%20Worker%20Type/).
Si SMB no informa bien de los enlaces, se puede estudiar una etapa de comprobación
en un nodo con acceso local al NAS y otra de codificación en el Worker GPU. Requiere
configurar ese nodo y verificar disponibilidad de las funciones en la versión y
licencia utilizadas; el servidor sin nodo interno no ejecuta esa etapa por sí solo.

### Activar y verificar Flows

1. Pausar los workers de transcodificación y dejar terminar el trabajo activo.
2. En Libraries → biblioteca → Transcode options, seleccionar **Flows**, elegir
   el diagrama y guardar. El nombre del diagrama puede mencionar «Classic Plugins»
   porque contiene ese tipo de plugin, aunque el método activo sea Flows.
3. Reanudar con un solo worker y revisar el informe de un archivo compartido.
   Debe ejecutar `Check For Hardlinks`, registrar varios enlaces y evitar ambos
   encoders. Los trabajos ya iniciados pueden conservar el modo anterior.
4. Comprobar que los trabajos nuevos muestran los pasos del Flow. En la API, la
   biblioteca observada cambió de `decisionMaker.settingsPlugin: true` y
   `settingsFlows: false` a `settingsPlugin: false` y `settingsFlows: true`.

Guardar el cambio se aplicó a los trabajos nuevos sin reiniciar Tdarr. Un scan puede
alimentar una cola que los workers activos comiencen a procesar: **no es un dry-run**.

## Diagnosticar una demora antes de comprimir

No atribuir una demora al último paso añadido sin consultar las marcas de tiempo
del informe. Separar:

1. Escaneo del original en el nodo, antes del Flow o plugin clásico.
2. Consulta de hardlinks y decisiones de filtros.
3. Codificación, comprobaciones y reemplazo.

En un job observado en Tdarr 2.94.02, el escaneo inicial tardó **49,056 segundos**
y el plugin NVENC registró inicio y fin de su ejecución en el mismo milisegundo,
omitiendo un archivo con dos enlaces. Ese log sitúa la demora antes del plugin;
no demuestra cuánto tarda cada lectura individual de metadatos. Los trabajos
posteriores ya usaban Flows y seguían mostrando una demora de unos 48 segundos
antes de ejecutar sus pasos.

La biblioteca tenía ExifTool y MediaInfo activados. Falta aislar qué herramienta,
lectura por SMB u otra operación provoca la espera. Comparar el mismo archivo
variando una opción de escaneo cada vez y revisar los tiempos antes/después; no se
han desactivado esos escáneres como solución comprobada. Conservar la protección
de hardlinks mientras se investiga.

## 2a. Worker Linux con Docker

Requisitos: Docker con Compose, controlador NVIDIA y [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html).

1. Montar el recurso SMB. Ejemplo para `/etc/fstab`, con credenciales en un archivo accesible solo por root que contenga `username=` y `password=`:

   ```text
   //<instancia>/media  /mnt/media-stack/media  cifs  credentials=/root/.smb-media-stack,uid=1000,gid=1000,vers=3.0,iocharset=utf8,_netdev,x-systemd.automount  0 0
   ```

   Ajustar `uid` y `gid` al `PUID` y `PGID` del Worker.
2. Obtener la Plantilla y completar el `.env` del Worker:

   ```sh
   git clone https://github.com/alberba/media-stack.git && cd media-stack/worker
   cp .env.example .env
   # Completar TDARR_SERVER_IP, TDARR_NODE_NAME y las rutas.
   python3 ../scripts/env_contract.py validate --scope worker --file .env
   docker compose up -d
   ```

No hacen falta traductores de rutas: el contenedor usa `/data/media` y `/temp`, igual que el servidor.

## 2b. Worker Windows con nodo nativo

Requisito: controlador NVIDIA.

1. Mapear el recurso como unidad, por ejemplo `M:` → `\\<instancia>\media`, activando la reconexión al iniciar sesión para la cuenta que ejecutará el nodo.
2. Descargar Tdarr desde [su página de descarga](https://tdarr.io/download) y ejecutar `Tdarr_Updater.exe`. La versión debe coincidir con la del servidor, indicada en `stacks/transcode/compose.yaml`.
3. Copiar [`worker/Tdarr_Node_Config.windows.json.example`](../worker/Tdarr_Node_Config.windows.json.example) a `Tdarr_Node\configs\Tdarr_Node_Config.json`, después de ejecutar el nodo una vez o sustituyendo el archivo creado. Ajustar:
   - `nodeName`: nombre único, por ejemplo `pc-3070-win`.
   - `serverURL` y `serverIP`: dirección de la Instancia.
   - `pathTranslators`: `/data/media` → `M:/` y `/temp` → una carpeta existente en un disco local rápido, por ejemplo `D:/tdarr-cache`.
4. Ejecutar `Tdarr_Node\Tdarr_Node.exe` o `Tdarr_Node_Tray.exe` para mantenerlo en la bandeja.

## Nombres y versiones de nodos

Cada nodo debe tener un nombre distinto. Si el mismo PC usa Linux y Windows, asignar nombres separados como `pc-3070-linux` y `pc-3070-win`. Cada sistema tiene sus propias rutas, configuración y FFmpeg; compartir nombre mezcla los ajustes y el historial en el servidor.

La versión del nodo debe coincidir siempre con la del servidor. Renovate actualiza conjuntamente las imágenes `tdarr` y `tdarr_node`. Actualizar el nodo de Windows con `Tdarr_Updater.exe` al mismo tiempo.

## Verificación antes de habilitar trabajos

1. Comprobar que el nodo aparece en Nodes y configurar un Worker de transcodificación GPU y cero Workers de transcodificación CPU.
2. Verificar **desde el Worker** que un archivo grande todavía compartido mediante hardlink muestra más de un enlace. El informe del plugin debe omitirlo por hardlinks. Si ve uno, detener los trabajos hasta resolver cómo el recurso SMB informa del contador.
3. Probar un archivo grande que ya no esté asociado a ningún torrent y comprobar reproducción, calidad, pistas y tamaño final en Jellyfin antes de procesar toda la Biblioteca.

La protección por hardlinks no garantiza que un archivo esté ausente de qBittorrent. La consulta explícita al cliente descrita en [las reglas](transcode-rules.md#solo-películas-que-no-estén-en-qbittorrent) sigue pendiente de implementación.
