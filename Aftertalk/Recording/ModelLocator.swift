import Foundation

enum ModelLocator {
    // MARK: - Pure path math (no I/O)
    //
    // Every getter below builds a URL via string math only. They're safe to
    // call from `@MainActor init` of a SwiftUI view model on cold launch
    // because they never touch the disk. The directories these URLs point
    // into are created off the main thread by `bootstrap` (a detached
    // utility-priority task), and any caller that's about to *write* a file
    // immediately after looking up a path must `await awaitBootstrap()`
    // first.

    /// Application Support root for our model + recording sandbox. Pure URL
    /// math: no `FileManager.url(...)` lookup, no `createDirectory`. The
    /// directory itself is materialized by the bootstrap task; callers that
    /// need it on disk should await `awaitBootstrap()` before writing.
    static func appSupport() -> URL {
        let base: URL
        if let root = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first {
            base = root
        } else {
            base = URL(fileURLWithPath: NSTemporaryDirectory())
        }
        return base
            .appendingPathComponent("Aftertalk", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    static func moonshineModelDirectory() -> URL {
        // Small streaming is the picked live-preview variant because it stays
        // real-time on sustained continuous speech. The canonical transcript
        // still comes from Parakeet polish after recording, so live ASR can
        // bias toward latency without sacrificing stored meeting quality.
        let folderName = "moonshine-small-streaming-en"
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return appSupport().appendingPathComponent(folderName, isDirectory: true)
    }

    /// Directory containing the Parakeet-TDT v2 Core ML bundle.
    ///
    /// FluidAudio's `AsrModels.load(from:)` expects this path to point at the
    /// model repo folder (it derives `parentDirectory = directory.deletingLastPathComponent()`
    /// and re-appends `version.repo.folderName`). For `parakeetV2` the folder
    /// name is `parakeet-tdt-0.6b-v2` (the `-coreml` suffix is stripped). We
    /// bundle the directory as a resource via xcodegen folder reference, but
    /// allow an Application-Support fallback for hot-swap during development.
    static func parakeetModelDirectory() -> URL {
        let folderName = "parakeet-tdt-0.6b-v2"
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent(folderName, isDirectory: true)
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return appSupport().appendingPathComponent(folderName, isDirectory: true)
    }

    /// Bundle URL containing the Kokoro 82M Core ML weights.
    ///
    /// FluidAudio's `KokoroTtsManager(directory:)` flows through
    /// `TtsModels.download(directory:)` which appends `Models/<repo.folderName>`
    /// — and `Repo.kokoro.folderName == "kokoro"` (NOT `kokoro-82m-coreml`). To
    /// honor the on-device "no network" invariant we ship the weights as a
    /// folder reference at `Aftertalk/Resources/Models/kokoro-82m-coreml/` (the
    /// literal `.mlmodelc` directories at the top level), then build a tiny
    /// staging tree at runtime with the layout FluidAudio expects:
    /// `<staging>/Models/kokoro/<files>`. `KokoroTTSService` owns the staging
    /// step; this helper just hands back the bundle source dir.
    static func kokoroBundleDirectory() -> URL? {
        let folderName = "kokoro-82m-coreml"
        let fm = FileManager.default
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent(folderName, isDirectory: true)
        if fm.fileExists(atPath: bundled.path) {
            return bundled
        }
        let fallback = appSupport().appendingPathComponent(folderName, isDirectory: true)
        if fm.fileExists(atPath: fallback.path) {
            return fallback
        }
        return nil
    }

    /// Writable staging directory the Kokoro service hands to FluidAudio.
    ///
    /// FluidAudio's G2P, voice-pack and vocab loaders **ignore** the `directory:`
    /// argument passed to `KokoroTtsManager` — they hardcode their lookups to
    /// `TtsModels.cacheDirectoryURL()`, which on iOS resolves to
    /// `<Caches>/fluidaudio/`. We therefore stage into that exact directory so
    /// that `<Caches>/fluidaudio/Models/kokoro/g2p_vocab.json` (and friends)
    /// resolve at runtime. The `directory:` argument we still pass to the
    /// manager is then redundant but harmless — kept consistent so the TTS
    /// variant `.mlmodelc` lookups also succeed if FluidAudio adds a code path
    /// that honors it.
    ///
    /// Pure path math: caller must `await ModelLocator.awaitBootstrap()`
    /// before writing into this directory. The directory itself is created by
    /// the bootstrap task off the main thread.
    static func kokoroStagingDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("fluidaudio", isDirectory: true)
    }

    /// Directory containing the FluidAudio Pyannote + WeSpeaker Core ML bundle.
    ///
    /// Unlike the Parakeet path, FluidAudio's
    /// `DiarizerModels.load(localSegmentationModel:localEmbeddingModel:)`
    /// takes per-file URLs to compiled `.mlmodelc` directories rather than a
    /// repo folder. We still keep the two bundles colocated under one folder
    /// so they ship together as a resource.
    ///
    /// Returns `nil` when neither the bundled folder nor the Application
    /// Support fallback exists, mirroring the Parakeet pattern so callers can
    /// gracefully fall through when the weights haven't been fetched (CI,
    /// fresh checkout).
    static func diarizerModelDirectory() -> URL? {
        let folderName = "speaker-diarization-coreml"
        let fm = FileManager.default
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent(folderName, isDirectory: true)
        if fm.fileExists(atPath: bundled.path) {
            return bundled
        }
        let fallback = appSupport().appendingPathComponent(folderName, isDirectory: true)
        if fm.fileExists(atPath: fallback.path) {
            return fallback
        }
        return nil
    }

    /// URL of the Pyannote segmentation `.mlmodelc` bundle (compiled CoreML
    /// directory). Returns `nil` when the model directory is empty.
    static func segmentationModelURL() -> URL? {
        guard let dir = diarizerModelDirectory() else { return nil }
        let url = dir.appendingPathComponent("pyannote_segmentation.mlmodelc", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// URL of the WeSpeaker v2 embedding `.mlmodelc` bundle. Returns `nil`
    /// when the model directory is empty.
    static func embeddingModelURL() -> URL? {
        guard let dir = diarizerModelDirectory() else { return nil }
        let url = dir.appendingPathComponent("wespeaker_v2.mlmodelc", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Background bootstrap
    //
    // `createDirectory(... withIntermediateDirectories: true)` for our two
    // writable roots used to run synchronously inside `appSupport()` and
    // `kokoroStagingDirectory()`, both of which were called from
    // `@MainActor init` of view models. That blocked the main thread for
    // 50–150 ms on cold launch. We move that work to a detached utility-
    // priority task that fires on first reference; callers about to write
    // immediately must `await awaitBootstrap()` first.

    /// Detached task that materializes the writable directories. Created
    /// lazily on first reference; subsequent references are zero-cost
    /// (Swift's static-let init is thread-safe and lock-free after the
    /// first hit).
    ///
    /// Static-let init is thread-safe (dispatch_once); the Task value is
    /// itself Sendable and immutable once created; the body captures only
    /// Sendable values (FileManager.default, URL). Swift 6 figures all
    /// that out without an isolation annotation, so we let it.
    private static let _bootstrap: Task<Void, Never> = Task.detached(priority: .utility) {
        let fm = FileManager.default
        // Two writable roots. Both created with intermediates so partial
        // failures (e.g. permissions) don't leave a half-state. `try?`
        // swallows errors — failure here is reported by the writing caller
        // when its actual write fails, with a more useful error context.
        try? fm.createDirectory(at: ModelLocator.appSupport(),
                                withIntermediateDirectories: true)
        try? fm.createDirectory(at: ModelLocator.kokoroStagingDirectory(),
                                withIntermediateDirectories: true)
    }

    /// Await the background bootstrap. Cheap on the second+ call (the task
    /// has resolved). Callers that look up a path and then immediately
    /// write a file under it must call this first; lazy-write callers
    /// (path lookup, existence probe) don't need to.
    static func awaitBootstrap() async {
        await _bootstrap.value
    }

    /// Fire-and-forget kicker. Importing this from app launch ensures the
    /// detached task is scheduled before any `await awaitBootstrap()` site
    /// is hit; without it the first `awaitBootstrap()` call still blocks on
    /// the disk work, defeating the optimization for that one caller.
    /// Returning `Void` (not the task) keeps the API minimal.
    @discardableResult
    static func kickoffBootstrap() -> Bool {
        _ = _bootstrap
        return true
    }
}
