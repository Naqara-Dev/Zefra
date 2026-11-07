import Foundation

/// Notices a part that runs hot on its own: hotter than the parts around it, and hotter than it
/// usually is when the rest of the Mac is this warm. It learns that from this Mac, on this Mac.
///
/// It can only say a reading is out of line. Whether that's a short, a failing battery, or something
/// sitting on the charger is more than a temperature can tell, and the wording says so.
enum DetectorSensitivity: String, Codable, CaseIterable, Sendable {
    case relaxed, normal, keen

    var title: String { rawValue.capitalized }

    /// Degrees above what's expected before it counts.
    var margin: Double {
        switch self {
        case .relaxed: 15
        case .normal: 10
        case .keen: 7
        }
    }
}

struct DetectorSettings: Codable, Hashable, Sendable {
    var enabled = true
    var sensitivity = DetectorSensitivity.normal
    /// How long a reading has to stay out of line, so a passing spike says nothing.
    var holdSeconds = 120.0
    var notify = true
    var ignored: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        sensitivity = try c.decodeIfPresent(DetectorSensitivity.self, forKey: .sensitivity) ?? .normal
        holdSeconds = try c.decodeIfPresent(Double.self, forKey: .holdSeconds) ?? 120
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? true
        ignored = try c.decodeIfPresent([String].self, forKey: .ignored) ?? []
    }
}

enum ChargeState: String, Sendable { case battery, adapter, charging }

struct Anomaly: Identifiable, Sendable, Equatable {
    enum Reason: Sendable, Equatable {
        /// Far above what this sensor has been learned to read in these conditions.
        case learned
        /// Far above the other sensors in the same part.
        case siblings
        /// Hotter than this kind of part should get, with the rest of the Mac well below it.
        case limit
    }

    var id: String
    var name: String
    var group: SensorGroup
    var value: Double
    /// What it would be expected to read, or what its siblings read.
    var expected: Double?
    /// The rest of the Mac.
    var rest: Double?
    var reason: Reason
    var since: Date
}

struct AnomalyEvent: Sendable, Equatable {
    var group: SensorGroup
    var started: Bool
}

/// What's been learned: for each sensor, how far it sits above the rest of the Mac, per condition.
struct DetectorBaseline: Codable, Sendable, Equatable {
    struct Stat: Codable, Sendable, Equatable {
        /// Seconds of watching.
        var s: Double
        /// Mean difference from the rest of the Mac.
        var m: Double
        /// Its variance.
        var v: Double
    }

    var sensors: [String: [String: Stat]] = [:]
}

struct AnomalyDetector: Sendable {
    /// Half an hour in a condition before what's been seen there is trusted.
    static let matureAfter: TimeInterval = 1800
    /// How far back learning effectively remembers.
    static let memory: TimeInterval = 6 * 3600
    /// A gap this long is a sleep or a restart: whatever was being timed starts over.
    static let longGap: TimeInterval = 60
    static let clearBand = 3.0
    static let clearAfter: TimeInterval = 60
    /// One warning per part per episode, and not again for an hour.
    static let quietAfterWarning: TimeInterval = 3600

    /// These move in seconds with whatever's running, so a difference from the rest means nothing.
    private static let fast: Set<SensorGroup> = [.cpuPerformance, .cpuEfficiency, .gpu, .soc]

    var baseline = DetectorBaseline()
    private(set) var active: [String: Anomaly] = [:]
    private var outOfLineSince: [String: Date] = [:]
    private var backInLineSince: [String: Date] = [:]
    private var warnedGroups = Set<SensorGroup>()
    private var lastWarning: [SensorGroup: Date] = [:]
    private var lastStep: Date?
    private(set) var watched = 0
    private(set) var ready = 0

    init(baseline: DetectorBaseline = DetectorBaseline()) {
        self.baseline = baseline
    }

    var anomalies: [Anomaly] {
        active.values.sorted { $0.value == $1.value ? $0.id < $1.id : $0.value > $1.value }
    }

    /// Below this nothing is worth a warning, however odd.
    static func floor(_ group: SensorGroup) -> Double {
        switch group {
        case .battery: 40
        case .storage: 55
        default: 50
        }
    }

    /// Hotter than this, with the rest of the Mac well below, is wrong without having to learn anything.
    /// A battery on charge is allowed more than one that isn't.
    static func limit(_ group: SensorGroup, charge: ChargeState) -> Double {
        switch group {
        case .battery: charge == .charging ? 50 : 45
        case .storage: 75
        default: 80
        }
    }

    private static let limitGap = 12.0

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// How hard the chips are working, judged by how far above the case they sit. Comparing them to
    /// the case rather than to a number makes it mean the same on any Mac.
    static func work(chips: Double?, rest: Double) -> Int {
        guard let chips else { return 0 }
        let gap = chips - rest
        return gap < 12 ? 0 : gap < 28 ? 1 : 2
    }

    private static func bucket(_ charge: ChargeState, rest: Double, work: Int, shift: Int = 0) -> String {
        "\(charge.rawValue)/\(Int((rest / 5).rounded(.down)) * 5 + shift * 5)/\(work)"
    }

    /// What's been learned that applies here: this condition, or the ones a step warmer or cooler.
    private func learned(_ id: String, charge: ChargeState, rest: Double, work: Int) -> DetectorBaseline.Stat? {
        guard let stats = baseline.sensors[id] else { return nil }
        for shift in [0, -1, 1] {
            if let stat = stats[Self.bucket(charge, rest: rest, work: work, shift: shift)], stat.s >= Self.matureAfter { return stat }
        }
        return nil
    }

    private mutating func learn(_ id: String, difference: Double, charge: ChargeState, rest: Double, work: Int, seconds: Double) {
        let key = Self.bucket(charge, rest: rest, work: work)
        var stat = baseline.sensors[id]?[key] ?? DetectorBaseline.Stat(s: 0, m: difference, v: 0)
        let weight = seconds / min(stat.s + seconds, Self.memory)
        let delta = difference - stat.m
        stat.m += weight * delta
        stat.v = (1 - weight) * (stat.v + weight * delta * delta)
        stat.s = min(stat.s + seconds, Self.memory)
        baseline.sensors[id, default: [:]][key] = stat
    }

    /// Forgets what a sensor was expected to read, for when its new normal really is normal.
    mutating func relearn(_ id: String) {
        baseline.sensors[id] = nil
        active[id] = nil
        outOfLineSince[id] = nil
        backInLineSince[id] = nil
    }

    mutating func step(now: Date, readings all: [SensorReading], charge: ChargeState, settings: DetectorSettings) -> [AnomalyEvent] {
        // TV keys on Apple silicon are reference values that sit at 94° on a healthy Mac, not parts.
        // Not the same as "doesn't count toward hottest": the battery's gauges don't either, and they matter here.
        let readings = all.filter { !($0.group == .power && $0.key.hasPrefix("TV")) }
        guard settings.enabled else {
            let events = warnedGroups.map { AnomalyEvent(group: $0, started: false) }
            active = [:]
            outOfLineSince = [:]
            backInLineSince = [:]
            warnedGroups = []
            lastStep = nil
            watched = 0
            ready = 0
            return events.sorted { $0.group.rawValue < $1.group.rawValue }
        }
        let seconds = lastStep.map { now.timeIntervalSince($0) } ?? 0
        lastStep = now
        if seconds > Self.longGap {
            outOfLineSince = [:]
            backInLineSince = [:]
        }
        let learning = seconds > 0 && seconds <= Self.longGap

        let slow = readings.filter { !Self.fast.contains($0.group) }
        let chips = readings.filter { Self.fast.contains($0.group) }.map(\.value).max()
        let ignored = Set(settings.ignored)
        let margin = settings.sensitivity.margin
        var seenNow = Set<String>()
        var watchedNow = 0
        var readyNow = 0

        for reading in slow where !ignored.contains(reading.id) {
            seenNow.insert(reading.id)
            watchedNow += 1
            // The rest of the Mac: other parts, so a whole battery heating up can't excuse itself.
            var others = slow.filter { $0.group != reading.group }
            if others.count < 5 { others = slow.filter { $0.id != reading.id } }
            let rest = others.count >= 5 ? Self.median(others.map(\.value)) : nil
            let work = rest.map { Self.work(chips: chips, rest: $0) } ?? 0

            var verdict: (reason: Anomaly.Reason, expected: Double?)?
            var threshold = Double.infinity

            if let rest, reading.value >= Self.limit(reading.group, charge: charge), reading.value - rest >= Self.limitGap {
                verdict = (.limit, nil)
                threshold = min(threshold, Self.limit(reading.group, charge: charge))
            }
            // Only the battery's sensors sit in one place, so only they should all agree.
            if reading.group == .battery {
                let siblings = readings.filter { $0.group == .battery && $0.id != reading.id }.map(\.value)
                if siblings.count >= 2, let middle = Self.median(siblings) {
                    let line = middle + margin
                    threshold = min(threshold, max(line, Self.floor(.battery)))
                    if verdict == nil, reading.value > line, reading.value >= Self.floor(.battery) { verdict = (.siblings, middle) }
                }
            }
            if let rest, let stat = learned(reading.id, charge: charge, rest: rest, work: work) {
                readyNow += 1
                let expected = rest + stat.m
                let line = expected + max(margin, 4 * stat.v.squareRoot())
                threshold = min(threshold, max(line, Self.floor(reading.group)))
                // Busy chips warm what's near them in ways a case temperature can't show, and the
                // question here is a part that's hot while the others aren't.
                if verdict == nil, work < 2, reading.value > line, reading.value >= Self.floor(reading.group) { verdict = (.learned, expected) }
            }

            if let verdict {
                backInLineSince[reading.id] = nil
                let since = outOfLineSince[reading.id] ?? now
                outOfLineSince[reading.id] = since
                if active[reading.id] != nil || now.timeIntervalSince(since) >= settings.holdSeconds {
                    active[reading.id] = Anomaly(id: reading.id, name: reading.name, group: reading.group, value: reading.value, expected: verdict.expected,
                                                 rest: rest, reason: verdict.reason, since: active[reading.id]?.since ?? since)
                }
            } else {
                outOfLineSince[reading.id] = nil
                if var anomaly = active[reading.id] {
                    anomaly.value = reading.value
                    active[reading.id] = anomaly
                    let clear = !threshold.isFinite || reading.value < threshold - Self.clearBand
                    if clear {
                        let since = backInLineSince[reading.id] ?? now
                        backInLineSince[reading.id] = since
                        if now.timeIntervalSince(since) >= Self.clearAfter {
                            active[reading.id] = nil
                            backInLineSince[reading.id] = nil
                        }
                    } else {
                        backInLineSince[reading.id] = nil
                    }
                }
                // Nothing out of line is learned from, or a fault would slowly become its own normal.
                if learning, active[reading.id] == nil, let rest {
                    learn(reading.id, difference: reading.value - rest, charge: charge, rest: rest, work: work, seconds: seconds)
                }
            }
        }

        // A sensor that's gone or now ignored has nothing more to say.
        for id in active.keys where !seenNow.contains(id) { active[id] = nil }
        for id in outOfLineSince.keys where !seenNow.contains(id) { outOfLineSince[id] = nil }
        watched = watchedNow
        ready = readyNow

        var events: [AnomalyEvent] = []
        let groups = Set(active.values.map(\.group))
        for group in groups.sorted(by: { $0.rawValue < $1.rawValue }) where !warnedGroups.contains(group) {
            warnedGroups.insert(group)
            if let last = lastWarning[group], now.timeIntervalSince(last) < Self.quietAfterWarning { continue }
            lastWarning[group] = now
            events.append(AnomalyEvent(group: group, started: true))
        }
        for group in warnedGroups.subtracting(groups).sorted(by: { $0.rawValue < $1.rawValue }) {
            warnedGroups.remove(group)
            events.append(AnomalyEvent(group: group, started: false))
        }
        return events
    }

    /// The plain-language version, used by the alert and by Diagnostics.
    static func describe(_ anomalies: [Anomaly], unit: TemperatureUnit) -> (title: String, detail: String)? {
        guard let worst = anomalies.max(by: { $0.value < $1.value }) else { return nil }
        let title = anomalies.count == 1 ? "\(worst.name) is running hot on its own" : "\(worst.group.title): \(anomalies.count) sensors are running hot on their own"
        var detail = "\(worst.name) is at \(unit.text(worst.value))"
        if let rest = worst.rest { detail += " while the rest of the Mac is around \(unit.text(rest))" }
        switch worst.reason {
        case .learned: if let expected = worst.expected { detail += ". Here it usually reads about \(unit.text(expected))" }
        case .siblings: if let expected = worst.expected { detail += ". The sensors beside it read \(unit.text(expected))" }
        case .limit: break
        }
        detail += ". A temperature can't say why, but a part heating up by itself can mean a fault."
        detail += worst.group == .battery || worst.group == .power
            ? " Unplug the charger. If the case is hot or bulging, shut down and get it checked."
            : " Keep an eye on it, and get it checked if it stays this way."
        return (title, detail)
    }
}
