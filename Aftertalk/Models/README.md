# Models

This directory holds on-device ML models. Files are gitignored; they're sourced from the public Moonshine CDN.

## moonshine-medium-streaming-en (active)

Streaming English ASR, 245M params, 6.65% WER on LibriSpeech test-clean — beats Whisper Large v3 (7.44%) at a fraction of the size. Bundle: ~303 MB.

Source: `https://download.moonshine.ai/model/medium-streaming-en/quantized/<file>`.

Files expected:
- `adapter.ort` (3.6 MB)
- `cross_kv.ort` (11.5 MB)
- `decoder_kv.ort` (146.2 MB)
- `encoder.ort` (94.2 MB)
- `frontend.ort` (47.5 MB)
- `streaming_config.json`
- `tokenizer.bin`

The C++ runtime probes for an optional `decoder_kv_with_attention.ort` and prints a warning if missing — expected and harmless for the streaming variants.

To populate locally:

```bash
mkdir -p Aftertalk/Models/moonshine-medium-streaming-en
cd Aftertalk/Models/moonshine-medium-streaming-en
for f in adapter.ort cross_kv.ort decoder_kv.ort encoder.ort frontend.ort streaming_config.json tokenizer.bin; do
  curl -fSL -o "$f" "https://download.moonshine.ai/model/medium-streaming-en/quantized/$f"
done
```

## moonshine-small-streaming-en (kept as fallback)

123M params, 7.84% WER, ~157 MB. Used pre-day-3.10. Same file list as medium. Source: the same CDN with `small-streaming-en` in the path, or extract from `https://github.com/moonshine-ai/moonshine/releases/latest/download/ios-Transcriber.tar.gz`.

Switching back: change `ModelLocator.moonshineModelDirectory` folder name and `MoonshineStreamer` `modelArch` to `.smallStreaming`. Two-line revert.

## parakeet-tdt-0.6b-v2 (batch / canonical pass)

Lives at `Aftertalk/Resources/Models/parakeet-tdt-0.6b-v2/` (note: `-coreml` suffix is stripped — FluidAudio's `Repo.parakeetV2.folderName` is `parakeet-tdt-0.6b-v2`). Used after the recording stops to regenerate a punctuation-correct, word-timestamped transcript that grounds summary + Q&A. The streaming Moonshine pass remains the live transcript shown during recording.

Bundle: ~600-700 MB on disk (.mlmodelc dirs). Files are gitignored.

To populate locally before building (one-time setup; the app never fetches at runtime):

```bash
./Scripts/fetch-parakeet-models.sh
```

Files expected under `Aftertalk/Resources/Models/parakeet-tdt-0.6b-v2/`:
- `Preprocessor.mlmodelc/`
- `Encoder.mlmodelc/`
- `Decoder.mlmodelc/`
- `JointDecision.mlmodelc/`
- `parakeet_vocab.json`

If the directory is empty at app launch, `FluidAudioParakeetTranscriber.warm()` throws `BatchASRError.modelMissing` cleanly — this is the expected CI behavior.

## kokoro-82m-coreml (neural TTS)

Lives at `Aftertalk/Resources/Models/kokoro-82m-coreml/`. Powers the voice answer for Day 4 Q&A. Bundle: ~325 MB combined (5s + 15s variants + G2P + multilingual G2P + the `af_heart` voice pack).

To populate locally before building (one-time setup; the app never fetches at runtime):

```bash
./Scripts/fetch-kokoro-models.sh
```

Files expected under `Aftertalk/Resources/Models/kokoro-82m-coreml/`:
- `kokoro_21_5s.mlmodelc/`
- `kokoro_21_15s.mlmodelc/`
- `G2PEncoder.mlmodelc/`
- `G2PDecoder.mlmodelc/`
- `g2p_vocab.json`
- `MultilingualG2PEncoder.mlmodelc/`
- `MultilingualG2PDecoder.mlmodelc/`
- `voices/af_heart.bin`

Layout deviation: FluidAudio's `KokoroTtsManager(directory:)` expects `<directory>/Models/kokoro/<file.mlmodelc>` (where `kokoro` is `Repo.kokoro.folderName`, NOT the HF repo basename `kokoro-82m-coreml`). At first launch `KokoroTTSService` builds a symlink tree under `~/Library/Application Support/Aftertalk/KokoroStage/Models/kokoro/` pointing at the bundled `.mlmodelc` directories — no on-disk duplication.

If the directory is empty at app launch, `RootView` falls back to `AVSpeechSynthesizerTTS` so the build still runs end-to-end. This is the expected CI behaviour.

iOS 26 note: Kokoro's compiled graph crashes on the ANE compiler under iOS 26 (`Cannot retrieve vector from IRValue format int32`). `KokoroTTSService` ships `computeUnits: .cpuAndGPU` to dodge it — see `KokoroTtsManager.swift:33-37` upstream.

## speaker-diarization-coreml (Pyannote 3.1 + WeSpeaker v2)

Lives at `Aftertalk/Resources/Models/speaker-diarization-coreml/`. Used after the recording stops to attribute each utterance to a speaker. The two bundles are independent CoreML compiled directories: `pyannote_segmentation.mlmodelc/` runs voice-activity / speaker-change detection in 10s windows, `wespeaker_v2.mlmodelc/` extracts a 256-dim L2-normalized speaker embedding per segment. FluidAudio's `SpeakerManager` clusters segments internally with cosine similarity at threshold 0.7 — we never touch the embeddings ourselves; we just persist the centroid into `SpeakerLabel.embeddingCentroid` for cross-meeting voice matching later.

Bundle: ~100 MB on disk (.mlmodelc dirs). Files are gitignored.

To populate locally before building (one-time setup; the app never fetches at runtime):

```bash
./Scripts/fetch-pyannote-models.sh
```

Files expected under `Aftertalk/Resources/Models/speaker-diarization-coreml/`:
- `pyannote_segmentation.mlmodelc/`
- `wespeaker_v2.mlmodelc/`

If the directory is empty at app launch, `PyannoteDiarizationService.warm()` throws `DiarizationError.modelMissing` cleanly and `MeetingProcessingPipeline` falls through to a non-diarized path: chunks get `speakerId = nil`, no `SpeakerLabel` rows are persisted. This is the expected CI / fresh-checkout behavior.

Source: `https://huggingface.co/FluidInference/speaker-diarization-coreml`.
