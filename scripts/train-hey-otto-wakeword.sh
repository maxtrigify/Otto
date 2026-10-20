#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
action="${1:-validate}"
config_path="${2:-$repo_root/Config/Voice/hey-otto-wakeword.yaml}"
expected_revision="95448a7559c453fcd87645bd67b247ffb45f85b0"
upstream_url="https://github.com/livekit/livekit-wakeword.git"

# OTTO_WAKEWORD_* is primary; the pre-rename MUSE_WAKEWORD_* names are read as a fallback.
otto_env() {
  local name="$1"
  local primary="OTTO_WAKEWORD_$name" legacy="MUSE_WAKEWORD_$name"
  if [[ -n "${!primary:-}" ]]; then
    printf '%s' "${!primary}"
  elif [[ -n "${!legacy:-}" ]]; then
    printf '%s' "${!legacy}"
  fi
  return 0
}

# Training data is phrase-specific, so "hey otto" gets its own root. The pre-rename
# Muse/VoiceTraining/HeyMuse workspace (synthesized "hey muse" clips) is never reused.
default_training_root="$HOME/Library/Application Support/Otto/VoiceTraining/HeyOtto"
training_root="$(otto_env TRAINING_ROOT)"
training_root="${training_root:-$default_training_root}"
wakeword_source_override="$(otto_env SOURCE)"
wakeword_source="${wakeword_source_override:-$training_root/upstream/livekit-wakeword}"
training_data_dir="$(otto_env DATA_DIR)"
training_data_dir="${training_data_dir:-$training_root/data}"
training_output_dir="$(otto_env OUTPUT_DIR)"
training_output_dir="${training_output_dir:-$training_root/output}"
minimum_free_override="$(otto_env MIN_FREE_GIB)"
resolved_config="$training_root/$(basename "${config_path%.yaml}").resolved.yaml"

for executable in git uv ffmpeg; do
  if ! command -v "$executable" >/dev/null 2>&1; then
    echo "Missing training dependency: $executable" >&2
    exit 2
  fi
done

if [[ ! -d "$wakeword_source/.git" ]]; then
  if [[ -n "$wakeword_source_override" ]]; then
    echo "OTTO_WAKEWORD_SOURCE is not a Git checkout: $wakeword_source" >&2
    exit 2
  fi
  mkdir -p "$(dirname "$wakeword_source")"
  git clone --filter=blob:none --no-checkout "$upstream_url" "$wakeword_source"
  git -C "$wakeword_source" checkout --detach "$expected_revision"
fi
if [[ "$(git -C "$wakeword_source" rev-parse HEAD)" != "$expected_revision" ]]; then
  echo "Wake-word source must be pinned to $expected_revision." >&2
  exit 2
fi

if [[ "$action" == "setup" || "$action" == "train" || "$action" == "smoke" ]]; then
  for executable in espeak-ng sox; do
    if ! command -v "$executable" >/dev/null 2>&1; then
      echo "Missing training dependency: $executable (install with Homebrew)." >&2
      exit 2
    fi
  done
fi

mkdir -p "$training_root" "$training_data_dir" "$training_output_dir"

escape_yaml_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

data_yaml="$(escape_yaml_string "$training_data_dir")"
output_yaml="$(escape_yaml_string "$training_output_dir")"
awk -v data_dir="$data_yaml" -v output_dir="$output_yaml" '
  /^[[:space:]]*data_dir:/ { print "data_dir: \"" data_dir "\""; next }
  /^[[:space:]]*output_dir:/ { print "output_dir: \"" output_dir "\""; next }
  /^[[:space:]]*background_paths:/ {
    print "  background_paths: [\"" data_dir "/backgrounds\"]"; next
  }
  /^[[:space:]]*rir_paths:/ {
    print "  rir_paths: [\"" data_dir "/rirs\"]"; next
  }
  { print }
' "$config_path" > "$resolved_config"

minimum_free_gib=0
case "$action" in
  setup) minimum_free_gib="${minimum_free_override:-24}" ;;
  train) minimum_free_gib="${minimum_free_override:-35}" ;;
  smoke) minimum_free_gib="${minimum_free_override:-12}" ;;
esac
if (( minimum_free_gib > 0 )); then
  available_kib="$(df -Pk "$training_root" | awk 'NR == 2 { print $4 }')"
  required_kib=$((minimum_free_gib * 1024 * 1024))
  if (( available_kib < required_kib )); then
    available_gib=$((available_kib / 1024 / 1024))
    echo "Wake-word $action requires at least ${minimum_free_gib} GiB free; ${available_gib} GiB is available." >&2
    echo "Choose a larger OTTO_WAKEWORD_TRAINING_ROOT or free disk space before continuing." >&2
    exit 2
  fi
fi

cd "$repo_root"

run_wakeword_pipeline() {
  local pipeline_config="$1"
  local uv_args=(
    --project "$wakeword_source"
    --extra train
    --extra eval
    --extra export
  )

  uv run "${uv_args[@]}" livekit-wakeword generate "$pipeline_config"
  uv run "${uv_args[@]}" python -c '
import sys
from onnxruntime import SessionOptions
from livekit.wakeword.config import load_config
from livekit.wakeword.data.augment import run_augment
from livekit.wakeword.data.features import run_extraction

config = load_config(sys.argv[1])
run_augment(config)
run_extraction(config, SessionOptions())
' "$pipeline_config"
  uv run "${uv_args[@]}" livekit-wakeword train "$pipeline_config"
  uv run "${uv_args[@]}" livekit-wakeword export "$pipeline_config"
  uv run "${uv_args[@]}" livekit-wakeword eval "$pipeline_config"
}

case "$action" in
  validate)
    PYTHONPATH="$wakeword_source/src" uv run --no-project \
      --with numpy --with onnxruntime --with pydantic --with pyyaml \
      python -c \
      'import sys; from livekit.wakeword.config import load_config; print(load_config(sys.argv[1]).model_name)' \
      "$resolved_config"
    ;;
  setup)
    uv run --project "$wakeword_source" --extra train livekit-wakeword setup --config "$resolved_config"
    ;;
  train)
    uv run --project "$wakeword_source" --extra train --extra eval --extra export \
      livekit-wakeword setup --config "$resolved_config"
    run_wakeword_pipeline "$resolved_config"
    ;;
  smoke)
    smoke_config="$repo_root/Config/Voice/hey-otto-wakeword-smoke.yaml"
    smoke_resolved_config="$training_root/hey-otto-wakeword-smoke.resolved.yaml"
    awk -v data_dir="$data_yaml" -v output_dir="$output_yaml" '
      /^[[:space:]]*data_dir:/ { print "data_dir: \"" data_dir "\""; next }
      /^[[:space:]]*output_dir:/ { print "output_dir: \"" output_dir "\""; next }
      /^[[:space:]]*background_paths:/ {
        print "  background_paths: [\"" data_dir "/backgrounds\"]"; next
      }
      /^[[:space:]]*rir_paths:/ {
        print "  rir_paths: [\"" data_dir "/rirs\"]"; next
      }
      { print }
    ' "$smoke_config" > "$smoke_resolved_config"
    uv run --project "$wakeword_source" --extra train --extra eval --extra export \
      livekit-wakeword setup --config "$smoke_resolved_config" --skip-acav
    run_wakeword_pipeline "$smoke_resolved_config"
    ;;
  *)
    echo "Usage: $0 {validate|setup|train|smoke} [config.yaml]" >&2
    exit 2
    ;;
esac
