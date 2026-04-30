import AVFoundation
import Foundation
import os

#if canImport(FluidAudio)
import FluidAudio
#endif

/// Batch ASR backend backed by FluidAudio's Parakeet-TDT v2 Core ML bundle.
///
/// Lifecycle: `warm()` loads the four .mlmodelc + vocab files off the bundled
/// Resources folder via `AsrModels.load(from:version:)`, then constructs an
/// `AsrManager` actor seeded with those models. `transcribe(audioFile:)` reads
/// the WAV/CAF off disk, asks the actor to run inference, and reshapes the
/// result into `CanonicalTranscript`.
///
/// We deliberately use the local-load factory (no network) and pin to v2 to
/// match the bundled weights. v3 would require a different joint model and a
/// separate download.
final class FluidAudioParakeetTranscriber: BatchASRService, @unchecked Sendable {
    private let modelDirectory: URL
    private let logger = Logger(subsystem: "com.theaayushstha.aftertalk", category: "BatchASR")

    #if canImport(FluidAudio)
    /// AsrManager is itself an `actor`, so cross-actor access is safe. We hold
    /// the reference behind an unchecked-Sendable wrapper because our class is
    /// not isolated. All state mutation goes through `AsrManager`'s actor.
    private var asrManager: AsrManager?
    #endif

    init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    func warm() async throws {
        #if canImport(FluidAudio)
        // Pre-flight: bail out cleanly if the bundled model directory is empty
        // (CI / fresh checkout). The fetch script populates the .mlmodelc files
        // outside of git.
        guard FileManager.default.fileExists(atPath: modelDirectory.path) else {
            throw BatchASRError.modelMissing("directory not found at \(modelDirectory.path)")
        }
        guard AsrModels.modelsExist(at: modelDirectory, version: .v2) else {
            throw BatchASRError.modelMissing(
                "parakeet v2 model files missing under \(modelDirectory.path) — run Scripts/fetch-parakeet-models.sh"
            )
        }

        let models = try await AsrModels.load(from: modelDirectory, version: .v2)
        let manager = AsrManager(models: models)
        // AsrManager seeds its own state via the convenience init when models
        // are passed in; nothing else to do until `transcribe(...)`.
        self.asrManager = manager
        logger.info("Parakeet warm: model directory=\(self.modelDirectory.lastPathComponent, privacy: .public)")
        #else
        throw BatchASRError.modelMissing("FluidAudio module not available")
        #endif
    }

    func transcribe(audioFile: URL) async throws -> CanonicalTranscript {
        #if canImport(FluidAudio)
        if asrManager == nil {
            // Lazy warm: pipeline can call transcribe() directly without a prior
            // warm() and we'll load the model on first use. Cheaper than failing
            // the run, and matches the "service warms itself when it needs to"
            // pattern callers expect.
            try await warm()
        }
        guard let manager = asrManager else {
            throw BatchASRError.transcriptionFailed("warm() failed to initialize Parakeet")
        }

        // Read the audio file and resample to mono Float32 16 kHz, the only
        // shape Parakeet accepts. AsrManager has a URL overload that does this
        // internally, but we also want the duration up front for the canonical
        // transcript and want to keep the disk read explicit.
        guard let file = try? AVAudioFile(forReading: audioFile) else {
            throw BatchASRError.audioUnreadable(audioFile)
        }
        let durationSec = Double(file.length) / file.processingFormat.sampleRate
        let rawSamples = try Self.readMono16kFloatSamples(from: file)

        // Apply the same ASR-conditioning boost the live Moonshine feed gets.
        // Previously Parakeet read the on-disk WAV as raw, un-boosted audio,
        // so the "polish" pass on quiet/distant speech could be measurably
        // worse than the live transcript (Moonshine saw +6 dB, Parakeet
        // saw 0 dB). Routing the same `boostForASR` here aligns both
        // encoders on the same dynamic range. Gain default = `.normal`
        // profile's 2.0× — matches the live path bit-for-bit. A future
        // Classroom Mode toggle would route a profile through and bump
        // gain to 3.5× here in lockstep with the live pump.
        let samples = AudioPreprocessor.boostForASR(rawSamples)

        // Each batch call gets a fresh decoder state — we are not chaining
        // chunks. v2 has 2 LSTM decoder layers (matches default).
        var decoderState = TdtDecoderState.make(decoderLayers: 2)
        let result: ASRResult
        do {
            result = try await manager.transcribe(samples, decoderState: &decoderState)
        } catch {
            throw BatchASRError.transcriptionFailed(String(describing: error))
        }

        let words: [CanonicalTranscript.WordTiming] = result.tokenTimings?.map { timing in
            CanonicalTranscript.WordTiming(
                text: timing.token,
                startSec: timing.startTime,
                endSec: timing.endTime
            )
        } ?? []

        return CanonicalTranscript(
            text: result.text,
            words: words,
            durationSec: durationSec,
            backend: "parakeet-tdt-0.6b-v2"
        )
        #else
        _ = audioFile
        throw BatchASRError.transcriptionFailed("FluidAudio module not available")
        #endif
    }

    func cleanup() async {
        #if canImport(FluidAudio)
        if let manager = asrManager {
            await manager.cleanup()
        }
        asrManager = nil
        #endif
        logger.info("Parakeet cleanup complete")
    }

    // MARK: - Audio plumbing

    /// Read an audio file into a `[Float]` of mono 16 kHz samples. Uses
    /// `AVAudioConverter` only when the file's processing format doesn't
    /// already match (typical for our 48 kHz Aftertalk recordings).
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
            throw BatchASRError.audioUnreadable(file.url)
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
            throw BatchASRError.audioUnreadable(file.url)
        }

        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw BatchASRError.audioUnreadable(file.url)
        }

        // Out capacity: ratio + a little slack for any tail samples the
        // converter holds back on the last call.
        let ratio = target16k / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount((Double(frameCount) * ratio).rounded(.up)) + 1024
        guard
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outFormat,
                frameCapacity: outCapacity
            )
        else {
            throw BatchASRError.audioUnreadable(file.url)
        }

        // Box the source buffer + a "consumed" flag in a class so the
        // `@Sendable` block AVAudioConverter wants can mutate them safely.
        // `nonisolated(unsafe)` is the standard escape for AVFoundation's
        // pre-Sendable types under Swift 6 strict mode.
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

        if status == .error, let convError {
            throw BatchASRError.transcriptionFailed("resample failed: \(convError.localizedDescription)")
        }

        return floatChannel0(of: outputBuffer)
    }

    private static func floatChannel0(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let chData = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: chData, count: Int(buffer.frameLength)))
    }
}
