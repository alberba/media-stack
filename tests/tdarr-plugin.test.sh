#!/usr/bin/env bash
# Tests for the transcode Profile's Tdarr plugin: it re-encodes only large video files
# that no longer have a hardlink (so nothing still seeding is touched). Needs node, or
# Docker to run it in the node image.
# Usage: tests/tdarr-plugin.test.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$REPO/stacks/transcode/plugins/Tdarr_Plugin_custom_NVENC_HEVC_Compress.js"
NODE_IMAGE="node:22-alpine"
. "$REPO/tests/lib.sh"

# Tdarr's layout: Plugins/Local/<plugin>.js requires ../methods/lib. The stub keeps
# only the part the plugin uses.
setup() {
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/Plugins/Local" "$SANDBOX/Plugins/methods" "$SANDBOX/media"
  cp "$PLUGIN" "$SANDBOX/Plugins/Local/plugin.js"
  cat > "$SANDBOX/Plugins/methods/lib.js" <<'EOF'
module.exports = () => ({
  loadDefaultValues: (inputs, details) => {
    const out = { ...inputs };
    details().Inputs.forEach((i) => { if (out[i.name] === undefined) out[i.name] = i.defaultValue; });
    return out;
  },
});
EOF
  echo movie > "$SANDBOX/media/single.mkv"
  echo movie > "$SANDBOX/media/seeding.mkv"
  mkdir -p "$SANDBOX/torrents" && ln "$SANDBOX/media/seeding.mkv" "$SANDBOX/torrents/seeding.mkv"
}
teardown() { rm -rf "$SANDBOX"; }

# run_plugin <file name in media/> <size in MB> [medium] [inputs JSON]: sets OUTPUT to
# "<processFile>|<preset>|<infoLog>".
run_plugin() {
  local script inputs="${4:-}"
  [ -n "$inputs" ] || inputs='{}'
  script="const p = require('/sandbox/Plugins/Local/plugin.js');
const r = p.plugin({ _id: '/sandbox/media/$1', file: '/sandbox/media/$1', file_size: $2, fileMedium: '${3:-video}' }, {}, $inputs, {});
console.log([r.processFile, r.preset, r.infoLog].join('|'));"
  if command -v node >/dev/null 2>&1; then
    OUTPUT="$(cd "$SANDBOX" && node -e "${script//\/sandbox/$SANDBOX}" 2>&1)"
  else
    OUTPUT="$(docker run --rm -v "$SANDBOX:/sandbox" "$NODE_IMAGE" node -e "$script" 2>&1)"
  fi
}

test_keeps_the_plugin_id_existing_stacks_use() {
  assert_file_contains "$PLUGIN" "id: 'Tdarr_Plugin_custom_NVENC_HEVC_Compress'"
}

test_encodes_a_large_file_without_other_links_with_nvenc() {
  run_plugin single.mkv 20480
  assert_output_contains "true|"
  assert_output_contains "hevc_nvenc -qp 24"
}

test_skips_a_large_file_that_is_still_seeding() {
  run_plugin seeding.mkv 20480
  assert_output_contains "false|"
  assert_output_contains "hardlink"
}

test_encodes_it_once_the_torrent_is_gone() {
  rm "$SANDBOX/torrents/seeding.mkv"
  run_plugin seeding.mkv 20480
  assert_output_contains "true|"
}

test_skips_files_under_the_minimum_size() {
  run_plugin single.mkv 5120
  assert_output_contains "false|"
  assert_output_contains "10 GB"
}

test_minimum_size_and_quality_are_inputs() {
  run_plugin single.mkv 5120 video '{ minSizeGB: "4", quality: "28" }'
  assert_output_contains "true|"
  assert_output_contains "hevc_nvenc -qp 28"
}

test_skips_what_is_not_video() {
  run_plugin single.mkv 20480 audio
  assert_output_contains "false|"
}

test_skips_a_file_it_cannot_read() {
  run_plugin missing.mkv 20480
  assert_output_contains "false|"
}

run_tests
