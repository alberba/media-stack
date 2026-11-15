# Reproducción directa remota: CUBIC y BBR

Esta guía explica cómo investigar cortes de Jellyfin sin cambiar la calidad del
archivo ni convertir sus pistas. Incluye lo aprendido en el
[diagnóstico del 15 de noviembre de 2026](research/2026-11-15-jellyfin-direct-play-bbr.md).
El ajuste descrito pertenece a la **Instancia**, no es un nuevo valor predeterminado
de la Plantilla.

## Qué cambia y qué se conserva

CUBIC y BBR son algoritmos de control de congestión TCP: deciden cuánto puede
enviar el servidor sin esperar nuevas confirmaciones de recepción. No modifican
el vídeo, el audio, la resolución ni el tamaño del archivo.

**DirectPlay** significa que Jellyfin entrega el archivo original al reproductor.
Un remux puede cambiar el contenedor copiando las pistas sin recodificarlas;
la transcodificación sí convierte alguna pista. Conviene comprobar el método real
de la sesión, no deducirlo solo de la calidad seleccionada en la tele.

El control de congestión es una función de Linux. Jellyfin y el proxy usan las
conexiones del sistema; no eligen automáticamente BBR porque una película tenga
un bitrate alto. El valor inicial depende de la configuración del kernel y de la
Instancia. Tener un módulo disponible tampoco significa que esté cargado o activo.
[Documentación de Linux](https://docs.kernel.org/networking/ip-sysctl.html).

## Explicación sencilla

Imagina que el NAS manda la película en camiones por una carretera:

- **CUBIC** aumenta el envío y, cuando detecta pérdidas como señal de congestión,
  reduce el ritmo. Esa reacción ayuda cuando existe saturación real, pero en
  determinadas rutas las pérdidas pueden hacer que reduzca demasiado el caudal.
- **BBR** estima la capacidad de entrega y el tiempo de viaje de los datos para
  ajustar el envío. Puede aprovechar mejor algunas rutas donde el comportamiento
  basado en pérdidas deja poco caudal.

Los dos intentan aprovechar la red sin desbordarla. CUBIC es una opción muy
estudiada para transferencias TCP y puede funcionar bien tanto para páginas web
como para descargas o vídeo. BBR no es una mejora universal: su resultado depende
de la red, del kernel y del tráfico con el que comparte la conexión. No aumenta
la velocidad contratada ni repara el equipo que pierde paquetes.
[CUBIC, RFC 9438](https://www.rfc-editor.org/rfc/rfc9438.html);
[explicación de BBR por sus autores](https://research.google/pubs/bbr-congestion-based-congestion-control-2/).

### Para qué sirve CUBIC y quién lo usaría

CUBIC se diseñó para aprovechar conexiones rápidas y de larga distancia con
estabilidad, mejorando el crecimiento de la ventana de algoritmos anteriores.
También busca compartir capacidad con otros flujos, incluyendo mecanismos de
compatibilidad con Reno. Su comportamiento cuenta con una amplia experiencia de
despliegue; no es un algoritmo defectuoso por haber rendido mal en este caso.

Puede utilizarlo un servidor web, un sistema de copias de seguridad, un equipo que
descarga archivos o un servidor de vídeo. La aplicación suele heredar la selección
del sistema. Una red que funciona bien con CUBIC no necesita cambiar solo porque
otra Instancia haya obtenido mejores resultados con BBR.
[Diseño y experiencia de despliegue de CUBIC](https://www.rfc-editor.org/rfc/rfc9438.html#section-1).

### Por qué una película revela el problema

Una descarga puede tardar más y terminar correctamente. Una película necesita
que llegue suficiente información a tiempo para mantener su búfer. Por eso un
problema de caudal sostenido puede afectar a ciertos archivos y dejar que otros
más ligeros funcionen sin cortes.

## Cómo distinguir las causas

1. **Anotar el síntoma exacto:** círculo de carga, tirones o imagen congelada;
   película, minuto, cliente, versión y ubicación del Espectador.
2. **Consultar la sesión:** `PlayMethod`, `TranscodingInfo`, pistas seleccionadas
   y avance de `PositionTicks`. Si se exige reproducción original, verificar
   `DirectPlay` y ausencia de conversión.
3. **Medir el archivo:** códecs, bitrate total y picos; no basta con saber que es
   1080p. En DirectPlay se entrega el contenedor, que puede incluir pistas no
   seleccionadas. Los picos no exigen necesariamente una conexión de igual
   velocidad instantánea si existe suficiente búfer.
4. **Descartar falta de recursos:** CPU, memoria, lectura de disco, errores del
   enlace, tráfico competidor y generación de segmentos si hay conversión.
5. **Comprobar la ruta efectiva:** un test de velocidad contra otro servidor no
   mide la conexión hasta la Instancia. Un equipo con Tailscale también puede
   acceder al dominio público por su conexión normal; verificar ruta e IP destino.
6. **Repetir la misma transferencia:** mismo recurso, rango de bytes y ruta.
   Usar una muestra limitada del archivo original para medir entrega sostenida.
   Descargar un recurso web pequeño puede ocultar un problema de una conexión
   larga. Descartar la salida evita guardar otra copia del vídeo.
7. **Observar TCP:** caudal de entrega, retransmisiones, ventana de congestión y
   tiempo limitado por la ventana del receptor. Una cola de envío por sí sola no
   localiza el problema ni demuestra que el cliente tenga mala cobertura.
8. **Aislar la prueba:** pausar la película puede dejar la descarga activa. Salir
   de reproducción y confirmar el descenso de tráfico antes de medir capacidad
   sin competencia. Si se mide con tráfico concurrente, registrarlo.

Los registros pueden incluir claves en las URL. Antes de guardarlos o compartirlos,
eliminar tokens, cabeceras de autorización, dominios, direcciones y nombres de
cuentas de la Instancia. Consultar APIs con credenciales autorizadas y comprobar
qué formato de autenticación admite la versión instalada.

## Probar BBR de forma acotada

Aplicar esta prueba cuando los datos apunten al transporte TCP y el kernel tenga
soporte para BBR. No activar conversión ni cambiar pistas para comparar algoritmos:
esas modificaciones impedirían atribuir la mejora al transporte.

Antes de cambiar nada, guardar los valores actuales del host y del proxy:

```sh
cat /proc/sys/net/ipv4/tcp_congestion_control
cat /proc/sys/net/ipv4/tcp_available_congestion_control
docker exec npm cat /proc/sys/net/ipv4/tcp_congestion_control
```

Si el kernel incluye el módulo, el Operador puede cargarlo con privilegios:

```sh
sudo modprobe tcp_bbr
```

No descargar módulos de otra versión del kernel para forzar la prueba. En un
entorno sin soporte o sin permisos sobre el host no se puede asumir que bastará
con un ajuste dentro del contenedor.

Para cambiar solo el espacio de red del proxy en ejecución:

```sh
proxy_pid=$(docker inspect --format '{{.State.Pid}}' npm)
sudo nsenter --target "$proxy_pid" --net sh -c \
  'echo bbr > /proc/sys/net/ipv4/tcp_congestion_control'

docker exec npm cat /proc/sys/net/ipv4/tcp_congestion_control
cat /proc/sys/net/ipv4/tcp_congestion_control
```

Repetir una descarga del mismo fragmento con BBR, volver al algoritmo anterior
como control y repetir. Registrar tiempos, errores y tráfico concurrente. Si no
hay una mejora consistente, restaurar el valor anterior.

El cambio de valor predeterminado afecta a **conexiones nuevas**. Salir de la
película y abrirla de nuevo; si el cliente reutiliza conexiones, puede ser necesario
cerrar y reabrir la app. Confirmar el algoritmo de la conexión cuando sea posible
y comprobar la fluidez en el dispositivo real.

El alcance es todo el contenedor `npm`, incluidas las demás aplicaciones que
publique, no solo Jellyfin. El host y los otros espacios de red conservan sus
valores. Una configuración que comparta el espacio de red con otros contenedores
también compartirá el ajuste.

## Conservar un ajuste validado

Una vez comprobada la mejora, incorporar esta opción a un override local de la
Instancia que esté incluido en su despliegue:

```yaml
services:
  npm:
    sysctls:
      net.ipv4.tcp_congestion_control: bbr
```

Si la Instancia ya tiene un `operator.compose.json`, mezclar esa opción en
`services.npm.sysctls` conservando todas las demás claves. No sustituir el archivo
entero por este ejemplo ni editar la definición pública del Perfil para una
necesidad específica de una Instancia.

En un host con `systemd-modules-load`, un archivo local
`/etc/modules-load.d/media-stack-bbr.conf` que contenga `tcp_bbr` permite cargar el
módulo al arrancar. Comprobar el mecanismo de arranque del NAS; una actualización
del fabricante puede cambiar el kernel o la conservación de ajustes locales.

Guardar una copia del override con sus permisos originales en los Datos de las
apps. Validar con `docker compose config --quiet`, usando el mismo conjunto de
archivos y `.env` que el despliegue real. Esto valida Compose, pero no demuestra
por sí solo que el módulo cargue tras un reinicio o que una recreación tenga éxito.

No hace falta reiniciar el proxy para medir el cambio en caliente. Programar la
comprobación de reinicio o recreación cuando pueda interrumpirse el servicio y
volver a verificar algoritmo, reproducción original y estabilidad.

## Revertir

Restaurar el valor anterior en el espacio de red actual; si era CUBIC:

```sh
proxy_pid=$(docker inspect --format '{{.State.Pid}}' npm)
sudo nsenter --target "$proxy_pid" --net sh -c \
  'echo cubic > /proc/sys/net/ipv4/tcp_congestion_control'
```

Restaurar también esa opción en el override local. Usar su copia anterior solo si
no se han hecho otros cambios posteriores que deban conservarse. Retirar el archivo
de carga de módulo creado para esta prueba únicamente si no lo necesita otro uso.
No es necesario descargar el módulo del kernel mientras haya conexiones activas.

Reabrir la reproducción para comprobar conexiones nuevas. La reversión del
transporte no requiere modificar los archivos multimedia ni las cuentas de Jellyfin.

## Subtítulos: una causa distinta de congelación

Extraer por primera vez subtítulos internos de un archivo grande puede tardar.
En el caso documentado, el cliente repetía peticiones que acababan canceladas sin
datos mientras esperaba la extracción. El vídeo convertido se generaba con margen,
pero el reproductor no avanzaba.

Desactivar temporalmente la pista permitió continuar. Al terminar la extracción,
la misma pista respondió correctamente y pudo reactivarse. Los subtítulos extraídos
quedaron en los Datos de las apps. Ese hallazgo no explica automáticamente todos
los cortes de reproducción original ni justifica desactivar subtítulos para todos
los Espectadores.

Si se prueba una copia externa, conservar idioma y marcas de la pista y verificar
los índices tras actualizar la biblioteca. En la Instancia investigada esa copia
se retiró porque la actualización reordenaba las pistas durante la sesión.
[Subtítulos externos en Jellyfin](https://jellyfin.org/docs/general/server/media/movies/).
