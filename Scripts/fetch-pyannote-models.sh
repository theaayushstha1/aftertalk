#!/usr/bin/env bash
# fetch-pyannote-models.sh
#
# Dev-only one-time setup: pulls the FluidAudio Pyannote 3.1 segmentation +
# WeSpeaker v2 embedding Core ML bundles from Hugging Face into
# Aftertalk/Resources/Models/speaker-diarization-coreml/. Mirrors the
# Parakeet fetch script. The app enforces a hard "no network at runtime"
# invariant (see CLAUDE.md): models must be on disk before the first launch,
# never fetched from the device.
#
# Run this once on a dev machine *before* `xcodebuild build` if you intend
# to exercise the diarization path. Without these files,
# `PyannoteDiarizationService.warm()` throws `DiarizationError.modelMissing`,
# which is the expected CI behavior.
#
# Total payload: ~100 MB (.mlmodelc directories are bundles of weights +
# compiled metadata). Files are gitignored.

set -euo pipefail

REPO_ID="FluidInference/speaker-diarization-coreml"
HF_BASE="https://huggingface.co/${REPO_ID}/resolve/main"

# Resolve repo root from script location so the script runs from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEST="${REPO_ROOT}/Aftertalk/Resources/Models/speaker-diarization-coreml"

echo "[pyannote] target: ${DEST}"
mkdir -p "${DEST}"

# Required model bundles. Names match ModelNames.Diarizer in FluidAudio.
# Each .mlmodelc is a compiled directory; download its component files.
MODEL_BUNDLES=(
  "pyannote_segmentation.mlmodelc"
  "wespeaker_v2.mlmodelc"
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
    echo "[pyannote] skip (exists): ${relpath}"
    return 0
  fi
  mkdir -p "$(dirname "${out}")"
  echo "[pyannote] fetch: ${relpath}"
  if ! curl -fSL --retry 3 --retry-delay 2 -o "${out}" "${HF_BASE}/${relpath}"; then
    echo "[pyannote] WARN: ${relpath} not present on HF (some bundles omit weights/weight.bin)" >&2
    rm -f "${out}"
  fi
}

if command -v hf >/dev/null 2>&1; then
  echo "[pyannote] using hf cli (faster, resumable)"
  hf download "${REPO_ID}" --local-dir "${DEST}"
elif command -v huggingface-cli >/dev/null 2>&1 && huggingface-cli --version >/dev/null 2>&1; then
  echo "[pyannote] using huggingface-cli (legacy)"
  huggingface-cli download "${REPO_ID}" --local-dir "${DEST}" --local-dir-use-symlinks False
else
  echo "[pyannote] no hf cli, falling back to curl"
  for bundle in "${MODEL_BUNDLES[@]}"; do
    for inner in "${MLMODELC_FILES[@]}"; do
      download_one "${bundle}/${inner}"
    done
  done
fi

echo "[pyannote] done. Bundle size:"
du -sh "${DEST}" || true
