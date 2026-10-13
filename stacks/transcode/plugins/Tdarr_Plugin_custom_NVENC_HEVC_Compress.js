/* eslint-disable */
// Shipped by the media-stack Template (transcode Profile) and mounted read-only into
// Tdarr's Plugins/Local, so edit it here, not in Tdarr's UI.
const details = () => {
  return {
    id: 'Tdarr_Plugin_custom_NVENC_HEVC_Compress',
    Stage: 'Pre-processing',
    Name: 'NVENC HEVC Compress (fuerza re-codificación)',
    Type: 'Video',
    Operation: 'Transcode',
    Description: `Re-codifica archivos de vídeo a HEVC usando NVENC (NVIDIA GPU).
Útil para comprimir remuxes o encodes de alto bitrate que ya están en HEVC.
Omite archivos cuyo tamaño sea menor al mínimo configurado, y los que aún tienen
otro hardlink (siguen compartiéndose en qBittorrent): re-codificarlos rompería el
torrent y duplicaría el espacio.`,
    Version: '1.2',
    Tags: 'pre-processing,ffmpeg,video only,h265,nvenc,gpu',
    Inputs: [
      {
        name: 'minSizeGB',
        type: 'string',
        defaultValue: '10',
        inputUI: { type: 'text' },
        tooltip: 'Tamaño mínimo del archivo en GB para procesarlo. Archivos más pequeños se omiten; 0 desactiva el mínimo para un Flow con filtro de bitrate.\nEjemplo: 0',
      },
      {
        name: 'quality',
        type: 'string',
        defaultValue: '18',
        inputUI: { type: 'text' },
        tooltip: 'Calidad objetivo NVENC (CQ). 18=conservadora, 24=más ahorro. No garantiza ausencia de pérdida.\nEjemplo: 18',
      },
    ],
  };
};

// eslint-disable-next-line @typescript-eslint/no-unused-vars
const plugin = (file, librarySettings, inputs, otherArguments) => {
  const lib = require('../methods/lib')();
  // eslint-disable-next-line @typescript-eslint/no-unused-vars,no-param-reassign
  inputs = lib.loadDefaultValues(inputs, details);

  const response = {
    processFile: false,
    preset: '',
    container: '.mkv',
    handBrakeMode: false,
    FFmpegMode: true,
    reQueueAfter: false,
    infoLog: '',
  };

  // Verificar que es vídeo
  if (file.fileMedium !== 'video') {
    response.infoLog += '☒ No es un archivo de vídeo.\n';
    return response;
  }

  // Comprobar tamaño mínimo
  const minSizeGB = Number(inputs.minSizeGB);
  if (!Number.isFinite(minSizeGB) || minSizeGB < 0) {
    response.infoLog += '☒ Tamaño mínimo inválido. Omitido.\n';
    return response;
  }
  const fileSizeGB = file.file_size / 1024; // file_size está en MB
  if (fileSizeGB < minSizeGB) {
    response.infoLog += `☒ Archivo (${fileSizeGB.toFixed(2)} GB) menor al mínimo (${minSizeGB} GB). Omitido.\n`;
    return response;
  }

  // Radarr/Sonarr importan con hardlinks: mientras el torrent sigue en qBittorrent,
  // el archivo de la Biblioteca tiene más de un enlace. Solo se toca cuando ya no.
  let links;
  try {
    links = require('fs').statSync(file._id).nlink;
  } catch (err) {
    response.infoLog += `☒ No se puede leer ${file._id} (${err.code || err.message}). Omitido.\n`;
    return response;
  }
  if (links > 1) {
    response.infoLog += `☒ Archivo con ${links} hardlinks: aún se comparte. Omitido.\n`;
    return response;
  }

  const quality = Number(inputs.quality);
  if (!Number.isFinite(quality) || quality < 1 || quality > 51) {
    response.infoLog += '☒ Calidad CQ inválida. Omitido.\n';
    return response;
  }

  response.infoLog += `☑ Archivo: ${fileSizeGB.toFixed(2)} GB → Re-codificando con NVENC HEVC (CQ=${quality}).\n`;
  response.processFile = true;

  // NVENC HEVC encode con hardware decoding (CUDA).
  // -hwaccel cuda -hwaccel_output_format cuda: decodifica en GPU y mantiene frames en memoria GPU.
  // hevc_nvenc: codificador NVENC de NVIDIA.
  // -map 0:V (mayúscula) excluye imágenes adjuntas (cover.jpg, thumbnails).
  response.preset = `-hwaccel cuda -hwaccel_output_format cuda`
    + `,-c:v hevc_nvenc -rc vbr -cq ${quality} -b:v 0 -preset p7 -tune hq -c:a copy -c:s copy -c:t copy -map 0:V -map 0:a? -map 0:s? -map 0:t? -map_metadata 0 -map_chapters 0 -fps_mode passthrough`;

  response.container = '.mkv';
  response.handBrakeMode = false;
  response.FFmpegMode = true;
  response.reQueueAfter = false;

  return response;
};

module.exports.details = details;
module.exports.plugin = plugin;
