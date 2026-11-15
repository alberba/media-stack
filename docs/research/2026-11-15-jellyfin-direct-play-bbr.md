# Diagnóstico: cortes de reproducción directa y prueba de BBR

Fecha: 2026-11-15. Caso técnico anonimizado de una Instancia con Jellyfin, Nginx
Proxy Manager y un Fire TV en otra ubicación. Los detalles privados, rutas reales,
cuentas, identificadores, dominios y credenciales se mantienen fuera del repositorio,
siguiendo [ADR-0001](../adr/0001-instance-runs-the-template.md).

**Estado:** reproducción directa del archivo de referencia recuperada y confirmada
por el Espectador. Persistencia configurada y validada con Compose, pendiente de
comprobar tras reinicio. La guía reutilizable está en
[Reproducción directa remota: CUBIC y BBR](../jellyfin-direct-play.md).

## Síntoma y alcance

Un archivo ligero funcionaba, mientras otras películas presentaban cortes en
Jellyfin Android TV 0.19.10. En una prueba con Wholphin también aparecía el círculo
de carga. En pruebas posteriores se observó imagen congelada sin círculo; no todos
los síntomas tenían necesariamente la misma causa.

El Espectador pidió conservar vídeo y audio originales, sin transcodificar. El
archivo de referencia era MKV con H.264 1080p, audio español DTS-HD MA y subtítulos
internos. Su bitrate total medio era 26,17 Mb/s; los primeros dos minutos daban
23,46 Mb/s de media y un pico de 48,83 Mb/s en una ventana de un segundo.
Un búfer suficiente puede absorber picos: no se deduce de ese pico un requisito
instantáneo idéntico para la conexión.

## Evidencias que acotaron el problema

- El NAS no mostraba saturación de CPU o disco. La interfaz Ethernet de 1 Gb/s no
  registraba errores ni descartes en las consultas; la tabla de seguimiento de
  conexiones estaba lejos de su límite. El tráfico de torrents era pequeño.
- Las cuatro películas analizadas decodificaron sus primeros 30 segundos sin
  errores en el NAS. No se verificaron íntegramente los archivos.
- El Fire TV comunicaba un test de Internet de 266,37 Mb/s y señal de -28 dBm.
  Ese test usaba otro destino y no medía la ruta hasta la Instancia.
- La descarga pública desde un Mac en la misma Wi-Fi también era irregular. Se
  verificó que salía hacia la IP pública por su interfaz Wi-Fi, sin Tailscale.
  SSH usaba Tailscale únicamente como canal de control.
- En la conexión de vídeo original del Fire TV se observaron retransmisiones,
  datos pendientes y caídas de la ventana de congestión con CUBIC. El tiempo
  limitado por la ventana del receptor era cero en las muestras registradas.
- Una descarga de los mismos 16 MiB dentro del NAS tardó aproximadamente 0,018 s.
  Eso descartaba falta de capacidad de entrega local para esa muestra, pero no
  era una medición del almacenamiento completo ni de la ruta de Internet.
- La comparación por Tailscale también fue lenta. El túnel era directo hasta el
  extremo público del NAS y no se adoptó como solución.
- Pausar dejaba la descarga activa. Para medir sin el vídeo compitiendo hubo que
  salir de reproducción y verificar que el tráfico del proxy había descendido.

## Prueba A/B del control de congestión

Se usó la misma petición HTTP Range, los mismos primeros 16 MiB del original y
el mismo dominio público. Se descartó la salida: no se recodificó ni guardó otra
copia del vídeo. Se cambió únicamente el algoritmo predeterminado en el espacio
de red del proxy y se usaron conexiones nuevas para las descargas de control.

| Condición | Tiempo | Caudal medio |
| --- | ---: | ---: |
| CUBIC inicial | 15,624 s | 8,59 Mb/s |
| BBR, primera repetición | 1,970 s | 68,12 Mb/s |
| BBR, segunda repetición | 2,083 s | 64,44 Mb/s |
| CUBIC, control posterior | 12,208 s | 10,99 Mb/s |

Tras volver a BBR y reabrir la película, el Espectador confirmó fluidez. La API
mostró `PlayMethod=DirectPlay`, audio DTS-HD original, subtítulos originales y
`TranscodingInfo=null`; la posición continuó avanzando en las muestras posteriores.
No había procesos ffmpeg de conversión al cierre.

El diagnóstico TCP confirmó BBR en la conexión nueva de vídeo. Una muestra
instantánea de entrega alcanzó 110,93 Mb/s; no debe compararse directamente con
los promedios de transferencia de la tabla.

**Conclusión respaldada por la prueba:** BBR mejoró la entrega en esta ruta y la
reproducción original volvió a funcionar. El control posterior con CUBIC y la
confirmación en el Fire TV refuerzan la atribución, aunque las pruebas no eliminan
toda variación de tráfico de Internet.

**No demostrado:** el equipo o tramo físico donde se pierden los paquetes, la
razón por la que el fabricante eligió CUBIC, ni que BBR sea mejor en todas las redes.

## Estado de la Instancia al terminar

- BBR activo en el espacio de red de `npm`; el host conservó CUBIC.
- Se añadió `services.npm.sysctls.net.ipv4.tcp_congestion_control: bbr` a un
  override local ya incluido en el despliegue. Se conservaron las demás opciones
  y se guardó una copia anterior en los Datos de las apps con sus permisos.
- Se configuró la carga de `tcp_bbr` al arrancar mediante un archivo local de
  `systemd-modules-load`. El módulo ya estaba instalado en el kernel de la Instancia.
- La validación `docker compose ... config --quiet` pasó con el conjunto real de
  archivos y el `.env` de la Instancia. No se reinició el NAS ni se recreó el proxy.
- La cuenta de prueba quedó con sus valores originales:
  `EnableVideoPlaybackTranscoding=false`, `EnableAudioPlaybackTranscoding=false`
  y `RemoteClientBitrateLimit=0`. Las demás cuentas no se modificaron.
- El vídeo, las pistas originales y la configuración de buffering del proxy
  quedaron sin cambios permanentes.

Este cambio afecta a las conexiones nuevas de todo el contenedor `npm`, incluidas
otras aplicaciones publicadas por él. No se incorporó como valor predeterminado
de la Plantilla.

## Pruebas alternativas y hallazgos secundarios

**Buffering de Nginx.** Desactivarlo temporalmente no produjo una mejora
consistente. Se restauró la configuración original y se validó con `nginx -t`.
Los avisos de escritura de vídeo en archivos temporales no demostraban por sí solos
la causa de los cortes.

**Conversión QSV.** La GPU podía generar H.264 y AAC a 6 Mb/s más rápido que en
tiempo real, incluso desde AV1 HDR. Una prueba habilitó esa adaptación, pero el
Espectador no la quería como solución. Se restauraron permisos y límite remoto;
la validación final se hizo sobre el archivo original.

**Espera de subtítulos.** Durante la prueba convertida aparecieron peticiones de
subtítulos internos canceladas repetidamente tras unos 30 segundos, con estado
499 y cero bytes. Coincidían con la extracción inicial de las pistas; el vídeo se
generaba con margen, pero el cliente dejaba de pedir nuevos segmentos.

Desactivar la pista desbloqueó esa prueba. Una vez extraída, los endpoints de
subtítulos respondieron correctamente y se pudo reactivar. Los archivos extraídos
quedaron en los Datos de las apps. Una copia externa de diagnóstico se retiró
porque reordenaba los índices durante la sesión; se verificó la restauración de
los índices originales. Este bloqueo adicional no explicaba por sí solo el
problema del original, que volvió al desactivar la conversión.

**Pista de audio alternativa.** El comando remoto para seleccionar AC3 de
comentarios no fue concluyente: el cliente no conservó el cambio y seguía
informando DTS-HD español. No se utilizó como evidencia para descartar el audio.

**Autenticación de la API.** El encabezado `Authorization` de MediaBrowser funcionó,
mientras `X-Emby-Token` devolvía 401 en la versión investigada. Los rechazos iniciales
no demostraban que las claves existentes fueran inválidas. No se cambiaron las
integraciones. Las credenciales se recibieron por campos seguros y no se guardaron
en documentación o registros del repositorio.

## Validación pendiente y reversión

Quedó pendiente probar las otras películas, varios Espectadores concurrentes y un
reinicio real del NAS o recreación del proxy. La configuración de persistencia
está preparada y validada, pero no se presentó como comprobada tras un reinicio.

Para revertir, restaurar el algoritmo anterior en el espacio de red de `npm` y
retirar solo el ajuste correspondiente del override local. Recuperar la copia
completa únicamente si no pisa cambios posteriores. Retirar la configuración de
carga del módulo solo si se creó para este caso y no la necesita otro uso.
La [guía operativa](../jellyfin-direct-play.md#revertir) recoge los pasos.

## Fuentes

- Evidencia de la investigación: registros de Jellyfin y Nginx, API de sesiones,
  ffprobe/ffmpeg, métricas de recursos, diagnósticos TCP y confirmación del Espectador.
  Los registros privados originales no se incorporan al repositorio.
- [Linux: parámetros TCP y control de congestión](https://docs.kernel.org/networking/ip-sysctl.html).
- [CUBIC, RFC 9438](https://www.rfc-editor.org/rfc/rfc9438.html).
- [BBR: explicación de sus autores](https://research.google/pubs/bbr-congestion-based-congestion-control-2/).
