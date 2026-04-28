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
}
