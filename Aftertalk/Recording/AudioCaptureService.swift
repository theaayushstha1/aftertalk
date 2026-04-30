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
    nonisolated(unsafe) private var fileWriter: AVAudioFile?
    nonisolated(unsafe) private var recordingURL: URL?

    var isCapturing: Bool { queue.sync { capturing } }

    /// URL of the most recently completed WAV recording, if any.
    /// Reset on each `start(pump:)`. Nil if file creation failed.
    var lastRecordingURL: URL? { queue.sync { recordingURL } }

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
        // Clear any URL from a prior session so callers don't pick up stale data.
        self.recordingURL = nil
        self.fileWriter = nil

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

        // Build the WAV destination + writer. If anything fails, we proceed
        // without persistence so streaming ASR + summary still work.
        let (writer, url) = AudioCaptureService.makeFileWriter(targetFormat: target, log: log)
        self.fileWriter = writer
        self.recordingURL = url

        // Captured by the audio tap closure. AVAudioEngine taps are serialized
        // on a dedicated audio thread, so we own this reference exclusively
        // from the tap callback.
        let writerRef = writer

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            let samples = AudioCaptureService.extractSamples(buffer: buffer,
                                                             converter: converter,
                                                             targetFormat: target,
                                                             sourceSampleRate: sourceSampleRate,
                                                             log: log)
            if !samples.isEmpty {
                // ASR feed gets a gain boost so far-field speakers (>1 m from
                // the phone) land in Moonshine's encoder operating range.
                // WAV destination keeps the raw signal so Parakeet polish and
                // demo playback stay authentic.
                let boosted = AudioPreprocessor.boostForASR(samples)
                pump.append(samples: boosted, sampleRate: Int32(targetSampleRate))
                if let writerRef {
                    AudioCaptureService.writeSamples(samples,
                                                     to: writerRef,
                                                     format: target,
                                                     log: log)
                }
            }
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            self.fileWriter = nil
            self.recordingURL = nil
            throw .engineStartFailed(String(describing: error))
        }

        self.engine = engine
        self.capturing = true
        log.debug("Audio capture started: input=\(inputFormat.sampleRate, privacy: .public)Hz, wav=\(url?.lastPathComponent ?? "<none>", privacy: .public)")
    }

    func stop() {
        queue.sync {
            guard self.capturing, let engine = self.engine else { return }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
            self.capturing = false
            // Releasing the AVAudioFile flushes its remaining frames to disk.
            // Keep `recordingURL` populated so callers can pick it up.
            self.fileWriter = nil
            self.log.debug("Audio capture stopped, wav=\(self.recordingURL?.lastPathComponent ?? "<none>", privacy: .public)")
        }
    }

    /// Pause the engine without tearing down the tap or releasing the file
    /// writer. Used during AVAudioSession interruptions (incoming call, Siri,
    /// FaceTime) so the session itself stays configured and we can resume in
    /// place. We do NOT call `AudioSessionManager.deactivate` from here —
    /// deactivating with attached nodes deadlocks (see CLAUDE.md "Audio
    /// session order is sacred"). Calling `pause` while not capturing is a
    /// no-op so the interruption observer can fire safely.
    func pause() {
        queue.sync {
            guard self.capturing, let engine = self.engine else { return }
            engine.pause()
            self.log.debug("Audio capture paused (interruption), wav=\(self.recordingURL?.lastPathComponent ?? "<none>", privacy: .public)")
        }
    }

    /// Restart the engine after an interruption ended. Tap + writer + sample
    /// rate converter are all still wired from the original `start(pump:)`
    /// call so the resume is essentially a single `engine.start()`. Returns
    /// false if the engine is already gone (capture was torn down before the
    /// interruption ended) so the VM can decide whether to surface an error.
    @discardableResult
    func resume() -> Bool {
        var ok = false
        queue.sync {
            guard self.capturing, let engine = self.engine else { return }
            do {
                try engine.start()
                ok = true
                self.log.debug("Audio capture resumed after interruption, wav=\(self.recordingURL?.lastPathComponent ?? "<none>", privacy: .public)")
            } catch {
                self.log.error("Audio capture resume failed: \(error.localizedDescription, privacy: .public)")
                ok = false
            }
        }
        return ok
    }

    /// Snapshot the in-flight WAV URL during an interruption. Caller can
    /// surface it to the UI / pipeline so the user doesn't perceive a total
    /// loss if the interruption never resolves. The actual `AVAudioFile`
    /// reference lives inside the audio tap closure and CoreAudio flushes
    /// individual buffers to disk as `file.write(from:)` returns, so the
    /// frames captured before `pause()` are already persisted — only the
    /// final WAV header is finalized at `stop()` when the `AVAudioFile`
    /// deallocates. No-op if no recording is active.
    func partialRecordingURL() -> URL? {
        queue.sync { self.recordingURL }
    }

    /// Build the destination URL + AVAudioFile writer for the WAV pass.
    /// Returns (nil, nil) if anything fails — caller proceeds without
    /// persistence so the streaming pipeline isn't impacted.
    private static func makeFileWriter(targetFormat: AVAudioFormat,
                                       log: Logger) -> (AVAudioFile?, URL?) {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory,
                                       in: .userDomainMask).first else {
            log.error("recording: no Application Support directory")
            return (nil, nil)
        }
        let dir = appSupport
            .appendingPathComponent("Aftertalk", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fm.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: dir.path
            )
        } catch {
            log.error("recording: mkdir failed: \(error.localizedDescription, privacy: .public)")
            return (nil, nil)
        }
        let url = dir.appendingPathComponent("\(UUID().uuidString).wav", isDirectory: false)
        // AVAudioFile WAV settings: float32, mono, 16 kHz, little-endian, non-interleaved.
        // Using `settings: targetFormat.settings` lets CoreAudio pick the matching
        // file format; we override the type to .wav by writing to a .wav URL.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetFormat.sampleRate,
            AVNumberOfChannelsKey: Int(targetFormat.channelCount),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true
        ]
        do {
            let file = try AVAudioFile(forWriting: url,
                                       settings: settings,
                                       commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            try? fm.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
            return (file, url)
        } catch {
            log.error("recording: AVAudioFile open failed: \(error.localizedDescription, privacy: .public)")
            return (nil, nil)
        }
    }

    /// Write the converted 16 kHz mono Float32 samples into the WAV file.
    /// Errors are logged + dropped — recording must not crash if disk hiccups.
    private static func writeSamples(_ samples: [Float],
                                     to file: AVAudioFile,
                                     format: AVAudioFormat,
                                     log: Logger) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            return
        }
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                channel.update(from: base, count: samples.count)
            }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        do {
            try file.write(from: buffer)
        } catch {
            log.error("recording: write failed: \(error.localizedDescription, privacy: .public)")
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
