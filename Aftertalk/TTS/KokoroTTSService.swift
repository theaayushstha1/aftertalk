import Foundation
import os

#if canImport(FluidAudio)
import FluidAudio
#endif

#if canImport(CoreML)
import CoreML
#endif

enum TTSError: Error, CustomStringConvertible {
    case modelMissing(String)
    case initializationFailed(String)
    case synthesisFailed(String)

    var description: String {
        switch self {
        case .modelMissing(let why): "Kokoro model missing: \(why)"
        case .initializationFailed(let why): "Kokoro init failed: \(why)"
        case .synthesisFailed(let why): "Kokoro synthesis failed: \(why)"
        }
    }
}

/// Neural-TTS backend driven by FluidAudio's `KokoroTtsManager`.
///
/// `KokoroTtsManager` is a `final class` (not Sendable, not an actor) and uses
/// `@TaskLocal` heavily inside the synthesis pipeline. To live cleanly under
/// Swift 6 strict concurrency we wrap it in our own actor — exactly how
/// `FluidAudioParakeetTranscriber` boxes `AsrManager`. All cross-actor access
/// flows through this actor's mailbox, so the underlying class only sees calls
/// from a single isolation domain.
///
/// Lifecycle:
///   1. `warm()` — stage the bundled Kokoro weights into the FluidAudio cache
///      layout, build the manager with `computeUnits: .cpuAndGPU` (iOS 26 ANE
///      compiler regression workaround), call `manager.initialize()`.
///   2. `speak(_:)` — call `synthesizeDetailed(text:)` (NOT `synthesize`,
///      which renormalises peaks per-call and makes back-to-back sentences
///      sound uneven), flatten `chunks.flatMap(\.samples)` into one `[Float]`,
///      hand it to `TTSWorker`, and await playback completion.
///   3. `stop()` — wipe the worker queue.
///   4. `cleanup()` — drop the FluidAudio model, tear down the worker.
actor KokoroTTSService: TTSService {
    private let log = Logger(subsystem: "com.theaayushstha.aftertalk", category: "Kokoro")
    private let voice: KokoroVoice
    private let worker = TTSWorker()
    private var didStage = false

    #if canImport(FluidAudio)
    /// `KokoroTtsManager` is a non-Sendable `final class`. To call its async
    /// methods from this actor under Swift 6 strict concurrency we wrap it in
    /// an `@unchecked Sendable` box — the same trick `FluidAudioParakeetTranscriber`
    /// uses for AVFoundation types. All access still funnels through the actor
    /// mailbox, so the box only ever sees calls from one isolation domain.
    private final class ManagerBox: @unchecked Sendable {
        let manager: KokoroTtsManager
        init(_ manager: KokoroTtsManager) { self.manager = manager }
    }
    private var managerBox: ManagerBox?
    #endif

    init(voice: KokoroVoice = .default) {
        self.voice = voice
    }

    func warm() async throws {
        #if canImport(FluidAudio)
        if managerBox?.manager.isAvailable == true { return }

        guard let bundleDir = ModelLocator.kokoroBundleDirectory() else {
            throw TTSError.modelMissing(
                "kokoro bundle not present — run Scripts/fetch-kokoro-models.sh"
            )
        }

        // FluidAudio's `KokoroTtsManager(directory:)` -> `TtsModels.download` ->
        // `<directory>/Models/kokoro/<file.mlmodelc>` lookup. Our bundled folder
        // is `<App.bundleURL>/kokoro-82m-coreml/<file.mlmodelc>`. Stage a
        // symlinked tree under Application Support that mimics the layout
        // FluidAudio expects without duplicating the weight bytes on disk.
        let staging = ModelLocator.kokoroStagingDirectory()
        try Self.stageBundleIntoFluidAudioLayout(bundle: bundleDir, staging: staging)

        // iOS 26 ANE has an int32 IR regression that crashes Kokoro's compiled
        // graph; FluidAudio's docstring (KokoroTtsManager.swift:33) recommends
        // `.cpuAndGPU` as the workaround until Apple ships a fixed compiler.
        let manager = KokoroTtsManager(
            defaultVoice: voice.fluidAudioId,
            directory: staging,
            computeUnits: .cpuAndGPU
        )
        do {
            try await manager.initialize()
        } catch {
            throw TTSError.initializationFailed(String(describing: error))
        }
        self.managerBox = ManagerBox(manager)
        // `manager.initialize()` only loads the TTS .mlmodelc graphs. The G2P
        // models, voice embedding cache and lexicon JSONs lazy-load on first
        // synthesis (~250-400 ms cold). Run a one-token dry synthesis here so
        // the first user-visible ask after launch hits a fully hot pipeline.
        // Output is discarded; we never enqueue it on the worker.
        do {
            _ = try await manager.synthesizeDetailed(text: "Hi.")
            log.info("Kokoro warm: voice=\(self.voice.fluidAudioId, privacy: .public) staging=\(staging.path, privacy: .public) (G2P + voice cached)")
        } catch {
            log.warning("Kokoro G2P prewarm dry-synth failed: \(String(describing: error), privacy: .public) — falling through, first ask will pay cold-start")
        }
        #else
        throw TTSError.modelMissing("FluidAudio module not available")
        #endif
    }

    func speak(_ sentence: String) async {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        #if canImport(FluidAudio)
        if managerBox == nil {
            // Lazy-warm so the first ask after launch still gets a voice even
            // if the prewarm task on RootView hasn't completed yet.
            do { try await warm() } catch {
                log.error("lazy warm failed: \(String(describing: error), privacy: .public)")
                return
            }
        }
        guard let box = managerBox else { return }

        do {
            let result = try await box.manager.synthesizeDetailed(text: trimmed)
            // synthesizeDetailed gives us per-chunk `[Float]` PCM at 24 kHz with
            // NO per-call peak normalisation, so concatenating chunks across
            // sentences keeps a consistent loudness curve.
            let samples = result.chunks.flatMap(\.samples)
            await worker.enqueue(samples)
            await worker.waitUntilDone()
        } catch {
            log.error("synth failed: \(String(describing: error), privacy: .public)")
        }
        #endif
    }

    func stop() async {
        await worker.cancel()
    }

    func cleanup() async {
        await worker.shutdown()
        #if canImport(FluidAudio)
        managerBox?.manager.cleanup()
        managerBox = nil
        #endif
    }

    // MARK: - Bundle staging

    /// Build a writable directory tree at `<staging>/Models/kokoro/` populated
    /// with copies of the bundled `.mlmodelc` directories + voice/G2P assets.
    ///
    /// We tried symlinking first — cheaper on disk — but FluidAudio's
    /// `DownloadUtils.loadModelsOnce` enumerates required model paths with
    /// `FileManager.fileExists(atPath:)` and on iOS that check returns `false`
    /// for symlinks that cross the sandbox boundary from `<App>/Library/Caches/`
    /// into the read-only signed bundle (`<App>/Aftertalk.app/...`). When the
    /// existence check fails, FluidAudio falls through to `downloadRepo` which
    /// `moveItem`s freshly-downloaded files onto our staging slots and crashes
    /// with `NSCocoaErrorDomain Code=516` ("File exists") because the symlink
    /// is already there. Copying real bytes into staging makes `fileExists`
    /// return `true`, so the download path never runs in airplane mode.
    ///
    /// Cost: ~700 MB duplicated under Caches (one-shot on first launch). The
    /// bundle still ships at ~1.3 GB so total disk on first warm is ~2 GB,
    /// dropping back as iOS evicts Caches under pressure. Subsequent launches
    /// see `coremldata.bin` already present in each `.mlmodelc` and skip the
    /// copy.
    private static func stageBundleIntoFluidAudioLayout(
        bundle: URL,
        staging: URL
    ) throws {
        let fm = FileManager.default
        let kokoroDir = staging
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("kokoro", isDirectory: true)
        try fm.createDirectory(at: kokoroDir, withIntermediateDirectories: true)

        let entries: [String]
        do {
            entries = try fm.contentsOfDirectory(atPath: bundle.path)
        } catch {
            throw TTSError.modelMissing("could not enumerate bundle: \(error)")
        }

        for entry in entries {
            let source = bundle.appendingPathComponent(entry)
            let dest = kokoroDir.appendingPathComponent(entry)
            if isStagingEntryPopulated(at: dest, sourcedFrom: source) {
                continue
            }
            // Replace whatever is there (stale symlink from old build, partial
            // copy from a crash) before re-copying. iOS removeItem is a no-op
            // when the path doesn't exist.
            try? fm.removeItem(at: dest)
            do {
                try fm.copyItem(at: source, to: dest)
            } catch {
                throw TTSError.initializationFailed(
                    "stage copy failed for \(entry): \(error)"
                )
            }
        }
    }

    /// True when `dest` already holds the staged form of `source`. For
    /// `.mlmodelc` directories we look for `coremldata.bin` inside (FluidAudio
    /// uses the same marker in `loadModelsOnce`). For loose JSON files we
    /// match byte size against the bundle copy — a fast proxy for "this is the
    /// same file we'd copy."
    private static func isStagingEntryPopulated(at dest: URL, sourcedFrom source: URL) -> Bool {
        let fm = FileManager.default
        var destIsDir: ObjCBool = false
        guard fm.fileExists(atPath: dest.path, isDirectory: &destIsDir) else { return false }

        if destIsDir.boolValue {
            // mlmodelc: look for the compile-output marker
            let marker = dest.appendingPathComponent("coremldata.bin")
            if fm.fileExists(atPath: marker.path) { return true }
            // Sub-folders (e.g. voices/) — match entry counts as a cheap check
            let srcCount = (try? fm.contentsOfDirectory(atPath: source.path).count) ?? -1
            let dstCount = (try? fm.contentsOfDirectory(atPath: dest.path).count) ?? -2
            return srcCount >= 0 && srcCount == dstCount
        }

        // Top-level JSON — same file size means identical (assets are static)
        let srcSize = (try? fm.attributesOfItem(atPath: source.path)[.size] as? Int) ?? -1
        let dstSize = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? -2
        return srcSize > 0 && srcSize == dstSize
    }
}
