import AVFoundation
import Foundation
import os

enum AudioCaptureError: Error, CustomStringConvertible {
    case formatUnavailable
    case converterUnavailable
    case engineStartFailed(String)

    var description: String {
        switch self {
        case .formatUnavailable: return "Could not build target audio format."
        case .converterUnavailable: return "Could not build sample-rate converter."
        case .engineStartFailed(let msg): return "AVAudioEngine.start failed: \(msg)"
        }
    }
}

protocol ASRSamplePump: Sendable {
    func append(samples: [Float], sampleRate: Int32)
}

/// Wraps AVAudioEngine + sample-rate conversion, feeding 16kHz mono Float32
/// frames to an `ASRSamplePump`. AVAudioEngine isn't Sendable, so all engine
/// access is serialized through a private dispatch queue and the engine
/// reference itself is held as `nonisolated(unsafe)`.
final class AudioCaptureService: @unchecked Sendable {
    private let log = Logger(subsystem: "com.theaayushstha.aftertalk", category: "AudioCapture")
    private let targetSampleRate: Double = 16_000
    private let queue = DispatchQueue(label: "com.theaayushstha.aftertalk.audio")

    nonisolated(unsafe) private var engine: AVAudioEngine?
    nonisolated(unsafe) private var capturing = false

    var isCapturing: Bool { queue.sync { capturing } }

    func start(pump: any ASRSamplePump) throws(AudioCaptureError) {
        var caughtError: AudioCaptureError?
        queue.sync {
            guard !self.capturing else { return }
            do {
                try self.startLocked(pump: pump)
            } catch let err as AudioCaptureError {
                caughtError = err
            } catch {
                caughtError = .engineStartFailed(String(describing: error))
            }
        }
        if let caughtError { throw caughtError }
    }

    private func startLocked(pump: any ASRSamplePump) throws(AudioCaptureError) {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            throw .formatUnavailable
        }

        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: targetSampleRate,
                                         channels: 1,
                                         interleaved: false) else {
            throw .formatUnavailable
        }

        let needsConversion = inputFormat.sampleRate != target.sampleRate
            || inputFormat.channelCount != target.channelCount
            || inputFormat.commonFormat != target.commonFormat

        let converter: AVAudioConverter?
        if needsConversion {
            guard let conv = AVAudioConverter(from: inputFormat, to: target) else {
                throw .converterUnavailable
            }
            converter = conv
        } else {
            converter = nil
        }

        let log = self.log
        let sourceSampleRate = inputFormat.sampleRate
        let targetSampleRate = self.targetSampleRate

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            let samples = AudioCaptureService.extractSamples(buffer: buffer,
                                                             converter: converter,
                                                             targetFormat: target,
                                                             sourceSampleRate: sourceSampleRate,
                                                             log: log)
            if !samples.isEmpty {
                pump.append(samples: samples, sampleRate: Int32(targetSampleRate))
            }
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw .engineStartFailed(String(describing: error))
        }

        self.engine = engine
        self.capturing = true
        log.debug("Audio capture started: input=\(inputFormat.sampleRate, privacy: .public)Hz")
    }

    func stop() {
        queue.sync {
            guard self.capturing, let engine = self.engine else { return }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
            self.capturing = false
            self.log.debug("Audio capture stopped")
        }
    }

    private static func extractSamples(buffer: AVAudioPCMBuffer,
                                       converter: AVAudioConverter?,
                                       targetFormat: AVAudioFormat,
                                       sourceSampleRate: Double,
                                       log: Logger) -> [Float] {
        if let converter {
            let capacity = AVAudioFrameCount(Double(buffer.frameLength)
                                             * targetFormat.sampleRate
                                             / sourceSampleRate)
            guard capacity > 0,
                  let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
            else {
                return []
            }

            var convError: NSError?
            // The buffer is consumed synchronously inside `converter.convert`
            // (single-threaded), so the @Sendable capture is safe in practice.
            nonisolated(unsafe) let bufferRef = buffer
            let inputBlock: AVAudioConverterInputBlock = { _, status in
                status.pointee = .haveData
                return bufferRef
            }
            converter.convert(to: outBuf, error: &convError, withInputFrom: inputBlock)
            if let convError {
                log.error("Conversion error: \(convError.localizedDescription, privacy: .public)")
                return []
            }
            return floatArray(from: outBuf)
        } else {
            return floatArray(from: buffer)
        }
    }

    private static func floatArray(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channels = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: channels[0], count: frameCount))
    }
}
