import AppKit
import Foundation

/// Whoever can actually change a fan's speed.
@MainActor
protocol FanControl: AnyObject {
    var isAvailable: Bool { get }
    /// Whether what it sets shows up in the SMC's fan mode, so a reset fan can be noticed.
    var changesHardware: Bool { get }
    func set(_ fan: Int, rpm: Double, done: @escaping @MainActor (String?) -> Void)
    func release(_ fan: Int, done: @escaping @MainActor (String?) -> Void)
    func releaseAll()
    func heartbeat(failsafe: Double)
}

/// Talks to the helper over XPC. The helper checks that this app is who it says it is; if this
/// process dies or the connection drops, the helper hands the fans back to macOS by itself.
@MainActor
final class HelperClient: FanControl {
    private(set) var isInstalled = false
    private(set) var answering = false
    private(set) var version: String?
    private var connection: NSXPCConnection?
    /// launchd restarts a helper that dies, so a lost connection is worth checking again soon.
    var onDropped: (@MainActor () -> Void)?

    var isAvailable: Bool { answering }
    var changesHardware: Bool { true }

    private func proxy(onError: @escaping @Sendable (Error) -> Void) -> ZefraHelper? {
        if connection == nil {
            let new = NSXPCConnection(machServiceName: HelperInfo.label, options: .privileged)
            new.remoteObjectInterface = NSXPCInterface(with: ZefraHelper.self)
            new.invalidationHandler = { [weak self] in Task { @MainActor in self?.dropped() } }
            new.interruptionHandler = { [weak self] in Task { @MainActor in self?.dropped() } }
            new.resume()
            connection = new
        }
        return connection?.remoteObjectProxyWithErrorHandler(onError) as? ZefraHelper
    }

    private func dropped() {
        connection = nil
        answering = false
        onDropped?()
    }

    /// Whether it's installed and answering, and with which version.
    func refresh(done: @escaping @MainActor () -> Void = {}) {
        isInstalled = FileManager.default.fileExists(atPath: HelperInfo.plistPath)
        guard isInstalled else {
            answering = false
            version = nil
            done()
            return
        }
        let failed: @Sendable (Error) -> Void = { [weak self] _ in
            Task { @MainActor in
                self?.answering = false
                self?.version = nil
                done()
            }
        }
        guard let proxy = proxy(onError: failed) else { return done() }
        proxy.hello { [weak self] version in
            Task { @MainActor in
                self?.answering = true
                self?.version = version
                done()
            }
        }
    }

    func set(_ fan: Int, rpm: Double, done: @escaping @MainActor (String?) -> Void) {
        let failed: @Sendable (Error) -> Void = { error in
            let text = error.localizedDescription
            Task { @MainActor in done(text) }
        }
        guard let proxy = proxy(onError: failed) else { return done("The helper isn't running.") }
        proxy.setFan(fan, rpm: rpm) { error in Task { @MainActor in done(error) } }
    }

    func release(_ fan: Int, done: @escaping @MainActor (String?) -> Void) {
        let failed: @Sendable (Error) -> Void = { error in
            let text = error.localizedDescription
            Task { @MainActor in done(text) }
        }
        guard let proxy = proxy(onError: failed) else { return done("The helper isn't running.") }
        proxy.setAuto(fan) { error in Task { @MainActor in done(error) } }
    }

    func releaseAll() {
        proxy(onError: { _ in })?.setAllAuto {}
    }

    func heartbeat(failsafe: Double) {
        proxy(onError: { _ in })?.heartbeat(failsafe: failsafe) { _ in }
    }
}

/// Puts the helper in place, or takes it away. macOS asks for the admin password once.
enum HelperInstaller {
    enum Failure: LocalizedError {
        case missing, cancelled, failed(String)
        var errorDescription: String? {
            switch self {
            case .missing: "The helper is missing from the app."
            case .cancelled: "Cancelled."
            case .failed(let text): text
            }
        }
    }

    private static var bundled: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "zefrad")
    }

    /// Single quotes, safe to paste into a shell script.
    static func shellQuoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func plist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(HelperInfo.label)</string>
            <key>Program</key><string>\(HelperInfo.toolPath)</string>
            <key>MachServices</key><dict><key>\(HelperInfo.label)</key><true/></dict>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
        </dict>
        </plist>
        """
    }

    private static func runAsAdmin(_ script: String, prompt: String) throws {
        let quoted = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(quoted)\" with prompt \"\(prompt)\" with administrator privileges"
        var error: NSDictionary?
        guard let apple = NSAppleScript(source: source) else { throw Failure.failed("Couldn't ask for permission.") }
        apple.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -128 { throw Failure.cancelled }
            throw Failure.failed(error[NSAppleScript.errorMessage] as? String ?? "It didn't work.")
        }
    }

    /// Runs it directly when already root (a script, or device management), otherwise asks.
    private static func run(_ script: String, prompt: String) throws {
        guard getuid() == 0 else { return try runAsAdmin(script, prompt: prompt) }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", script]
        try shell.run()
        shell.waitUntilExit()
        if shell.terminationStatus != 0 { throw Failure.failed("The helper's install script failed.") }
    }

    static func install() throws {
        guard let tool = bundled else { throw Failure.missing }
        let staged = FileManager.default.temporaryDirectory.appending(path: "zefra-\(UUID().uuidString).plist")
        try plist().write(to: staged, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: staged) }
        let script = [
            "/bin/launchctl bootout system/\(HelperInfo.label) 2>/dev/null",
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/bin/cp -f \(shellQuoted(tool.path)) \(shellQuoted(HelperInfo.toolPath))",
            "/usr/sbin/chown root:wheel \(shellQuoted(HelperInfo.toolPath))",
            "/bin/chmod 544 \(shellQuoted(HelperInfo.toolPath))",
            "/bin/cp -f \(shellQuoted(staged.path)) \(shellQuoted(HelperInfo.plistPath))",
            "/usr/sbin/chown root:wheel \(shellQuoted(HelperInfo.plistPath))",
            "/bin/chmod 644 \(shellQuoted(HelperInfo.plistPath))",
            "/bin/launchctl bootstrap system \(shellQuoted(HelperInfo.plistPath))",
        ].joined(separator: "; ")
        try run(script, prompt: "Zefra needs to install a small helper to set fan speeds.")
    }

    static func uninstall() throws {
        let script = [
            "/bin/launchctl bootout system/\(HelperInfo.label) 2>/dev/null",
            "/bin/rm -f \(shellQuoted(HelperInfo.plistPath)) \(shellQuoted(HelperInfo.toolPath))",
        ].joined(separator: "; ")
        try run(script, prompt: "Zefra needs to remove its helper.")
    }
}

#if DEBUG
/// Pretends to be the helper, so everything above it can be tried without root. `-ZefraFakeFans YES`.
@MainActor
final class FakeFanControl: FanControl {
    /// `-ZefraFakeNoHelper YES` starts as if the helper weren't installed yet.
    var isAvailable = !UserDefaults.standard.bool(forKey: "ZefraFakeNoHelper")
    var changesHardware: Bool { false }
    private(set) var rpm: [Int: Double] = [:]

    func set(_ fan: Int, rpm value: Double, done: @escaping @MainActor (String?) -> Void) {
        rpm[fan] = value
        print("ZEFRA_FAN \(fan) \(Int(value))")
        fflush(stdout)
        done(nil)
    }

    func release(_ fan: Int, done: @escaping @MainActor (String?) -> Void) {
        rpm[fan] = nil
        print("ZEFRA_FAN \(fan) auto")
        fflush(stdout)
        done(nil)
    }

    func releaseAll() { rpm.removeAll() }
    func heartbeat(failsafe: Double) {}
}
#endif
