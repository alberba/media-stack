#!/usr/bin/env bash
# Verify bitrate selection and output rejection without encoding library media.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
run_policy_tests() {
  "$@" <<'JS'
const assert = require('assert');
const select = require('./stacks/transcode/flows/conservative-select.js').evaluate;
const validate = require('./stacks/transcode/flows/conservative-output.js').validate;
const video = { codec_type:'video', codec_name:'h264', width:1920, height:1080,
  pix_fmt:'yuv420p', avg_frame_rate:'24000/1001', bit_rate:'30000000' };
const file = { fileMedium:'video', file_size:5000, ffProbeData:{streams:[video], format:{duration:'3600'}} };
const withVideo = changes => ({ ...file, ffProbeData: { ...file.ffProbeData, streams:[{...video,...changes}] } });
assert(select(file).process, 'High bitrate file below 10GiB should be eligible');
assert(!select(withVideo({bit_rate:'24000000'})).process);
assert(select(withVideo({bit_rate:'25000000'})).process);
assert(!select(withVideo({bit_rate:undefined})).process, 'No overall bitrate fallback');
assert(select(withVideo({bit_rate:undefined,tags:{BPS:'30000000'}})).process);
for(const change of [{codec_name:'av1'}, {pix_fmt:'yuv420p10le'}, {pix_fmt:undefined},
  {color_transfer:'smpte2084'}, {color_transfer:'arib-std-b67'}, {avg_frame_rate:'60'},
  {side_data_list:[{side_data_type:'DOVI configuration record'}]}]) assert(!select(withVideo(change)).process);
assert(!select(withVideo({width:3840,height:1600,bit_rate:'79000000'})).process);
assert(select(withVideo({width:3840,height:1600,bit_rate:'80000000'})).process);
const audio = {codec_type:'audio',codec_name:'dts',channels:6,tags:{language:'eng'}};
const original = {...file,ffProbeData:{...file.ffProbeData,streams:[video,audio]}};
const output = {file_size:4000,ffProbeData:{format:{duration:'3600'},streams:[{...video,codec_name:'hevc'},audio]}};
assert(validate(original,output).accept);
assert(!validate(original,{...output,ffProbeData:{...output.ffProbeData,streams:[{...video,codec_name:'hevc',avg_frame_rate:'30'},audio]}}).accept);
assert(!validate(original,{...output,file_size:4800}).accept);
assert(!validate(original,{...output,ffProbeData:{...output.ffProbeData,format:{duration:'1800'}}}).accept);
assert(!validate(original,{...output,ffProbeData:{...output.ffProbeData,streams:[{...video,codec_name:'hevc'}]}}).accept);
console.log('PASS: bitrate boundaries, unknown metadata, HDR/DV/10-bit exclusions, duration, savings and copied audio');
JS
}
cd "$REPO"
if command -v node >/dev/null 2>&1; then
  run_policy_tests node
else
  run_policy_tests docker run --rm -i -v "$REPO:/repo:ro" -w /repo node:22-alpine node
fi
