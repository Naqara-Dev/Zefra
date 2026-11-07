import Foundation

/// What the guard needs from the machine. The real one writes SMC keys; tests hand it a fake.
protocol FanHardware: AnyObject {
    var fanCount: Int { get }
    func range(of fan: Int) -> (min: Double, max: Double)?
    func force(_ fan: Int, rpm: Double) throws
    func release(_ fan: Int) throws
    func hottest() -> Double?
}

/// The rules the privileged side lives by, whatever it's asked: speeds stay within what the fan
/// reports, nobody listening means fans go back to macOS, and too hot means fans go back to macOS.
final class FanGuard {
    /// Silence longer than this and the app is gone or hung.
    static let heartbeatLimit: TimeInterval = 15
    /// No limit the app asks for goes above this.
    static let highestFailsafe = 105.0
    /// Plans stay locked out this long after the failsafe trips.
    static let lockout: TimeInterval = 60

    let hardware: FanHardware
    private(set) var forced = Set<Int>()
    private var lastHeartbeat: Date?
    private var failsafe = 98.0
    private var hotReadings = 0
    private(set) var lockedUntil: Date?

    init(hardware: FanHardware) { self.hardware = hardware }

    func heartbeat(failsafe limit: Double, now: Date) {
        lastHeartbeat = now
        failsafe = min(max(limit, 60), Self.highestFailsafe)
    }

    /// nil on success, or what went wrong.
    func setFan(_ fan: Int, rpm: Double, now: Date) -> String? {
        guard fan >= 0, fan < hardware.fanCount, let range = hardware.range(of: fan) else { return "There's no fan \(fan)." }
        guard rpm.isFinite else { return "That isn't a speed." }
        if let lockedUntil, now < lockedUntil { return "Too hot: macOS keeps the fans for now." }
        lastHeartbeat = now
        do {
            try hardware.force(fan, rpm: min(max(rpm, range.min), range.max))
            forced.insert(fan)
            return nil
        } catch {
            return "\(error)"
        }
    }

    func setAuto(_ fan: Int) -> String? {
        guard fan >= 0, fan < hardware.fanCount else { return "There's no fan \(fan)." }
        do {
            try hardware.release(fan)
            forced.remove(fan)
            return nil
        } catch {
            return "\(error)"
        }
    }

    /// Every fan, forced or not: after a crash this process wouldn't know which ones were.
    func releaseAll() {
        for fan in 0..<hardware.fanCount { try? hardware.release(fan) }
        forced.removeAll()
    }

    func clientLeft() { releaseAll() }

    /// Runs on a timer. Returns true when it just took the fans back.
    @discardableResult
    func tick(now: Date) -> Bool {
        guard !forced.isEmpty else {
            hotReadings = 0
            return false
        }
        if let lastHeartbeat, now.timeIntervalSince(lastHeartbeat) > Self.heartbeatLimit {
            releaseAll()
            return true
        }
        if let hottest = hardware.hottest(), hottest >= failsafe {
            hotReadings += 1
            // Three in a row: one reading alone can be a spike.
            if hotReadings >= 3 {
                hotReadings = 0
                lockedUntil = now.addingTimeInterval(Self.lockout)
                releaseAll()
                return true
            }
        } else {
            hotReadings = 0
        }
        return false
    }
}
