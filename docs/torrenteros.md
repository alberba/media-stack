# Torrenteros: normas de seeding y publicación

Resumen de la guía aportada por el Operador el 12 de octubre de 2026. No se ha
verificado directamente en el sitio del tracker. La referencia documenta las
obligaciones; no modifica la configuración de ninguna app. Ver las
[reglas de compresión y retirada](transcode-rules.md) para distinguir las normas
del tracker de la política de conservación elegida.

## Descargas y ratio

- **Cada torrent descargado debe sembrarse durante 72 horas**. La guía indica que
  el tiempo se consulta en la flecha de descarga de la esquina superior del sitio.
- Alcanzar ratio 1:1 no sustituye esas 72 horas: el texto no ofrece una alternativa
  por ratio ni especifica un plazo máximo para acumular el tiempo.
- El ratio que importa es el **contabilizado por el tracker**, no el mostrado por
  qBittorrent. El ratio mínimo de la cuenta es **0,25**; si queda por debajo, hay
  que contactar con el equipo. No convertir este mínimo de cuenta en una regla
  de ratio 0,25 por torrent.
- Mantener torrents compartidos permite ganar puntos de bonificación (BON), que
  pueden canjearse por crédito de subida, invitaciones y otras recompensas. Ese
  crédito puede hacer que el ratio de cuenta difiera de la subida real del cliente.

## Hit-and-run

Incumplir el tiempo mínimo genera advertencias:

| Advertencias | Consecuencia indicada |
| --- | --- |
| Una | La guía indica que no supone un problema inmediato; sigue siendo una advertencia |
| Dos | Se bloquea la posibilidad de descargar torrents |
| Tres | Se deshabilita la cuenta automáticamente; hay que hablar con moderación |

Cumplir el mínimo no obliga a retirar el torrent inmediatamente. Antes de automatizar
su retirada, contrastar el tiempo y estado registrados en el sitio. Los contadores
del cliente y del tracker pueden discrepar.

## Reglas generales

- No compartir ni publicar archivos `.torrent` del tracker: están vinculados a la
  cuenta. Los ejemplos de qui del repositorio no contienen torrents ni passkeys.
- Una persona puede tener **una sola cuenta**. Las cuentas duplicadas están
  prohibidas; la guía indica expulsión de los usuarios y de su red de invitaciones.
- Usar un nombre de usuario normal, sin palabras obscenas ni frases sin sentido.
- No se permite contenido XXX.

## Publicación de torrents

Estas condiciones son distintas de las de quien descarga:

- Se requiere el rango **SuperUser** como mínimo para publicar.
- Buscar duplicados antes de subir. Se admite otra resolución o versión.
- Revisar subtítulos, sincronización de audio, color, resolución y demás aspectos
  de calidad antes de publicar.
- Después de subir, descargar de nuevo el `.torrent` desde el sitio.
- Publicar **un torrent por película o temporada**; no colecciones de películas o
  series. Para series, se permite un torrent por temporada.
- Usar los nombres de TMDB: inglés para películas/series inglesas o de origen
  extranjero, español para las de origen español.
- Indicar si el audio es **Castellano o Latino**, por ejemplo en el título o MediaInfo.
- Cada torrent publicado exige **al menos 170 horas de siembra o al menos tres
  seeders**. Es la regla del uploader, no la regla de 72 horas de quien descarga.

## Invitaciones

La guía exige activar 2FA en Perfil → Ajustes → Autenticación de dos pasos antes
de invitar. Recomienda Authy en el texto aportado; este documento no evalúa ni
recomienda una aplicación de autenticación concreta.

Las invitaciones se compran en Perfil → Bonus Puntos → Tienda; el texto indica
**2500 puntos por una invitación**. Después se envían desde Perfil → Otro → Invita
→ Enviar invitación. El correo puede llegar a spam. Confirmar precio y menús en el
sitio antes de usarlos, porque esta referencia procede de la guía aportada.

## Consecuencias para la automatización

La regla pública de 72 horas no debe aplicarse a Torrenteros solo porque coincida
numéricamente con su mínimo: sigue siendo un tracker privado, con obligaciones y
contabilidad propias. El etiquetado de privados en qui lo conserva frente a la
retirada pública. **La retirada automática de Torrenteros sigue pendiente de una
política elegida y de validación**; no se activa por añadir este documento.

La política general elegida conserva privados con cinco o más leechers reportados
por el tracker. Esa excepción es una decisión del Operador, no una obligación
adicional de la guía de Torrenteros.
