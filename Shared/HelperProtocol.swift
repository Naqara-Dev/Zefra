import Foundation

enum HelperInfo {
    static let label = "com.naqara.zefra.helper"
    /// Goes up whenever the helper changes, so an old one gets replaced.
    static let version = "1"
    static let toolPath = "/Library/PrivilegedHelperTools/\(label)"
    static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    static let appIdentifier = "com.naqara.zefra"
}

/// All the helper will do. There's no way through it to any other SMC key, or to anything else.
@objc protocol ZefraHelper {
    func hello(reply: @escaping @Sendable (String) -> Void)
    func setFan(_ fan: Int, rpm: Double, reply: @escaping @Sendable (String?) -> Void)
    func setAuto(_ fan: Int, reply: @escaping @Sendable (String?) -> Void)
    func setAllAuto(reply: @escaping @Sendable () -> Void)
    /// "I'm still here." Answers whether the helper has taken the fans back.
    func heartbeat(failsafe: Double, reply: @escaping @Sendable (Bool) -> Void)
}
