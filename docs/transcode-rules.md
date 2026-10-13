# Reglas de compresión y protección de torrents

Esta guía reúne las condiciones implementadas por el [plugin de Tdarr](../stacks/transcode/plugins/Tdarr_Plugin_custom_NVENC_HEVC_Compress.js), sus límites y las decisiones que corresponden al Operador. La configuración de cada Instancia puede diferir de los valores de la Plantilla. Para configurar el Worker y la biblioteca, ver [transcode.md](transcode.md).

## Qué decide el plugin NVENC de la Plantilla

Esta sección describe el plugin clásico incluido en el repositorio; un Flow o
un plugin de otra GPU puede añadir o cambiar condiciones. Ver [configuración de
Flows](transcode.md#classic-plugins-y-flows-seleccionar-el-método).

Las comprobaciones se realizan en este orden. La primera que falla termina la evaluación del archivo.

| Condición | Resultado |
| --- | --- |
| Tdarr no identifica el archivo como vídeo (`fileMedium !== 'video'`) | Omitir |
| Tamaño inferior a `minSizeGB` | Omitir |
| No se puede consultar el archivo con `statSync` | Omitir y registrar el error |
| Más de un hardlink (`nlink > 1`) | Omitir |
| Supera las comprobaciones anteriores | Recodificar el vídeo a HEVC con NVENC |

- `minSizeGB` vale **10** por defecto. Aunque la interfaz dice GB, el cálculo usa **GiB**: `file_size` en MiB dividido entre 1024. Un archivo exactamente igual al mínimo pasa la comprobación.
- `quality` vale **18** por defecto y se usa como CQ con VBR y `-b:v 0`. El preset NVENC es `p7`, tuning `hq`. Un CQ mayor pide menor calidad; el tamaño final depende del contenido. Ver la [política conservadora por bitrate](transcode-quality.md) para el Flow y su validación de salida.
- El tamaño que evalúa el plugin procede de los metadatos de Tdarr; los hardlinks se consultan en el sistema de archivos en el momento de ejecutar el plugin.
- El vídeo se vuelve a codificar aunque ya sea HEVC. No hay filtro por bitrate, duración, resolución, HDR, Dolby Vision ni ahorro esperado. Tampoco hay una comprobación propia de «ya comprimido».
- Se solicita decodificación CUDA y codificación NVIDIA `hevc_nvenc`. Tener una GPU Intel/AMD en el servidor no satisface este requisito del plugin.
- La salida es MKV; se copian audio y subtítulos. El mapeo `0:V` excluye imágenes adjuntas. El mapeo de audio, subtítulos y adjuntos es opcional (`?`); se copian también adjuntos, metadatos y capítulos.
- `reQueueAfter` es `false`. El plugin no calcula el ahorro ni verifica por sí mismo que la salida sea más pequeña, conserve el HDR o reproduzca correctamente. Las comprobaciones y el reemplazo final dependen de Tdarr y su configuración.
- El mínimo acepta valores finitos no negativos; **0** permite que el Flow seleccione por bitrate. CQ acepta valores entre 1 y 51. Los inputs inválidos omiten el archivo.

## Qué significa un hardlink

Con la [topología de `/data`](wiring.md#data-y-hardlinks), Radarr/Sonarr pueden importar un archivo mediante hardlink. La ruta de descargas y la ruta de la Biblioteca apuntan entonces al mismo inode, sin duplicar los datos.

| Situación | Qué puede decidir el plugin |
| --- | --- |
| Archivo en descargas y Biblioteca unidos por hardlink | Ve al menos dos enlaces y lo omite si llega a esa comprobación |
| Torrent pausado o detenido, conservando ambos enlaces | También lo omite; no distingue estados de qBittorrent |
| Torrent eliminado de qBittorrent, pero archivo de descarga conservado | Puede seguir omitiéndolo porque queda el segundo enlace |
| Archivo de descarga eliminado y Biblioteca conservada | Puede quedar con un enlace y pasar a ser candidato |
| Importación mediante copia independiente | Puede ver un enlace en la Biblioteca aunque el torrent siga en qBittorrent |
| Otro hardlink creado para cualquier uso | Lo omite aunque no haya ningún torrent |
| Worker accediendo por SMB que informa incorrectamente de un solo enlace | Puede seleccionar un archivo que debía excluir |

Por tanto, **un enlace no demuestra que la película esté fuera de qBittorrent**, y varios enlaces no demuestran que se esté sembrando. El plugin no consulta qBittorrent, trackers, categorías, etiquetas, ratio ni tiempo de siembra.

Antes de habilitar trabajos, comprobar desde el Worker que un archivo grande importado con hardlink y todavía presente en descargas muestra más de un enlace. El resultado observado desde el servidor no sustituye esta comprobación a través del SMB del Worker.

## «Solo películas que no estén en qBittorrent»

Es una política posible, pero **no está implementada como condición directa**. Para aplicarla hacen falta dos restricciones adicionales:

1. Limitar la biblioteca de Tdarr a las carpetas de películas: una biblioteca que apunte a `/data/media` puede incluir también series. El plugin solo distingue vídeo de otros medios.
2. Añadir una comprobación de pertenencia a qBittorrent antes de autorizar la compresión. Debe excluir los archivos de todos los torrents presentes, incluidos los pausados, detenidos o con error, si la regla es «no estar en qbit».

La correspondencia debe considerar todos los archivos de torrents multifichero, traducir rutas entre descargas, Biblioteca y Worker, e identificar las importaciones con nombres cambiados. Un hardlink permite comparar dispositivo e inode donde ambos sean accesibles; para copias independientes hace falta una correspondencia fiable del historial de importación u otra evidencia. Comparar únicamente el título o el nombre del torrent no basta.

Si qBittorrent no responde o la correspondencia queda dudosa, esa protección debería omitir el archivo. También debería comprobarlo cerca del inicio del trabajo, porque un dry-run es una fotografía y puede quedar obsoleto. Estas son condiciones de una futura protección, no garantías del plugin actual.

Mientras tanto, el filtro por hardlinks sirve como protección parcial cuando las importaciones son realmente hardlinks y el Worker ve correctamente sus contadores. Bajar el mínimo de tamaño no mejora ni empeora la fiabilidad de esa identificación; amplía los archivos que llegan a ella.

## Trackers privados, seeding y limpieza

Tdarr no valida obligaciones de ratio, tiempo mínimo ni hit-and-run. Que un archivo sea candidato no demuestra que el torrent se haya retirado cumpliendo las reglas del tracker.

- Las [normas de SeedCore aportadas por el Operador](seedcore.md) exigen 72 horas acumuladas **o** ratio 1:1 en 20 días para descargas; freeleech no exime del seeding. Las obligaciones de quien publica son distintas. Esto documenta la regla, no confirma su aplicación en las apps.
- Las [normas de Torrenteros aportadas por el Operador](torrenteros.md) exigen 72 horas por descarga, con ratio mínimo de cuenta 0,25 contabilizado por el tracker. Ratio 1:1 no sustituye ese tiempo. Quien publica tiene la condición distinta de 170 horas o tres seeders.
- Los límites efectivos se configuran en las apps de la Instancia y deben comprobarse con las reglas vigentes de cada tracker. La Plantilla no establece aquí un mínimo universal.
- Retirar un torrent y borrar sus datos son acciones distintas: lo primero cambia su presencia en qBittorrent; lo segundo puede reducir los hardlinks y habilitar la compresión.
- [Cleanuparr](profiles.md#seeding) puede limpiar descargas; [Maintainerr](profiles.md#cleanup) puede borrar elementos de la Biblioteca según las reglas del Operador. Sus acciones pueden cambiar qué enlaces quedan. Su presencia no demuestra que tengan reglas activas ni que respeten las obligaciones de un tracker concreto.
- Revisar las reglas de limpieza y eliminación automática junto con las de compresión. No retirar torrents para hacerlos candidatos antes de cumplir las obligaciones de seeding.
- La [investigación sobre trackers privados](research/private-trackers-admin-only.md) contiene datos y propuestas fechadas; no sustituye la comprobación de las normas vigentes ni constituye configuración aplicada.

## Política elegida: públicos frente a privados

El Operador ha elegido separar la retirada según el tipo de torrent. La retirada
pública y el etiquetado de privados están activados en qui en la Instancia revisada
el 12 de octubre de 2026. Las reglas de retirada privada siguen pendientes. Ninguna
de estas condiciones de retirada está implementada en el plugin de Tdarr.

| Tipo | Condición para poder retirar de qBittorrent |
| --- | --- |
| Público confirmado | Al menos **72 horas acumuladas de seeding**, sin exigir ratio ni condición de popularidad |
| Privado de SeedCore descargado | Exigir **ratio mínimo 1:1** antes de retirar, aunque ya haya sembrado 72 horas; además, cumplir la obligación del tracker dentro de su plazo |
| Otro privado | Cumplir las condiciones específicas de ese tracker; no aplicar la regla pública |
| Tipo desconocido, metadatos pendientes o clasificación dudosa | Conservar y revisar |
| Torrent publicado por el Operador | Aplicar la obligación de uploader, no asumir la de descarga |

**Excepción por popularidad solo para privados:** conservar el torrent si el
tracker informa de **al menos cinco leechers**, aunque ya cumpla el tiempo o ratio
de retirada. Usar el número total reportado por el tracker, no solo los leechers
conectados al cliente. Con menos de cinco puede volver a evaluarse para retirada;
esta excepción no fija una conservación permanente. Si el dato no está disponible
o hay errores del tracker, conservar y revisar en vez de asumir cero demanda.

Para públicos, alcanzar ratio 1 antes de las 72 horas **no autoriza la retirada**.
Para SeedCore, la política actual del Operador es más exigente que el mínimo del
tracker: **las 72 horas por sí solas no autorizan la retirada**. Se conserva la
[referencia de la guía](seedcore.md#descargas-obligaciones-de-seeding), que permite
72 horas acumuladas **o** ratio 1:1 dentro de 20 días. Ese plazo es para cumplir la
obligación del tracker, no una fecha de eliminación automática; si el ratio aún no
llega a 1, la política elegida mantiene el torrent.
Usar tiempo de seeding, no antigüedad desde que se añadió ni desde que terminó la
descarga. Las categorías de películas o series no identifican si un torrent es
público o privado.

### Regla pública que preparar en qui

#### Trackers privados identificados por el Operador

| Tracker | Dominio indicado | Política de retirada |
| --- | --- | --- |
| SeedCore | `seedcore.net` y sus subdominios | Ratio mínimo 1:1, conservando con cinco o más leechers |
| Torrenteros | `torrenteros.org` y sus subdominios | Guía: 72 horas por descarga y ratio de cuenta mínimo 0,25; retirada automática pendiente de política y validación |
| MyAnonamouse | `t.myanonamouse.net` (dominio raíz `myanonamouse.net`) | Sin retirada automática hasta definir sus condiciones |

Estos dominios identifican trackers privados y no deben tratarse como públicos.
La regla pública preparada sigue usando `PRIVATE = false` y 72 horas de seeding;
no se han añadido objetivos adicionales de ratio o popularidad. Antes de activarla,
contrastar la marca `PRIVATE` con los trackers de cada torrent: cualquier
contradicción requiere revisar la clasificación. Para reglas privadas por dominio,
comparar el hostname exacto o un subdominio del dominio raíz, no coincidencias
parciales arbitrarias. No guardar URLs de announce con passkeys en el repositorio.

La [documentación de automatizaciones de qui](https://getqui.com/docs/features/automations/)
incluye la condición booleana `Private`, el campo `Seeding Time` en segundos,
condiciones combinadas y ejecución en dry-run. Verificar su disponibilidad y
comportamiento en la versión instalada antes de guardar la regla.

El [payload de ejemplo](../examples/qui/publicos-72h.dry-run.json.example) está preparado
según el [modelo de qui v1.31.1](https://github.com/autobrr/qui/blob/v1.31.1/internal/models/automation.go)
y su [API de automatizaciones](https://github.com/autobrr/qui/blob/v1.31.1/internal/api/handlers/automations.go).
Es un cuerpo para crear una regla mediante API, no un archivo de importación de
interfaz validado. Los ejemplos incluyen `enabled: false` y `dryRun: true`, aunque
las reglas equivalentes se activaron en la Instancia durante la validación.

El 12 de octubre de 2026 se comparó el dry-run del motor de qui con una simulación
mediante la API de qBittorrent. Ambos seleccionaron los mismos candidatos públicos.
Se comprobó que sus vídeos tenían hardlinks en la Biblioteca y, tras una retirada
manual autorizada de esos candidatos, se verificó que los vídeos permanecían
intactos. El dry-run posterior de la regla con protección por etiquetas no encontró
nuevos candidatos. Estos resultados no prueban todos los casos de detección de
cross-seeds ni equivalen a probar la eliminación periódica de qui con datos
compartidos. Los inventarios se conservaron fuera del repositorio.

La selección deseada combina con **AND**:

- Torrent identificado como público (`Private = false`).
- Tiempo de seeding **mayor o igual a 259200 segundos** (72 horas; 4320 minutos).

No añadir objetivos de ratio o popularidad ni filtros de estado o importación a
la selección pública. La etiqueta descrita a continuación sirve exclusivamente
para conservar vínculos con privados, no como objetivo adicional de seeding. Las comprobaciones de conservación de la Biblioteca y
archivos
compartidos sirven para verificar cómo ejecutar el borrado sin afectar a otros
torrents; no son objetivos adicionales de seeding.

**Excepción elegida para archivos compartidos con privados:** si un torrent público
comparte algún archivo con un privado, conservar también la entrada del público;
la retirada queda pendiente de las condiciones del privado. Si no comparte con
privados, retirarlo tras las 72 horas. La acción
`deleteWithFilesPreserveCrossSeeds` por sí sola no garantiza esta excepción:
puede retirar la entrada pública conservando los datos. La regla activa añade
`CROSS_SEED_TAGS NOT_EQUAL proteger-privado`, con coincidencia exacta de etiqueta.
Los ejemplos del repositorio siguen desactivados y en dry-run para permitir su
revisión antes de aplicarlos a otra Instancia.

### Automatizaciones nativas de qui activadas

El Operador eligió usar exclusivamente qui, sin scripts locales ni tareas cron:

1. **Privados — etiqueta de protección**, cada 60 segundos: con `PRIVATE = true`,
   añade `proteger-privado` conservando las demás etiquetas. Está ordenada antes
   de la retirada. Ver [ejemplo](../examples/qui/privados-etiqueta.dry-run.json.example).
2. **Públicos — retirar tras 72 h de seeding**, cada 900 segundos: combina
   `PRIVATE = false`, `SEEDING_TIME >= 259200` y
   `CROSS_SEED_TAGS NOT_EQUAL proteger-privado`. Usa la acción
   `deleteWithFilesPreserveCrossSeeds`. No retira privados ni aplica ratio o
   popularidad a públicos.

La etiqueta de protección debe reservarse para privados y no quitarse manualmente.
La condición consulta las etiquetas del torrent y de sus cross-seeds detectados.
Si alguno tiene la etiqueta, conserva la entrada pública y sus datos.

**Límites de esta opción elegida:** qui detecta esos vínculos por rutas, nombres y
metadatos de release; no verifica aquí cualquier inode compartido ni todos los
solapamientos parciales entre episodios y packs. Puede detectar releases similares
que sean copias independientes, o no detectar un hardlink con metadatos distintos.
El etiquetado y la retirada usan evaluaciones periódicas y cachés, no una operación
atómica: un privado recién añadido puede tardar en tener etiqueta y en aparecer
en la detección. El orden y la mayor frecuencia de etiquetado reducen esa ventana,
pero no garantizan que desaparezca. No interpretar esta opción como una comprobación
completa de archivos compartidos con privados.

Antes de activar, se verificó que todos los privados existentes tenían la etiqueta
y que ningún público la tenía. La simulación adicional sin mínimo temporal produjo
el mismo conjunto de públicos con y sin protección: no había un caso positivo de
exclusión por etiqueta detectado para validar ese comportamiento en el inventario.
No se crearon torrents de prueba en producción.

La acción prevista es retirar el torrent **y sus archivos de descargas**, conservando
el archivo importado en la Biblioteca. Si la importación es un hardlink, borrar el
enlace de descargas deja el de la Biblioteca; no usar rutas de la Biblioteca como
destino de borrado. No basta con quitar solo la entrada del cliente, porque podría
quedar el segundo enlace y Tdarr seguiría omitiendo el archivo.

Primero revisar el resultado en dry-run: puede haber torrents antiguos que cumplan
la regla en cuanto se active. No expandir una regla pública para borrar también
cross-seeds privados. Confirmar las protecciones de archivos compartidos de la
herramienta antes de activar la eliminación.

### Compresión posterior

Una retirada válida solo habilita la evaluación de Tdarr: el archivo todavía debe
cumplir sus filtros de vídeo, tamaño y hardlinks. El objetivo sigue siendo excluir
cualquier archivo asociado a un torrent presente en qBittorrent mediante la
comprobación explícita pendiente de implementación. La Biblioteca debe volver a
evaluarse después de la retirada; quitar el torrent no garantiza por sí solo que
Tdarr vuelva a procesar un archivo previamente omitido.

Evitar límites globales de ratio o inactividad que detengan públicos antes de las
72 horas. Revisar también las otras apps que puedan retirar torrents para que no
contradigan esta separación.

### Secuencia para activar la automatización

1. Auditar clasificación público/privado, límites efectivos de qBittorrent,
   importaciones, rutas compartidas y reglas de limpieza de las otras apps.
2. Preparar en qui el etiquetado de privados y la retirada pública en dry-run.
   Verificar el etiquetado antes de habilitar la retirada pública. Las reglas de
   retirada privada requieren una validación aparte: SeedCore exige ratio mínimo 1
   en la política elegida y conserva torrents con cinco o más leechers. Otros
   privados permanecen fuera hasta definir y validar su política de retirada, aunque
   ya se hayan documentado sus mínimos.
3. Revisar el listado de candidatos y motivos de conservación, incluidos los
   archivos compartidos entre torrents. No activar borrados durante esta revisión.
4. Seleccionar el método correcto en Tdarr y comprobar hardlinks desde el Worker
   antes de habilitar compresiones. La sesión adoptó el plugin comunitario de
   hardlinks en el Flow; la consulta explícita de pertenencia a qBittorrent sigue
   pendiente y no debe presentarse como una garantía implementada. Verificar
   también cómo se reevalúan los archivos omitidos después de la retirada.
5. Activar la retirada sobre el resultado revisado y comprobar que conserva la
   Biblioteca. Después habilitar la compresión, empezando con un archivo.

No configurar una pausa automática al alcanzar ratio o tiempo que impida seguir
sembrando los torrents protegidos por popularidad. El cumplimiento del mínimo y
la decisión de dejar de sembrar son condiciones separadas.

## Espacio de almacenamiento mientras se siembra

Un original de 20 GiB unido por hardlinks a descargas y Biblioteca ocupa unos
20 GiB, no 40. Si se conserva el original para seeding y se sustituye solo la
Biblioteca por un encode independiente de 8 GiB, se ocupan unos 28 GiB. Cuando
se elimina el último enlace al original, quedan los 8 GiB del encode.

Por eso comprimir mientras se conserva el original puede aumentar la ocupación.
La protección por hardlinks evita ese caso; eliminar solo la entrada de qBittorrent
conservando sus datos tampoco libera los bloques del original. Reservar además
espacio de caché y salida temporal para el trabajo.

## Cómo interpretar un dry-run

Un dry-run de decisión llama al plugin sin ejecutar FFmpeg, encolar trabajos ni modificar los ajustes. Debe indicar el umbral simulado, el alcance de archivos, los candidatos y el motivo de cada exclusión.

- Si usa la base de datos de Tdarr, cubre los archivos registrados, no necesariamente todos los vídeos que existen en disco.
- Puede refrescar tamaño y hardlinks para esa simulación; esto debe indicarse porque el plugin normal usa el tamaño registrado por Tdarr.
- La suma de tamaños de candidatos es el espacio que ocupan ahora, **no el ahorro esperado**.
- Simular 5 GiB no cambia el valor guardado en la biblioteca. Aplicarlo requiere editar `minSizeGB` en el stack de plugins de esa biblioteca.
- El resultado no verifica pertenencia a qBittorrent, cumplimiento del tracker, acceso del Worker, capacidad de la GPU ni calidad de la salida.
- Los informes con títulos y rutas de una Instancia quedan fuera de git; este documento recoge las reglas reutilizables, no el inventario personal.
