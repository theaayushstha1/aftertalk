import AVFoundation
import Foundation
import os

enum QuestionASRError: Error, CustomStringConvertible {
    case permissionDenied
    case captureFailed(any Error)
    case asrFailed(any Error)
    case sessionFailed(any Error)

    var description: String {
        switch self {
        case .permissionDenied: return "Microphone permission denied."
        case .captureFailed(let e): return "Audio capture failed: \(e)"
        case .asrFailed(let e): return "ASR failed: \(e)"
        case .sessionFailed(let e): return "Audio session failed: \(e)"
        }
    }
}

/// Records a short voice question and returns the final transcript on release.
///
/// Owns its own MoonshineStreamer so it doesn't conflict with the meeting
/// recorder's instance. Audio session runs in `.playAndRecord` + `.voiceChat`
/// for the entire Q&A turn so Kokoro can speak the answer back through the
/// same active session — switching to `.record` would silently disable the
/// output unit and `engine.start()` on TTSWorker would fail with -10851
/// ("Format not supported", 0 Hz output rate). Session stays live across
/// listen → think → speak; deactivation happens when ChatThreadView
/// disappears.
@MainActor
final class QuestionASR {
    private let log = Logger(subsystem: "com.theaayushstha.aftertalk", category: "QuestionASR")
    private let streamer: MoonshineStreamer
    private let pump: Pump
    private let capture = AudioCaptureService()
    private var deltaTask: Task<Void, Never>?

    private(set) var liveTranscript: String = ""
    private var committedLines: [String] = []
    private var activeLine: String = ""

    init() {
        let dir = ModelLocator.moonshineModelDirectory()
        let s = MoonshineStreamer(modelDirectory: dir)
        self.streamer = s
        self.pump = Pump(streamer: s)
        let deltas = s.deltas()
        self.deltaTask = Task { @MainActor [weak self] in
            for await delta in deltas {
                self?.apply(delta: delta)
            }
        }
    }

    /// Loads the Moonshine model graph so the first hold-to-ask doesn't lose
    /// the user's opening words to a ~400ms cold start. Safe to call multiple
    /// times — Moonshine's `warm()` is idempotent.
    func prewarm() async {
        do { try await streamer.warm() }
        catch { log.error("prewarm failed: \(String(describing: error), privacy: .public)") }
    }

    func start() async throws(QuestionASRError) {
        let granted = await Self.requestMicPermission()
        guard granted else { throw .permissionDenied }
        committedLines.removeAll()
        activeLine = ""
        liveTranscript = ""
        do {
            try await AudioSessionManager.shared.configureForVoiceChat()
        } catch {
            throw .sessionFailed(error)
        }
        do {
            try await streamer.start()
        } catch {
            throw .asrFailed(error)
        }
        do {
            try capture.start(pump: pump)
        } catch {
            await streamer.stop()
            throw .captureFailed(error)
        }
    }

    /// Stops capture and drains the final ASR delta. Leaves the audio session
    /// active in `.playAndRecord` + `.voiceChat` so Kokoro can play the
    /// answer back through the same engine. The session is torn down by
    /// `ChatThreadView`'s lifecycle when the user navigates away.
    func stop() async -> String {
        capture.stop()
        await streamer.stop()
        // Same drain budget as the meeting recorder: the final LineCompleted
        // has to traverse the dispatch queue and main-actor consumer.
        try? await Task.sleep(for: .milliseconds(300))
        return liveTranscript
    }

    private func apply(delta: TranscriptDelta) {
        if delta.isFinal {
            let line = delta.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { committedLines.append(line) }
            activeLine = ""
        } else {
            activeLine = delta.text
        }
        liveTranscript = ([committedLines.joined(separator: " "), activeLine]
            .filter { !$0.isEmpty }
            .joined(separator: " "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func requestMicPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default: return false
        }
    }

    private final class Pump: ASRSamplePump, @unchecked Sendable {
        private let streamer: MoonshineStreamer
        init(streamer: MoonshineStreamer) { self.streamer = streamer }
        func append(samples: [Float], sampleRate: Int32) {
            streamer.append(samples: samples, sampleRate: sampleRate)
        }
    }
}
