#!/usr/bin/env bash
# fetch-parakeet-models.sh
#
# Dev-only one-time setup: pulls the Parakeet-TDT-0.6B v2 Core ML bundle from
# Hugging Face into Aftertalk/Resources/Models/parakeet-tdt-0.6b-v2/. The app
# enforces a hard "no network at runtime" invariant (see CLAUDE.md): models
# must be on disk before the first launch, never fetched from the device.
#
# Run this once on a dev machine *before* `xcodebuild build` if you intend to
# exercise the FluidAudio batch ASR path. Without these files,
# `FluidAudioParakeetTranscriber.warm()` throws `BatchASRError.modelMissing`,
# which is the expected CI behavior.
#
# The destination folder name is `parakeet-tdt-0.6b-v2` (no `-coreml` suffix)
# because that's the literal `Repo.parakeetV2.folderName` FluidAudio looks up
# at runtime.
#
# Total payload: ~600-700 MB (.mlmodelc directories are bundles of weights +
# compiled metadata). Files are gitignored.

set -euo pipefail

REPO_ID="FluidInference/parakeet-tdt-0.6b-v2-coreml"
HF_BASE="https://huggingface.co/${REPO_ID}/resolve/main"

# Resolve repo root from script location so the script runs from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEST="${REPO_ROOT}/Aftertalk/Resources/Models/parakeet-tdt-0.6b-v2"

echo "[parakeet] target: ${DEST}"
mkdir -p "${DEST}"

# Required model bundles + vocab. Names match ModelNames.ASR in FluidAudio.
# Each .mlmodelc is a compiled directory; download its component files.
MODEL_BUNDLES=(
  "Preprocessor.mlmodelc"
  "Encoder.mlmodelc"
  "Decoder.mlmodelc"
  "JointDecision.mlmodelc"
)

# Files that live inside every .mlmodelc directory. Hugging Face serves them
# as flat files; we recreate the directory structure locally.
MLMODELC_FILES=(
  "model.mil"
  "metadata.json"
  "coremldata.bin"
  "weights/weight.bin"
)

download_one() {
  local relpath="$1"
  local out="${DEST}/${relpath}"
  if [ -s "${out}" ]; then
    echo "[parakeet] skip (exists): ${relpath}"
    return 0
  fi
  mkdir -p "$(dirname "${out}")"
  echo "[parakeet] fetch: ${relpath}"
  if ! curl -fSL --retry 3 --retry-delay 2 -o "${out}" "${HF_BASE}/${relpath}"; then
    echo "[parakeet] WARN: ${relpath} not present on HF (some bundles omit weights/weight.bin)" >&2
    rm -f "${out}"
  fi
}

if command -v huggingface-cli >/dev/null 2>&1; then
  echo "[parakeet] using huggingface-cli (faster, resumable)"
  huggingface-cli download "${REPO_ID}" --local-dir "${DEST}" --local-dir-use-symlinks False
else
  echo "[parakeet] huggingface-cli not found, falling back to curl"
  for bundle in "${MODEL_BUNDLES[@]}"; do
    for inner in "${MLMODELC_FILES[@]}"; do
      download_one "${bundle}/${inner}"
    done
  done
  download_one "parakeet_vocab.json"
fi

echo "[parakeet] done. Bundle size:"
du -sh "${DEST}" || true
