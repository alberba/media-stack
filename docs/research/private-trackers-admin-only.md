# Trackers privados solo para el Operador (SeedCore y Torrenteros)

**Estado: investigación y propuesta de restricción de búsquedas mediante etiquetas y aprobación manual. Este diseño de permisos no se ha implementado ni probado en una Instancia.** La automatización de seeding en qui y las comprobaciones de Tdarr son una cuestión separada, documentada en [reglas de compresión](../transcode-rules.md). Esta investigación no modifica el Wiring.

Fecha: 2026-10-07. Código leído: Seerr **v3.5.0** (la versión fijada en [stacks/seerr/compose.yaml](../../stacks/seerr/compose.yaml)), y Sonarr, Radarr y Prowlarr en la rama `develop` de GitHub. Radarr y Sonarr de la Plantilla van en 6.4.4 y 4.0.20 (ver [stacks/arr/compose.yaml](../../stacks/arr/compose.yaml)); no se ha comprobado que `develop` coincida con esas versiones exactas. Esta es una lectura de código y documentación oficial, no una prueba en una Instancia.

## Objetivo

Que SeedCore y Torrenteros los use solo el Operador. Los Espectadores no deben poder disparar búsquedas ni descargas en esos trackers por su cuenta. Solo deben llegar a ellos a través de una solicitud que el Operador apruebe de forma explícita, o no usarlos nunca.

## Conclusión

La opción recomendada es **etiquetas (tags) con una sola pareja Radarr/Sonarr, más aprobación manual en Seerr**. No requiere cambiar el Wiring ni añadir servicios.

1. Los dos indexers llevan la etiqueta `priv` en Prowlarr y también en Radarr/Sonarr.
2. Seerr sigue enviando las solicitudes de los Espectadores sin etiqueta, así que esas series y películas solo usan indexers sin etiqueta.
3. Para que una solicitud use los trackers privados, el Operador añade `priv` a esa solicitud, a la serie o a la película.

Hay una **trampa importante**: Prowlarr **no propaga sus etiquetas** a Radarr/Sonarr. Los indexers sincronizados llegan **sin etiqueta**, y un indexer sin etiqueta lo usa cualquier serie o película. La etiqueta hay que ponerla a mano, una vez, en cada Radarr/Sonarr (ver [Pasos](#pasos)).

## Cómo funcionan las etiquetas

### Sonarr y Radarr: regla de coincidencia

- **Documentación.** "Only use this indexer for series with at least one matching tag. Leave blank to use with all series." Para Radarr dice lo mismo con "movies". [Sonarr](https://wiki.servarr.com/sonarr/settings), [Radarr](https://wiki.servarr.com/radarr/settings).
- **Aviso explícito de Sonarr.** "A Series will use both indexers that have matching tags and indexers that have no tags." [Sonarr, sección Tags](https://wiki.servarr.com/sonarr/settings).
- **Búsqueda automática e interactiva.** Se filtran igual con `i.Definition.Tags.Empty() || i.Definition.Tags.Intersect(series.Tags).Any()`. Un indexer con etiquetas queda fuera para una serie sin esa etiqueta, y una serie sin etiquetas solo ve indexers sin etiqueta. [Sonarr `ReleaseSearchService.Dispatch`](https://github.com/Sonarr/Sonarr/blob/develop/src/NzbDrone.Core/IndexerSearch/ReleaseSearchService.cs), [Radarr](https://github.com/Radarr/Radarr/blob/develop/src/NzbDrone.Core/IndexerSearch/ReleaseSearchService.cs).
- **RSS.** La sincronización RSS consulta todos los indexers con RSS activo, pero una especificación del motor de decisión rechaza la release si el indexer tiene etiquetas y ninguna está en la serie (`Series tags do not match any of the indexer tags`). Por tanto el RSS tampoco filtra a nadie por fuera de la regla. [Sonarr `IndexerTagSpecification`](https://github.com/Sonarr/Sonarr/blob/develop/src/NzbDrone.Core/DecisionEngine/Specifications/RssSync/IndexerTagSpecification.cs), [Radarr](https://github.com/Radarr/Radarr/blob/develop/src/NzbDrone.Core/DecisionEngine/Specifications/RssSync/IndexerTagSpecification.cs).
- **Consecuencia práctica.** En la búsqueda interactiva de una serie sin `priv`, **el propio Operador tampoco verá SeedCore ni Torrenteros**. Hay que etiquetar primero la serie o película.

### Prowlarr: etiquetas y sincronización con las apps

- **Documentación.** En la ficha de la aplicación, "If you have added a tag to your indexer during setup, only indexers with this tag will be used for this program entry." Las etiquetas sirven para "Specifying Indexers to certain apps". [Prowlarr Settings](https://wiki.servarr.com/prowlarr/settings).
- **FAQ.** "Only in instances where an App and Indexer have matching tags or no tags at all will an indexer be synced to an app". [Prowlarr FAQ](https://wiki.servarr.com/prowlarr/faq).
- **Código.** Si la **app no tiene etiquetas**, `ShouldHandleIndexer` devuelve `true` para todos los indexers, también los etiquetados. Si la app tiene etiquetas y el indexer ninguna, no coinciden y el indexer **no se sincroniza**. [Prowlarr `ApplicationService.ShouldHandleIndexer`](https://github.com/Prowlarr/Prowlarr/blob/develop/src/NzbDrone.Core/Applications/ApplicationService.cs).
- **Etiquetas al sincronizar.** Al crear el indexer remoto, Prowlarr construye `Tags = new HashSet<int>()`, es decir, **vacío**. Al actualizar uno existente conserva las etiquetas que el usuario puso en la app remota (`UnionWith(remoteIndexer.Tags)`). [Prowlarr `Sonarr.cs`](https://github.com/Prowlarr/Prowlarr/blob/develop/src/NzbDrone.Core/Applications/Sonarr/Sonarr.cs).
- **Estado actual del Wiring.** Crea las aplicaciones de Prowlarr con `syncLevel="fullSync"` y sin etiquetas, de modo que **todos los indexers se sincronizan a todos los managers**. Ver `prowlarr()` en [steps.py](../../stacks/wire/wire/steps.py).

### Seerr v3.5.0: peticiones, etiquetas y permisos

- **Servidor por defecto y etiquetas.** Una solicitud va al servidor por defecto no-4K, salvo que lleve un `serverId` explícito. Las etiquetas son las `tags` del servidor, salvo que la solicitud traiga otras. [`MediaRequestSubscriber.ts`](https://github.com/seerr-team/seerr/blob/v3.5.0/server/subscriber/MediaRequestSubscriber.ts).
- **Serie o película que ya existe en Sonarr.** Seerr **une** las etiquetas existentes con las nuevas (`Array.from(new Set([...series.tags, ...options.tags]))`). Una serie ya marcada `priv` no pierde la marca cuando otro Espectador pide una temporada más. Para Radarr, la unión de etiquetas solo se hace si la película existe pero no está monitorizada. [`sonarr.ts`](https://github.com/seerr-team/seerr/blob/v3.5.0/server/api/servarr/sonarr.ts), [`radarr.ts`](https://github.com/seerr-team/seerr/blob/v3.5.0/server/api/servarr/radarr.ts).
- **Aprobación automática.** Solo la tienen quienes poseen `AUTO_APPROVE` (o la variante de película o serie), `MANAGE_REQUESTS` o `ADMIN`. [`MediaRequest.ts`](https://github.com/seerr-team/seerr/blob/v3.5.0/server/entity/MediaRequest.ts), [`permissions.ts`](https://github.com/seerr-team/seerr/blob/v3.5.0/server/lib/permissions.ts).
- **Permisos por defecto.** Los usuarios nuevos reciben solo `Permission.REQUEST`, sin aprobación automática. Se cambia en Settings, Users, Default Permissions. [`settings/index.ts`](https://github.com/seerr-team/seerr/blob/v3.5.0/server/lib/settings/index.ts), [docs de usuarios](https://docs.seerr.dev/using-seerr/settings/users).
- **Quién elige servidor, perfil y etiquetas.** El modal avanzado de solicitud solo aparece con `REQUEST_ADVANCED` o `MANAGE_REQUESTS`. Modificar una solicitud ajena (incluidas sus etiquetas) exige `MANAGE_REQUESTS`. [`RequestModal`](https://github.com/seerr-team/seerr/blob/v3.5.0/src/components/RequestModal/AdvancedRequester/index.tsx), [`routes/request.ts`](https://github.com/seerr-team/seerr/blob/v3.5.0/server/routes/request.ts).
- **Tag por usuario (`tagRequests`).** Si el servidor tiene `tagRequests` activado, Seerr crea y añade una etiqueta `<idUsuario>-<nombre>` a cada serie o película que ese usuario solicite. [`MediaRequestSubscriber.ts`](https://github.com/seerr-team/seerr/blob/v3.5.0/server/subscriber/MediaRequestSubscriber.ts).
- **Reglas de override.** Seerr tiene reglas por servidor que pueden fijar carpeta, perfil y etiquetas según usuario, género, idioma o palabra clave. Solo se evalúan para el servidor por defecto de cada tipo, y para quien tiene `REQUEST_ADVANCED`/`MANAGE_REQUESTS` no pisan lo que ya eligió. [`overrideRules.ts`](https://github.com/seerr-team/seerr/blob/v3.5.0/server/lib/overrideRules.ts), [`MediaRequest.ts`](https://github.com/seerr-team/seerr/blob/v3.5.0/server/entity/MediaRequest.ts).
- **Importante: el control es de interfaz, no de servidor.** El `POST /request` pasa `req.body` a `MediaRequest.request` sin descartar `serverId`, `profileId`, `rootFolder` ni `tags` de quien no tiene `REQUEST_ADVANCED`. Lo que impide el abuso es que, sin `AUTO_APPROVE`, la solicitud queda **pendiente** hasta que un administrador la apruebe. Un Espectador con la API podría pedir etiquetas o servidor arbitrarios, pero nada se ejecuta hasta la aprobación. Esto sale de leer el código de v3.5.0; no se ha probado. [`routes/request.ts`](https://github.com/seerr-team/seerr/blob/v3.5.0/server/routes/request.ts).

## Diseño recomendado

### Pasos

**1. Prowlarr (una vez).**

1. Crear la etiqueta `priv` (Settings, Tags).
2. Añadir SeedCore y Torrenteros con la etiqueta `priv`.
3. Dejar las aplicaciones Radarr y Sonarr que creó el Wiring **sin etiquetas** y con `Full Sync`. Así reciben todos los indexers, incluidos los privados.
4. En los dos indexers privados, rellenar Seed Ratio y Seed Time en las opciones avanzadas (ver [Ratio y hit-and-run](#ratio-y-hit-and-run)). [Prowlarr Indexers](https://wiki.servarr.com/prowlarr/indexers).

**2. Radarr y Sonarr (una vez por instancia: `radarr`, `sonarr`, y `radarr-vo`/`sonarr-vo` si el Perfil `vo` está activo).**

1. Crear la etiqueta `priv`.
2. En Settings, Indexers, editar `SeedCore (Prowlarr)` y `Torrenteros (Prowlarr)` y ponerles la etiqueta `priv`. Prowlarr conserva esa etiqueta en futuras sincronizaciones (ver código arriba).
3. Dejar Seerr con el servidor por defecto sin etiquetas (es lo que escribe hoy el Wiring: `"tags": []`).

**3. Seerr.**

1. Para cada Espectador, **no** dar `AUTO_APPROVE`, `AUTO_APPROVE_MOVIE`, `AUTO_APPROVE_TV`, `MANAGE_REQUESTS` ni `REQUEST_ADVANCED`. Con los permisos por defecto (`REQUEST`) ya es así. Comprobar que nadie los tiene tras importar usuarios de Jellyfin.
2. Solo el Operador (admin) tiene el permiso de gestionar solicitudes.

**4. Flujo de uso.**

- **Descarga normal de un Espectador.** Pide, el Operador aprueba o aprueba automáticamente según su política, y la serie o película entra sin `priv`. Solo usa indexers públicos.
- **Solicitud del Espectador que el Operador quiere resolver con trackers privados.** Antes de aprobar, el Operador edita la solicitud y añade la etiqueta `priv`, o lo hace después en Sonarr/Radarr y lanza una búsqueda. Desde ese momento la serie o película usa SeedCore y Torrenteros.
- **Petición del propio Operador.** Con `REQUEST_ADVANCED`/`MANAGE_REQUESTS`, selecciona `priv` en el modal avanzado.
- **Evitar fugas por defecto.** No poner `priv` en las etiquetas del servidor de Seerr, porque entonces todo lo pedido iría a los trackers privados.

### Variante con `tagRequests`

Con `tagRequests` activado, cada serie o película recibe `<id>-<usuario>`. Si se etiquetan los indexers privados con la etiqueta del Operador (por ejemplo `1-admin`) en lugar de `priv`, todo lo que el Operador pida queda ligado a los trackers privados **sin elegirlo en cada solicitud**.

Limitaciones: la etiqueta solo existe tras la primera solicitud de ese usuario, hay que localizarla en Sonarr/Radarr para añadirla al indexer, y llena la lista de etiquetas con una por usuario. El Wiring crea el servidor con `tagRequests: false`. [steps.py](../../stacks/wire/wire/steps.py).

## Limitaciones y trampas

1. **Etiqueta perdida = fuga.** Si se borra y vuelve a crear el indexer en Prowlarr, o se vuelve a conectar la app, el indexer remoto llega **sin etiqueta** y lo puede usar cualquier serie. Falta una comprobación automática: se podría verificar por la API (`/api/v3/indexer`) que SeedCore y Torrenteros llevan etiquetas. No existe todavía.
2. **La etiqueta va en la serie o película, no en la persona.** Cualquier solicitud posterior de otro Espectador sobre esa misma serie ya marcada `priv` también usará los trackers privados (Seerr une etiquetas, no las quita). Esto es coherente con "aprobado por el Operador", pero conviene saberlo.
3. **Búsqueda interactiva.** Sin `priv` en la serie, ni el Operador ve los trackers privados. Etiquetar antes de buscar.
4. **Contenido ya en biblioteca.** Lo que ya está importado sin `priv` no se actualizará desde los trackers privados. Habría que etiquetarlo a mano.
5. **Etiquetas del servidor de Seerr.** Cambiar `tags` en el servidor por defecto de Seerr afecta a **todas** las solicitudes nuevas, sin importar quién las haga.
6. **Interfaz sin garantía de servidor.** Ver el punto de `POST /request` más arriba: la protección real es la aprobación manual. Si algún día un Espectador recibe `AUTO_APPROVE`, hay que revisar este diseño.
7. **Otras apps.** Esta investigación solo cubre Prowlarr, Sonarr, Radarr y Seerr. Bazarr, Jackett (Perfil `jackett`), cleanuparr o qui no se han revisado en este punto. Un Espectador con acceso a Prowlarr o a los \*arr rompería cualquier restricción por etiquetas.
8. **Wiring.** El Wiring solo siembra lo que falta y no sobrescribe lo configurado por el Operador ([ADR-0002](../adr/0002-wiring-only-seeds.md)), así que las etiquetas manuales sobreviven a un `docker compose up`.

## Ratio y hit-and-run

Actualización: las [normas de SeedCore aportadas por el Operador](../seedcore.md) especifican **72 horas o ratio 1:1 dentro de 20 días**. Esa evidencia aclara la alternativa que la definición de Prowlarr por sí sola no establece. La [guía de Torrenteros aportada por el Operador](../torrenteros.md) exige 72 horas por descarga y ratio mínimo de cuenta 0,25, contabilizado por el tracker. Los datos de definiciones que siguen son antecedentes de la investigación, no una regla de exigir ambos mínimos ni un reflejo de ajustes aplicados.

Estos datos salen de las definiciones de Prowlarr, no de las reglas publicadas por los trackers. **Hay que confirmar las reglas vigentes en cada sitio.**

- Ambos son trackers privados con API estilo UNIT3D. [SeedCore](https://github.com/Prowlarr/Indexers/blob/master/definitions/v11/seedcore-api.yml), [Torrenteros](https://github.com/Prowlarr/Indexers/blob/master/definitions/v11/torrenteros-api.yml).
- **SeedCore** declara en su definición ratio mínimo 1.0 y tiempo mínimo de siembra de 3 días.
- **Torrenteros** declara un tiempo mínimo de siembra de 3 días y comenta que el ratio global mínimo es 0.25.
- **Qué hacer con eso.** Rellenar Seed Ratio y Seed Time (en minutos; 3 días son 4320) en el indexer de Prowlarr o de cada \*arr. Sonarr y Radarr las pasan a qBittorrent al añadir el torrent. Para que no se borre antes, "Completed Download Handling - Remove" solo elimina si el cliente informa de que terminó de sembrar y el torrent está en pausa. [Sonarr Settings](https://wiki.servarr.com/sonarr/settings).
- **Hardlinks.** Importar con hardlink permite sembrar sin duplicar disco. Ya es el comportamiento por defecto y la Plantilla comparte `DATA_ROOT` para ello. [Sonarr Settings](https://wiki.servarr.com/sonarr/settings).
- **Riesgo propio de la Plantilla.** Con el Perfil `seeding`, cleanuparr puede borrar descargas atascadas o sin hardlink si el Operador activa esas reglas. Antes de usarlo con torrents privados hay que comprobar que respeta el tiempo mínimo de siembra. No lo he verificado en esta investigación.
- **VPN.** El tráfico de qBittorrent sale por gluetun. Un cambio de IP o la falta de puerto entrante puede perjudicar el ratio o provocar avisos en el tracker. Muchos trackers privados lo prohíben o lo limitan; comprobar sus normas.
- **Quién paga el ratio.** Si el Operador aprueba trackers privados para descargas que piden otros, el ratio y los hit-and-run son suyos. Esa es una razón más para la aprobación manual.

## Alternativas comparadas

| Opción | Cómo funciona | A favor | En contra |
|---|---|---|---|
| **A. Etiquetas + una sola pareja \*arr (recomendada)** | `priv` en indexers de Prowlarr y de cada \*arr; el Operador etiqueta lo que quiere resolver con ellos | Sin servicios nuevos ni cambios en el Wiring; solo un paso manual por \*arr | Etiqueta manual en cada \*arr, riesgo de fuga si se pierde (trampa 1) |
| **B. Pareja \*arr dedicada a trackers privados** | Segunda Radarr/Sonarr (por ejemplo la del Perfil `vo`) registrada en Seerr como servidor no por defecto; en Prowlarr, esa app con etiqueta `priv`, y las del Core etiquetadas con otra etiqueta para que no reciban los privados | Separación fuerte: el Core nunca ve los indexers privados | Hay que etiquetar a mano las apps del Core en Prowlarr y todos los indexers públicos; el Wiring crea las apps sin etiqueta, que reciben todo. Duplica bibliotecas y categorías; ver Perfil `vo` en [compose](../../stacks/vo/compose.yaml) |
| **C. Servidor "4K" de Seerr como canal privado** | Seerr permite un segundo servidor marcado 4K y exige permisos `REQUEST_4K` y `AUTO_APPROVE_4K` aparte ([docs de servicios](https://docs.seerr.dev/using-seerr/settings/services)) | Permisos de Seerr por separado, sin tocar etiquetas | Usa una función pensada para otra cosa; Seerr cuenta el estado 4K aparte y la interfaz lo muestra como 4K. No recomendado |
| **D. Indexers privados sin sincronizar; búsqueda manual en Prowlarr** | Mantenerlos fuera de las apps y buscar desde la interfaz de Prowlarr | Cero riesgo de fuga a Espectadores | Sin automatización, sin importación automática ni renombrado |
| **E. Reglas de override de Seerr por usuario** | Reglas que añaden etiquetas según el usuario que pide | Se aplica sin pasos por solicitud | Solo corre para el servidor por defecto y no pisa a usuarios avanzados; sirve para añadir `priv` a un usuario concreto, no para quitarlo al resto. Se complementa con A |
| **F. Perfiles de calidad** | Un perfil de calidad por tipo de uso | Útil para elegir calidad | **No** restringe indexers; no sirve para este objetivo |

## Preguntas abiertas

1. ¿Los Espectadores deben poder acabar usando los trackers solo si el Operador aprueba **cada** solicitud, o prefieres una lista de títulos o usuarios de confianza?
2. ¿Quieres que SeedCore y Torrenteros cubran **todo** lo que pida el Operador (variante `tagRequests`) o solo lo que el Operador marque?
3. ¿Hay biblioteca existente que deba reetiquetarse para que se actualice desde los privados?
4. ¿La Plantilla debe automatizar algo de esto (por ejemplo crear la etiqueta `priv` en el Wiring, o una comprobación de que los indexers privados llevan etiqueta), o es configuración de una Instancia concreta? Hoy las etiquetas son de la Instancia, no de la Plantilla.
5. ¿Qué dicen las normas actuales de cada tracker sobre ratio, hit-and-run, VPN y uso de cleanuparr? Esta nota no las ha podido consultar.
6. ¿Algún Espectador tiene acceso a Prowlarr, Sonarr o Radarr directamente, o solo a Seerr y Jellyfin?
