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

    static func moonshineTinyDirectory() -> URL {
        let folderName = "moonshine-tiny-streaming-en"
        let fm = FileManager.default
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        if fm.fileExists(atPath: bundled.path) {
            return bundled
        }
        return appSupport().appendingPathComponent(folderName, isDirectory: true)
    }
}
