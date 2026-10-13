// Canonical Custom Function source: validate the cached output before replacement.
function validate(original, output) {
  const fail = reason => ({ accept: false, reason });
  const a = original.ffProbeData, b = output.ffProbeData;
  const durationA = Number(a?.format?.duration), durationB = Number(b?.format?.duration);
  if (!(durationA > 0 && durationB > 0) || Math.abs(durationA - durationB) > Math.max(1, durationA * 0.001)) return fail('Duración ausente o distinta');
  const streams = obj => (obj?.streams || []).filter(s => !s.disposition?.attached_pic);
  const av = streams(a).filter(s => s.codec_type === 'video'), bv = streams(b).filter(s => s.codec_type === 'video');
  if (av.length !== 1 || bv.length !== 1 || bv[0].codec_name !== 'hevc'
      || av[0].width !== bv[0].width || av[0].height !== bv[0].height
      || !['yuv420p', 'nv12'].includes(bv[0].pix_fmt)) return fail('Vídeo/resolución/formato de salida no coincide');
  const frameRate = s => {
    const [n, d = '1'] = String(s.avg_frame_rate || s.r_frame_rate || '').split('/');
    return Number(n) / Number(d);
  };
  const fpsA = frameRate(av[0]), fpsB = frameRate(bv[0]);
  if (!(fpsA > 0 && fpsB > 0) || Math.abs(fpsA - fpsB) > 0.01) return fail('FPS distintos o desconocidos');
  for (const type of ['audio', 'subtitle', 'attachment']) {
    const before = streams(a).filter(s => s.codec_type === type), after = streams(b).filter(s => s.codec_type === type);
    if (before.length !== after.length || before.some((s, i) =>
      s.codec_name !== after[i].codec_name || s.channels !== after[i].channels
      || s.tags?.language !== after[i].tags?.language)) return fail(`Pistas ${type} distintas`);
  }
  const ratio = Number(output.file_size) / Number(original.file_size);
  if (!(ratio > 0 && ratio <= 0.90)) return fail('Ahorro inferior al 10%; conservar original');
  return { accept: true, reason: `Comprobaciones correctas; ahorro ${(100 * (1-ratio)).toFixed(1)}%` };
}
module.exports = async args => {
  const result = validate(args.originalLibraryFile, args.inputFileObj);
  args.jobLog(result.reason);
  if (!result.accept) throw new Error(`Resultado conservador rechazado: ${result.reason}`);
  return { outputFileObj: args.inputFileObj, outputNumber: 1, variables: args.variables };
};
module.exports.validate = validate;
