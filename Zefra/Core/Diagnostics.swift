import Foundation

struct BatteryInfo: Sendable, Equatable {
    var percent: Double
    var cycles: Int
    var designCycles: Int
    var designCapacity: Double
    var maxCapacity: Double
    var temperature: Double?
    var volts: Double
    var amps: Double
    var isCharging: Bool
    var onAdapter: Bool
    /// What macOS says of it: "Service Recommended" and the like. nil when it has nothing to say.
    var systemCondition: String? = nil
    /// The battery's own controller has flagged a permanent fault.
    var permanentFailure = false

    /// What's worth telling someone about. A healthy battery reports an empty condition, not "normal".
    var notice: String? {
        if permanentFailure { return "Permanent fault" }
        guard let condition = systemCondition?.trimmingCharacters(in: .whitespacesAndNewlines), !condition.isEmpty,
              condition.lowercased() != "normal" else { return nil }
        return condition
    }

    var health: Double { designCapacity > 0 ? min(maxCapacity / designCapacity * 100, 100) : 0 }
    var watts: Double { volts * amps }
}

struct Finding: Identifiable, Sendable, Equatable {
    enum Level: Int, Sendable, Comparable {
        case ok, note, warning, problem
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    var id: String { area + title }
    var area: String
    var level: Level
    var title: String
    var detail: String
}

struct FanStatus: Sendable, Equatable {
    var spec: FanSpec
    var name: String
    var rpm: Double
    /// The speed it's been asked for, when it has been.
    var target: Double?
}

struct SensorStats: Sendable, Equatable {
    var id: String
    var name: String
    var group: SensorGroup
    var value: Double
    var low: Double
    var high: Double
    /// Seconds it has been watched.
    var watched: TimeInterval
}

enum ThermalLevel: Int, Sendable, Comparable {
    case nominal, fair, serious, critical
    static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Slowing down"
        case .critical: "Slowing down a lot"
        }
    }
}

/// A drive's SMART data.
struct DriveHealth: Sendable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var isInternal: Bool
    var temperature: Double?
    var percentUsed: Int
    var availableSpare: Int
    var spareThreshold: Int
    var powerOnHours: Int
    var unsafeShutdowns: Int
    var mediaErrors: Int
    /// NVMe's critical warning bits; zero is good.
    var criticalWarning: Int

    /// The fields of an NVMe SMART log, as the drive lays them out. nil when it's too short to be one.
    init?(name: String, isInternal: Bool, log: [UInt8]) {
        guard log.count >= 176 else { return nil }
        func little(_ from: Int, _ count: Int) -> Int {
            // Counters are 16 bytes wide, far more than any real value needs.
            log[from..<(from + min(count, 7))].reversed().reduce(0) { $0 << 8 | Int($1) }
        }
        self.name = name
        self.isInternal = isInternal
        let kelvin = little(1, 2)
        temperature = kelvin > 0 ? Double(kelvin) - 273.15 : nil
        criticalWarning = Int(log[0])
        availableSpare = Int(log[3])
        spareThreshold = Int(log[4])
        percentUsed = Int(log[5])
        powerOnHours = little(128, 16)
        unsafeShutdowns = little(144, 16)
        mediaErrors = little(160, 16)
    }
}

/// How the last shutdown went, as far as can be told.
enum LastShutdown: Sendable, Equatable {
    /// Nothing to compare with yet.
    case unknown
    case clean
    /// The drive counted a power loss or forced shutdown.
    case unsafe(count: Int)
    /// macOS wrote a panic report since last time.
    case panic(report: String)

    /// Compares what the drives and report folder say now with what was seen before.
    static func judge(drives: [DriveHealth], newestPanic: String?, seen: SeenEvents) -> LastShutdown {
        if let newestPanic, newestPanic != seen.lastPanicReport { return .panic(report: newestPanic) }
        var known = false
        for drive in drives where drive.isInternal {
            guard let before = seen.unsafeShutdowns[drive.name] else { continue }
            known = true
            if drive.unsafeShutdowns > before { return .unsafe(count: drive.unsafeShutdowns - before) }
        }
        return known ? .clean : .unknown
    }
}

/// Reads what's on the machine and says what stands out. Nothing here touches hardware.
enum Diagnostics {
    struct Input: Sendable {
        var readsSensors: Bool
        var sensors: [SensorStats]
        var fans: [FanStatus]
        var hottest: Double?
        var battery: BatteryInfo?
        var thermal: ThermalLevel
        var helperInstalled: Bool
        var helperCurrent: Bool
        var drives: [DriveHealth] = []
        var lastShutdown = LastShutdown.unknown
        /// Fans the SMC itself marks as faulty.
        var flaggedFans: [Int] = []
        /// Sensors that were reading and have stopped.
        var silentSensors: [String] = []
        /// What the smart detector found. Only the running app has watched long enough to say.
        var anomalies: [Anomaly] = []
        var detectorWatched: Int?
        var detectorReady = 0
        var unit = TemperatureUnit.celsius
    }

    /// Long enough that a sensor that hasn't moved really isn't moving.
    static let stuckAfter: TimeInterval = 300

    static func run(_ input: Input) -> [Finding] {
        var found: [Finding] = []
        sensors(input, &found)
        fans(input, &found)
        battery(input, &found)
        thermal(input, &found)
        helper(input, &found)
        drives(input, &found)
        shutdown(input, &found)
        detector(input, &found)
        return found.sorted { $0.level != $1.level ? $0.level > $1.level : $0.area < $1.area }
    }

    private static func sensors(_ input: Input, _ found: inout [Finding]) {
        guard input.readsSensors, !input.sensors.isEmpty else {
            found.append(Finding(area: "Sensors", level: .problem, title: "No sensors could be read",
                                 detail: "Zefra couldn't read any temperature from this Mac."))
            return
        }
        found.append(Finding(area: "Sensors", level: .ok, title: "\(input.sensors.count) sensors reporting", detail: "Every one reads a believable temperature."))
        if !input.silentSensors.isEmpty {
            found.append(Finding(area: "Sensors", level: .warning, title: "\(input.silentSensors.count) sensor\(input.silentSensors.count == 1 ? "" : "s") stopped reporting",
                                 detail: input.silentSensors.prefix(4).joined(separator: ", ") + " read fine earlier and now give nothing believable."))
        }
        // Only ones that matter: board sensors often hold still, and that means nothing.
        let watched = input.sensors.filter { $0.watched >= stuckAfter && $0.group != .board && $0.group != .power && $0.group != .battery }
        let stuck = watched.filter { $0.high - $0.low < 0.01 }
        // A family that's all stuck is a set of placeholders; a lone one among moving ones isn't.
        let moving = Set(watched.filter { $0.high - $0.low >= 0.01 }.map(\.group))
        let suspicious = stuck.filter { moving.contains($0.group) && $0.value > 60 }
        if !suspicious.isEmpty {
            found.append(Finding(area: "Sensors", level: .note, title: "\(suspicious.count) sensor\(suspicious.count == 1 ? "" : "s") not moving",
                                 detail: suspicious.prefix(4).map(\.name).joined(separator: ", ") + " hold one value while others in their group change."))
        }
    }

    private static func fans(_ input: Input, _ found: inout [Finding]) {
        guard !input.fans.isEmpty else {
            found.append(Finding(area: "Fans", level: .note, title: "No fans found", detail: "This Mac cools without fans, or doesn't report them."))
            return
        }
        var clean = true
        for index in input.flaggedFans {
            clean = false
            let name = input.fans.first { $0.spec.index == index }?.name ?? "Fan \(index + 1)"
            found.append(Finding(area: "Fans", level: .problem, title: "The Mac reports \(name) as faulty", detail: "It's flagged by the Mac's own controller. Run the fan test to see whether it spins."))
        }
        for fan in input.fans {
            if fan.spec.maxRPM <= fan.spec.minRPM {
                clean = false
                found.append(Finding(area: "Fans", level: .warning, title: "\(fan.name) reports an odd range",
                                     detail: "Its minimum is \(Int(fan.spec.minRPM)) RPM and its maximum \(Int(fan.spec.maxRPM)) RPM."))
            }
            if let target = fan.target, target > 0, abs(fan.rpm - target) > max(target * 0.25, 500) {
                clean = false
                found.append(Finding(area: "Fans", level: .warning, title: "\(fan.name) isn't reaching its speed",
                                     detail: "Asked for \(Int(target)) RPM, running at \(Int(fan.rpm)) RPM. It may still be speeding up; check again in a moment."))
            }
            if fan.rpm < 1, fan.target == nil, (input.hottest ?? 0) >= 92 {
                clean = false
                found.append(Finding(area: "Fans", level: .problem, title: "\(fan.name) is stopped while the Mac is hot",
                                     detail: "The hottest part is at \(Int((input.hottest ?? 0).rounded()))°. Use the fan test to see whether it spins."))
            }
        }
        if clean {
            let all = input.fans.count == 1 ? "1 fan" : "\(input.fans.count) fans"
            found.append(Finding(area: "Fans", level: .ok, title: "\(all) behaving", detail: "A fan that's stopped while the Mac is cool is normal: macOS stops them at idle."))
        }
    }

    private static func battery(_ input: Input, _ found: inout [Finding]) {
        guard let battery = input.battery else { return }
        if battery.permanentFailure {
            found.append(Finding(area: "Battery", level: .problem, title: "The battery reports a permanent fault", detail: "It needs service."))
        } else if let condition = battery.systemCondition, !condition.isEmpty, condition.lowercased() != "normal" {
            found.append(Finding(area: "Battery", level: .warning, title: "macOS says: \(condition)", detail: "That comes from macOS's own check of the battery."))
        }
        let health = Int(battery.health.rounded())
        let cycles = "\(battery.cycles) of \(battery.designCycles) cycles"
        switch battery.health {
        case ..<70: found.append(Finding(area: "Battery", level: .problem, title: "Battery at \(health)% of its design capacity", detail: "\(cycles). Worth having it looked at."))
        case ..<80: found.append(Finding(area: "Battery", level: .warning, title: "Battery at \(health)% of its design capacity", detail: "\(cycles). It's wearing, and you'll notice shorter runs."))
        default: found.append(Finding(area: "Battery", level: .ok, title: "Battery at \(health)% of its design capacity", detail: cycles))
        }
        if battery.designCycles > 0, battery.cycles >= battery.designCycles {
            found.append(Finding(area: "Battery", level: .warning, title: "Past its rated cycles", detail: "\(cycles)."))
        }
        if let temp = battery.temperature, temp >= 45 {
            found.append(Finding(area: "Battery", level: .warning, title: "Battery is hot", detail: "\(Int(temp.rounded()))°. Heat is what wears batteries most."))
        }
    }

    private static func drives(_ input: Input, _ found: inout [Finding]) {
        for drive in input.drives {
            let where_ = drive.isInternal ? "" : " (external)"
            let usage = "\(drive.percentUsed)% of its rated writes used, \(drive.powerOnHours) hours on."
            if drive.criticalWarning != 0 {
                found.append(Finding(area: "Drives", level: .problem, title: "\(drive.name)\(where_) reports a critical warning", detail: "\(usage) Back it up now."))
            } else if drive.availableSpare <= drive.spareThreshold, drive.spareThreshold > 0 {
                found.append(Finding(area: "Drives", level: .problem, title: "\(drive.name)\(where_) is out of spare blocks", detail: "\(usage) Back it up now."))
            } else if drive.mediaErrors > 0 {
                found.append(Finding(area: "Drives", level: .warning, title: "\(drive.name)\(where_) has \(drive.mediaErrors) media errors", detail: "\(usage) Keep a backup."))
            } else if drive.percentUsed >= 90 {
                found.append(Finding(area: "Drives", level: .warning, title: "\(drive.name)\(where_) is near the end of its rated writes", detail: usage))
            } else {
                found.append(Finding(area: "Drives", level: .ok, title: "\(drive.name)\(where_) is healthy", detail: usage))
            }
        }
    }

    private static func shutdown(_ input: Input, _ found: inout [Finding]) {
        switch input.lastShutdown {
        case .unknown:
            found.append(Finding(area: "Last shutdown", level: .note, title: "Watching from now on", detail: "Zefra will notice a forced shutdown or a crash from the next restart on."))
        case .clean:
            found.append(Finding(area: "Last shutdown", level: .ok, title: "No forced shutdown or crash", detail: "Since Zefra last looked."))
        case .unsafe(let count):
            found.append(Finding(area: "Last shutdown", level: .warning, title: "The Mac didn't shut down cleanly", detail: "The drive counted \(count == 1 ? "a forced shutdown or power loss" : "\(count) forced shutdowns or power losses") since Zefra last looked."))
        case .panic(let report):
            found.append(Finding(area: "Last shutdown", level: .problem, title: "macOS crashed and restarted", detail: "It left a report: \(report)."))
        }
    }

    private static func detector(_ input: Input, _ found: inout [Finding]) {
        for group in SensorGroup.allCases {
            let here = input.anomalies.filter { $0.group == group }
            guard let text = AnomalyDetector.describe(here, unit: input.unit) else { continue }
            found.append(Finding(area: "Smart detector", level: group == .battery || group == .power ? .problem : .warning, title: text.title, detail: text.detail))
        }
        guard input.anomalies.isEmpty, let watched = input.detectorWatched, watched > 0 else { return }
        found.append(Finding(area: "Smart detector", level: .ok, title: "No part is running hot on its own",
                             detail: "Watching \(watched) sensors. It knows what's usual for \(input.detectorReady) of them in the current conditions, and keeps learning as you use the Mac."))
    }

    private static func thermal(_ input: Input, _ found: inout [Finding]) {
        switch input.thermal {
        case .nominal, .fair: found.append(Finding(area: "Thermal", level: .ok, title: "No thermal slowdown", detail: "macOS reports \(input.thermal.title.lowercased())."))
        case .serious: found.append(Finding(area: "Thermal", level: .warning, title: "macOS is slowing the Mac to cool it", detail: "Thermal pressure is high."))
        case .critical: found.append(Finding(area: "Thermal", level: .problem, title: "macOS is slowing the Mac a lot to cool it", detail: "Thermal pressure is critical."))
        }
    }

    private static func helper(_ input: Input, _ found: inout [Finding]) {
        if !input.helperInstalled {
            found.append(Finding(area: "Fan control", level: .note, title: "Fan control isn't set up", detail: "Reading temperatures works without it. Setting fan speeds needs the helper, in Settings."))
        } else if !input.helperCurrent {
            found.append(Finding(area: "Fan control", level: .warning, title: "The helper isn't answering", detail: "Reinstall it in Settings."))
        } else {
            found.append(Finding(area: "Fan control", level: .ok, title: "Helper running", detail: "If Zefra stops, it hands the fans back to macOS."))
        }
    }

    static func report(_ findings: [Finding], model: String, system: String, date: Date) -> String {
        var lines = ["Zefra diagnostics", "\(model), macOS \(system)", ISO8601DateFormatter().string(from: date), ""]
        for finding in findings {
            let mark = switch finding.level {
            case .ok: "OK     "
            case .note: "NOTE   "
            case .warning: "WARN   "
            case .problem: "PROBLEM"
            }
            lines.append("\(mark) [\(finding.area)] \(finding.title). \(finding.detail)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
