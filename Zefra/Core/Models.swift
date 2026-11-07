import Foundation

/// Where a sensor sits. Sensor names differ on every Mac, so groups come from each name's family.
enum SensorGroup: String, Codable, CaseIterable, Sendable, Identifiable {
    case cpuPerformance, cpuEfficiency, gpu, soc, memory, storage, battery, wireless, power, board

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpuPerformance: "CPU performance"
        case .cpuEfficiency: "CPU efficiency"
        case .gpu: "GPU"
        case .soc: "SoC"
        case .memory: "Memory"
        case .storage: "Storage"
        case .battery: "Battery"
        case .wireless: "Wireless"
        case .power: "Power"
        case .board: "Board"
        }
    }
}

/// What a rule or a curve watches.
enum TempSource: Codable, Hashable, Sendable {
    case hottest
    case cpu
    case cpuAverage
    case group(SensorGroup)
    case sensor(String)
}

/// One sensor at one moment.
struct SensorReading: Sendable, Identifiable, Equatable {
    var id: String
    var key: String
    var name: String
    var group: SensorGroup
    var value: Double
    var countsTowardHottest: Bool
}

/// All sensors at one moment, and what rules ask of them.
struct TempSnapshot: Sendable {
    var readings: [SensorReading] = []
    private var values: [String: Double] = [:]
    private var groupPeaks: [SensorGroup: Double] = [:]
    private var cpuAverage: Double?
    private(set) var hottest: SensorReading?

    init(readings: [SensorReading] = []) {
        self.readings = readings
        for reading in readings {
            values[reading.id] = reading.value
            groupPeaks[reading.group] = max(groupPeaks[reading.group] ?? -.infinity, reading.value)
            if reading.countsTowardHottest, reading.value > (hottest?.value ?? -.infinity) { hottest = reading }
        }
        let cores = readings.filter { $0.group == .cpuPerformance || $0.group == .cpuEfficiency }
        if !cores.isEmpty { cpuAverage = cores.map(\.value).reduce(0, +) / Double(cores.count) }
    }

    func value(of source: TempSource) -> Double? {
        switch source {
        case .hottest: hottest?.value
        case .cpu:
            switch (groupPeaks[.cpuPerformance], groupPeaks[.cpuEfficiency]) {
            case let (p?, e?): max(p, e)
            case let (p?, nil): p
            case let (nil, e?): e
            default: nil
            }
        case .cpuAverage: cpuAverage
        case .group(let group): groupPeaks[group]
        case .sensor(let id): values[id]
        }
    }
}

struct CurvePoint: Codable, Hashable, Sendable {
    var temp: Double
    var percent: Double
}

/// Fan speed as a function of a temperature. Below the first point the fan can go back to macOS,
/// which is what lets it stop: "on at 60°, off below 57°" without writing a rule.
struct Curve: Codable, Hashable, Sendable {
    var source: TempSource = .cpu
    var points: [CurvePoint]
    var releasesBelowFirstPoint = true

    /// How far below the first point it has to drop before letting go, so it doesn't flap.
    static let releaseBand = 3.0

    /// Sorted, within range, with no two points on one temperature, and never fewer than two.
    var cleaned: Curve {
        var copy = self
        var seen = Set<Int>()
        copy.points = points.sorted { $0.temp < $1.temp }
            .map { CurvePoint(temp: min(max($0.temp, 0), 120), percent: min(max($0.percent, 0), 100)) }
            .filter { seen.insert(Int($0.temp.rounded())).inserted }
        if copy.points.isEmpty { copy.points = [CurvePoint(temp: 50, percent: 0), CurvePoint(temp: 90, percent: 100)] }
        if copy.points.count == 1 {
            let only = copy.points[0]
            copy.points.append(CurvePoint(temp: min(only.temp + 20, 120), percent: 100))
        }
        return copy
    }

    /// Straight lines between points, flat past either end.
    func percent(at temp: Double) -> Double {
        let points = cleaned.points
        if temp <= points[0].temp { return points[0].percent }
        if temp >= points[points.count - 1].temp { return points[points.count - 1].percent }
        for (a, b) in zip(points, points.dropFirst()) where temp <= b.temp {
            guard b.temp > a.temp else { return b.percent }
            return a.percent + (b.percent - a.percent) * (temp - a.temp) / (b.temp - a.temp)
        }
        return points[points.count - 1].percent
    }
}

enum FanPlan: Codable, Hashable, Sendable {
    /// macOS decides, and may stop the fan when it's cool.
    case system
    case fixed(percent: Double)
    case curve(Curve)
}

struct Profile: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var name: String
    var icon = "fan"
    /// Every fan, unless it has a plan of its own below.
    var plan: FanPlan = .system
    var perFan: [Int: FanPlan] = [:]

    func plan(forFan index: Int) -> FanPlan { perFan[index] ?? plan }
}

enum PowerCondition: String, Codable, CaseIterable, Sendable {
    case any, adapter, battery

    var title: String {
        switch self {
        case .any: "On any power"
        case .adapter: "Only when plugged in"
        case .battery: "Only on battery"
        }
    }
}

enum PowerSource: Sendable { case adapter, battery }

/// A daily window in minutes after midnight. It can run past midnight.
struct DailyWindow: Codable, Hashable, Sendable {
    var from: Int
    var to: Int

    func contains(minute: Int) -> Bool {
        if from == to { return true }
        return from < to ? (minute >= from && minute < to) : (minute >= from || minute < to)
    }
}

enum RuleDirection: String, Codable, CaseIterable, Sendable {
    /// On when it gets hot, off when it has cooled.
    case rises
    /// On when it has cooled, off when it warms up.
    case falls
}

enum RuleAction: Codable, Hashable, Sendable {
    /// `fans` nil means every fan.
    case setFans(percent: Double, fans: [Int]?)
    case switchProfile(UUID)
    case notifyOnly
}

/// "When the CPU stays above 75° for 5 s, run the fans at 80%, until it stays below 60° for 30 s."
struct Rule: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var enabled: Bool
    var source: TempSource
    var direction: RuleDirection
    /// The temperature that starts it, and how long it has to hold there.
    var onAt: Double
    var onHold: Double
    /// The temperature that ends it, and how long it has to hold there.
    var offAt: Double
    var offHold: Double
    var power: PowerCondition
    var window: DailyWindow?
    var action: RuleAction
    var notifyOn: Bool
    var notifyOff: Bool
    var sound: Bool
    var email: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, source, direction, onAt, onHold, offAt, offHold, power, window, action, notifyOn, notifyOff, sound, email
    }

    init(id: UUID = UUID(), name: String, enabled: Bool = true, source: TempSource = .cpu, direction: RuleDirection = .rises, onAt: Double, onHold: Double = 5,
         offAt: Double, offHold: Double = 30, power: PowerCondition = .any, window: DailyWindow? = nil, action: RuleAction,
         notifyOn: Bool = false, notifyOff: Bool = false, sound: Bool = false, email: Bool = false) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.source = source
        self.direction = direction
        self.onAt = onAt
        self.onHold = onHold
        self.offAt = offAt
        self.offHold = offHold
        self.power = power
        self.window = window
        self.action = action
        self.notifyOn = notifyOn
        self.notifyOff = notifyOff
        self.sound = sound
        self.email = email
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        source = try c.decodeIfPresent(TempSource.self, forKey: .source) ?? .cpu
        direction = try c.decodeIfPresent(RuleDirection.self, forKey: .direction) ?? .rises
        onAt = try c.decode(Double.self, forKey: .onAt)
        onHold = try c.decodeIfPresent(Double.self, forKey: .onHold) ?? 5
        offAt = try c.decode(Double.self, forKey: .offAt)
        offHold = try c.decodeIfPresent(Double.self, forKey: .offHold) ?? 30
        power = try c.decodeIfPresent(PowerCondition.self, forKey: .power) ?? .any
        window = try c.decodeIfPresent(DailyWindow.self, forKey: .window)
        action = try c.decode(RuleAction.self, forKey: .action)
        notifyOn = try c.decodeIfPresent(Bool.self, forKey: .notifyOn) ?? false
        notifyOff = try c.decodeIfPresent(Bool.self, forKey: .notifyOff) ?? false
        sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? false
        email = try c.decodeIfPresent(Bool.self, forKey: .email) ?? false
    }

    /// Whether `temp` has reached the start of the rule.
    func isOnSide(_ temp: Double) -> Bool { direction == .rises ? temp >= onAt : temp <= onAt }
    /// Whether `temp` has reached the end of the rule.
    func isOffSide(_ temp: Double) -> Bool { direction == .rises ? temp <= offAt : temp >= offAt }

    /// An end that crosses the start would switch on and off for ever.
    var hasValidBand: Bool { direction == .rises ? offAt < onAt : offAt > onAt }
}

enum TemperatureUnit: String, Codable, CaseIterable, Sendable {
    case celsius, fahrenheit

    func display(_ celsius: Double) -> Double { self == .celsius ? celsius : celsius * 9 / 5 + 32 }
    func fromDisplay(_ value: Double) -> Double { self == .celsius ? value : (value - 32) * 5 / 9 }
    var symbol: String { self == .celsius ? "°C" : "°F" }

    /// "72°", in this unit, rounded.
    func text(_ celsius: Double?) -> String {
        guard let celsius else { return "–" }
        return "\(Int(display(celsius).rounded()))°"
    }
}

/// What the menu bar shows, in the order chosen.
enum MenuBarItem: Codable, Hashable, Sendable {
    case icon
    case temperature(TempSource)
    case fan(Int)
    case power
}

enum AppearanceChoice: String, Codable, CaseIterable, Sendable {
    case dark, light, system
    var title: String { rawValue.capitalized }
}

enum MenuBarLayout: String, Codable, CaseIterable, Sendable {
    case row, stacked, twoLines

    var title: String {
        switch self {
        case .row: "In a row"
        case .stacked: "Stacked"
        case .twoLines: "Two lines"
        }
    }
}

enum MenuBarIcon: String, Codable, CaseIterable, Sendable {
    case fan, thermometer

    var title: String { rawValue.capitalized }
    var symbol: String { self == .fan ? "fan" : "thermometer.medium" }
}

enum LogSchedule: String, Codable, CaseIterable, Sendable {
    /// One file that keeps growing.
    case append
    /// A fresh file each time Zefra starts.
    case eachLaunch
    /// A new file each day.
    case daily

    var title: String {
        switch self {
        case .append: "One file"
        case .eachLaunch: "Each launch"
        case .daily: "Each day"
        }
    }
}

enum MailSecurity: String, Codable, CaseIterable, Sendable {
    /// Connects in the clear and upgrades before anything is said: port 587.
    case startTLS
    /// Encrypted from the first byte: port 465.
    case tls

    var title: String { self == .startTLS ? "STARTTLS" : "TLS" }
    var defaultPort: Int { self == .startTLS ? 587 : 465 }
}

struct MailSettings: Codable, Hashable, Sendable {
    var enabled = false
    var host = ""
    var port = 587
    var security = MailSecurity.startTLS
    var username = ""
    var usesPassword = true
    var from = ""
    var to = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 587
        security = try c.decodeIfPresent(MailSecurity.self, forKey: .security) ?? .startTLS
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        usesPassword = try c.decodeIfPresent(Bool.self, forKey: .usesPassword) ?? true
        from = try c.decodeIfPresent(String.self, forKey: .from) ?? ""
        to = try c.decodeIfPresent(String.self, forKey: .to) ?? ""
    }

    var isComplete: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && !from.isEmpty && !to.isEmpty && (1...65535).contains(port)
    }
}

/// A key and its modifiers, as Carbon wants them.
struct HotKey: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// What it looks like, for showing: "⌥⌘Z".
    var label: String
}

struct Settings: Codable, Hashable, Sendable {
    var unit = TemperatureUnit.celsius
    /// Seconds between readings.
    var interval = 2.0
    var historyMinutes = 60
    /// Above this every fan goes back to macOS, whatever the plan says.
    var failsafe = 98.0
    /// How fast the fans may speed up and slow down, in percent per second.
    var rampUp = 25.0
    var rampDown = 4.0
    /// Hand the fans back to macOS while the Mac sleeps.
    var releaseDuringSleep = true
    var showInDock = true
    var showInMenuBar = true
    var menuBar: [MenuBarItem] = [.icon, .temperature(.cpu), .temperature(.group(.gpu)), .fan(0)]
    var menuBarLayout = MenuBarLayout.twoLines
    var menuBarIcon = MenuBarIcon.thermometer
    var menuBarSmallText = false
    /// Fan controls above the temperatures in the menu bar's panel, rather than below.
    var panelFansOnTop = false
    var appearance = AppearanceChoice.dark
    var notifications = true
    /// nil plays the system's default.
    var alertSound: String?
    var notifyAbnormalShutdown = true
    var notifyBatteryService = true
    var notifyDriveProblem = true
    var logging = false
    var logEverySeconds = 10.0
    /// nil means Zefra's own folder.
    var logFolder: String?
    var logSchedule = LogSchedule.daily
    var logDatedName = true
    var mail = MailSettings()
    var showWindowKey: HotKey?
    var toggleBoostKey: HotKey?
    var nextProfileKey: HotKey?
    var detector = DetectorSettings()

    init() {}

    /// Temperatures above, fan speed below. Fills in what that needs, so choosing it shows something.
    mutating func useTwoLines(hasGPU: Bool, firstFan: Int?) {
        menuBarLayout = .twoLines
        menuBarIcon = .thermometer
        if !menuBar.contains(.icon) { menuBar.insert(.icon, at: 0) }
        let temperatures = menuBar.filter { if case .temperature = $0 { true } else { false } }
        if temperatures.isEmpty { menuBar.append(.temperature(.cpu)) }
        if temperatures.count < 2, hasGPU, !menuBar.contains(.temperature(.group(.gpu))) { menuBar.append(.temperature(.group(.gpu))) }
        let hasFan = menuBar.contains { if case .fan = $0 { true } else { false } }
        if !hasFan, let firstFan { menuBar.append(.fan(firstFan)) }
    }

    /// A setting added in a later version takes its default when an older file doesn't have it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T { try c.decodeIfPresent(T.self, forKey: key) ?? fallback }
        unit = try get(.unit, d.unit)
        interval = try get(.interval, d.interval)
        historyMinutes = try get(.historyMinutes, d.historyMinutes)
        failsafe = try get(.failsafe, d.failsafe)
        rampUp = try get(.rampUp, d.rampUp)
        rampDown = try get(.rampDown, d.rampDown)
        releaseDuringSleep = try get(.releaseDuringSleep, d.releaseDuringSleep)
        showInDock = try get(.showInDock, d.showInDock)
        showInMenuBar = try get(.showInMenuBar, d.showInMenuBar)
        menuBar = try get(.menuBar, d.menuBar)
        menuBarLayout = try get(.menuBarLayout, d.menuBarLayout)
        menuBarIcon = try get(.menuBarIcon, d.menuBarIcon)
        menuBarSmallText = try get(.menuBarSmallText, d.menuBarSmallText)
        panelFansOnTop = try get(.panelFansOnTop, d.panelFansOnTop)
        appearance = try get(.appearance, d.appearance)
        notifications = try get(.notifications, d.notifications)
        alertSound = try c.decodeIfPresent(String.self, forKey: .alertSound)
        notifyAbnormalShutdown = try get(.notifyAbnormalShutdown, d.notifyAbnormalShutdown)
        notifyBatteryService = try get(.notifyBatteryService, d.notifyBatteryService)
        notifyDriveProblem = try get(.notifyDriveProblem, d.notifyDriveProblem)
        logging = try get(.logging, d.logging)
        logEverySeconds = try get(.logEverySeconds, d.logEverySeconds)
        logFolder = try c.decodeIfPresent(String.self, forKey: .logFolder)
        logSchedule = try get(.logSchedule, d.logSchedule)
        logDatedName = try get(.logDatedName, d.logDatedName)
        mail = try get(.mail, d.mail)
        showWindowKey = try c.decodeIfPresent(HotKey.self, forKey: .showWindowKey)
        toggleBoostKey = try c.decodeIfPresent(HotKey.self, forKey: .toggleBoostKey)
        nextProfileKey = try c.decodeIfPresent(HotKey.self, forKey: .nextProfileKey)
        detector = try get(.detector, d.detector)
    }
}

/// What's already been said, so an old event isn't announced twice.
struct SeenEvents: Codable, Hashable, Sendable {
    /// Each drive's unsafe-shutdown count when last looked at.
    var unsafeShutdowns: [String: Int] = [:]
    var lastPanicReport: String?
    var batteryNotice: String?
    var driveNotices: [String: String] = [:]
    /// The first-run screen has been answered, one way or the other.
    var onboarded = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unsafeShutdowns = try c.decodeIfPresent([String: Int].self, forKey: .unsafeShutdowns) ?? [:]
        lastPanicReport = try c.decodeIfPresent(String.self, forKey: .lastPanicReport)
        batteryNotice = try c.decodeIfPresent(String.self, forKey: .batteryNotice)
        driveNotices = try c.decodeIfPresent([String: String].self, forKey: .driveNotices) ?? [:]
        onboarded = try c.decodeIfPresent(Bool.self, forKey: .onboarded) ?? false
    }
}

/// Everything the user can change, kept as one JSON file.
struct Config: Codable, Hashable, Sendable {
    var profiles: [Profile]
    var activeProfile: UUID
    var rules: [Rule]
    var settings = Settings()
    var sensorNames: [String: String] = [:]
    var hiddenSensors: Set<String> = []
    var fanNames: [Int: String] = [:]
    var seen = SeenEvents()

    enum CodingKeys: String, CodingKey { case profiles, activeProfile, rules, settings, sensorNames, hiddenSensors, fanNames, seen }

    init(profiles: [Profile], activeProfile: UUID, rules: [Rule]) {
        self.profiles = profiles
        self.activeProfile = activeProfile
        self.rules = rules
    }

    /// A file written by an older version still opens: anything missing takes its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try c.decode([Profile].self, forKey: .profiles)
        activeProfile = try c.decode(UUID.self, forKey: .activeProfile)
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
        sensorNames = try c.decodeIfPresent([String: String].self, forKey: .sensorNames) ?? [:]
        hiddenSensors = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenSensors) ?? []
        fanNames = try c.decodeIfPresent([Int: String].self, forKey: .fanNames) ?? [:]
        seen = try c.decodeIfPresent(SeenEvents.self, forKey: .seen) ?? SeenEvents()
        if profiles.isEmpty { profiles = Self.starter.profiles }
        if !profiles.contains(where: { $0.id == activeProfile }) { activeProfile = profiles[0].id }
    }

    static var starter: Config {
        let automatic = Profile(name: "Automatic", icon: "sparkles", plan: .system)
        let quiet = Profile(name: "Quiet", icon: "moon", plan: .curve(Curve(source: .cpu, points: [
            CurvePoint(temp: 70, percent: 0), CurvePoint(temp: 80, percent: 25), CurvePoint(temp: 88, percent: 60), CurvePoint(temp: 95, percent: 100),
        ])))
        let balanced = Profile(name: "Balanced", icon: "wind", plan: .curve(Curve(source: .cpu, points: [
            CurvePoint(temp: 58, percent: 0), CurvePoint(temp: 68, percent: 25), CurvePoint(temp: 78, percent: 50), CurvePoint(temp: 86, percent: 80), CurvePoint(temp: 92, percent: 100),
        ])))
        let cool = Profile(name: "Cool", icon: "snowflake", plan: .curve(Curve(source: .cpu, points: [
            CurvePoint(temp: 45, percent: 15), CurvePoint(temp: 55, percent: 35), CurvePoint(temp: 65, percent: 60), CurvePoint(temp: 75, percent: 85), CurvePoint(temp: 82, percent: 100),
        ])))
        let full = Profile(name: "Full speed", icon: "tornado", plan: .fixed(percent: 100))
        return Config(profiles: [automatic, quiet, balanced, cool, full], activeProfile: automatic.id, rules: [
            Rule(name: "Very hot, tell me", source: .hottest, onAt: 95, onHold: 10, offAt: 85, offHold: 30, action: .notifyOnly, notifyOn: true, sound: true),
            Rule(name: "Heavy work, fans up", enabled: false, source: .cpu, onAt: 80, onHold: 5, offAt: 62, offHold: 30, action: .setFans(percent: 80, fans: nil)),
            Rule(name: "Hot battery, fans up", enabled: false, source: .group(.battery), onAt: 42, onHold: 30, offAt: 38, offHold: 60, action: .setFans(percent: 60, fans: nil), notifyOn: true),
        ])
    }
}
