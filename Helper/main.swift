import Foundation
import Security

// zefrad: runs as root so the app doesn't have to. It sets fan speeds and nothing else, for the
// signed Zefra app and nobody else, and hands the fans back to macOS whenever it's in doubt.

final class SMCFans: FanHardware {
    private let smc: SMC
    let fanCount: Int
    private var hotKeys: [String] = []

    init() throws {
        smc = try SMC()
        fanCount = Int(smc.number("FNum") ?? 0)
        // Only the parts that decide whether the Mac is in danger.
        hotKeys = smc.allKeys().filter { key in
            guard key.count == 4, key.hasPrefix("Te") || key.hasPrefix("Tp") || key.hasPrefix("Tg") else { return false }
            guard let value = smc.number(key) else { return false }
            return value > 10 && value < 125
        }
    }

    func range(of fan: Int) -> (min: Double, max: Double)? {
        guard let high = smc.number("F\(fan)Mx"), high > 0 else { return nil }
        return (smc.number("F\(fan)Mn") ?? 0, high)
    }

    func force(_ fan: Int, rpm: Double) throws {
        guard let modeKey = SMC.modeKey(fan, on: smc) else { throw SMC.Failure.noKey("F\(fan)Md") }
        if smc.number(modeKey) != 1 {
            // Newer Apple Silicon Macs only take a mode change after this key is set, and may take a
            // moment to accept it.
            if smc.has("Ftst"), smc.number("Ftst") != 1 { try smc.write("Ftst", [1]) }
            var last: Error?
            var accepted = false
            for _ in 0..<40 {
                do {
                    try smc.write(modeKey, [1])
                    if smc.number(modeKey) == 1 { accepted = true; break }
                } catch { last = error }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard accepted else { throw last ?? SMC.Failure.result(key: modeKey, code: 0) }
        }
        let targetKey = "F\(fan)Tg"
        let info = try smc.info(targetKey)
        guard let bytes = SMC.encode(rpm, type: info.type) else { throw SMC.Failure.badValue(targetKey) }
        try smc.write(targetKey, bytes)
    }

    func release(_ fan: Int) throws {
        guard let modeKey = SMC.modeKey(fan, on: smc) else { return }
        // A fan macOS is running stays untouched: only one that was forced gets written.
        if smc.number(modeKey) == 1 { try smc.write(modeKey, [0]) }
        // With every fan back in automatic, the unlock goes too.
        let anyForced = (0..<fanCount).contains { other in
            guard let key = SMC.modeKey(other, on: smc) else { return false }
            return smc.number(key) == 1
        }
        if !anyForced, smc.has("Ftst"), smc.number("Ftst") != 0 { try? smc.write("Ftst", [0]) }
    }

    func hottest() -> Double? {
        hotKeys.compactMap { smc.number($0) }.filter { $0 > 10 && $0 < 125 }.max()
    }
}

final class Service: NSObject, ZefraHelper, NSXPCListenerDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.naqara.zefra.helper")
    private let fans: FanGuard
    private var clients = 0
    private var tookBack = false
    private var timer: DispatchSourceTimer?

    init(fans: FanGuard) {
        self.fans = fans
        super.init()
    }

    func start() {
        // Whatever an earlier run left behind.
        queue.sync { fans.releaseAll() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [self] in
            if fans.tick(now: .now) { tookBack = true }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        queue.sync { fans.releaseAll() }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ZefraHelper.self)
        connection.exportedObject = self
        let left: @Sendable () -> Void = { [self] in
            queue.async { [self] in
                clients -= 1
                if clients <= 0 {
                    clients = 0
                    fans.clientLeft()
                }
            }
        }
        // Each fires at most once for a given end; only invalidation means it's really gone.
        connection.invalidationHandler = left
        queue.sync { clients += 1 }
        connection.resume()
        return true
    }

    func hello(reply: @escaping @Sendable (String) -> Void) { reply(HelperInfo.version) }

    func setFan(_ fan: Int, rpm: Double, reply: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in reply(fans.setFan(fan, rpm: rpm, now: .now)) }
    }

    func setAuto(_ fan: Int, reply: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in reply(fans.setAuto(fan)) }
    }

    func setAllAuto(reply: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            fans.releaseAll()
            reply()
        }
    }

    func heartbeat(failsafe: Double, reply: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            fans.heartbeat(failsafe: failsafe, now: .now)
            let took = tookBack
            tookBack = false
            reply(took)
        }
    }
}

/// Only an app with Zefra's identifier, signed by the same certificate as this helper.
func clientRequirement() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
          let leaf = certificates.first else { return nil }
    let hash = SHA1.hex(of: SecCertificateCopyData(leaf) as Data)
    return "identifier \"\(HelperInfo.appIdentifier)\" and certificate leaf = H\"\(hash)\""
}

guard let requirement = clientRequirement() else {
    // Unsigned or ad hoc: there'd be nothing to check a caller against, so nobody gets in.
    FileHandle.standardError.write(Data("zefrad: not signed by a certificate; refusing to run\n".utf8))
    exit(78)
}

let hardware: SMCFans
do {
    hardware = try SMCFans()
} catch {
    FileHandle.standardError.write(Data("zefrad: \(error)\n".utf8))
    exit(1)
}

let service = Service(fans: FanGuard(hardware: hardware))
service.start()

for number in [SIGTERM, SIGINT, SIGHUP] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        service.stop()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

let listener = NSXPCListener(machServiceName: HelperInfo.label)
listener.setConnectionCodeSigningRequirement(requirement)
listener.delegate = service
listener.resume()
dispatchMain()
