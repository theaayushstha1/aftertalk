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
