<div align="center">

# Aftertalk

### Meeting memory that never leaves your phone.

<a href="docs/assets/aftertalk-demo.mp4">
  <img src="docs/assets/aftertalk-demo.gif" alt="Aftertalk iPhone demo: recording, structured summary, voice Q&A" width="320">
</a>

<sub><a href="docs/assets/aftertalk-demo.mp4">▶︎ watch the 22-second walkthrough (MP4)</a></sub>

<br />

[![iOS 26+](https://img.shields.io/badge/iOS-26%2B-1B1B1F?style=flat-square&logo=apple&logoColor=white)](https://developer.apple.com/ios/)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-2096FF?style=flat-square&logo=swift&logoColor=white)](https://developer.apple.com/swiftui/)
[![Foundation Models](https://img.shields.io/badge/Foundation%20Models-on--device-2F7D55?style=flat-square)](https://developer.apple.com/documentation/FoundationModels)
[![Local-first](https://img.shields.io/badge/Network-zero-1B1B1F?style=flat-square)](#privacy)
[![License: MIT](https://img.shields.io/badge/License-MIT-FFC107?style=flat-square)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-33%20passing-2F7D55?style=flat-square&logo=swift&logoColor=white)](#tests)

[**Demo**](#demo) · [**Architecture**](#architecture) · [**Q&A flow**](#qa-flow) · [**Stack**](#stack) · [**Privacy**](#privacy) · [**Build**](#build) · [**Status**](#status)

[Decisions log](DECISIONS.md) · [How it was built](THOUGHT-PROCESS.md)

</div>

---

## What it does

| **Capture** | **Understand** | **Ask** |
|---|---|---|
| Live Moonshine streaming ASR while you record. | Foundation Models extracts decisions, action items, topics, open questions. | Hold-to-talk Q&A on this meeting **or** all of them. |
| Optional Parakeet polish for word-accurate timing. | NLContextual embeddings + BM25 + RRF for hybrid retrieval. | Streaming answers with citation pills, optional Kokoro TTS. |
| Pyannote diarization for speaker-attributed chunks. | Sentence-aligned chunks indexed in SwiftData on the phone. | Soft grounding gate, full-transcript context for short meetings. |

---

<a id="demo"></a>

## Product tour

<div align="center">

<table>
  <tr>
    <td align="center"><img src="docs/assets/readme-record.png" width="200" alt="Live recording"><br><sub><b>Record</b></sub></td>
    <td align="center"><img src="docs/assets/readme-meetings.png" width="200" alt="Meetings"><br><sub><b>Meetings</b></sub></td>
    <td align="center"><img src="docs/assets/readme-summary.png" width="200" alt="Summary"><br><sub><b>Summary</b></sub></td>
    <td align="center"><img src="docs/assets/readme-transcript.png" width="200" alt="Transcript"><br><sub><b>Transcript</b></sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/assets/readme-actions.png" width="200" alt="Actions"><br><sub><b>Actions</b></sub></td>
    <td align="center"><img src="docs/assets/readme-ask.png" width="200" alt="Ask"><br><sub><b>Ask</b></sub></td>
    <td align="center"><img src="docs/assets/readme-search.png" width="200" alt="Search"><br><sub><b>Search</b></sub></td>
    <td align="center"><img src="docs/assets/readme-global-chat.png" width="200" alt="Global chat"><br><sub><b>Global</b></sub></td>
  </tr>
</table>

</div>

---

<a id="architecture"></a>

## Architecture

```mermaid
%%{init: {'theme': 'base', 'themeVariables': {'primaryColor': '#F5E7D0', 'primaryTextColor': '#1D1712', 'primaryBorderColor': '#B4532A', 'lineColor': '#8A5A44', 'secondaryColor': '#E7F1EA', 'tertiaryColor': '#E7ECF8', 'fontFamily': 'Inter, ui-sans-serif, system-ui'}}}%%
flowchart LR
    A([iPhone mic]):::capture --> B[Moonshine live ASR]:::model
    B --> C[Live transcript]:::ui
    A --> D[WAV on device]:::data
    D --> E[Parakeet polish]:::model
    D --> F[FluidAudio diarization]:::model
    E --> G[Canonical transcript]:::data
    F --> G
    G --> H[Chunks + summary]:::data
    H --> I[NLContextualEmbedding]:::model
    H --> J[Foundation Models summary]:::model
    I --> K[(SwiftData)]:::store
    J --> K
    H --> K
    K --> L[Search]:::ui
    K --> M[Meeting chat]:::ui
    K --> N[Global chat]:::ui

    classDef capture fill:#F7D9C4,stroke:#B4532A,color:#1D1712;
    classDef model fill:#E7ECF8,stroke:#4F68A8,color:#172033;
    classDef data fill:#FFF4CC,stroke:#A07708,color:#2D2200;
    classDef store fill:#E7F1EA,stroke:#2F7D55,color:#102418;
    classDef ui fill:#F0E7FF,stroke:#7450A8,color:#241338;
```

<a id="qa-flow"></a>

## Q&A flow

```mermaid
%%{init: {'theme': 'base', 'themeVariables': {'actorBkg': '#F5E7D0', 'actorBorder': '#B4532A', 'signalColor': '#4F68A8', 'activationBkgColor': '#E7F1EA', 'noteBkgColor': '#FFF4CC', 'fontFamily': 'Inter, ui-sans-serif, system-ui'}}}%%
sequenceDiagram
    autonumber
    participant U as User
    participant ASR as Question ASR
    participant Q as QAOrchestrator
    participant R as Hybrid retriever
    participant DB as SwiftData
    participant LLM as Foundation Models
    participant TTS as Local TTS

    U->>ASR: hold-to-talk question
    ASR-->>Q: local transcript
    alt Short meeting (≤ ~10k chars)
        Q->>DB: full transcript + structured summary
        Q->>R: best-effort retrieval (citations only)
    else Larger / global
        Q->>R: dense + BM25 + RRF fusion
        R->>DB: chunks, summaries, embeddings
    end
    DB-->>Q: packed context
    Q->>LLM: stream answer locally
    loop sentence stream
        LLM-->>Q: snapshot
        Q-->>U: chat bubble + citations
        Q->>TTS: speak completed sentence
    end
```

<a id="stack"></a>

## Stack

| Layer | Implementation | Notes |
|---|---|---|
| App shell | SwiftUI · SwiftData · AVAudioEngine | iOS 26+, Swift 6 strict concurrency |
| Live ASR | **Moonshine medium streaming** + EnergyVADGate | VAD-gated input keeps medium under real-time |
| Polish ASR | FluidAudio **Parakeet TDT 0.6B v2** | Word-accurate timings, ~0.5× real-time |
| Diarization | FluidAudio Pyannote 3.1 + WeSpeaker v2 | Best-effort labels, `clusteringThreshold=0.5` + ghost-cluster cleanup |
| LLM | Apple **Foundation Models** | 4096-token context, structured `@Generable` summary |
| Embeddings | Apple **NLContextualEmbedding** (512-dim) | System asset, no shipped weights |
| Retrieval | Dense + **BM25** + **Reciprocal Rank Fusion** | Full-transcript path for short meetings |
| Storage | SwiftData rows + app-local audio files | Cascade delete + repair tool for degraded indexes |
| TTS | FluidAudio **Kokoro 82M** (ANE) | AVSpeechSynthesizer fallback |

<a id="privacy"></a>

## Privacy

Aftertalk is built so meeting content never leaves the phone.

| Layer | Guarantee |
|---|---|
| Runtime network | No production `URLSession` or `URLRequest` usage in app Swift sources. |
| Capture | Recording and Q&A run locally once model assets are present. |
| Storage | Audio, transcript, summary, chat, and embeddings are app-local. |
| Verification | Settings includes a live privacy audit and model-asset status. |

```bash
git grep -nE "URLSession|URLRequest" -- 'Aftertalk/**/*.swift'
# returns zero matches in production sources
```

<a id="build"></a>

## Build

```bash
git clone https://github.com/theaayushstha1/aftertalk
cd aftertalk
xcodegen generate

# Local model bundles (gitignored, downloaded by these scripts)
./Scripts/fetch-parakeet-models.sh
./Scripts/fetch-kokoro-models.sh
./Scripts/fetch-pyannote-models.sh

# Moonshine .ort weights go under
# Aftertalk/Models/moonshine-medium-streaming-en/

open Aftertalk.xcodeproj
```

Requirements: Xcode 17+, iOS 26+ device, Apple Developer signing.

<a id="tests"></a>

## Tests

```bash
xcodebuild test -scheme Aftertalk \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

33 tests across 6 suites — VAD gating, sentence boundary detection, title sanitization, diarization cluster cleanup, BM25 tokenization, and RRF fusion. The diarization regression test explicitly encodes the ghost-cluster cycle bug that broke speaker labels under degraded acoustic conditions.

<a id="status"></a>

## Status

**Shipping**

- Record · live transcript · structured summary · transcript detail · action items · search · per-meeting chat · global chat · Settings privacy audit.
- Q&A avoids the old low-cosine refusal: full-transcript context for short meetings, hybrid dense+BM25+RRF for larger or cross-meeting queries.
- Soft grounding gate refuses only when there are truly no chunks AND no summary on the device.
- Embedding fallback + dim-mismatch filter so degraded indexes can't poison live retrieval.
- Repair tool re-embeds chunks and creates missing summary embeddings when a working embedding service comes back online.
- Optional model assets degrade explicitly with banners instead of silently breaking the recording path.

**Known limits**

- Far-field classrooms are microphone-limited; a phone across a room cannot match a lapel mic near the speaker. The `RecordingProfile.farField` plumbing exists but isn't user-toggleable yet.
- Single-channel diarization labels are best-effort, especially on PC-speaker-played audio or heavy room reverb. FluidAudio's `OfflineDiarizerManager` + VBx is the documented next step.
- Pipeline parallelism. Polish and diarization run concurrently today via `async let`; full background diarization (chunk + summarize from polish alone) is deferred for submission stability.
- Final 30-min + 10-min device perf chart still pending a real-device capture run.

## License

MIT

## Credits

Moonshine ASR by Useful Sensors · FluidAudio by Fluid Inference · Apple Foundation Models · Apple NLContextualEmbedding.
