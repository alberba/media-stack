// Canonical Custom Function source for Tdarr. Shared with the hourly rechecker.
// Thresholds are an Operator policy, not a guarantee of perceptual quality.
function evaluate(file) {
  const reject = reason => ({ process: false, reason });
  if (file.fileMedium !== 'video') return reject('No es vídeo');
  const streams = file.ffProbeData?.streams || [];
  const videos = streams.filter(s => s.codec_type === 'video' && !s.disposition?.attached_pic);
  if (videos.length !== 1) return reject('Número de pistas de vídeo no compatible');
  const video = videos[0];
  if (streams.some(s => (s.side_data_list || []).some(d => /dovi|dolby|mastering|content light/i.test(d.side_data_type || '')))
      || ['smpte2084', 'arib-std-b67'].includes(video.color_transfer)
      || video.color_primaries === 'bt2020') return reject('HDR/Dolby Vision: conservar original');
  if (!['yuv420p', 'nv12'].includes(video.pix_fmt)) return reject('Profundidad/formato desconocido o distinto de SDR 8-bit');
  const [numerator, denominator = '1'] = String(video.avg_frame_rate || video.r_frame_rate || '').split('/');
  const fps = Number(numerator) / Number(denominator);
  if (!(fps > 0 && fps <= 30)) return reject('FPS desconocidos o superiores a 30');
  if (!['h264', 'hevc'].includes(video.codec_name)) return reject('Códec no seleccionado; conservar AV1 y otros');
  const width = Number(video.width), height = Number(video.height);
  if (!(width > 0 && height > 0 && width <= 3840 && height <= 2160)) return reject('Resolución no compatible');
  const tier = width <= 1280 && height <= 720 ? '720p' : width <= 1920 && height <= 1080 ? '1080p' : '4K';
  const limits = { '720p': { h264: 15, hevc: 12 }, '1080p': { h264: 25, hevc: 20 }, '4K': { h264: 80, hevc: 60 } };
  // Use only the video stream bitrate, never size/duration or container bitrate.
  const bitrate = Number(video.bit_rate || video.tags?.BPS || video.tags?.['BPS-eng']);
  if (!(Number.isFinite(bitrate) && bitrate > 0)) return reject('Bitrate de vídeo desconocido');
  const mbps = bitrate / 1e6, minimum = limits[tier][video.codec_name];
  return { process: mbps >= minimum, reason: `${tier} ${video.codec_name}: ${mbps.toFixed(2)} Mb/s; mínimo ${minimum} Mb/s` };
}
module.exports = async args => {
  const decision = evaluate(args.inputFileObj);
  args.jobLog(decision.reason);
  return { outputFileObj: args.inputFileObj, outputNumber: decision.process ? 1 : 2, variables: args.variables };
};
module.exports.evaluate = evaluate;
