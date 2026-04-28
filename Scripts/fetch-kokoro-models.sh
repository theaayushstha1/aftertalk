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

# Top-level assets shipped alongside the bundles. FluidAudio's Kokoro pipeline
# loads these directly from `<Caches>/fluidaudio/Models/kokoro/`:
# - `g2p_vocab.json`        — G2P grapheme/phoneme tables (G2PModel.swift:171)
# - `vocab_index.json`      — phoneme → token id lookup (KokoroVocabulary.swift:28)
# - `us_lexicon_cache.json` — preferred US English lexicon (KokoroSynthesizer+LexiconCache.swift)
# - `us_gold.json` / `us_silver.json` — fallback US lexicons
# - `gb_gold.json` / `gb_silver.json` — UK lexicons
# Without these the app would have to hit the network at first synthesis,
# which violates our airplane-mode invariant.
TOP_LEVEL_FILES=(
  "g2p_vocab.json"
  "vocab_index.json"
  "us_lexicon_cache.json"
  "us_gold.json"
  "us_silver.json"
  "gb_gold.json"
  "gb_silver.json"
)

# Default voice pack (af_heart). FluidAudio's voice loader expects the JSON
# variant (KokoroSynthesizer+VoiceEmbeddings.swift:28) — the `.bin` files at
# the same path are unused by the public API. Add more voice ids here if we
# audition different voices for the demo.
VOICE_FILES=(
  "voices/af_heart.json"
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

# Allowlist to keep the bundle near 700 MB. The HF repo also ships
# uncompiled `.mlpackage`, ANE residency dumps, kokoro_24_*, kokoro_*_v2 and
# kokoro_*_10s variants we don't load — pulling those balloons the bundle to
# ~4 GB and breaks app installs on real devices.
HF_INCLUDES=(
  "kokoro_21_5s.mlmodelc/*"
  "kokoro_21_15s.mlmodelc/*"
  "G2PEncoder.mlmodelc/*"
  "G2PDecoder.mlmodelc/*"
  "MultilingualG2PEncoder.mlmodelc/*"
  "MultilingualG2PDecoder.mlmodelc/*"
  "g2p_vocab.json"
  "vocab_index.json"
  "us_lexicon_cache.json"
  "us_gold.json"
  "us_silver.json"
  "gb_gold.json"
  "gb_silver.json"
  "voices/af_heart.json"
)

if command -v hf >/dev/null 2>&1; then
  echo "[kokoro] using hf cli (faster, resumable, allowlist)"
  hf_args=()
  for pattern in "${HF_INCLUDES[@]}"; do
    hf_args+=(--include "${pattern}")
  done
  hf download "${REPO_ID}" --local-dir "${DEST}" "${hf_args[@]}"
elif command -v huggingface-cli >/dev/null 2>&1 && huggingface-cli --version >/dev/null 2>&1; then
  echo "[kokoro] using huggingface-cli (legacy, allowlist)"
  hf_args=()
  for pattern in "${HF_INCLUDES[@]}"; do
    hf_args+=(--include "${pattern}")
  done
  huggingface-cli download "${REPO_ID}" --local-dir "${DEST}" --local-dir-use-symlinks False "${hf_args[@]}"
else
  echo "[kokoro] no hf cli, falling back to curl"
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
