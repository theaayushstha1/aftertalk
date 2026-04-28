import Foundation

enum ModelLocator {
    static func appSupport() -> URL {
        let fm = FileManager.default
        let root = try? fm.url(for: .applicationSupportDirectory,
                               in: .userDomainMask,
                               appropriateFor: nil,
                               create: true)
        let base = root ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Aftertalk", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func moonshineModelDirectory() -> URL {
        let folderName = "moonshine-medium-streaming-en"
        let fm = FileManager.default
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        if fm.fileExists(atPath: bundled.path) {
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
        let fm = FileManager.default
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent(folderName, isDirectory: true)
        if fm.fileExists(atPath: bundled.path) {
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

    /// Writable staging directory the Kokoro service hands to FluidAudio. Lives
    /// under Application Support and gets a `Models/kokoro/` subtree wired to
    /// the bundled `.mlmodelc` directories via symlinks (cheap, no on-disk
    /// duplication).
    static func kokoroStagingDirectory() -> URL {
        let dir = appSupport().appendingPathComponent("KokoroStage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
