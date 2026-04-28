#!/usr/bin/env bash
# fetch-kokoro-models.sh
#
# Dev-only one-time setup: pulls the Kokoro 82M Core ML bundle from Hugging
# Face into Aftertalk/Resources/Models/kokoro-82m-coreml/. The app enforces a
# hard "no network at runtime" invariant (see CLAUDE.md): models must be on
# disk before the first launch, never fetched from the device.
#
# Run once on a dev machine *before* `xcodebuild build` if you want to
# exercise the FluidAudio Kokoro TTS path. Without these files,
# `KokoroTTSService.warm()` throws `TTSError.modelMissing` and `RootView`
# falls through to AVSpeechSynthesizer — expected CI behaviour.
#
# Layout note: the destination folder is `kokoro-82m-coreml` (the literal HF
# repo name). At runtime `KokoroTTSService` symlinks the contents into
# `~/Library/Application Support/Aftertalk/KokoroStage/Models/kokoro/` because
# that is the directory layout `KokoroTtsManager(directory:)` actually expects
# (`Repo.kokoro.folderName == "kokoro"`, `<dir>/Models/kokoro/...`).
#
# Total payload: ~325 MB on disk for both 5s + 15s variants combined.
# Files are gitignored.

set -euo pipefail

REPO_ID="FluidInference/kokoro-82m-coreml"
HF_BASE="https://huggingface.co/${REPO_ID}/resolve/main"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEST="${REPO_ROOT}/Aftertalk/Resources/Models/kokoro-82m-coreml"

echo "[kokoro] target: ${DEST}"
mkdir -p "${DEST}"

# Required compiled CoreML bundles (recon §1.3):
# - Two TTS variants: kokoro_21_5s.mlmodelc, kokoro_21_15s.mlmodelc
# - G2P pair: G2PEncoder.mlmodelc, G2PDecoder.mlmodelc + g2p_vocab.json
# - Multilingual G2P pair (loaded eagerly by FluidAudio):
#   MultilingualG2PEncoder.mlmodelc, MultilingualG2PDecoder.mlmodelc
MODEL_BUNDLES=(
  "kokoro_21_5s.mlmodelc"
  "kokoro_21_15s.mlmodelc"
  "G2PEncoder.mlmodelc"
  "G2PDecoder.mlmodelc"
  "MultilingualG2PEncoder.mlmodelc"
  "MultilingualG2PDecoder.mlmodelc"
)

# Files that live inside every .mlmodelc directory.
MLMODELC_FILES=(
  "model.mil"
  "metadata.json"
  "coremldata.bin"
  "weights/weight.bin"
)

# Top-level assets shipped alongside the bundles.
TOP_LEVEL_FILES=(
  "g2p_vocab.json"
)

# Default voice pack (af_heart). The repo also ships ~50 other voices; we only
# need the one we ship with the demo. Add more here if/when we A/B voices.
VOICE_FILES=(
  "voices/af_heart.bin"
)

download_one() {
  local relpath="$1"
  local out="${DEST}/${relpath}"
  if [ -s "${out}" ]; then
    echo "[kokoro] skip (exists): ${relpath}"
    return 0
  fi
  mkdir -p "$(dirname "${out}")"
  echo "[kokoro] fetch: ${relpath}"
  if ! curl -fSL --retry 3 --retry-delay 2 -o "${out}" "${HF_BASE}/${relpath}"; then
    echo "[kokoro] WARN: ${relpath} not present on HF (some bundles omit weights/weight.bin)" >&2
    rm -f "${out}"
  fi
}

if command -v huggingface-cli >/dev/null 2>&1; then
  echo "[kokoro] using huggingface-cli (faster, resumable)"
  huggingface-cli download "${REPO_ID}" --local-dir "${DEST}" --local-dir-use-symlinks False
else
  echo "[kokoro] huggingface-cli not found, falling back to curl"
  for bundle in "${MODEL_BUNDLES[@]}"; do
    for inner in "${MLMODELC_FILES[@]}"; do
      download_one "${bundle}/${inner}"
    done
  done
  for top in "${TOP_LEVEL_FILES[@]}"; do
    download_one "${top}"
  done
  for voice in "${VOICE_FILES[@]}"; do
    download_one "${voice}"
  done
fi

echo "[kokoro] done. Bundle size:"
du -sh "${DEST}" || true
