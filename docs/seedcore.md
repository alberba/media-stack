# SeedCore: normas de seeding y publicación

Resumen en español del texto de SeedCore aportado por el Operador el 12 de octubre de 2026. No se ha verificado directamente en el sitio del tracker. Documentar estas normas no implica que estén configuradas en qBittorrent, Prowlarr, Radarr/Sonarr o las apps de limpieza.

## Descargas: obligaciones de seeding

- Cada torrent exige **72 horas acumuladas de seeding o ratio 1:1**. Es una alternativa, no la obligación de alcanzar ambos valores.
- Hay **20 días** para cumplir; las horas no tienen que ser consecutivas. El texto aportado no precisa el momento exacto desde el que cuenta ese plazo.
- El hit-and-run está estrictamente prohibido.
- **Freeleech no exime del tiempo de seeding**. No interpretar una descarga gratuita como permiso para retirarla inmediatamente.
- Es obligatoria la secuencia de anuncios **started → completed → stopped**.
- El cliente debe ser conectable mediante un **puerto abierto**.
- Cambiar IP o VPN durante torrents activos puede acarrear sanciones cuando el objetivo sea actuar de forma indebida. El texto no prohíbe de forma absoluta todos los cambios de IP.

### Consecuencias para Tdarr y la limpieza

**Política actual del Operador:** conservar las descargas de SeedCore hasta alcanzar
**ratio mínimo 1:1**, aunque ya hayan acumulado 72 horas de seeding. Esta decisión
es más exigente que el mínimo de la guía y no cambia la referencia original:
**72 horas o ratio 1:1 dentro de 20 días**. Si se cumple el tiempo pero no el ratio,
el torrent sigue conservándose. El plazo de 20 días no obliga a eliminarlo.
Esta política está documentada; no confirma que los ajustes de las apps la apliquen.

Además, el Operador conserva torrents con **cinco o más leechers reportados por
el tracker**, aunque hayan alcanzado ratio 1:1. Es una decisión de conservación
por demanda, no una obligación adicional de la guía. Con demanda desconocida o
errores del tracker, no se autoriza la retirada automática.

La [protección actual de Tdarr](transcode-rules.md) no comprueba ninguna de estas obligaciones. Tener un único hardlink no demuestra cumplimiento; eliminar un torrent de qBittorrent tampoco.

Antes de retirar un torrent, comprobar que ha satisfecho la obligación correspondiente y que se ha anunciado correctamente al tracker. Revisar cualquier regla de eliminación de qBittorrent, Radarr/Sonarr y Cleanuparr: no se ha auditado aquí su configuración efectiva ni cómo combinan ratio y tiempo.

Para aplicar «comprimir solo películas ausentes de qBittorrent» hace falta una comprobación adicional de pertenencia al cliente, descrita en la guía de reglas. Hasta implementarla, la protección es por hardlinks. La compresión para uso local y la publicación de una nueva release tienen condiciones distintas.

## Freeleech automático

Los umbrales usan la unidad «GB» del texto del tracker; no se ha confirmado si significa GB decimal o GiB.

| Contenido y tamaño | Freeleech automático indicado |
| --- | --- |
| Películas de más de 6 GB | 10 % |
| Películas de más de 10 GB | 100 % |
| Torrents de series de más de 10 GB, incluidos packs | 100 % |

El texto dice «más de»: no especifica qué ocurre exactamente en el límite. El freeleech total evita que la descarga afecte al ratio, pero mantiene las obligaciones de seeding. El umbral de compresión de Tdarr es independiente de estos umbrales.

## Publicación: presentación y metadatos

Estas reglas corresponden a quien **sube torrents a SeedCore**.

- Nombre limpio, sin espacios, separado por puntos y con formato Scene: nombre, año cuando corresponda, fuente, resolución y grupo original. Conservar el grupo; no modificar el nombre para atribuir la release a otro.
- Si hay doblaje rumano, añadir `.RoDubbed` antes del grupo en el nombre del formulario. No es obligatorio renombrar los archivos locales.
- Introducir el ID numérico de **IGDB para juegos** y **TMDB para películas/series** en el campo correspondiente.
- Para juegos, usar descripción y requisitos mínimos/recomendados de Steam; recurrir a IGDB si no existe en Steam. Añadir el tráiler oficial. El texto aportado omite la etiqueta concreta para insertarlo.
- Añadir **exactamente seis imágenes**. Para películas/series, miniaturas BBCode de tamaño medio que se amplíen al pulsarlas; para juegos, imágenes de calidad 1080p en un alojamiento estable. Agruparlas centradas.
- Las capturas deben proceder directamente del archivo publicado: no usar imágenes promocionales, de Internet o de otras releases.
- Pegar **MediaInfo en formato Texto** en su campo específico, sin espacios vacíos excesivos; no en la descripción principal.
- Subir el archivo **NFO por separado**, en su campo específico. Puede contener información técnica, instalación y notas del grupo.
- Mantener una carpeta de release ordenada. El ejemplo permite `sample.mkv` salvo para WEB-DL y remux.
- La etiqueta **INTERNAL** requiere aprobación; falsificarla puede implicar prohibición de subir torrents.

## Publicación: fuente, calidad e integridad

- Se prohíben CAM, HDCAM, TS, TC y grabaciones de pantalla. Se exigen fuentes digitales limpias.
- No se permiten torrents procedentes de trackers públicos ni de SpeedApp (SPD), según el texto aportado.
- Está prohibido **recodificar otro encode** para publicarlo: incluye WEBRip, encodes existentes x264/x265 y releases de YTS, PSA o MeGusta.
- Las fuentes admitidas para crear un encode son Blu-ray/UHD Blu-ray original o remux, WEB-DL original, HDTV sin procesar y DVD original.
- Un WEB-DL debe ser auténtico, sin recodificación ni bitrate modificado. No renombrar un WEBRip o encode como WEB-DL; el equipo puede pedir prueba de origen.
- Un remux debe conservarse **1:1**: no quitar audio/subtítulos, recomprimir vídeo/audio ni modificar innecesariamente el contenedor.
- No modificar repacks, instaladores, cracks, archivos personales ni el grupo original.
- Se prohíben bitrates extremadamente bajos. La guía recomienda al menos **3 Mbps para 1080p** y **8 Mbps para 2160p**; no convertir esa recomendación en una validación que Tdarr ya tenga.
- El resultado recodificado por Tdarr no debe seguir presentándose como un WEB-DL intacto o un remux 1:1 si se publica. El plugin actual también puede recodificar encodes existentes, lo que no cumple la regla de fuente para publicación.

## Publicación: duplicados

No subir si ya existe la misma release con el mismo grupo, resolución y fuente, o un encode idéntico. La guía admite diferencias de resolución, fuente, grupo con encode distinto, o remux frente a encode.

La nota sobre SCAUT describe mejoras de comprobación de aceptación real del upload, búsqueda ignorando palabras posteriores al año y comparación HDR/SDR. No demuestra que SCAUT esté instalado en esta Plantilla ni elimina la obligación de comprobar duplicados.

## Publicación: seeding del uploader

El uploader debe mantener el torrent sembrando **cinco días o hasta que haya al menos cinco seeders activos que hayan subido datos**, según el texto. Es una obligación distinta de las 72 horas o ratio 1:1 de quien descarga.

El checklist final habla de esperar a que aparezcan cinco personas más, mientras la regla anterior dice cinco seeders activos: confirmar con el equipo cómo se cuenta antes de automatizar la retirada de un torrent propio.

El sistema asigna freeleech automáticamente. No marcar manualmente Free o Double Upload salvo material raro, colecciones o material importante, conforme a la excepción indicada por la guía.

## Grupos y contradicciones del texto

La lista de grupos prohibidos incluye:

SPHD, SPWEB, RARBG, YTS, YIFY, GalaxyRG, TARTAR, VXT, Vyndros, PSA/PSArips, MeGusta, UTR (Joy, QxR), Silence, Pahe/Pahe.in, RMTeam/RMTeamX, Cleo, AnimeRG, MiniHD, ShAaNiG, 300MB Movies, TERMiNAL, Cinemaluxe, BONE, RZeroX, EliteMovieRG, EMBER, ETRG, ExtraTorrentRG, TGx, EVO, ION10, CMRG, AFG, mSD, KiNGDOM, Ganool, nItRo e IceBane.

La misma guía presenta como apreciados los siguientes grupos:

- Scene/WEB-DL/Blu-ray: DON, CtrlHD, EbP, HiDt, DIMENSION, NTb, FLUX, FraMeSToR, WiKi, NTG, D-Z0N3, SbR, AMIABLE, CiNEFiLE, GECKOS, HDMaNiAcS, DRONES, SHORTBREHD, WATCHABLE, SURCODE, DEFLATE, Replica, ROCCaT, SADPANDA, TOPKEK, TEPES, playWEB, KiMCHI, NOSiViD, DECEMBER, MONUMENT, BLUTONiUM, RETAIL, ARCHiViST, MoKi, CRFW y NOGRP interno de confianza.
- WEB-DL P2P: NTG, FLUX, KiNGS, TEKNO3D, CMRG (a veces permitido en ciertos trackers), SMURF, MiNX (WEB-DL, no encodes), EVO (WEB-DL original), TEPES, playWEB, KiMCHI, SLOT, ViSUM, SIGMA, RAW, successfulcrab y NINJACENTRAL.
- Blu-ray/encodes P2P: QxR, Tigole, FraMeSToR, WiKi, SbR, DON, CtrlHD, EbP, HiDt, PTer, VietHD, HDChina, CHD, MTeam, LoRD, c0kE, TayTO, decibeL, EPSiLON, Geek, PTpOWeR, KRaLiMaRKo, ZQ, iFT, SA89, BMF y FGT (remux/encodes Blu-ray, no recodificaciones WEB).

**Hay contradicciones explícitas**: QxR aparece asociado a UTR en la lista prohibida y como respetado; EVO y CMRG aparecen en ambos apartados. No construir una lista automática de permitidos a partir de estas recomendaciones sin aclarar las excepciones con el equipo de SeedCore.

## Contenido prohibido y sanciones

El texto prohíbe explotación sexual de menores, incesto (distinguiéndolo de temas artísticos tabú), violencia real gráfica, instrucciones para fabricar drogas o explosivos y documentos gubernamentales clasificados o filtrados. También prohíbe malware, archivos sospechosos y software sin informe de VirusTotal e información necesaria.

Las consecuencias indicadas incluyen eliminación de torrents, pérdida de permisos de publicación y desactivación de cuenta; para archivos infectados se indica expulsión permanente. Estas reglas de publicación no son filtros implementados por Tdarr.
