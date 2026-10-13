# Ejemplos de automatizaciones de qui

Payloads de la API de qui **v1.31.1**, documentados en
[reglas de compresión y protección de torrents](../../docs/transcode-rules.md).
No contienen credenciales, IDs de una Instancia, torrents ni URLs de announce.
El sufijo `.example` permite versionarlos como ejemplos reutilizables.

| Archivo | Función |
| --- | --- |
| [privados-etiqueta.dry-run.json.example](privados-etiqueta.dry-run.json.example) | Añadir `proteger-privado` a torrents con `PRIVATE = true` |
| [publicos-72h.dry-run.json.example](publicos-72h.dry-run.json.example) | Seleccionar públicos con 72 horas, excluyendo cross-seeds detectados con esa etiqueta |

Ambos llevan `enabled: false` y `dryRun: true`. **No son exportaciones de la
interfaz de qui**, sino cuerpos JSON para su API. Antes de usarlos, comprobar
compatibilidad de campos y la conexión de qBittorrent en la versión instalada.

## Preparación y validación

1. Obtener el ID de la conexión a qBittorrent mediante `GET /api/instances`.
   Autenticar con una clave API de qui en la cabecera `X-API-Key`; conservarla fuera
   de git y de los informes.
2. Enviar cada payload a
   `POST /api/instances/{id}/automations/dry-run`. No se guardan como reglas activas
   ni se realizan borrados; el resultado se registra en la actividad de qui.
3. Consultar los candidatos en
   `GET /api/instances/{id}/automations/activity/{activityId}`. Comparar la selección
   y comprobar que los archivos importados permanecen en la Biblioteca.
4. Si se quieren guardar como reglas, usar
   `POST /api/instances/{id}/automations`, inicialmente con los flags del ejemplo.
   Revisar y aplicar el etiquetado antes de habilitar cualquier retirada pública.
5. Ordenar primero la regla de etiquetado y después la de retirada. El ejemplo
   propone 60 segundos para etiquetar y 900 segundos para retirar. El orden y la
   frecuencia no hacen atómicas las actualizaciones de etiquetas y cachés.

Pasar a `enabled: true` y `dryRun: false` permite acciones reales. La acción de
retirada elimina datos de descargas si qui no detecta cross-seeds que los necesiten.
No activar antes de revisar candidatos existentes, importaciones y limitaciones
de detección descritas en la guía.

Los ejemplos no crean ni modifican reglas de retirada para trackers privados,
ni configuran Tdarr. Cambiar los archivos del repositorio tampoco actualiza una
regla que ya se haya guardado en qui; los datos de las apps pertenecen a la Instancia.
