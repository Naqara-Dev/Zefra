import Foundation

struct FanSpec: Sendable, Hashable {
    var index: Int
    var minRPM: Double
    var maxRPM: Double

    func rpm(forPercent percent: Double) -> Double {
        minRPM + (maxRPM - minRPM) * min(max(percent, 0), 100) / 100
    }

    func percent(forRPM rpm: Double) -> Double {
        guard maxRPM > minRPM else { return 0 }
        return min(max((rpm - minRPM) / (maxRPM - minRPM) * 100, 0), 100)
    }
}

/// Why a fan is doing what it's doing, in words the app can show.
enum FanReason: Equatable, Sendable {
    case system
    case belowCurve(profile: String)
    case fixed(profile: String)
    case curve(profile: String)
    case rule(name: String)
    case manual
    case failsafe
    case sensorMissing

    var text: String {
        switch self {
        case .system: "macOS is in charge"
        case .belowCurve(let profile): "\(profile): cool enough, macOS is in charge"
        case .fixed(let profile): "\(profile): set speed"
        case .curve(let profile): "\(profile): following the curve"
        case .rule(let name): "Rule: \(name)"
        case .manual: "Set by hand"
        case .failsafe: "Too hot: handed back to macOS"
        case .sensorMissing: "Its sensor isn't reporting: handed back to macOS"
        }
    }
}

struct FanDecision: Equatable, Sendable {
    var index: Int
    /// nil means macOS is in charge.
    var percent: Double?
    var rpm: Double?
    var reason: FanReason
}

struct RuleEvent: Equatable, Sendable {
    var ruleID: UUID
    var name: String
    var turnedOn: Bool
    var temp: Double?
}

struct RuleRuntime: Equatable, Sendable {
    var active = false
    var activeSince: Date?
    /// When the temperature reached the other side, while it waits out the hold.
    var pendingSince: Date?
}

struct EngineInput: Sendable {
    var now: Date
    var temps: TempSnapshot
    var power: PowerSource
    var fans: [FanSpec]
    var minuteOfDay: Int
    /// Fans set by hand: these win over profile and rules, but not over the failsafe.
    var manual: [Int: Double] = [:]
}

struct EngineOutput: Equatable, Sendable {
    var decisions: [FanDecision]
    var events: [RuleEvent]
    var activeProfile: UUID
    var failsafe: Bool
}

/// The decisions, and nothing else: no hardware, no clock, no UI. Hand it readings and it says what
/// each fan should do and which rules just changed.
struct Engine: Sendable {
    var config: Config
    private(set) var runtimes: [UUID: RuleRuntime] = [:]
    private var engaged: [Int: Bool] = [:]
    private var lastPercent: [Int: Double] = [:]
    private var lastStep: Date?
    private var failsafeLatched = false

    /// How far it has to cool below the failsafe before plans take over again.
    static let failsafeBand = 10.0

    init(config: Config) { self.config = config }

    func runtime(of rule: Rule) -> RuleRuntime { runtimes[rule.id] ?? RuleRuntime() }

    mutating func step(_ input: EngineInput) -> EngineOutput {
        var events: [RuleEvent] = []
        for rule in config.rules { advance(rule, input, &events) }
        // Rules that no longer exist leave nothing behind.
        let known = Set(config.rules.map(\.id))
        for id in runtimes.keys where !known.contains(id) { runtimes[id] = nil }

        updateFailsafe(input.temps)
        let profile = effectiveProfile()
        let elapsed = lastStep.map { max(input.now.timeIntervalSince($0), 0) }
        lastStep = input.now

        var decisions: [FanDecision] = []
        for fan in input.fans {
            var (percent, reason) = target(for: fan, profile: profile, input: input)
            if failsafeLatched { percent = nil; reason = .failsafe }
            guard let wanted = percent else {
                lastPercent[fan.index] = nil
                decisions.append(FanDecision(index: fan.index, percent: nil, rpm: nil, reason: reason))
                continue
            }
            let eased = ramp(from: lastPercent[fan.index], to: wanted, elapsed: elapsed, manual: input.manual[fan.index] != nil)
            lastPercent[fan.index] = eased
            decisions.append(FanDecision(index: fan.index, percent: eased, rpm: fan.rpm(forPercent: eased), reason: reason))
        }
        return EngineOutput(decisions: decisions, events: events, activeProfile: profile.id, failsafe: failsafeLatched)
    }

    /// The profile in force: the first active rule that switches profile, or the one chosen.
    func effectiveProfile() -> Profile {
        for rule in config.rules where runtimes[rule.id]?.active == true && rule.enabled {
            if case .switchProfile(let id) = rule.action, let profile = config.profiles.first(where: { $0.id == id }) {
                return profile
            }
        }
        return config.profiles.first { $0.id == config.activeProfile } ?? config.profiles.first ?? Profile(name: "Automatic")
    }

    /// What every fan would do at this temperature with every hold already waited out: for "try it".
    func preview(temp: Double, source: TempSource?, input: EngineInput) -> [FanDecision] {
        var copy = self
        copy.lastPercent = [:]
        copy.engaged = [:]
        copy.lastStep = nil
        var readings = input.temps.readings
        // Every sensor the rules look at reads the temperature being tried.
        for index in readings.indices where source == nil || Self.belongs(readings[index], to: source!) { readings[index].value = temp }
        var preview = input
        preview.temps = TempSnapshot(readings: readings)
        var far = input.now
        for rule in copy.config.rules { copy.runtimes[rule.id] = RuleRuntime() }
        // Twice, a long way apart: the first starts the holds, the second finishes them.
        for _ in 0..<2 {
            preview.now = far
            _ = copy.step(preview)
            far = far.addingTimeInterval(100_000)
        }
        preview.now = far
        copy.lastPercent = [:]
        return copy.step(preview).decisions
    }

    private static func belongs(_ reading: SensorReading, to source: TempSource) -> Bool {
        switch source {
        case .hottest: reading.countsTowardHottest
        case .cpu, .cpuAverage: reading.group == .cpuPerformance || reading.group == .cpuEfficiency
        case .group(let group): reading.group == group
        case .sensor(let id): reading.id == id
        }
    }

    private mutating func advance(_ rule: Rule, _ input: EngineInput, _ events: inout [RuleEvent]) {
        var state = runtimes[rule.id] ?? RuleRuntime()
        defer { runtimes[rule.id] = state }
        let temp = input.temps.value(of: rule.source)

        func set(_ on: Bool) {
            state.active = on
            state.activeSince = on ? input.now : nil
            state.pendingSince = nil
            events.append(RuleEvent(ruleID: rule.id, name: rule.name, turnedOn: on, temp: temp))
        }

        guard rule.enabled else {
            // Turned off in the app: nothing to wait out, and nothing to announce.
            state = RuleRuntime()
            return
        }
        let allowed = Self.allowed(rule, power: input.power, minute: input.minuteOfDay)
        guard allowed else {
            if state.active { set(false) } else { state.pendingSince = nil }
            return
        }
        // A sensor that isn't reporting neither starts nor ends a rule.
        guard let temp else {
            state.pendingSince = nil
            return
        }
        let wantsChange = state.active ? rule.isOffSide(temp) : rule.isOnSide(temp)
        guard wantsChange else {
            state.pendingSince = nil
            return
        }
        let since = state.pendingSince ?? input.now
        state.pendingSince = since
        if input.now.timeIntervalSince(since) >= (state.active ? rule.offHold : rule.onHold) { set(!state.active) }
    }

    static func allowed(_ rule: Rule, power: PowerSource, minute: Int) -> Bool {
        switch rule.power {
        case .any: break
        case .adapter: if power != .adapter { return false }
        case .battery: if power != .battery { return false }
        }
        return rule.window?.contains(minute: minute) ?? true
    }

    private mutating func updateFailsafe(_ temps: TempSnapshot) {
        guard let hottest = temps.hottest?.value else { return }
        if hottest >= config.settings.failsafe {
            failsafeLatched = true
        } else if hottest <= config.settings.failsafe - Self.failsafeBand {
            failsafeLatched = false
        }
    }

    private mutating func target(for fan: FanSpec, profile: Profile, input: EngineInput) -> (Double?, FanReason) {
        if let manual = input.manual[fan.index] { return (min(max(manual, 0), 100), .manual) }

        var percent: Double?
        var reason: FanReason
        switch profile.plan(forFan: fan.index) {
        case .system:
            engaged[fan.index] = nil
            reason = .system
        case .fixed(let value):
            engaged[fan.index] = nil
            percent = min(max(value, 0), 100)
            reason = .fixed(profile: profile.name)
        case .curve(let raw):
            let curve = raw.cleaned
            if let temp = input.temps.value(of: curve.source) {
                if curve.releasesBelowFirstPoint {
                    let first = curve.points[0].temp
                    let on = engaged[fan.index] ?? false
                    let staysOn = on ? temp >= first - Curve.releaseBand : temp >= first
                    engaged[fan.index] = staysOn
                    if staysOn {
                        percent = curve.percent(at: temp)
                        reason = .curve(profile: profile.name)
                    } else {
                        reason = .belowCurve(profile: profile.name)
                    }
                } else {
                    percent = curve.percent(at: temp)
                    reason = .curve(profile: profile.name)
                }
            } else {
                engaged[fan.index] = nil
                reason = .sensorMissing
            }
        }
        // Rules only ever add cooling: the fastest thing anyone asks for wins.
        for rule in config.rules where rule.enabled && runtimes[rule.id]?.active == true {
            guard case .setFans(let asked, let fans) = rule.action, fans?.contains(fan.index) ?? true else { continue }
            let wanted = min(max(asked, 0), 100)
            if percent == nil || wanted > percent! {
                percent = wanted
                reason = .rule(name: rule.name)
            }
        }
        return (percent, reason)
    }

    /// Fast up, slow down, so the fans don't surge with every short burst of work.
    private func ramp(from previous: Double?, to wanted: Double, elapsed: TimeInterval?, manual: Bool) -> Double {
        guard let previous, let elapsed, !manual else { return wanted }
        let settings = config.settings
        if wanted > previous { return min(wanted, previous + settings.rampUp * elapsed) }
        return max(wanted, previous - settings.rampDown * elapsed)
    }
}
