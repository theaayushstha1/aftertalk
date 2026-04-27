import Foundation
import MoonshineVoice
import os

enum MoonshineError: Error, CustomStringConvertible {
    case modelNotFound(URL)
    case loadFailed(String)
    case streamFailed(String)

    var description: String {
        switch self {
        case .modelNotFound(let url): return "Moonshine model directory missing at \(url.path)."
        case .loadFailed(let msg): return "Moonshine load failed: \(msg)"
        case .streamFailed(let msg): return "Moonshine stream failed: \(msg)"
        }
    }
}

struct TranscriptDelta: Sendable, Hashable {
    let text: String
    let isFinal: Bool
}

/// Lightweight diagnostic snapshot surfaced to the UI so we can see, on device,
/// whether the underlying Moonshine stream is alive, processing, or wedged.
struct ASRDiagnostics: Sendable, Hashable {
    var isActive: Bool = false
    var addAudioCalls: Int = 0
    var addAudioErrors: Int = 0
    var lastAddAudioError: String?
    var startCalls: Int = 0
    var stopCalls: Int = 0
}

protocol ASRService: AnyObject, Sendable {
    func warm() async throws
    func start() async throws
    func append(samples: [Float], sampleRate: Int32)
    func stop() async
    func deltas() -> AsyncStream<TranscriptDelta>
}

/// Wraps Moonshine's `Transcriber` + `Stream`. The Transcriber and Stream
/// objects are created once and live for the full app lifetime — Moonshine's
/// Stream API is designed to be `start()`/`stop()`-cycled across utterances
/// on the same Stream object, which resets internal line-state cleanly without
/// leaking ONNX runtime state. Recreating either Transcriber or Stream on each
/// session causes silent state corruption (samples flow but no events emit on
/// the second session).
///
/// All access to the Moonshine objects is serialized through a dedicated
/// dispatch queue because the listener callback fires on a non-main thread.
final class MoonshineStreamer: ASRService, @unchecked Sendable {
    private let log = Logger(subsystem: "com.theaayushstha.aftertalk", category: "Moonshine")
    private let modelDirectory: URL
    private let queue = DispatchQueue(label: "com.theaayushstha.aftertalk.moonshine")

    nonisolated(unsafe) private var transcriber: Transcriber?
    nonisolated(unsafe) private var stream: MoonshineVoice.Stream?
    nonisolated(unsafe) private var continuation: AsyncStream<TranscriptDelta>.Continuation?
    nonisolated(unsafe) private var diagContinuation: AsyncStream<ASRDiagnostics>.Continuation?
    nonisolated(unsafe) private var diagState = ASRDiagnostics()
    private let deltaStream: AsyncStream<TranscriptDelta>
    private let diagStream: AsyncStream<ASRDiagnostics>

    init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
        var sink: AsyncStream<TranscriptDelta>.Continuation!
        self.deltaStream = AsyncStream { sink = $0 }
        self.continuation = sink

        var diagSink: AsyncStream<ASRDiagnostics>.Continuation!
        self.diagStream = AsyncStream { diagSink = $0 }
        self.diagContinuation = diagSink
    }

    /// Loads the Transcriber + creates the Stream + attaches the listener.
    /// Idempotent. Safe to call from `.task` / view-appear so the first user
    /// press doesn't pay the cold-start cost (~600ms with mediumStreaming).
    /// Does NOT arm the session — call `start()` per utterance.
    func warm() async throws {
        guard FileManager.default.fileExists(atPath: modelDirectory.path) else {
            throw MoonshineError.modelNotFound(modelDirectory)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            queue.async { [weak self] in
                guard let self else { cont.resume(); return }
                do {
                    if self.transcriber == nil {
                        let t = try Transcriber(modelPath: self.modelDirectory.path,
                                                modelArch: .mediumStreaming)
                        let s = try t.createStream(updateInterval: 0.10)
                        s.addListener { [weak self] event in
                            self?.dispatch(event)
                        }
                        self.transcriber = t
                        self.stream = s
                        self.log.debug("Moonshine warm")
                    }
                    cont.resume()
                } catch {
                    self.diagState.lastAddAudioError = "warm: \(error)"
                    self.publishDiag()
                    cont.resume(throwing: MoonshineError.loadFailed(String(describing: error)))
                }
            }
        }
    }

    func start() async throws {
        try await warm()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            queue.async { [weak self] in
                guard let self else { cont.resume(); return }
                do {
                    // Per-session: arm the stream. Calling start() on an
                    // already-active stream would double-start the ONNX
                    // pipeline, so guard with isActive().
                    if let s = self.stream, !s.isActive() {
                        try s.start()
                        self.diagState.isActive = true
                        self.diagState.startCalls += 1
                        self.diagState.lastAddAudioError = nil
                        self.publishDiag()
                        self.log.debug("Moonshine session started (start#\(self.diagState.startCalls))")
                    }
                    cont.resume()
                } catch {
                    self.diagState.lastAddAudioError = "start: \(error)"
                    self.publishDiag()
                    cont.resume(throwing: MoonshineError.loadFailed(String(describing: error)))
                }
            }
        }
    }

    func append(samples: [Float], sampleRate: Int32) {
        guard !samples.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, let s = self.stream else { return }
            self.diagState.addAudioCalls += 1
            do {
                try s.addAudio(samples, sampleRate: sampleRate)
            } catch {
                self.diagState.addAudioErrors += 1
                self.diagState.lastAddAudioError = String(describing: error)
                self.log.error("addAudio failed: \(String(describing: error), privacy: .public)")
            }
            // Throttle diagnostic publishes to once every 10 audio chunks
            // (~50ms apart at 1024-frame buffers / 16kHz) to avoid flooding.
            if self.diagState.addAudioCalls % 10 == 0 {
                self.publishDiag()
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self else { cont.resume(); return }
                if let s = self.stream, s.isActive() {
                    do {
                        try s.stop()
                        self.diagState.isActive = false
                        self.diagState.stopCalls += 1
                        self.log.debug("Moonshine session stopped (stop#\(self.diagState.stopCalls))")
                    } catch {
                        self.diagState.lastAddAudioError = "stop: \(error)"
                        self.log.error("stream.stop failed: \(String(describing: error), privacy: .public)")
                    }
                    self.publishDiag()
                }
                cont.resume()
            }
        }
    }

    deinit {
        queue.sync {
            stream?.close()
            transcriber?.close()
        }
        continuation?.finish()
        diagContinuation?.finish()
    }

    func deltas() -> AsyncStream<TranscriptDelta> {
        deltaStream
    }

    func diagnostics() -> AsyncStream<ASRDiagnostics> {
        diagStream
    }

    private func publishDiag() {
        diagContinuation?.yield(diagState)
    }

    nonisolated private func dispatch(_ event: any TranscriptEvent) {
        let delta: TranscriptDelta?
        if let textChanged = event as? LineTextChanged {
            delta = .init(text: textChanged.line.text, isFinal: false)
        } else if let completed = event as? LineCompleted {
            delta = .init(text: completed.line.text, isFinal: true)
        } else {
            delta = nil
        }
        guard let delta else { return }
        queue.async { [weak self] in
            self?.continuation?.yield(delta)
        }
    }
}
