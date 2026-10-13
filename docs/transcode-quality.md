# Calidad y selección por bitrate

La política activa prioriza conservar la calidad. Selecciona por **bitrate del
vídeo**, no por tamaño total ni por un mínimo de 10 GiB. Es una política
conservadora elegida por el Operador, no un estándar que garantice calidad visual.
Toda recodificación con pérdida puede degradar la imagen; conservar el original
es la única opción que evita esa pérdida por completo.

## Política conservadora

El [selector](../stacks/transcode/flows/conservative-select.js) se usa como código
de un paso `Custom Function` en el Flow, compartido por las ramas NVENC y VAAPI.
Solo acepta una pista de vídeo SDR 8-bit (`yuv420p` o `nv12`), H.264 o HEVC,
resolución hasta 3840×2160 y hasta 30 fps conocidos. Omite HDR/PQ/HLG, Dolby Vision,
10-bit, AV1, varias pistas de vídeo y metadatos insuficientes. No hace tone mapping.

| Resolución | H.264: mínimo de vídeo | HEVC: mínimo de vídeo |
| --- | --- | --- |
| Hasta 720p | 15 Mb/s | 12 Mb/s |
| Hasta 1080p | 25 Mb/s | 20 Mb/s |
| Superior a 1080p, hasta 4K | 80 Mb/s | 60 Mb/s |

El límite se incluye. Se usa `bit_rate` de la pista, o sus etiquetas Matroska `BPS`
o `BPS-eng`. Si faltan, se conserva el archivo: no se sustituye el dato por el
bitrate del contenedor, que también cuenta audio y otras pistas. No se lee el
vídeo completo para estimar el bitrate.

Un archivo corto de menos de 10 GiB puede superar el límite; uno largo de más de
10 GiB puede quedar por debajo. Para comparar unidades, **100 MB/min ≈ 13,33 Mb/s**,
con MB decimales. Los umbrales altos favorecen conservar encodes existentes; no
permiten deducir cuánto se ahorrará ni si habrá pérdida visible.

### Codificación

- **NVENC:** HEVC con calidad objetivo **CQ 18**, VBR, `-b:v 0`, preset `p7` y
  tuning `hq`. CQ menor pide mayor calidad; p7 favorece calidad sobre velocidad.
  Ver la [guía oficial de NVIDIA](https://docs.nvidia.com/video-technologies/video-codec-sdk/13.1/ffmpeg-with-nvidia-gpu/index.html).
- **VAAPI:** el plugin personalizado de la Instancia utiliza **QP 18**. QP de
  VAAPI y CQ de NVENC no son escalas intercambiables ni prometen igual resultado.
  La Plantilla sigue distribuyendo únicamente el encoder NVENC; adaptar el plugin
  VAAPI del Operador para aceptar `minSizeGB=0` y conservar las pistas.
- Ambos encoders reciben `minSizeGB=0` en este Flow: el selector común decide qué
  comprimir. El plugin NVENC conserva un mínimo clásico predeterminado de 10 GiB
  para bibliotecas que no usan este Flow.
- Se mantienen resolución y fps de origen. Se copian audio, subtítulos y adjuntos,
  además de metadatos y capítulos. Las pistas de audio/subtítulos/adjuntos son
  opcionales en el mapeo, para aceptar archivos que no las contienen.

### Validación antes de reemplazar

El [validador](../stacks/transcode/flows/conservative-output.js) es otro paso
`Custom Function`, después de `Check File Changed` y antes de `Replace Original File`.
Exige:

- Duración conocida y diferencia no mayor que el máximo entre un segundo y 0,1 %.
- Una pista de vídeo HEVC con la misma resolución y formato SDR de 8 bits.
- El mismo número y orden de pistas de audio, subtítulos y adjuntos, con los mismos
  códecs, canales de audio e idiomas.
- **Ahorro mínimo del 10 %** sobre el archivo original.

Si una comprobación falla, el trabajo termina con error y conserva el original;
no se añade el resultado a Skiplist. No se sube CQ/QP automáticamente para forzar
más ahorro. Estas comprobaciones de metadatos no demuestran calidad perceptual,
integridad de cada frame ni conservación perfecta de capítulos o sincronización.
Comparar escenas con movimiento, grano y zonas oscuras antes de considerar validado
el resultado de un encoder. No se ha realizado una comparación visual de la nueva
configuración en el Worker.

```text
Input → Hardlinks
          ├─ varios enlaces → Terminar
          └─ un enlace → Selección conservadora → Skiplist → Elegir GPU → Codificar
                                                                         ↓
                                                              Check File Changed
                                                                         ↓
                                                              Validar resultado
                                                                         ↓
                                                              Reemplazar → Skiplist
```

Los archivos descartados por selección y los ya registrados terminan sin codificar.
Un trabajo iniciado antes de guardar el Flow puede conservar su configuración previa.
Los scripts son la fuente del código de ambos `Custom Function`: copiarlos completos
al Flow. El rechecker verifica coincidencia exacta, conexiones y orden. Editar un
script en el repositorio exige actualizar también el código guardado en el Flow.
La revisión horaria no aplica un mínimo de tamaño; un archivo liberado vuelve a
pasar por esta selección al recibirlo el Worker.

## Alternativa: priorizar ahorro

**Documentada, no activada.** Como punto de partida para evaluar muestras:

| Resolución | H.264: mínimo de vídeo | HEVC: mínimo de vídeo |
| --- | --- | --- |
| Hasta 720p | 6 Mb/s | 4 Mb/s |
| Hasta 1080p | 10 Mb/s | 8 Mb/s |
| Superior a 1080p, hasta 4K | 35 Mb/s | 25 Mb/s |

Se podría probar NVENC CQ 23–24 y exigir ahorro del 20 %. Esos valores también
son propuestas del Operador, no garantías ni equivalentes de QP VAAPI. Se acepta
más riesgo de pérdida visible y se comprimen más encodes existentes.

Mantener hardlinks, Skiplist por contenido, copia de pistas y validación de salida.
Conservar las exclusiones HDR/Dolby Vision/10-bit hasta verificar un flujo que
preserve sus metadatos y formato; priorizar ahorro no justifica descartarlos.
Cambiar los umbrales requiere actualizar el selector, el Flow y la validación del
rechecker juntos. Revisar muestras antes de activar esta alternativa.
