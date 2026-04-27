# Models

This directory holds on-device ML models. The actual weights are gitignored — they're either downloaded on first launch or sourced manually from the project's HuggingFace mirror.

## moonshine-tiny-streaming-en

Source: https://huggingface.co/moonshine-ai/moonshine-tiny-streaming-en

Files expected:
- `adapter.ort`
- `cross_kv.ort`
- `decoder_kv.ort`
- `decoder_kv_with_attention.ort`
- `encoder.ort`
- `frontend.ort`
- `streaming_config.json`
- `tokenizer.bin`

To populate locally:

```bash
# from repo root
brew install git-lfs huggingface-cli
huggingface-cli download moonshine-ai/moonshine-tiny-streaming-en --local-dir Aftertalk/Models/moonshine-tiny-streaming-en
```
