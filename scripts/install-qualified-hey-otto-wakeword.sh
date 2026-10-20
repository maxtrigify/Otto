#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <hey_otto.onnx|hey_muse.onnx> <held-out-real-speaker-eval.json>" >&2
  exit 2
fi

model_path="$1"
evaluation_path="$2"

# The classifier's file name says which phrase it was trained on, and it is installed under that
# same name. hey_otto.onnx is a "Hey Otto" model from Config/Voice/hey-otto-wakeword.yaml;
# hey_muse.onnx is the pre-rename "Hey Muse" model, which is the file name the current app loads.
# Anything else is rejected rather than guessed.
model_name="$(basename "$model_path" .onnx)"
case "$model_name" in
  hey_otto) phrase="Hey Otto" ;;
  hey_muse) phrase="Hey Muse" ;;
  *)
    echo "Model file must be named hey_otto.onnx or hey_muse.onnx (got $(basename "$model_path"))." >&2
    exit 2
    ;;
esac
for executable in jq shasum; do
  if ! command -v "$executable" >/dev/null 2>&1; then
    echo "Missing qualification dependency: $executable" >&2
    exit 2
  fi
done
if [[ ! -f "$model_path" ]]; then
  echo "Wake-word model not found: $model_path" >&2
  exit 2
fi
if [[ ! -f "$evaluation_path" ]]; then
  echo "Wake-word evaluation not found: $evaluation_path" >&2
  exit 2
fi

jq -e '
  .schema_version == 1 and
  .corpus_kind == "held-out-real-speakers" and
  .real_speaker_count >= 5 and
  .positive_samples >= 100 and
  .negative_samples > 0 and
  .validation_hours >= 10 and
  .recall >= 0.90 and
  .false_positives_per_hour <= 0.10 and
  .threshold > 0 and .threshold < 1
' "$evaluation_path" >/dev/null || {
  echo "The model has not passed the $phrase real-speaker release gates." >&2
  exit 1
}

# OTTO_WAKEWORD_INSTALL_ROOT is primary; MUSE_WAKEWORD_INSTALL_ROOT is the pre-rename fallback.
# Without an override, install into Application Support/Otto. If only a real (not yet migrated)
# Application Support/Muse folder exists, install there instead: creating Otto here would leave
# both folders behind, and Otto never merges them on launch.
support_root="$HOME/Library/Application Support"
default_root="$support_root/Otto/VoiceModels/WakeWord"
if [[ ! -e "$support_root/Otto" && -d "$support_root/Muse" && ! -L "$support_root/Muse" ]]; then
  default_root="$support_root/Muse/VoiceModels/WakeWord"
fi
install_root="${OTTO_WAKEWORD_INSTALL_ROOT:-${MUSE_WAKEWORD_INSTALL_ROOT:-$default_root}}"
mkdir -p "$install_root"
staging_dir="$(mktemp -d "$install_root/.install.XXXXXX")"
trap 'rmdir "$staging_dir" 2>/dev/null || true' EXIT

model_digest="$(shasum -a 256 "$model_path" | awk '{print $1}')"
cp "$model_path" "$staging_dir/$model_name.onnx"
jq --arg evaluated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg model_sha256 "$model_digest" '
  {
    schemaVersion: .schema_version,
    evaluatedAt: $evaluated_at,
    threshold: .threshold,
    recall: .recall,
    falsePositivesPerHour: .false_positives_per_hour,
    positiveSamples: .positive_samples,
    negativeSamples: .negative_samples,
    validationHours: .validation_hours,
    realSpeakerCount: .real_speaker_count,
    corpusKind: .corpus_kind,
    modelSHA256: $model_sha256
  }
' "$evaluation_path" > "$staging_dir/$model_name.quality.json"

mv "$staging_dir/$model_name.onnx" "$install_root/$model_name.onnx"
mv "$staging_dir/$model_name.quality.json" "$install_root/$model_name.quality.json"
echo "Installed qualified $phrase model at $install_root/$model_name.onnx"
