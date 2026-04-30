# Aftertalk

Private meeting intelligence for iPhone. Record a conversation, get a live transcript, structured notes, searchable history, and voice Q&A with citations. Audio, text, embeddings, summaries, and questions stay on device.

<p align="center">
  <img src="docs/assets/aftertalk-demo.gif" alt="Aftertalk iPhone demo showing recording, meeting notes, search, and chat" width="320">
</p>

<p align="center">
  <kbd>iOS 26+</kbd>
  <kbd>SwiftUI</kbd>
  <kbd>Foundation Models</kbd>
  <kbd>Moonshine ASR</kbd>
  <kbd>FluidAudio</kbd>
  <kbd>Local-first</kbd>
</p>

## What It Does

| Capture | Understand | Ask |
|---|---|---|
| Live on-device transcription with Moonshine streaming ASR. | Local summaries, action items, topics, transcript chunks, and speaker-attributed excerpts. | Per-meeting and cross-meeting chat grounded in saved meeting context. |
| Post-recording polish with Parakeet when model assets are bundled. | SwiftData storage plus local embeddings for semantic recall. | Streaming answers with citations and optional local neural TTS. |

## Product Tour

<table>
  <tr>
    <td align="center"><img src="docs/assets/readme-record.png" width="210" alt="Live recording screen"><br><b>Live recording</b></td>
    <td align="center"><img src="docs/assets/readme-meetings.png" width="210" alt="Meetings list"><br><b>Meeting memory</b></td>
    <td align="center"><img src="docs/assets/readme-summary.png" width="210" alt="Meeting summary"><br><b>Structured summary</b></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/assets/readme-transcript.png" width="210" alt="Transcript screen"><br><b>Transcript</b></td>
    <td align="center"><img src="docs/assets/readme-actions.png" width="210" alt="Actions screen"><br><b>Action items</b></td>
    <td align="center"><img src="docs/assets/readme-ask.png" width="210" alt="Ask meeting screen"><br><b>Ask this meeting</b></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/assets/readme-search.png" width="210" alt="Search screen"><br><b>Search</b></td>
    <td align="center"><img src="docs/assets/readme-global-chat.png" width="210" alt="Global chat screen"><br><b>Global chat</b></td>
    <td align="center"><img src="docs/assets/readme-settings.png" width="210" alt="Settings privacy audit"><br><b>Privacy audit</b></td>
  </tr>
</table>

## Local Pipeline

```mermaid
%%{init: {'theme': 'base', 'themeVariables': {'primaryColor': '#F5E7D0', 'primaryTextColor': '#1D1712', 'primaryBorderColor': '#B4532A', 'lineColor': '#8A5A44', 'secondaryColor': '#E7F1EA', 'tertiaryColor': '#E7ECF8', 'fontFamily': 'Inter, ui-sans-serif, system-ui'}}}%%
flowchart LR
    A([iPhone mic]):::capture --> B[Moonshine streaming ASR]:::model
    B --> C[Live transcript]:::ui
    B --> D[Transcript chunks]:::data
    A --> E[Parakeet polish]:::model
    E --> D
    D --> F[Foundation Models summary]:::model
    D --> G[Local embeddings]:::model
    F --> H[(SwiftData)]:::store
    G --> H
    D --> H
    H --> I[Search + citations]:::ui
    H --> J[Meeting chat]:::ui
    H --> K[Global chat]:::ui
    J --> L[Kokoro / AVSpeech TTS]:::model

    classDef capture fill:#F7D9C4,stroke:#B4532A,color:#1D1712;
    classDef model fill:#E7ECF8,stroke:#4F68A8,color:#172033;
    classDef data fill:#FFF4CC,stroke:#A07708,color:#2D2200;
    classDef store fill:#E7F1EA,stroke:#2F7D55,color:#102418;
    classDef ui fill:#F0E7FF,stroke:#7450A8,color:#241338;
```

## Q&A Flow

```mermaid
%%{init: {'theme': 'base', 'themeVariables': {'actorBkg': '#F5E7D0', 'actorBorder': '#B4532A', 'signalColor': '#4F68A8', 'activationBkgColor': '#E7F1EA', 'noteBkgColor': '#FFF4CC', 'fontFamily': 'Inter, ui-sans-serif, system-ui'}}}%%
sequenceDiagram
    autonumber
    participant U as User
    participant ASR as Question ASR
    participant Q as QAOrchestrator
    participant R as Local retriever
    participant DB as SwiftData
    participant LLM as Foundation Models
    participant TTS as TTS

    U->>ASR: hold-to-talk question
    ASR-->>Q: local transcript
    Q->>R: retrieve meeting context
    R->>DB: summaries, chunks, embeddings
    DB-->>R: grounded excerpts
    R-->>Q: packed context + citations
    Q->>LLM: stream answer locally
    loop answer snapshots
        LLM-->>Q: partial text
        Q-->>U: update chat bubble
        Q->>TTS: synthesize completed sentence
    end
```

## Component Map

```mermaid
%%{init: {'theme': 'base', 'themeVariables': {'primaryColor': '#E7ECF8', 'primaryBorderColor': '#4F68A8', 'primaryTextColor': '#172033', 'lineColor': '#8A5A44', 'fontFamily': 'Inter, ui-sans-serif, system-ui'}}}%%
classDiagram
    class RecordingViewModel {
        +start()
        +stop()
        +liveTranscript
    }
    class MoonshineStreamer {
        +warm()
        +append(samples)
        +deltas()
    }
    class MeetingProcessingPipeline {
        +process(recording)
    }
    class MeetingsRepository {
        +saveMeeting()
        +deleteMeeting()
        +fetchChunks()
    }
    class EmbeddingService {
        <<protocol>>
        +embed(text)
    }
    class HierarchicalRetriever {
        +retrieve(query)
        +packContext()
    }
    class QAOrchestrator {
        +runAsk()
        +runAskGlobal()
    }
    class TTSService {
        <<protocol>>
        +speak(text)
        +stop()
    }

    RecordingViewModel --> MoonshineStreamer
    RecordingViewModel --> MeetingProcessingPipeline
    MeetingProcessingPipeline --> MeetingsRepository
    MeetingProcessingPipeline --> EmbeddingService
    QAOrchestrator --> HierarchicalRetriever
    QAOrchestrator --> TTSService
    HierarchicalRetriever --> MeetingsRepository
```

## Data Shape

```mermaid
%%{init: {'theme': 'base', 'themeVariables': {'primaryColor': '#E7F1EA', 'primaryBorderColor': '#2F7D55', 'primaryTextColor': '#102418', 'lineColor': '#8A5A44', 'fontFamily': 'Inter, ui-sans-serif, system-ui'}}}%%
erDiagram
    MEETING ||--o{ TRANSCRIPT_CHUNK : has
    MEETING ||--o{ SPEAKER_LABEL : has
    MEETING ||--|| MEETING_SUMMARY : has
    MEETING ||--o{ CHAT_THREAD : has
    CHAT_THREAD ||--o{ CHAT_MESSAGE : has
    MEETING_SUMMARY ||--o{ SUMMARY_EMBEDDING : indexes

    MEETING {
      uuid id
      string title
      date recordedAt
      double durationSeconds
      string audioPath
      string fullTranscript
    }
    TRANSCRIPT_CHUNK {
      uuid id
      uuid meetingId
      string text
      double startSec
      double endSec
      string speakerId
      int embeddingDim
    }
    MEETING_SUMMARY {
      uuid meetingId
      string decisions
      string topics
      string openQuestions
      string actionItemsJSON
    }
    CHAT_MESSAGE {
      uuid threadId
      string role
      string text
    }
```

## Stack

| Area | Implementation |
|---|---|
| App | SwiftUI, SwiftData, AVAudioEngine |
| Live ASR | Moonshine medium streaming |
| Polish ASR | FluidAudio Parakeet TDT 0.6B v2 |
| Diarization | FluidAudio diarization assets, best-effort single-mic speaker labels |
| LLM | Apple Foundation Models on iOS 26 |
| Embeddings | Apple NLContextualEmbedding |
| Storage | SwiftData rows plus local vector search |
| TTS | FluidAudio Kokoro with AVSpeech fallback |

## Privacy Model

Aftertalk is designed so meeting content does not leave the phone.

| Layer | Guarantee |
|---|---|
| App runtime | No production `URLSession` or `URLRequest` usage in app Swift sources. |
| Capture | Works in airplane mode once model assets are present. |
| Storage | Audio, transcript, summary, chat, and embeddings are stored locally with SwiftData / app files. |
| UI | Settings exposes a live privacy audit and model asset status. |

Audit command:

```bash
git grep -nE "URLSession|URLRequest" -- 'Aftertalk/**/*.swift'
```

## Build

```bash
git clone https://github.com/theaayushstha1/aftertalk
cd aftertalk
xcodegen generate

# Model bundles are installed before running the app.
./Scripts/fetch-parakeet-models.sh
./Scripts/fetch-kokoro-models.sh
./Scripts/fetch-pyannote-models.sh

# Add Moonshine .ort files under:
# Aftertalk/Models/moonshine-medium-streaming-en/

open Aftertalk.xcodeproj
```

Requirements: Xcode 17+, iOS 26+ device, Apple Developer signing, model bundles present before the offline demo.

## Current Status

Done:

- Recording, live transcript, transcript detail, summaries, actions, search, per-meeting chat, global chat, Settings privacy audit.
- Local model fallbacks for missing optional assets where possible.
- Test coverage for VAD gating, sentence boundaries, and title sanitization.
- Perf CSV export path wired through the app Documents folder.

Still being hardened:

- RAG recall for broad questions and older meetings.
- Far-field classroom audio; a single iPhone mic cannot fully overcome distance, room reverb, or PC-speaker re-recording.
- Single-channel diarization; labels are best-effort, while citations still point to the exact transcript excerpt.
- Final perf chart from a real 30-minute meeting plus 10-minute Q&A run.

## License

MIT

## Credits

Moonshine ASR by Useful Sensors. FluidAudio by Fluid Inference. Apple Foundation Models and NLContextualEmbedding power the local intelligence layer.
