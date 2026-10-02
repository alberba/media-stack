#!/usr/bin/env bash
# Load Compose-resolved settings into an associative array supplied by the caller.
# The temporary file is mode 600 and the caller's EXIT trap removes it if interrupted.
# shellcheck disable=SC2034 # Nameref and temporary path are read by the sourcing caller.
env_contract_load() {
  local target_name="$1" env_file="$2" mode="${3:-effective}"
  local -n target="$target_name"
  local key value output
  local -a options=()
  [ "$mode" != file ] || options+=(--file-only)
  output="$(mktemp)"
  ENV_VALUES_TEMP="$output"
  if ! python3 "$REPO/scripts/env_contract.py" resolve --file "$env_file" "${options[@]}" > "$output"; then
    rm -f "$output"
    ENV_VALUES_TEMP=""
    return 1
  fi
  target=()
  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    target["$key"]="$value"
  done < "$output"
  rm -f "$output"
  ENV_VALUES_TEMP=""
}
