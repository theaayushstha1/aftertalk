import AVFoundation
import Foundation
import os

#if canImport(FluidAudio)
import FluidAudio
#endif

final class FluidAudioParakeetTranscriber: BatchASRService, @unchecked Sendable {
    private let modelDirectory: URL
    private let logger = Logger(subsystem: "com.theaayushstha.aftertalk", category: "BatchASR")

    #if canImport(FluidAudio)
    private var asrManager: AsrManager?
    #endif

    init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    func warm() async throws {
        #if canImport(FluidAudio)
        #if false
        // VERIFY: parakeet-recon agent will confirm exact API for FluidAudio v0.12.4
        guard FileManager.default.fileExists(atPath: modelDirectory.path) else {
            throw BatchASRError.modelMissing("directory not found at \(modelDirectory.path)")
        }
        let models = try await AsrModels.load(from: modelDirectory)
        self.asrManager = try await AsrManager(models: models)
        logger.info("Parakeet warm: model directory=\(self.modelDirectory.path, privacy: .public)")
        #else
        logger.info("Parakeet warm skipped: FluidAudio symbols not yet verified")
        throw BatchASRError.modelMissing("FluidAudio Parakeet API not yet wired")
        #endif
        #else
        throw BatchASRError.modelMissing("FluidAudio module not available")
        #endif
    }

    func transcribe(audioFile: URL) async throws -> CanonicalTranscript {
        #if canImport(FluidAudio)
        #if false
        // VERIFY: parakeet-recon agent will confirm exact API for FluidAudio v0.12.4
        guard let manager = asrManager else {
            throw BatchASRError.transcriptionFailed("warm() not called before transcribe()")
        }
        guard let file = try? AVAudioFile(forReading: audioFile) else {
            throw BatchASRError.audioUnreadable(audioFile)
        }
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw BatchASRError.audioUnreadable(audioFile)
        }
        try file.read(into: buffer)
        let samples: [Float] = {
            guard let chData = buffer.floatChannelData?[0] else { return [] }
            return Array(UnsafeBufferPointer(start: chData, count: Int(buffer.frameLength)))
        }()
        let durationSec = Double(file.length) / file.processingFormat.sampleRate
        let result = try await manager.transcribe(samples)
        let words: [CanonicalTranscript.WordTiming] = result.tokenTimings?.map {
            CanonicalTranscript.WordTiming(text: $0.token, startSec: $0.startTime, endSec: $0.endTime)
        } ?? []
        return CanonicalTranscript(
            text: result.text,
            words: words,
            durationSec: durationSec,
            backend: "parakeet-tdt-0.6b-v2"
        )
        #else
        _ = audioFile
        throw BatchASRError.transcriptionFailed("FluidAudio Parakeet API not yet wired")
        #endif
        #else
        _ = audioFile
        throw BatchASRError.transcriptionFailed("FluidAudio module not available")
        #endif
    }

    func cleanup() async {
        #if canImport(FluidAudio)
        #if false
        // VERIFY: parakeet-recon agent will confirm exact API for FluidAudio v0.12.4
        asrManager = nil
        #endif
        #endif
        logger.info("Parakeet cleanup complete")
    }
}
