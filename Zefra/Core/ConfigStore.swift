import Foundation

/// The settings file, shared by the app and the command line.
enum ConfigStore {
    static var home: URL {
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "ZefraHome") ?? ProcessInfo.processInfo.environment["ZEFRA_HOME"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Zefra", directoryHint: .isDirectory)
    }

    static var file: URL { home.appending(path: "config.json") }

    /// What the smart detector has learned about this Mac. Separate from the settings: it's large,
    /// changes all the time, and doesn't belong in a settings export.
    static var baselineFile: URL { home.appending(path: "baseline.json") }

    static func loadBaseline() -> DetectorBaseline {
        (try? Data(contentsOf: baselineFile)).flatMap { try? JSONDecoder().decode(DetectorBaseline.self, from: $0) } ?? DetectorBaseline()
    }

    static func saveBaseline(_ baseline: DetectorBaseline) {
        guard let data = try? JSONEncoder().encode(baseline) else { return }
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try? data.write(to: baselineFile, options: .atomic)
    }

    static func load() -> Config {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Config.self, from: $0) } ?? .starter
    }

    static func encoded(_ config: Config) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(config)
    }

    @discardableResult
    static func save(_ config: Config) -> Bool {
        guard let data = encoded(config) else { return false }
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (try? data.write(to: file, options: .atomic)) != nil
    }
}
