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

        // Diarization tuning. The default `clusteringThreshold=0.7` (cosine
        // boundary 0.84) under-segments on similar-voice audio (two podcast
        // hosts with the same accent and pitch land at ~0.78 cosine distance,
        // below the boundary, and collapse to one cluster). We tighten to
        // 0.55 (boundary ~0.71) so genuinely different voices split, then
        // rely on `collapseSpuriousClusters` to merge same-voice ghost
        // clusters by centroid distance — the standard "oversample then
        // collapse" pattern. `minSpeechDuration=0.6` is slightly looser than
        // the 1.0s default so brief turns ("Yeah, exactly") still get an
        // embedding that contributes to the cluster.
        var cfg = DiarizerConfig.default
        cfg.clusteringThreshold = 0.6
        cfg.minSpeechDuration = 0.6
        let manager = DiarizerManager(config: cfg)
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
        logger.info("Diarized \(samples.count, privacy: .public) samples in \(elapsed, privacy: .public)s — \(result.segments.count, privacy: .public) raw segments")

        let collapsed = Self.collapseSpuriousClusters(result.segments, logger: logger)
        return collapsed.map { seg in
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

    // MARK: - Cluster collapse post-processing

    #if canImport(FluidAudio)
    /// "Oversample then collapse." FluidAudio's online `SpeakerManager` is
    /// permissive at the default `clusteringThreshold=0.7` — it correctly
    /// registers every real voice but also occasionally spawns a 1-2 segment
    /// ghost cluster from same-voice embedding drift on short utterances.
    /// We catch those here: any cluster that owns < `minSegments` AND
    /// < `minAirtimeFraction` of total speaking time is reassigned to its
    /// nearest neighbor by centroid cosine distance.
    ///
    /// Why post-processing instead of tightening the threshold:
    ///   - threshold=0.7 → boundary 0.84 → real speakers at distance 0.85-0.95
    ///     spawn ghosts (over-segmentation)
    ///   - threshold=0.8 → boundary 0.96 → similar voices (same gender, similar
    ///     pitch on a podcast) at distance 0.7-0.9 collapse into one cluster
    ///     (under-segmentation)
    /// No single threshold satisfies both. The permissive default + post-merge
    /// is the standard fix in the speaker-diarization literature.
    static func collapseSpuriousClusters(
        _ segments: [TimedSpeakerSegment],
        logger: Logger,
        minSegments: Int = 3,
        minAirtimeFraction: Float = 0.08
    ) -> [TimedSpeakerSegment] {
        guard !segments.isEmpty else { return [] }
        // Aggregate per speaker: count, airtime, summed embedding for centroid.
        var byId: [String: (count: Int, airtime: Float, sumEmb: [Float])] = [:]
        for seg in segments {
            let dur = seg.endTimeSeconds - seg.startTimeSeconds
            if let prev = byId[seg.speakerId] {
                var emb = prev.sumEmb
                let n = min(emb.count, seg.embedding.count)
                for i in 0..<n { emb[i] += seg.embedding[i] }
                byId[seg.speakerId] = (prev.count + 1, prev.airtime + dur, emb)
            } else {
                byId[seg.speakerId] = (1, dur, seg.embedding)
            }
        }
        guard byId.count > 1 else {
            // Only one cluster, nothing to merge.
            return segments
        }

        // Centroids = mean embedding per cluster.
        var centroids: [String: [Float]] = [:]
        for (id, e) in byId {
            let inv = 1.0 / Float(max(e.count, 1))
            centroids[id] = e.sumEmb.map { $0 * inv }
        }

        let totalAirtime = segments.reduce(Float(0)) { $0 + ($1.endTimeSeconds - $1.startTimeSeconds) }

        // Decide which clusters are spurious. Don't collapse all clusters:
        // if every cluster qualifies as small, the recording was just short —
        // keep them as-is.
        var remap: [String: String] = [:]
        let candidates = byId.filter { (_, e) in
            e.count < minSegments && (e.airtime / max(totalAirtime, 1)) < minAirtimeFraction
        }
        guard candidates.count < byId.count else {
            logger.info("collapse: every cluster is small — leaving \(byId.count, privacy: .public) clusters intact")
            return segments
        }

        // Largest non-small cluster by airtime — used as a fallback target
        // when a tiny ghost has a degenerate (zero-norm) embedding so cosine
        // distance can't pick a winner. Without this fallback those ghosts
        // survive even though they obviously belong to a real speaker.
        let nonSmallIds = Set(byId.keys).subtracting(candidates.keys)
        let fallbackTarget: String? = nonSmallIds
            .max(by: { (byId[$0]?.airtime ?? 0) < (byId[$1]?.airtime ?? 0) })

        // Iterate candidates smallest-airtime-first so any chain we form
        // points from tinier ghost → bigger ghost → real speaker, then we
        // chain-resolve at the end. Stable iteration also makes the merge
        // log readable.
        let orderedCandidates = candidates.sorted { (lhs, rhs) in
            lhs.value.airtime < rhs.value.airtime
        }

        for (smallId, e) in orderedCandidates {
            var bestId: String?
            var bestDist: Float = .infinity
            if let smallCentroid = centroids[smallId] {
                for (otherId, otherCentroid) in centroids where otherId != smallId {
                    let d = Self.cosineDistance(smallCentroid, otherCentroid)
                    if d < bestDist {
                        bestDist = d
                        bestId = otherId
                    }
                }
            }
            // Degenerate centroid (zero norm → cosineDistance == .infinity for
            // every comparison) means we couldn't pick a nearest neighbor on
            // similarity. Fall back to the largest real cluster — a 1-segment
            // ghost almost certainly belongs to whoever spoke most.
            if bestId == nil || bestDist == .infinity {
                bestId = fallbackTarget
            }
            if let target = bestId {
                remap[smallId] = target
                logger.info("collapse: merging spurious speaker \(smallId, privacy: .public) (segments=\(e.count, privacy: .public), airtime=\(e.airtime, privacy: .public)s) into \(target, privacy: .public) at distance \(bestDist, privacy: .public)")
            }
        }

        guard !remap.isEmpty else {
            logger.info("collapse: no spurious clusters detected — \(byId.count, privacy: .public) speakers kept")
            return segments
        }

        // Chain-resolve: when ghost A → ghost B and ghost B → real C, A must
        // also resolve to C. The original single-hop apply left dangling
        // pointers when remap target was itself remapped. Walk each chain
        // until it lands on something not in remap (or detect a cycle).
        for key in Array(remap.keys) {
            var seen: Set<String> = [key]
            var cursor = remap[key]!
            while let next = remap[cursor], !seen.contains(next) {
                seen.insert(next)
                cursor = next
            }
            remap[key] = cursor
        }

        return segments.map { seg in
            guard let target = remap[seg.speakerId] else { return seg }
            return TimedSpeakerSegment(
                speakerId: target,
                embedding: seg.embedding,
                startTimeSeconds: seg.startTimeSeconds,
                endTimeSeconds: seg.endTimeSeconds,
                qualityScore: seg.qualityScore
            )
        }
    }

    /// Cosine distance between two embeddings, range [0, 2]. Mirrors
    /// `SpeakerUtilities.cosineDistance` so we don't need to depend on
    /// FluidAudio's internal symbol layout.
    private static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return .infinity }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<n {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return .infinity }
        let sim = dot / (sqrt(na) * sqrt(nb))
        return 1.0 - sim
    }
    #endif

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
