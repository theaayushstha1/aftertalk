import AVFoundation
import Foundation
import os

/// Audio output sink for synthesised TTS samples.
///
/// Owns an `AVAudioEngine` graph (`AVAudioPlayerNode -> mainMixer -> output`)
/// and converts every incoming 24 kHz mono Float32 buffer up to whatever sample
/// rate the speaker hardware exposes (typically 48 kHz on iPhone). We do the
/// conversion explicitly with `AVAudioConverter` because the project rules
/// (`CLAUDE.md` invariant 5) forbid relying on implicit graph conversion —
/// AVAudioEngine *can* paper over rate mismatches but the result has audible
/// dropouts on iOS 26 device under load.
///
/// Sentence playback is sequential: callers `await enqueue(samples)` for each
/// sentence and the worker schedules them back-to-back on the player node.
/// `waitUntilDone()` blocks until the queue drains. `cancel()` stops the player
/// and forgets pending continuations so a new utterance can start immediately.
actor TTSWorker {
    private let log = Logger(subsystem: "com.theaayushstha.aftertalk", category: "TTSWorker")

    /// Source format Kokoro emits.
    private let inputFormat: AVAudioFormat
    /// Output format the engine actually wants. Resolved lazily on first
    /// enqueue so we observe the real hardware rate after the audio session
    /// has been activated.
    private var outputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    /// Number of buffers we've handed off to the player but that haven't fired
    /// their completion callback yet. When this hits zero we resume any
    /// outstanding `waitUntilDone` continuations.
    private var pending: Int = 0
    private var idleContinuations: [CheckedContinuation<Void, Never>] = []
    private var isRunning = false

    init() {
        // 24 kHz mono Float32 — the format every Kokoro `[Float]` chunk arrives in.
        self.inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        )!
    }

    /// Hand a single Kokoro chunk to the player. Returns immediately after the
    /// buffer is scheduled — playback completes asynchronously and the worker
    /// keeps a count of in-flight buffers for `waitUntilDone()`.
    func enqueue(_ samples: [Float]) async {
        guard !samples.isEmpty else { return }

        do {
            try ensureRunning()
        } catch {
            log.error("engine start failed: \(String(describing: error), privacy: .public)")
            return
        }

        guard let outputFormat, let converter else {
            log.error("output format not resolved, dropping samples")
            return
        }

        // Build the input buffer once, then convert into a player-rate buffer.
        let inFrames = AVAudioFrameCount(samples.count)
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inFrames) else {
            log.error("could not allocate input buffer")
            return
        }
        inBuffer.frameLength = inFrames
        if let dst = inBuffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!, count: samples.count)
            }
        }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outCapacity = AVAudioFrameCount((Double(inFrames) * ratio).rounded(.up)) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else {
            log.error("could not allocate output buffer")
            return
        }

        // Box the source buffer in a single-shot cursor — AVAudioConverter wants
        // a `@Sendable` block that hands data back, and we only have one chunk.
        final class InputCursor: @unchecked Sendable {
            nonisolated(unsafe) var buffer: AVAudioPCMBuffer
            var consumed = false
            init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        }
        // AVAudioConverter is stateful. Once our input block returns
        // `.endOfStream`, the converter latches into a terminal state and
        // silently produces zero frames on the next `convert` call — which is
        // exactly what was happening: sentence 1 played, sentences 2..N
        // synthesised cleanly but came out silent. `reset()` drops that state
        // so each Kokoro chunk gets a fresh conversion.
        converter.reset()
        let cursor = InputCursor(inBuffer)
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError) { _, status in
            if cursor.consumed {
                status.pointee = .endOfStream
                return nil
            }
            cursor.consumed = true
            status.pointee = .haveData
            return cursor.buffer
        }
        if status == .error, let convError {
            log.error("convert failed: \(convError.localizedDescription, privacy: .public)")
            return
        }

        // AVAudioConverter can return success with frameLength == 0 on rate
        // boundaries when the input chunk is too small to produce a single
        // output frame. Scheduling a zero-frame buffer fires the completion
        // callback synchronously — counting that against `pending` would
        // un-balance `waitUntilDone()`. Skip it.
        guard outBuffer.frameLength > 0 else {
            log.info("convert produced 0 frames, skipping schedule")
            return
        }

        pending += 1
        // The completion handler is `@Sendable` and our `bufferDidFinish` is
        // actor-isolated, so we hop back into the actor inside the closure.
        // (Compiler suggests an async alternative, but that variant requires a
        // Sendable AVAudioPlayerNode reference which AVFoundation doesn't
        // provide. Closure form stays — silence the warning intentionally
        // via the deprecation pragma below.)
        #if compiler(>=5.10)
        // The async alternative isn't usable here per the comment above;
        // disable the diagnostic for this single call so the build stays
        // warning-clean without hiding real warnings elsewhere.
        @available(iOS 26.0, *)
        func scheduleBufferShim(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable () -> Void) {
            player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: completion)
        }
        scheduleBufferShim(outBuffer) { [weak self] in
            Task { [weak self] in await self?.bufferDidFinish() }
        }
        #else
        player.scheduleBuffer(outBuffer, at: nil, options: []) { [weak self] in
            Task { [weak self] in await self?.bufferDidFinish() }
        }
        #endif

        if !player.isPlaying {
            player.play()
        }
    }

    /// Suspend the caller until every queued buffer has finished playing.
    /// If the queue is already empty, returns immediately.
    func waitUntilDone() async {
        if pending == 0 { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            idleContinuations.append(cont)
        }
    }

    /// Hard-stop: dump the player's queue and reset pending counters so a fresh
    /// utterance can start clean. Used for barge-in / cancel.
    func cancel() async {
        player.stop()
        pending = 0
        let waiters = idleContinuations
        idleContinuations.removeAll()
        for cont in waiters { cont.resume() }
    }

    /// Tear down the engine. The worker is safe to reuse afterwards: the
    /// next `enqueue` will rebuild the graph in `ensureRunning`. We
    /// detach the player node here (instead of just stopping the engine)
    /// because `engine.attach(player)` throws if the node is already
    /// attached, and `MeetingDetailView.onDisappear` calls cleanup → next
    /// chat open hits enqueue → ensureRunning → attach → throw without
    /// this detach step.
    func shutdown() async {
        await cancel()
        if isRunning {
            engine.stop()
            // `detach` is the inverse of `attach`. After a successful
            // detach, `ensureRunning` is free to call `attach` again on
            // the next utterance without AVAudioEngine raising
            // "required condition is false: !nodeimpl->IsAttached()".
            engine.detach(player)
            isRunning = false
        }
    }

    // MARK: - Private

    private func ensureRunning() throws {
        if isRunning { return }
        // Resolve the speaker rate now that the audio session is active. Falls
        // back to 48 kHz if the hardware refuses to report.
        let session = AVAudioSession.sharedInstance()
        let hwRate = session.sampleRate > 0 ? session.sampleRate : 48_000
        guard let outFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hwRate,
            channels: 1,
            interleaved: false
        ) else {
            throw TTSWorkerError.formatUnsupported(hwRate)
        }
        self.outputFormat = outFmt
        self.converter = AVAudioConverter(from: inputFormat, to: outFmt)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outFmt)
        engine.prepare()
        try engine.start()
        isRunning = true
        log.info("TTSWorker engine up at \(hwRate, privacy: .public) Hz")
    }

    private func bufferDidFinish() {
        pending = max(0, pending - 1)
        guard pending == 0 else { return }
        let waiters = idleContinuations
        idleContinuations.removeAll()
        for cont in waiters { cont.resume() }
    }
}

enum TTSWorkerError: Error, CustomStringConvertible {
    case formatUnsupported(Double)

    var description: String {
        switch self {
        case .formatUnsupported(let rate): "Speaker format \(rate) Hz unsupported"
        }
    }
}
