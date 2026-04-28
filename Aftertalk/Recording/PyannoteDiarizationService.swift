import AVFoundation
import Foundation
import os

#if canImport(FluidAudio)
import FluidAudio
#endif

/// Offline speaker diarization backed by FluidAudio's Pyannote 3.1 segmentation
/// + WeSpeaker v2 embedding Core ML bundles. Mirrors the lifecycle of
/// `FluidAudioParakeetTranscriber`: `warm()` lazy-loads the two `.mlmodelc`
/// directories off the bundled Resources folder via
/// `DiarizerModels.load(localSegmentationModel:localEmbeddingModel:)` (no
/// network), then constructs a single `DiarizerManager` we keep alive for
/// the entire app session so the underlying `SpeakerManager` clusters stay
/// stable across calls.
///
/// `DiarizerManager` is itself a `final class` (not actor, not Sendable) and
/// uses `consuming` ownership for its synchronous `initialize(models:)`. We
/// wrap all access in this actor and hold the manager via a
/// `@unchecked Sendable` box so Swift 6 strict concurrency stops complaining,
/// matching how `FluidAudioParakeetTranscriber` handles `AsrManager`.
///
/// Compute units default to `.all` on device; CI defaults to
/// `.cpuAndNeuralEngine` per `DiarizerModels.defaultConfiguration()`.
/// If we ever hit the same iOS 26 ANE compiler regression Kokoro warns about,
/// pass `.cpuAndGPU` here too via `MLModelConfiguration`.
actor PyannoteDiarizationService: DiarizationService {
    private let segmentationURL: URL
    private let embeddingURL: URL
    private let logger = Logger(subsystem: "com.theaayushstha.aftertalk", category: "Diarization")

    #if canImport(FluidAudio)
    /// `DiarizerManager` is a `final class`, not `Sendable`. Holding it inside
    /// this actor means every call lands on the same isolation domain — we
    /// box it as unchecked-Sendable so the actor's state is itself Sendable
    /// from the compiler's POV.
    private final class ManagerBox: @unchecked Sendable {
        nonisolated(unsafe) var manager: DiarizerManager?
        init(_ manager: DiarizerManager? = nil) { self.manager = manager }
    }
    private let box = ManagerBox()
    #endif

    init(segmentationURL: URL, embeddingURL: URL) {
        self.segmentationURL = segmentationURL
        self.embeddingURL = embeddingURL
    }

    func warm() async throws {
        #if canImport(FluidAudio)
        if box.manager != nil { return }

        let fm = FileManager.default
        guard fm.fileExists(atPath: segmentationURL.path) else {
            throw DiarizationError.modelMissing("missing pyannote_segmentation.mlmodelc at \(segmentationURL.path)")
        }
        guard fm.fileExists(atPath: embeddingURL.path) else {
            throw DiarizationError.modelMissing("missing wespeaker_v2.mlmodelc at \(embeddingURL.path)")
        }

        let started = Date()
        let models: DiarizerModels
        do {
            models = try await DiarizerModels.load(
                localSegmentationModel: segmentationURL,
                localEmbeddingModel: embeddingURL
            )
        } catch {
            throw DiarizationError.modelMissing("DiarizerModels.load failed: \(error)")
        }

        let manager = DiarizerManager(config: .default)
        // initialize(models:) is synchronous + consuming. Do NOT `await` it.
        manager.initialize(models: models)
        box.manager = manager
        let elapsed = Date().timeIntervalSince(started)
        logger.info("Diarizer warm: seg=\(self.segmentationURL.lastPathComponent, privacy: .public) emb=\(self.embeddingURL.lastPathComponent, privacy: .public) compileSec=\(elapsed, privacy: .public)")
        #else
        throw DiarizationError.modelMissing("FluidAudio module not available")
        #endif
    }

    func diarize(audioFile: URL) async throws -> [SpeakerSegment] {
        #if canImport(FluidAudio)
        if box.manager == nil {
            try await warm()
        }
        guard let manager = box.manager else {
            throw DiarizationError.modelMissing("warm() failed silently")
        }

        // Read PCM samples as 16 kHz mono Float32. AudioCaptureService already
        // writes the WAV at 16 kHz mono Float32 (Day 3), so this is normally a
        // straight-through read — but we still defensively resample if the
        // file got persisted at another rate (older meetings, future code).
        guard let file = try? AVAudioFile(forReading: audioFile) else {
            throw DiarizationError.audioUnreadable(audioFile)
        }
        let samples: [Float]
        do {
            samples = try Self.readMono16kFloatSamples(from: file)
        } catch {
            throw DiarizationError.audioUnreadable(audioFile)
        }
        guard !samples.isEmpty else { return [] }

        let started = Date()
        let result: DiarizationResult
        do {
            result = try await manager.performCompleteDiarization(
                samples,
                sampleRate: 16_000,
                atTime: 0
            )
        } catch {
            throw DiarizationError.inferenceFailed(error)
        }
        let elapsed = Date().timeIntervalSince(started)
        logger.info("Diarized \(samples.count, privacy: .public) samples in \(elapsed, privacy: .public)s — \(result.segments.count, privacy: .public) segments")

        return result.segments.map { seg in
            SpeakerSegment(
                speakerId: seg.speakerId,
                startSec: Double(seg.startTimeSeconds),
                endSec: Double(seg.endTimeSeconds),
                embedding: seg.embedding,
                qualityScore: seg.qualityScore
            )
        }
        #else
        _ = audioFile
        throw DiarizationError.modelMissing("FluidAudio module not available")
        #endif
    }

    func cleanup() async {
        #if canImport(FluidAudio)
        if let manager = box.manager {
            manager.cleanup()
        }
        box.manager = nil
        #endif
        logger.info("Diarizer cleanup complete")
    }

    // MARK: - Audio plumbing

    /// Read an audio file into `[Float]` mono 16 kHz samples. Identical to
    /// the Parakeet implementation; duplicated to avoid coupling the two
    /// services through a shared helper while we're still iterating.
    private static func readMono16kFloatSamples(from file: AVAudioFile) throws -> [Float] {
        let inFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return [] }

        guard
            let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inFormat,
                frameCapacity: frameCount
            )
        else {
            throw DiarizationError.audioUnreadable(file.url)
        }
        try file.read(into: inputBuffer)

        let target16k: Double = 16_000
        let needsResample =
            inFormat.sampleRate != target16k
            || inFormat.channelCount != 1
            || inFormat.commonFormat != .pcmFormatFloat32
            || inFormat.isInterleaved

        if !needsResample {
            return floatChannel0(of: inputBuffer)
        }

        guard
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: target16k,
                channels: 1,
                interleaved: false
            )
        else {
            throw DiarizationError.audioUnreadable(file.url)
        }
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw DiarizationError.audioUnreadable(file.url)
        }

        let ratio = target16k / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount((Double(frameCount) * ratio).rounded(.up)) + 1024
        guard
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outFormat,
                frameCapacity: outCapacity
            )
        else {
            throw DiarizationError.audioUnreadable(file.url)
        }

        final class InputCursor: @unchecked Sendable {
            nonisolated(unsafe) var buffer: AVAudioPCMBuffer
            var consumed = false
            init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        }
        let cursor = InputCursor(inputBuffer)
        var convError: NSError?
        let status = converter.convert(to: outputBuffer, error: &convError) { _, status in
            if cursor.consumed {
                status.pointee = .endOfStream
                return nil
            }
            cursor.consumed = true
            status.pointee = .haveData
            return cursor.buffer
        }
        if status == .error, convError != nil {
            // Fold convError into audioUnreadable — the call site treats both
            // as "diarization can't run on this file" and falls through.
            throw DiarizationError.audioUnreadable(file.url)
        }

        return floatChannel0(of: outputBuffer)
    }

    private static func floatChannel0(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let chData = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: chData, count: Int(buffer.frameLength)))
    }
}
