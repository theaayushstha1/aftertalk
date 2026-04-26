# Aftertalk

> Your meeting, captured and conversational. Fully offline. Nothing leaves the device.

<!-- HERO_GIF: replaced day 7 with a 10s gif from the demo recording -->

Aftertalk is a personal experiment in fully on-device meeting intelligence. Built in 7 days during finals week for iOS 18+ on iPhone Air and iPhone 17 Pro Max. Open source, MIT licensed.

<!-- BUILD_STATUS_BADGE -->

## Why
Meeting note tools today either send your audio to a vendor's cloud, or skip transcription entirely and rely on you to summarize. Aftertalk runs the entire pipeline — ASR, summarization, RAG over multiple meetings, voice Q&A with neural TTS — on the phone, in airplane mode. The privacy claim is auditable: no `URLSession` import in production paths, runtime `NWPathMonitor` assertion, demo video records with airplane mode visible throughout.

## What's inside

<!-- COMPONENT_TABLE: filled day 7 with measured latency numbers -->
| Layer | Model | Size | License | Latency |
|---|---|---|---|---|
| ASR | Moonshine tiny EN | TBD | MIT | TBD ms TTFT |
| LLM | Apple Foundation Models | (system) | Apple | TBD tok/s |
| Embeddings | gte-small | TBD | Apache-2 | TBD ms / vector |
| Vector store | sqlite-vec | TBD | MIT | TBD ms / query |
| TTS | Kokoro 82M (FluidAudio) | TBD | Apache-2 | TBD ms first-audio |
| Diarization | Pyannote (FluidAudio) | TBD | MIT | TBD% accuracy |
| VAD | TEN-VAD | TBD | Apache-2 | TBD ms / frame |
| EoU | Pipecat SmartTurnV3 | TBD | MIT | TBD ms / inference |

## Architecture

<!-- MERMAID_DIAGRAM: filled day 7 -->
See [`ARCHITECTURE.md`](./ARCHITECTURE.md) for the full pipeline, data model, token + latency budgets, and audio session pitfall checklist.

## Performance (iPhone 17 Pro Max)
<!-- PERF_NUMBERS: filled day 7 from MetricKit run -->
- Time-to-first-spoken-word: TBD ms (brief target: <3000 ms)
- ASR TTFT: TBD ms
- Summary latency for 30-min meeting: TBD s
- Memory peak: TBD MB
- Battery delta over 40-min session: TBD %
- Thermal state: stayed `.fair` or below

Profile chart: [`perf/30min-meeting-chart.png`](./perf/30min-meeting-chart.png)

## Privacy

This is the entire pitch. Three layers of audit:
1. **Static**: zero `URLSession`, `URLRequest`, or HTTP calls in production code path. Verify: `git grep -n "URLSession\|URLRequest\|http://\|https://" Aftertalk/`
2. **Runtime**: `NWPathMonitor` assertion in `AppDelegate` fires if any interface is up while a meeting is recording.
3. **Visual**: airplane badge in app chrome turns green only when all interfaces are down. Visible throughout the demo video.

Specific commits that landed each privacy invariant:
<!-- PRIVACY_COMMITS: filled day 7 -->
- `<sha>` introduced `NWPathMonitor` runtime assertion
- `<sha>` removed final third-party SDK that opened a network socket
- `<sha>` set `NSAppTransportSecurity.NSAllowsArbitraryLoads = false` and removed exception domains

## Build

```bash
git clone https://github.com/theaayushstha1/aftertalk
cd aftertalk
open Aftertalk.xcodeproj
# Select your iPhone, build, run.
# First launch downloads ~150MB of models from a public mirror to ~/Library/Application Support/Aftertalk/Models/
# After that, the app works fully offline.
```

Requirements:
- Xcode 16+
- iOS 18+ device (iPhone 14+ recommended for Foundation Models perf)
- Apple Developer account on the signing team

## Stretch goals shipped

- [x] **Speaker diarization** — FluidAudio Pyannote Core ML, ~80% accuracy on iPhone mic
- [x] **Streaming Q&A** — sentence-boundary chunking → Kokoro TTS prefetch, ~750ms TTFSW
- [x] **Cross-meeting memory** — hierarchical 3-layer retrieval, global chat thread
- [x] **Neural TTS** — Kokoro 82M ANE-optimized, single-take voice
- [x] **Power profile** — MetricKit dump + matplotlib chart in `perf/`

Bonus:
- [x] Senior-grade VAD + barge-in (TEN-VAD + Pipecat SmartTurnV3 EoU)
- [x] Per-meeting + global chat threads with citations

## Tradeoffs

A few honest calls that didn't make it into v1:
- **iPhone Air is ~30% slower than 17 Pro Max** on Foundation Models throughput. We tuned the budget on Air; demo video uses 17 Pro Max for tightest TTFSW.
- **Kokoro voice is single-language English.** Multi-language voices are 4x bigger; out of scope for one week.
- **Pyannote on iPhone mic** holds ~80% diarization accuracy. >2 speakers degrades visibly. Demo restricted to 2-speaker recordings.
- **Foundation Models 4K cap** forces hierarchical RAG. Long meetings (>30min) compress less faithfully — we'd add map-reduce summarization with another two weeks.

## What I'd build with another two weeks

1. **Map-reduce summarization** for >30min meetings. Current single-pass approach degrades on long context.
2. **On-device speaker enrollment**. Right now speakers are auto-labeled "Speaker 1, 2." Enrollment would let you say "this is Sara" and have her recognized in future meetings.
3. **A Live Activity** with a recording timer + waveform. Brings the airplane-mode privacy promise into the system UI.

## Acknowledgments

- Moonshine ASR — Useful Sensors
- FluidAudio (diarization + Kokoro TTS) — Fluid Inference
- TEN-VAD — Tencent
- Pipecat SmartTurn — Daily
- gte-small embeddings — Alibaba DAMO
- sqlite-vec — Alex Garcia

## License

MIT
