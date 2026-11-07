import Foundation

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failures: [String] = []

func check(_ condition: @autoclosure () -> Bool, _ name: String, line: Int = #line) {
    if condition() { passed += 1 } else { failures.append("line \(line): \(name)") }
}

func close(_ a: Double?, _ b: Double, _ tolerance: Double = 0.01) -> Bool { a.map { abs($0 - b) <= tolerance } ?? false }

let start = Date(timeIntervalSince1970: 1_000_000)
let fans = [FanSpec(index: 0, minRPM: 2000, maxRPM: 8000), FanSpec(index: 1, minRPM: 2000, maxRPM: 8000)]

func reading(_ id: String, _ value: Double, _ group: SensorGroup = .cpuPerformance, hottest: Bool = true) -> SensorReading {
    SensorReading(id: id, key: id, name: id, group: group, value: value, countsTowardHottest: hottest)
}

func snapshot(cpu: Double, gpu: Double = 30, battery: Double = 30) -> TempSnapshot {
    TempSnapshot(readings: [reading("c", cpu), reading("g", gpu, .gpu), reading("b", battery, .battery)])
}

func input(_ seconds: Double, cpu: Double, power: PowerSource = .adapter, minute: Int = 600, manual: [Int: Double] = [:]) -> EngineInput {
    EngineInput(now: start.addingTimeInterval(seconds), temps: snapshot(cpu: cpu), power: power, fans: fans, minuteOfDay: minute, manual: manual)
}

func config(rules: [Rule] = [], plan: FanPlan = .system) -> Config {
    let profile = Profile(name: "Test", plan: plan)
    var config = Config(profiles: [profile], activeProfile: profile.id, rules: rules)
    config.settings.rampUp = 1000
    config.settings.rampDown = 1000
    return config
}

func testCurves() {
    let curve = Curve(points: [CurvePoint(temp: 50, percent: 10), CurvePoint(temp: 70, percent: 50), CurvePoint(temp: 90, percent: 100)])
    check(close(curve.percent(at: 40), 10), "flat below the first point")
    check(close(curve.percent(at: 50), 10), "exactly on the first point")
    check(close(curve.percent(at: 60), 30), "halfway along a line")
    check(close(curve.percent(at: 80), 75), "halfway along the second line")
    check(close(curve.percent(at: 120), 100), "flat above the last point")

    let unsorted = Curve(points: [CurvePoint(temp: 90, percent: 100), CurvePoint(temp: 50, percent: 0)])
    check(close(unsorted.percent(at: 70), 50), "points out of order still work")
    check(unsorted.cleaned.points[0].temp == 50, "cleaning sorts")

    let wild = Curve(points: [CurvePoint(temp: -20, percent: -50), CurvePoint(temp: 300, percent: 900)]).cleaned
    check(wild.points[0].temp == 0 && wild.points[0].percent == 0, "low values clamp")
    check(wild.points[1].temp == 120 && wild.points[1].percent == 100, "high values clamp")
    check(Curve(points: []).cleaned.points.count == 2, "no points gets a usable curve")
    check(Curve(points: [CurvePoint(temp: 60, percent: 20)]).cleaned.points.count == 2, "one point gets a second")
    let same = Curve(points: [CurvePoint(temp: 60, percent: 20), CurvePoint(temp: 60, percent: 80), CurvePoint(temp: 80, percent: 90)]).cleaned
    check(same.points.count == 2, "two points on one temperature become one")
    check(same.percent(at: 60).isFinite && same.percent(at: 70).isFinite, "no division by zero")
}

func testSnapshot() {
    let temps = TempSnapshot(readings: [reading("p", 70), reading("e", 60, .cpuEfficiency), reading("g", 80, .gpu),
                                        reading("ref", 100, .power, hottest: false), reading("b", 35, .battery)])
    check(close(temps.value(of: .hottest), 80), "hottest ignores what doesn't count")
    check(temps.hottest?.id == "g", "hottest names the sensor")
    check(close(temps.value(of: .cpu), 70), "cpu takes both kinds of core")
    check(close(temps.value(of: .group(.battery)), 35), "a group")
    check(close(temps.value(of: .sensor("ref")), 100), "one sensor, counted or not")
    check(temps.value(of: .sensor("nope")) == nil, "a missing sensor is nil")
    check(temps.value(of: .group(.memory)) == nil, "an empty group is nil")
    check(TempSnapshot().value(of: .hottest) == nil, "nothing to read")
    let efficiencyOnly = TempSnapshot(readings: [reading("e", 50, .cpuEfficiency)])
    check(close(efficiencyOnly.value(of: .cpu), 50), "cpu with only efficiency cores")
}

func testCatalog() {
    check(Catalog.entry(forSMCKey: "Tp1i")?.group == .cpuPerformance, "Tp is performance")
    check(Catalog.entry(forSMCKey: "Te05")?.group == .cpuEfficiency, "Te is efficiency")
    check(Catalog.entry(forSMCKey: "Tg0K")?.group == .gpu, "Tg is GPU")
    check(Catalog.entry(forSMCKey: "TG0B")?.group == .battery, "TG, capital G, is the gauge")
    check(Catalog.entry(forSMCKey: "TB0T")?.group == .battery, "TB is battery")
    check(Catalog.entry(forSMCKey: "TH0x")?.group == .storage, "TH is the SSD")
    check(Catalog.entry(forSMCKey: "TVMR")?.countsTowardHottest == false, "reference values never count as hottest")
    check(Catalog.entry(forSMCKey: "Ts0P")?.group == .board, "the case sensor isn't the SoC")
    check(Catalog.entry(forSMCKey: "Ts00")?.group == .soc, "Ts is the SoC")
    check(Catalog.entry(forSMCKey: "F0Ac") == nil, "a fan key isn't a temperature")
    check(Catalog.entry(forSMCKey: "TOOLONG") == nil, "not four letters")
    check(Catalog.entry(forHIDName: "PMU tdev1", hasSMC: true) == nil, "tdev is rubbish")
    check(Catalog.entry(forHIDName: "PMU tcal", hasSMC: false) == nil, "tcal isn't a part")
    check(Catalog.entry(forHIDName: "NAND CH0 temp", hasSMC: true)?.group == .storage, "NAND")
    check(Catalog.entry(forHIDName: "gas gauge battery", hasSMC: true)?.group == .battery, "gauge")
    check(Catalog.entry(forHIDName: "PMU tdie1", hasSMC: true) == nil, "dies already come from the SMC")
    check(Catalog.entry(forHIDName: "PMU tdie1", hasSMC: false)?.group == .power, "dies, with no SMC")
    check(Catalog.isPlausible(50) && !Catalog.isPlausible(-9201) && !Catalog.isPlausible(8.3) && !Catalog.isPlausible(.nan) && !Catalog.isPlausible(140), "plausible range")
}

func testRuleHysteresis() {
    let rule = Rule(name: "Up", source: .cpu, onAt: 70, onHold: 5, offAt: 55, offHold: 10, action: .setFans(percent: 80, fans: nil))
    var engine = Engine(config: config(rules: [rule]))

    var out = engine.step(input(0, cpu: 60))
    check(out.decisions[0].percent == nil, "below the start, macOS is in charge")
    check(out.events.isEmpty, "nothing happens")

    out = engine.step(input(1, cpu: 75))
    check(out.decisions[0].percent == nil, "above, but the hold hasn't passed")
    out = engine.step(input(4, cpu: 75))
    check(out.decisions[0].percent == nil, "still holding")
    out = engine.step(input(6, cpu: 75))
    check(close(out.decisions[0].percent, 80), "on after holding 5 s")
    check(out.events == [RuleEvent(ruleID: rule.id, name: "Up", turnedOn: true, temp: 75)], "one event for turning on")
    check(out.decisions[0].reason == .rule(name: "Up"), "says which rule")
    check(close(out.decisions[1].percent, 80), "every fan")
    check(close(out.decisions[0].rpm, 6800), "percent becomes RPM within the fan's range")

    out = engine.step(input(7, cpu: 60))
    check(close(out.decisions[0].percent, 80), "between the two: stays on, that's the whole point")
    out = engine.step(input(100, cpu: 60))
    check(close(out.decisions[0].percent, 80), "stays on for as long as it's between")
    out = engine.step(input(101, cpu: 50))
    check(close(out.decisions[0].percent, 80), "below the end, but the hold hasn't passed")
    out = engine.step(input(105, cpu: 58))
    out = engine.step(input(106, cpu: 50))
    out = engine.step(input(115, cpu: 50))
    check(close(out.decisions[0].percent, 80), "warming up in the middle restarted the hold")
    out = engine.step(input(117, cpu: 50))
    check(out.decisions[0].percent == nil, "off after holding 10 s")
    check(out.events.first?.turnedOn == false, "an event for turning off")
    check(out.decisions[0].reason == .system, "back with macOS")

    // A brief spike does nothing.
    var spike = Engine(config: config(rules: [rule]))
    _ = spike.step(input(0, cpu: 90))
    _ = spike.step(input(3, cpu: 40))
    out = spike.step(input(6, cpu: 90))
    check(out.decisions[0].percent == nil, "a spike that doesn't hold starts nothing")
}

func testRuleZeroHold() {
    let rule = Rule(name: "Now", source: .cpu, onAt: 70, onHold: 0, offAt: 60, offHold: 0, action: .setFans(percent: 50, fans: nil))
    var engine = Engine(config: config(rules: [rule]))
    check(close(engine.step(input(0, cpu: 70)).decisions[0].percent, 50), "no hold: on the moment it arrives, inclusive")
    check(engine.step(input(1, cpu: 60)).decisions[0].percent == nil, "no hold: off the moment it arrives, inclusive")
}

func testFallingRule() {
    let rule = Rule(name: "Cool", source: .cpu, direction: .falls, onAt: 40, onHold: 0, offAt: 50, offHold: 0, action: .notifyOnly)
    var engine = Engine(config: config(rules: [rule]))
    check(engine.step(input(0, cpu: 45)).events.isEmpty, "between: off stays off")
    let on = engine.step(input(1, cpu: 39)).events
    check(on.first?.turnedOn == true, "on when it has cooled")
    check(engine.step(input(2, cpu: 45)).events.isEmpty, "between: on stays on")
    check(engine.step(input(3, cpu: 51)).events.first?.turnedOn == false, "off when it warms up")
    check(rule.hasValidBand, "a falling rule's end is above its start")
    check(!Rule(name: "x", onAt: 40, offAt: 50, action: .notifyOnly).hasValidBand, "a rising rule's end above its start is wrong")
    check(!Rule(name: "x", onAt: 40, offAt: 40, action: .notifyOnly).hasValidBand, "the same temperature would flap")
}

func testRuleConditions() {
    var rule = Rule(name: "Plugged", source: .cpu, onAt: 70, onHold: 0, offAt: 60, offHold: 60, power: .adapter, action: .setFans(percent: 50, fans: nil))
    var engine = Engine(config: config(rules: [rule]))
    check(engine.step(input(0, cpu: 80, power: .battery)).decisions[0].percent == nil, "only plugged in: on battery it doesn't start")
    check(close(engine.step(input(1, cpu: 80, power: .adapter)).decisions[0].percent, 50), "plugged in: it starts")
    let unplug = engine.step(input(2, cpu: 80, power: .battery))
    check(unplug.decisions[0].percent == nil, "unplugged: it ends at once, without the hold")
    check(unplug.events.first?.turnedOn == false, "and says so")

    rule.power = .any
    rule.window = DailyWindow(from: 22 * 60, to: 7 * 60)
    engine = Engine(config: config(rules: [rule]))
    check(engine.step(input(0, cpu: 80, minute: 12 * 60)).decisions[0].percent == nil, "outside the window")
    check(close(engine.step(input(1, cpu: 80, minute: 23 * 60)).decisions[0].percent, 50), "inside a window past midnight, before it")
    check(close(engine.step(input(2, cpu: 80, minute: 3 * 60)).decisions[0].percent, 50), "inside a window past midnight, after it")
    check(DailyWindow(from: 60, to: 120).contains(minute: 60), "start is inside")
    check(!DailyWindow(from: 60, to: 120).contains(minute: 120), "end is outside")
    check(DailyWindow(from: 60, to: 60).contains(minute: 5), "the same time all round means always")

    var off = rule
    off.enabled = false
    off.window = nil
    engine = Engine(config: config(rules: [off]))
    let silent = engine.step(input(0, cpu: 99))
    check(silent.decisions[0].percent == nil && silent.events.isEmpty, "a disabled rule does nothing and says nothing")

    // A rule switched off while running lets go straight away.
    var running = Rule(name: "R", source: .cpu, onAt: 70, onHold: 0, offAt: 60, offHold: 60, action: .setFans(percent: 50, fans: nil))
    engine = Engine(config: config(rules: [running]))
    _ = engine.step(input(0, cpu: 80))
    running.enabled = false
    engine.config.rules = [running]
    check(engine.step(input(1, cpu: 80)).decisions[0].percent == nil, "disabling a running rule stops it")
    engine.config.rules = []
    check(engine.step(input(2, cpu: 80)).decisions[0].percent == nil, "deleting a rule leaves nothing")
}

func testMissingSensor() {
    let rule = Rule(name: "S", source: .sensor("gone"), onAt: 10, onHold: 0, offAt: 5, offHold: 0, action: .setFans(percent: 50, fans: nil))
    var engine = Engine(config: config(rules: [rule], plan: .curve(Curve(source: .sensor("gone"), points: [CurvePoint(temp: 40, percent: 50), CurvePoint(temp: 60, percent: 100)]))))
    let out = engine.step(input(0, cpu: 80))
    check(out.decisions[0].percent == nil, "a missing sensor never drives a fan")
    check(out.decisions[0].reason == .sensorMissing, "and says why")
    check(out.events.isEmpty, "and starts no rule")
}

func testCombining() {
    let low = Rule(name: "Low", source: .cpu, onAt: 60, onHold: 0, offAt: 50, offHold: 0, action: .setFans(percent: 40, fans: nil))
    let high = Rule(name: "High", source: .cpu, onAt: 70, onHold: 0, offAt: 60, offHold: 0, action: .setFans(percent: 90, fans: [1]))
    var engine = Engine(config: config(rules: [low, high]))
    var out = engine.step(input(0, cpu: 75))
    check(close(out.decisions[0].percent, 40), "fan 0 only gets the rule that covers it")
    check(close(out.decisions[1].percent, 90), "fan 1 takes the fastest")
    check(out.decisions[1].reason == .rule(name: "High"), "and names it")
    check(out.events.count == 2, "both rules started")

    engine = Engine(config: config(rules: [low], plan: .fixed(percent: 70)))
    out = engine.step(input(0, cpu: 75))
    check(close(out.decisions[0].percent, 70), "a rule never slows a fan below its plan")
    check(out.decisions[0].reason == .fixed(profile: "Test"), "the plan is still the reason")

    engine = Engine(config: config(rules: [high], plan: .fixed(percent: 70)))
    check(close(engine.step(input(0, cpu: 75)).decisions[1].percent, 90), "a faster rule beats the plan")

    engine = Engine(config: config(rules: [high]))
    out = engine.step(input(0, cpu: 75, manual: [1: 20]))
    check(close(out.decisions[1].percent, 20) && out.decisions[1].reason == .manual, "set by hand wins over rules")
    check(out.decisions[0].percent == nil, "and only for that fan")
}

func testProfileSwitching() {
    let quiet = Profile(name: "Quiet", plan: .system)
    let cool = Profile(name: "Cool", plan: .fixed(percent: 60))
    let rule = Rule(name: "Switch", source: .cpu, onAt: 70, onHold: 0, offAt: 60, offHold: 0, action: .switchProfile(cool.id))
    var settings = Config(profiles: [quiet, cool], activeProfile: quiet.id, rules: [rule])
    settings.settings.rampUp = 1000
    settings.settings.rampDown = 1000
    var engine = Engine(config: settings)
    var out = engine.step(input(0, cpu: 50))
    check(out.activeProfile == quiet.id && out.decisions[0].percent == nil, "starts on the chosen profile")
    out = engine.step(input(1, cpu: 75))
    check(out.activeProfile == cool.id && close(out.decisions[0].percent, 60), "a rule switches profile")
    out = engine.step(input(2, cpu: 50))
    check(out.activeProfile == quiet.id && out.decisions[0].percent == nil, "and switches back when it ends")

    let gone = Rule(name: "Gone", source: .cpu, onAt: 70, onHold: 0, offAt: 60, offHold: 0, action: .switchProfile(UUID()))
    engine.config.rules = [gone]
    out = engine.step(input(3, cpu: 75))
    check(out.activeProfile == quiet.id, "a rule pointing at a deleted profile changes nothing")

    let plans = Profile(name: "Mixed", plan: .fixed(percent: 10), perFan: [1: .fixed(percent: 90)])
    check(plans.plan(forFan: 0) == .fixed(percent: 10) && plans.plan(forFan: 1) == .fixed(percent: 90), "a fan can have its own plan")
}

func testCurvePlan() {
    let curve = Curve(source: .cpu, points: [CurvePoint(temp: 60, percent: 20), CurvePoint(temp: 80, percent: 100)])
    var engine = Engine(config: config(plan: .curve(curve)))
    var out = engine.step(input(0, cpu: 50))
    check(out.decisions[0].percent == nil, "below the curve, macOS is in charge")
    check(out.decisions[0].reason == .belowCurve(profile: "Test"), "and says so")
    check(engine.step(input(1, cpu: 59)).decisions[0].percent == nil, "just below the first point: still off")
    out = engine.step(input(2, cpu: 70))
    check(close(out.decisions[0].percent, 60), "on the curve")
    check(close(engine.step(input(3, cpu: 58)).decisions[0].percent, 20), "cooling just past the first point: stays on")
    check(engine.step(input(4, cpu: 56)).decisions[0].percent == nil, "past the band: lets go")
    check(engine.step(input(5, cpu: 58)).decisions[0].percent == nil, "warming inside the band: doesn't start again")
    check(close(engine.step(input(6, cpu: 60)).decisions[0].percent, 20), "back at the first point: starts again")

    var always = curve
    always.releasesBelowFirstPoint = false
    engine = Engine(config: config(plan: .curve(always)))
    check(close(engine.step(input(0, cpu: 20)).decisions[0].percent, 20), "told not to let go: holds the first point's speed")
}

func testRamp() {
    var settings = config(plan: .fixed(percent: 0))
    settings.settings.rampUp = 10
    settings.settings.rampDown = 2
    var engine = Engine(config: settings)
    check(close(engine.step(input(0, cpu: 50)).decisions[0].percent, 0), "starts where it's asked")
    engine.config.profiles[0].plan = .fixed(percent: 100)
    check(close(engine.step(input(1, cpu: 50)).decisions[0].percent, 10), "speeds up at its rate")
    check(close(engine.step(input(3, cpu: 50)).decisions[0].percent, 30), "keeps going")
    check(close(engine.step(input(100, cpu: 50)).decisions[0].percent, 100), "stops at the target")
    engine.config.profiles[0].plan = .fixed(percent: 0)
    check(close(engine.step(input(101, cpu: 50)).decisions[0].percent, 98), "slows at its own rate")
    check(close(engine.step(input(103, cpu: 50)).decisions[0].percent, 94), "keeps slowing")
    let hand = engine.step(input(104, cpu: 50, manual: [0: 30]))
    check(close(hand.decisions[0].percent, 30), "by hand doesn't ramp")
    check(close(hand.decisions[1].percent, 92), "the other fan still does")
    engine.config.profiles[0].plan = .system
    check(engine.step(input(105, cpu: 50)).decisions[0].percent == nil, "going back to macOS is immediate")
    engine.config.profiles[0].plan = .fixed(percent: 50)
    check(close(engine.step(input(106, cpu: 50)).decisions[0].percent, 50), "starting from macOS doesn't ramp from zero")
    // Time running backwards (the clock changed) never produces a wild value.
    engine.config.profiles[0].plan = .fixed(percent: 70)
    let back = engine.step(input(50, cpu: 50)).decisions[0].percent
    check(close(back, 50), "a clock going back holds still")
}

func testFailsafe() {
    var settings = config(plan: .fixed(percent: 30))
    settings.settings.failsafe = 90
    var engine = Engine(config: settings)
    check(close(engine.step(input(0, cpu: 80)).decisions[0].percent, 30), "below the limit, the plan runs")
    var out = engine.step(input(1, cpu: 90))
    check(out.failsafe && out.decisions[0].percent == nil, "at the limit, macOS takes over")
    check(out.decisions[0].reason == .failsafe, "and says why")
    out = engine.step(input(2, cpu: 85))
    check(out.failsafe, "still latched just under it")
    out = engine.step(input(3, cpu: 80))
    check(!out.failsafe && close(out.decisions[0].percent, 30), "cooled by the band: the plan comes back")
    out = engine.step(input(4, cpu: 95, manual: [0: 10]))
    check(out.decisions[0].percent == nil, "by hand doesn't beat the failsafe")
    let rule = Rule(name: "R", source: .cpu, onAt: 50, onHold: 0, offAt: 40, offHold: 0, action: .setFans(percent: 100, fans: nil))
    engine = Engine(config: { var c = settings; c.rules = [rule]; return c }())
    check(engine.step(input(0, cpu: 95)).decisions[0].percent == nil, "a rule doesn't beat the failsafe")
}

func testPreview() {
    let rule = Rule(name: "R", source: .cpu, onAt: 70, onHold: 500, offAt: 60, offHold: 0, action: .setFans(percent: 90, fans: nil))
    let plan = FanPlan.curve(Curve(source: .cpu, points: [CurvePoint(temp: 50, percent: 20), CurvePoint(temp: 90, percent: 60)]))
    let engine = Engine(config: config(rules: [rule], plan: plan))
    let now = input(0, cpu: 30)
    check(close(engine.preview(temp: 80, source: .cpu, input: now)[0].percent, 90), "try it: waits out holds")
    check(close(engine.preview(temp: 60, source: .cpu, input: now)[0].percent, 30), "try it: the curve below the rule")
    check(engine.preview(temp: 30, source: .cpu, input: now)[0].percent == nil, "try it: cool")
    check(engine.runtime(of: rule).active == false, "trying leaves the real state alone")
}

func testUnits() {
    check(TemperatureUnit.celsius.text(71.6) == "72°", "celsius rounds")
    check(TemperatureUnit.fahrenheit.text(100) == "212°", "fahrenheit")
    check(TemperatureUnit.celsius.text(nil) == "–", "nothing to show")
    check(close(TemperatureUnit.fahrenheit.fromDisplay(212), 100), "fahrenheit back")
    check(close(TemperatureUnit.celsius.fromDisplay(40), 40), "celsius back")
    let fan = FanSpec(index: 0, minRPM: 2317, maxRPM: 7826)
    check(fan.rpm(forPercent: 0) == 2317 && fan.rpm(forPercent: 100) == 7826, "percent ends")
    check(fan.rpm(forPercent: 500) == 7826 && fan.rpm(forPercent: -5) == 2317, "percent clamps")
    check(close(fan.percent(forRPM: fan.rpm(forPercent: 42)), 42), "percent and back")
    check(FanSpec(index: 0, minRPM: 5, maxRPM: 5).percent(forRPM: 5) == 0, "no range, no division by zero")
}

func testConfigFile() throws {
    let starter = Config.starter
    check(starter.rules.allSatisfy(\.hasValidBand), "starter rules are all valid")
    check(starter.rules.filter { if case .setFans = $0.action { $0.enabled } else { false } }.isEmpty, "nothing touches the fans until asked")
    check(starter.profiles.first { $0.id == starter.activeProfile }?.plan == .system, "starts by leaving the fans to macOS")
    let data = try JSONEncoder().encode(starter)
    let again = try JSONDecoder().decode(Config.self, from: data)
    check(again == starter, "survives a round trip")

    let old = #"{"profiles":[{"id":"7F2D6C5E-9D0B-4C4E-8F3A-1B2C3D4E5F60","name":"Mine","icon":"fan","plan":{"system":{}},"perFan":{}}],"activeProfile":"00000000-0000-0000-0000-000000000000"}"#
    let decoded = try JSONDecoder().decode(Config.self, from: Data(old.utf8))
    check(decoded.profiles[0].name == "Mine", "a file with missing parts opens")
    check(decoded.activeProfile == decoded.profiles[0].id, "a profile that's gone falls back to one that exists")
    check(decoded.settings.failsafe == 98 && decoded.rules.isEmpty, "missing parts take defaults")
    let partial = try JSONDecoder().decode(Settings.self, from: Data(#"{"failsafe":90}"#.utf8))
    check(partial.failsafe == 90 && partial.rampUp == 25 && partial.unit == .celsius, "settings with missing parts keep what's there")
    let empty = #"{"profiles":[],"activeProfile":"00000000-0000-0000-0000-000000000000"}"#
    let opened = try JSONDecoder().decode(Config.self, from: Data(empty.utf8))
    check(!opened.profiles.isEmpty, "never without a profile")
}

func testDiagnostics() {
    func base() -> Diagnostics.Input {
        Diagnostics.Input(readsSensors: true,
                          sensors: [SensorStats(id: "a", name: "A", group: .cpuPerformance, value: 50, low: 40, high: 60, watched: 600)],
                          fans: [FanStatus(spec: FanSpec(index: 0, minRPM: 2000, maxRPM: 8000), name: "Fan 1", rpm: 0, target: nil)],
                          hottest: 50,
                          battery: BatteryInfo(percent: 80, cycles: 200, designCycles: 1000, designCapacity: 6000, maxCapacity: 5700, temperature: 30, volts: 12, amps: 0, isCharging: false, onAdapter: true),
                          thermal: .nominal, helperInstalled: true, helperCurrent: true, lastShutdown: .clean)
    }
    func worst(_ input: Diagnostics.Input, _ area: String) -> Finding.Level? {
        Diagnostics.run(input).filter { $0.area == area }.map(\.level).max()
    }
    check(Diagnostics.run(base()).allSatisfy { $0.level == .ok }, "a healthy Mac is all clear; a stopped fan while cool is normal")

    var i = base(); i.readsSensors = false
    check(worst(i, "Sensors") == .problem, "no sensors")
    i = base(); i.fans[0].rpm = 0; i.hottest = 95
    check(worst(i, "Fans") == .problem, "stopped while hot")
    i = base(); i.fans[0].rpm = 2000; i.fans[0].target = 7000
    check(worst(i, "Fans") == .warning, "not reaching its speed")
    i = base(); i.fans[0].rpm = 6900; i.fans[0].target = 7000
    check(worst(i, "Fans") == .ok, "close enough to its speed")
    i = base(); i.fans[0].spec.maxRPM = 100
    check(worst(i, "Fans") == .warning, "an odd range")
    i = base(); i.fans = []
    check(worst(i, "Fans") == .note, "no fans is a note, not a fault")
    i = base(); i.battery?.maxCapacity = 4600
    check(worst(i, "Battery") == .warning, "worn battery")
    i = base(); i.battery?.maxCapacity = 3000
    check(worst(i, "Battery") == .problem, "very worn battery")
    i = base(); i.battery?.cycles = 1200
    check(worst(i, "Battery") == .warning, "past its cycles")
    i = base(); i.battery?.temperature = 50
    check(worst(i, "Battery") == .warning, "hot battery")
    i = base(); i.battery = nil
    check(worst(i, "Battery") == nil, "a desktop has no battery findings")
    i = base(); i.thermal = .serious
    check(worst(i, "Thermal") == .warning, "thermal pressure")
    i = base(); i.thermal = .critical
    check(worst(i, "Thermal") == .problem, "critical pressure")
    i = base(); i.helperInstalled = false
    check(worst(i, "Fan control") == .note, "no helper is only a note")
    i = base(); i.helperCurrent = false
    check(worst(i, "Fan control") == .warning, "a helper not answering")
    i = base(); i.sensors = [SensorStats(id: "m", name: "M", group: .cpuPerformance, value: 70, low: 40, high: 90, watched: 600),
                             SensorStats(id: "s", name: "Stuck", group: .cpuPerformance, value: 70, low: 70, high: 70, watched: 600)]
    check(Diagnostics.run(i).contains { $0.title.contains("not moving") }, "one stuck among moving")
    i = base(); i.sensors = [SensorStats(id: "s", name: "Stuck", group: .cpuPerformance, value: 70, low: 70, high: 70, watched: 10)]
    check(!Diagnostics.run(i).contains { $0.title.contains("not moving") }, "too soon to say")
    let sorted = Diagnostics.run({ var x = base(); x.thermal = .critical; return x }())
    check(sorted.first?.level == .problem, "worst first")
    let report = Diagnostics.report(sorted, model: "Mac", system: "26", date: start)
    check(report.contains("PROBLEM") && report.contains("macOS 26"), "the report reads")
    let info = BatteryInfo(percent: 1, cycles: 1, designCycles: 1, designCapacity: 0, maxCapacity: 10, temperature: nil, volts: 12, amps: -2, isCharging: false, onAdapter: false)
    check(info.health == 0 && info.watts == -24, "no design capacity, no division by zero")
}

final class FakeFans: FanHardware {
    var fanCount = 2
    var rpm: [Int: Double] = [:]
    var released: [Int] = []
    var temp: Double? = 50
    var fail = false
    func range(of fan: Int) -> (min: Double, max: Double)? { fan < fanCount ? (2000, 8000) : nil }
    func force(_ fan: Int, rpm value: Double) throws {
        if fail { throw NSError(domain: "x", code: 1) }
        rpm[fan] = value
    }
    func release(_ fan: Int) throws { rpm[fan] = nil; released.append(fan) }
    func hottest() -> Double? { temp }
}

func testGuard() {
    let fake = FakeFans()
    let guardian = FanGuard(hardware: fake)
    check(guardian.setFan(0, rpm: 5000, now: start) == nil && fake.rpm[0] == 5000, "a fair speed goes through")
    _ = guardian.setFan(0, rpm: 99999, now: start)
    check(fake.rpm[0] == 8000, "too fast is clamped to the fan's maximum")
    _ = guardian.setFan(0, rpm: 1, now: start)
    check(fake.rpm[0] == 2000, "too slow is clamped to its minimum")
    _ = guardian.setFan(0, rpm: -500, now: start)
    check(fake.rpm[0] == 2000, "negative is clamped")
    check(guardian.setFan(0, rpm: .nan, now: start) != nil, "NaN is refused")
    check(guardian.setFan(0, rpm: .infinity, now: start) != nil, "infinity is refused")
    check(guardian.setFan(9, rpm: 3000, now: start) != nil, "no such fan")
    check(guardian.setFan(-1, rpm: 3000, now: start) != nil, "negative fan")
    check(guardian.setAuto(9) != nil, "no such fan to release")
    fake.fail = true
    check(guardian.setFan(1, rpm: 3000, now: start) != nil, "a hardware failure is reported")
    check(!guardian.forced.contains(1), "and it isn't counted as forced")
    fake.fail = false

    // Silence.
    guardian.heartbeat(failsafe: 98, now: start)
    check(!guardian.tick(now: start.addingTimeInterval(10)), "a recent heartbeat is fine")
    check(fake.rpm[0] != nil, "fan still forced")
    check(guardian.tick(now: start.addingTimeInterval(16)), "silence takes the fans back")
    check(fake.rpm.isEmpty && guardian.forced.isEmpty, "all of them")
    check(!guardian.tick(now: start.addingTimeInterval(17)), "nothing left to take")

    // The app leaving.
    _ = guardian.setFan(0, rpm: 3000, now: start)
    guardian.clientLeft()
    check(fake.rpm.isEmpty, "the app leaving takes the fans back")
    fake.released = []
    guardian.releaseAll()
    check(fake.released == [0, 1], "release covers every fan, even ones it doesn't know it forced")

    // Heat, in-process.
    let t = start.addingTimeInterval(100)
    _ = guardian.setFan(0, rpm: 3000, now: t)
    guardian.heartbeat(failsafe: 90, now: t)
    fake.temp = 95
    check(!guardian.tick(now: t), "one hot reading could be a spike")
    fake.temp = 50
    check(!guardian.tick(now: t), "and it cooled")
    fake.temp = 95
    check(!guardian.tick(now: t) && !guardian.tick(now: t), "two more isn't three in a row")
    check(guardian.tick(now: t), "three in a row takes the fans back")
    check(fake.rpm.isEmpty, "fans released")
    check(guardian.setFan(0, rpm: 3000, now: t.addingTimeInterval(30)) != nil, "locked out for a while")
    check(fake.rpm.isEmpty, "the refusal does nothing")
    fake.temp = 50
    check(guardian.setFan(0, rpm: 3000, now: t.addingTimeInterval(61)) == nil, "the lockout ends")

    // The limit it's given is bounded.
    guardian.heartbeat(failsafe: 500, now: t.addingTimeInterval(61))
    fake.temp = 106
    _ = guardian.tick(now: t.addingTimeInterval(61))
    _ = guardian.tick(now: t.addingTimeInterval(61))
    check(guardian.tick(now: t.addingTimeInterval(61)), "asking for a silly limit doesn't lift the real one")
}

func testSMCValues() {
    check(SMC.decode(type: "ui8 ", [2]) == 2, "ui8: the number of fans")
    check(SMC.decode(type: "flag", [1]) == 1, "flag")
    check(SMC.decode(type: "ui16", [0x01, 0x00]) == 256, "ui16 is big-endian")
    check(SMC.decode(type: "ui32", [0, 0, 12, 175]) == 3247, "ui32: the number of keys")
    check(close(SMC.decode(type: "flt ", [0, 144, 244, 69]), 7826), "flt is little-endian: a fan's maximum")
    check(SMC.decode(type: "fpe2", [0x1F, 0x40]) == 2000, "fpe2: an Intel fan's speed")
    check(close(SMC.decode(type: "sp78", [0x2A, 0x80]), 42.5), "sp78: an Intel temperature")
    check(close(SMC.decode(type: "sp78", [0xFF, 0x00]), -1), "sp78 is signed")
    check(SMC.decode(type: "ch8*", [65]) == nil, "a type that isn't a number")
    check(SMC.decode(type: "flt ", [0]) == nil, "too few bytes")
    check(SMC.decode(type: "ui32", [1]) == nil, "too few bytes for ui32")
    for (type, value) in [("flt ", 3456.0), ("fpe2", 2000.0), ("ui8 ", 1.0), ("ui16", 512.0)] {
        check(close(SMC.encode(value, type: type).flatMap { SMC.decode(type: type, $0) }, value), "\(type) survives writing and reading back")
    }
    check(SMC.encode(1, type: "ch8*") == nil, "refuses a type it can't write")
    check(SMC.encode(99999999, type: "fpe2") != nil && SMC.encode(-5, type: "ui16") == [0, 0], "out of range clamps, never crashes")
    check(SMC.encode(.infinity, type: "ui8 ") == [255], "infinity clamps")
    check(SMC.code("F0Md") == 0x46304D64 && SMC.name(0x46304D64) == "F0Md", "key names both ways")
}

func testSensorNames() {
    let m4Pro = Catalog.Chip(brand: "Apple M4 Pro")
    check(m4Pro.tag == "m4Pro", "brand string to tag")
    check(Catalog.Chip(brand: "Apple M1").tag == "m1", "plain chip")
    check(Catalog.Chip(brand: "Apple M3 Ultra").tag == "m3Ultra", "ultra")
    check(Catalog.Chip(brand: "Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz").isIntel, "intel")
    check(!m4Pro.isIntel, "apple silicon")
    check(m4Pro.matches("m4*") && m4Pro.matches("m4Pro") && m4Pro.matches("all") && m4Pro.matches("apple"), "what covers an M4 Pro")
    check(!m4Pro.matches("m3*") && !m4Pro.matches("m4") && !m4Pro.matches("m4Max"), "what doesn't")
    check(!Catalog.Chip(tag: "m10").matches("m1*"), "a generation tag isn't a prefix trap")
    check(!Catalog.Chip(tag: "intel").matches("apple"), "intel isn't apple")
    check(Catalog.entry(forSMCKey: "Te05", chip: m4Pro)?.name == "CPU efficiency core 1", "a name for this chip")
    check(Catalog.entry(forSMCKey: "TB1T", chip: m4Pro)?.name == "Battery 1", "a name for every Apple chip")
    check(Catalog.entry(forSMCKey: "TH0x", chip: m4Pro)?.name == "NAND", "the NAND")
    check(Catalog.entry(forSMCKey: "Te05", chip: m4Pro)?.group == .cpuEfficiency, "names don't change the group")
    check(Catalog.entry(forSMCKey: "TVMR", chip: m4Pro)?.countsTowardHottest == false, "a name never makes a reference value count")
    check(Catalog.entry(forSMCKey: "TZZZ", chip: m4Pro)?.name == "Board TZZZ", "no name: the family's, with the raw key")
    let intel = Catalog.Chip(tag: "intel")
    check(Catalog.entry(forSMCKey: "TG0P", chip: intel)?.group == .gpu, "TG is the GPU on Intel")
    check(Catalog.entry(forSMCKey: "TG0B", chip: m4Pro)?.group == .battery, "and the battery gauge on Apple silicon")
    check(Catalog.entry(forSMCKey: "TC0P", chip: intel)?.name == "CPU proximity", "an Intel name")
    check(Catalog.entry(forSMCKey: "TA1P", chip: intel)?.name == "Ambient 1", "a pattern fills in its digit")
    check(Catalog.knownName(forSMCKey: "TAxP", chip: intel) == nil, "a pattern's % only takes a digit")
    check(KnownSensors.rows.allSatisfy { $0.key.count == 4 && $0.key.hasPrefix("T") }, "the table holds only temperature keys")
}

func testAverage() {
    let temps = TempSnapshot(readings: [reading("p", 80), reading("q", 60), reading("e", 40, .cpuEfficiency), reading("g", 99, .gpu)])
    check(close(temps.value(of: .cpuAverage), 60), "average of every CPU sensor")
    check(close(temps.value(of: .cpu), 80), "peak stays the peak")
    check(TempSnapshot(readings: [reading("g", 50, .gpu)]).value(of: .cpuAverage) == nil, "no CPU sensors, no average")
    let rule = Rule(name: "A", source: .cpuAverage, onAt: 70, onHold: 0, offAt: 60, offHold: 0, action: .setFans(percent: 50, fans: nil))
    var engine = Engine(config: config(rules: [rule]))
    let few = TempSnapshot(readings: [reading("p", 90), reading("q", 40)])
    let inputAt = EngineInput(now: start, temps: few, power: .adapter, fans: fans, minuteOfDay: 0)
    check(engine.step(inputAt).decisions[0].percent == nil, "one hot core doesn't lift an average rule")
}

func testDrives() {
    var log = [UInt8](repeating: 0, count: 512)
    log[1] = 0x37; log[2] = 0x01 // 311 K
    log[3] = 100; log[4] = 10; log[5] = 1
    log[128] = 0xD6; log[129] = 0x05 // 1494 hours
    log[144] = 9
    let drive = DriveHealth(name: "SSD", isInternal: true, log: log)!
    check(close(drive.temperature, 37.85), "Kelvin to Celsius, little-endian")
    check(drive.powerOnHours == 1494 && drive.unsafeShutdowns == 9 && drive.percentUsed == 1, "fields sit where NVMe puts them")
    check(DriveHealth(name: "x", isInternal: true, log: [1, 2, 3]) == nil, "too short")
    var cold = log; cold[1] = 0; cold[2] = 0
    check(DriveHealth(name: "x", isInternal: true, log: cold)?.temperature == nil, "no temperature reported")
    var huge = log
    for i in 128..<144 { huge[i] = 0xFF }
    check((DriveHealth(name: "x", isInternal: true, log: huge)?.powerOnHours ?? -1) > 0, "a huge counter doesn't overflow")

    func judged(_ count: Int, seen: [String: Int], panic: String? = nil, last: String? = nil) -> LastShutdown {
        var d = drive; d.unsafeShutdowns = count
        var s = SeenEvents(); s.unsafeShutdowns = seen; s.lastPanicReport = last
        return LastShutdown.judge(drives: [d], newestPanic: panic, seen: s)
    }
    check(judged(9, seen: [:]) == .unknown, "first look: nothing to compare with")
    check(judged(9, seen: ["SSD": 9]) == .clean, "same count: clean")
    check(judged(11, seen: ["SSD": 9]) == .unsafe(count: 2), "count went up")
    check(judged(9, seen: ["SSD": 9], panic: "p1.panic") == .panic(report: "p1.panic"), "a new panic report")
    check(judged(9, seen: ["SSD": 9], panic: "p1.panic", last: "p1.panic") == .clean, "an old panic report is old news")
    var external = drive; external.isInternal = false; external.unsafeShutdowns = 50
    var s = SeenEvents(); s.unsafeShutdowns = ["SSD": 1]
    check(LastShutdown.judge(drives: [external], newestPanic: nil, seen: s) == .unknown, "unplugging an external drive isn't a Mac shutting down badly")

    func level(_ d: DriveHealth) -> Finding.Level? {
        let i = Diagnostics.Input(readsSensors: true, sensors: [], fans: [], hottest: nil, battery: nil, thermal: .nominal, helperInstalled: true, helperCurrent: true, drives: [d])
        return Diagnostics.run(i).filter { $0.area == "Drives" }.map(\.level).max()
    }
    check(level(drive) == .ok, "a healthy drive")
    var bad = drive; bad.criticalWarning = 1
    check(level(bad) == .problem, "a critical warning")
    bad = drive; bad.availableSpare = 5
    check(level(bad) == .problem, "out of spare")
    bad = drive; bad.mediaErrors = 3
    check(level(bad) == .warning, "media errors")
    bad = drive; bad.percentUsed = 95
    check(level(bad) == .warning, "worn out")

    func one(_ change: (inout Diagnostics.Input) -> Void) -> [Finding] {
        var i = Diagnostics.Input(readsSensors: true, sensors: [SensorStats(id: "a", name: "A", group: .gpu, value: 50, low: 40, high: 60, watched: 9)],
                                  fans: [FanStatus(spec: fans[0], name: "Fan 1", rpm: 0, target: nil)], hottest: 50,
                                  battery: BatteryInfo(percent: 80, cycles: 2, designCycles: 1000, designCapacity: 100, maxCapacity: 95, temperature: 30, volts: 12, amps: 0, isCharging: false, onAdapter: true),
                                  thermal: .nominal, helperInstalled: true, helperCurrent: true)
        change(&i)
        return Diagnostics.run(i)
    }
    check(one { $0.lastShutdown = .unsafe(count: 1) }.contains { $0.area == "Last shutdown" && $0.level == .warning }, "unsafe shutdown is a warning")
    check(one { $0.lastShutdown = .panic(report: "x") }.contains { $0.area == "Last shutdown" && $0.level == .problem }, "a panic is a problem")
    check(one { $0.lastShutdown = .clean }.contains { $0.area == "Last shutdown" && $0.level == .ok }, "clean")
    check(one { $0.flaggedFans = [0] }.contains { $0.title.contains("Fan 1") && $0.level == .problem }, "a fan the Mac flags")
    check(one { $0.silentSensors = ["A"] }.contains { $0.title.contains("stopped reporting") }, "a sensor that went quiet")
    check(one { $0.battery?.permanentFailure = true }.contains { $0.title.contains("permanent") && $0.level == .problem }, "a battery fault")
    check(one { $0.battery?.systemCondition = "Service Recommended" }.contains { $0.title.contains("Service Recommended") }, "macOS's word on the battery")
    check(!one { $0.battery?.systemCondition = "Normal" }.contains { $0.title.contains("macOS says") }, "Normal isn't news")
}

func testLogFile() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Jakarta")!
    let at = Date(timeIntervalSince1970: 1_794_000_000)
    let next = at.addingTimeInterval(86400)
    let day = LogFile.day(at, calendar: calendar)
    check(day.count == 10 && day.hasPrefix("2026-"), "a date for a file name")
    check(LogFile.name(schedule: .daily, dated: false, launch: at, now: next, calendar: calendar) != LogFile.name(schedule: .daily, dated: false, launch: at, now: at, calendar: calendar), "daily changes with the day, dated or not")
    check(LogFile.name(schedule: .append, dated: false, launch: at, now: next, calendar: calendar) == "Zefra Log.csv", "one file keeps its name")
    check(LogFile.name(schedule: .eachLaunch, dated: false, launch: at, now: next, calendar: calendar) == "Zefra Log.csv", "each launch without a date replaces the file")
    check(LogFile.name(schedule: .eachLaunch, dated: true, launch: at, now: next, calendar: calendar) != LogFile.name(schedule: .eachLaunch, dated: true, launch: at.addingTimeInterval(5), now: next, calendar: calendar), "two launches, two files")
    check(LogFile.header(fans: [0, 1]).contains("fan1_rpm,watts"), "a header per fan")
    check(LogFile.row(time: "t", values: [50, nil], rules: [], alert: false) == "t,50.0,,\"\"\n", "a plain row")
    check(LogFile.row(time: "t", values: [], rules: [], alert: true).hasPrefix("ALERT: "), "an alert stands out")
    check(LogFile.row(time: "t", values: [], rules: ["a, b", "c\"d"], alert: false).contains("\"a, b; c\"\"d\""), "names can't break the columns")
}

func testMail() {
    check(Mail.address("me@example.com") == "me@example.com", "a good address")
    check(Mail.address(" me@example.com ") == "me@example.com", "trimmed")
    for bad in ["nope", "a@b@c", "@b", "a@", "a b@c", "a@c\r\nBcc: x@y", "<a@b>", "a,b@c"] {
        check(Mail.address(bad) == nil || !Mail.address(bad)!.contains("Bcc") || bad.contains("\r"), "address: \(bad)")
    }
    check(Mail.address("a b@c") == nil && Mail.address("<a@b>") == nil && Mail.address("a@b@c") == nil, "refuses what isn't an address")
    let injected = Mail.message(from: "a@b", to: "c@d", subject: "Hot\r\nBcc: evil@x", body: "hi", date: start)
    check(!injected.contains("\r\nBcc:"), "a line break can't add a header")
    check(injected.contains("Subject: HotBcc: evil@x"), "the text stays, flattened")
    check(Mail.message(from: "a@b", to: "c@d", subject: "s", body: ".\nx", date: start).contains("\r\n..\r\nx"), "a lone dot can't end the message")
    check(Mail.encodedHeader("Panas 85°").hasPrefix("=?UTF-8?B?"), "non-ASCII subjects are encoded")
    check(Mail.encodedHeader("plain") == "plain", "ASCII stays")
    var settings = MailSettings()
    check(Mail.curlConfig(settings, password: nil) == nil, "incomplete settings send nothing")
    settings.host = "smtp.example.com"; settings.from = "a@b.c"; settings.to = "d@e.f"; settings.username = "me"
    let config = Mail.curlConfig(settings, password: "p\"w\\x\ny")!
    check(config.contains("url = \"smtp://smtp.example.com:587\""), "starttls url")
    check(config.contains("ssl-reqd"), "never in the clear")
    check(config.contains(#"user = "me:p\"w\\xy""#), "a password can't break out of its quotes")
    settings.security = .tls; settings.port = 465
    check(Mail.curlConfig(settings, password: "x")!.contains("smtps://smtp.example.com:465"), "tls url")
    settings.usesPassword = false
    check(!Mail.curlConfig(settings, password: "x")!.contains("user ="), "no password, no login")
    settings.host = "evil.com/../x"
    check(Mail.curlConfig(settings, password: nil) == nil, "a host can't be a path")
    settings.host = "ok.com"; settings.port = 70000
    check(Mail.curlConfig(settings, password: nil) == nil, "a port has to be a port")
    check(MailSecurity.startTLS.defaultPort == 587 && MailSecurity.tls.defaultPort == 465, "default ports")
}

func testOlderFiles() throws {
    let old = #"{"id":"7F2D6C5E-9D0B-4C4E-8F3A-1B2C3D4E5F60","name":"R","onAt":70,"offAt":60,"action":{"notifyOnly":{}}}"#
    let rule = try JSONDecoder().decode(Rule.self, from: Data(old.utf8))
    check(rule.enabled && !rule.email && rule.onHold == 5 && rule.offHold == 30 && rule.power == .any, "a rule from before these options opens with defaults")
    let settings = try JSONDecoder().decode(Settings.self, from: Data(#"{"interval":7}"#.utf8))
    check(settings.interval == 7 && settings.logSchedule == .daily && settings.mail.port == 587 && settings.showWindowKey == nil, "settings from before these options")
    let again = try JSONDecoder().decode(Settings.self, from: try JSONEncoder().encode(settings))
    check(again == settings, "settings survive a round trip")
    let source = try JSONDecoder().decode(TempSource.self, from: try JSONEncoder().encode(TempSource.cpuAverage))
    check(source == .cpuAverage, "a new source survives a round trip")
}

func testOnboardingFlag() throws {
    let old = try JSONDecoder().decode(SeenEvents.self, from: Data(#"{"batteryNotice":"Normal"}"#.utf8))
    check(!old.onboarded, "a settings file from before onboarding hasn't answered it")
    var seen = SeenEvents(); seen.onboarded = true
    let again = try JSONDecoder().decode(SeenEvents.self, from: JSONEncoder().encode(seen))
    check(again.onboarded, "the answer is remembered")
}

private func parts(battery: Double = 36, board: Double = 40, storage: Double = 40, cpu: Double = 45, gauge: Double? = nil) -> [SensorReading] {
    func r(_ id: String, _ group: SensorGroup, _ value: Double) -> SensorReading {
        SensorReading(id: id, key: id, name: id, group: group, value: value, countsTowardHottest: true)
    }
    var list = [r("gauge", .battery, gauge ?? battery), r("bat1", .battery, battery), r("bat2", .battery, battery), r("bat3", .battery, battery)]
    list += (0..<6).map { r("board\($0)", .board, board + Double($0)) }
    list += [r("ssd", .storage, storage), r("nand", .storage, storage), r("wifi", .wireless, board), r("charger", .power, board)]
    list += [r("core", .cpuPerformance, cpu), r("gpu", .gpu, cpu)]
    return list
}

/// Runs readings through the detector at one a second for this long.
@discardableResult
private func run(_ detector: inout AnomalyDetector, from start: Date, seconds: Int, every: Int = 5, charge: ChargeState = .battery, settings: DetectorSettings = DetectorSettings(),
                 readings: () -> [SensorReading]) -> [AnomalyEvent] {
    var events: [AnomalyEvent] = []
    for second in stride(from: 0, to: seconds, by: every) {
        events += detector.step(now: start.addingTimeInterval(Double(second)), readings: readings(), charge: charge, settings: settings)
    }
    return events
}

func testDetector() throws {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    var d = AnomalyDetector()

    // The case that started this: one battery sensor hot, everything else cool.
    var events = run(&d, from: t0, seconds: 110) { parts(gauge: 60) }
    check(events.isEmpty && d.anomalies.isEmpty, "not before the hold is up")
    events = run(&d, from: t0.addingTimeInterval(110), seconds: 20) { parts(gauge: 60) }
    check(events == [AnomalyEvent(group: .battery, started: true)], "a hot battery sensor warns once")
    check(d.anomalies.map(\.id) == ["gauge"], "and names that sensor, not its neighbours")
    check(d.anomalies.first?.rest != nil, "and says what the rest of the Mac is at")

    let text = AnomalyDetector.describe(d.anomalies, unit: .celsius)
    check(text?.title == "gauge is running hot on its own", "the warning says what")
    check(text?.detail.contains("Unplug the charger") == true, "and what to do")
    check(text?.detail.lowercased().contains("short") == false, "it doesn't claim to have found a short")

    // Staying hot doesn't repeat it.
    events = run(&d, from: t0.addingTimeInterval(130), seconds: 600) { parts(gauge: 60) }
    check(events.isEmpty, "no second warning while it stays hot")

    // Cooling takes time to count, so a sensor hovering at the line can't flap.
    events = run(&d, from: t0.addingTimeInterval(730), seconds: 50) { parts() }
    check(events.isEmpty && !d.anomalies.isEmpty, "not over the moment it cools")
    events = run(&d, from: t0.addingTimeInterval(780), seconds: 20) { parts() }
    check(events == [AnomalyEvent(group: .battery, started: false)], "over once it has stayed cool")

    // Back again soon: visible, but not another notification.
    events = run(&d, from: t0.addingTimeInterval(800), seconds: 130) { parts(gauge: 60) }
    check(events.isEmpty && !d.anomalies.isEmpty, "shown again, but quiet within the hour")

    // A passing spike.
    var spike = AnomalyDetector()
    run(&spike, from: t0, seconds: 60) { parts(gauge: 60) }
    run(&spike, from: t0.addingTimeInterval(60), seconds: 300) { parts() }
    check(spike.anomalies.isEmpty, "a spike shorter than the hold says nothing")

    // Things that are hot for good reason.
    var busy = AnomalyDetector()
    events = run(&busy, from: t0, seconds: 600) { parts(cpu: 95) }
    check(events.isEmpty && busy.anomalies.isEmpty, "a hot CPU isn't 'on its own': chips do this")
    var warm = AnomalyDetector()
    events = run(&warm, from: t0, seconds: 600) { parts(battery: 46, board: 44, storage: 44, cpu: 60) }
    check(events.isEmpty, "a warm battery in a warm Mac is fine")
    var sun = AnomalyDetector()
    events = run(&sun, from: t0, seconds: 600) { parts(battery: 52, board: 50, storage: 50, cpu: 65) }
    check(events.isEmpty, "a Mac left in the sun is hot all over, not out of line")
    var cold = AnomalyDetector()
    events = run(&cold, from: t0, seconds: 600) { parts(battery: 22, board: 22, storage: 22, cpu: 25, gauge: 36) }
    check(events.isEmpty, "out of line but not hot isn't worth a warning")

    // Whole battery, nothing else: on battery that's wrong, on charge it isn't yet.
    var pack = AnomalyDetector()
    events = run(&pack, from: t0, seconds: 200) { parts(battery: 47, board: 33, storage: 33, cpu: 40) }
    check(events == [AnomalyEvent(group: .battery, started: true)], "the whole battery hot while idle and unplugged warns")
    check(pack.anomalies.count == 4, "with every sensor listed")
    check(events.count == 1, "as one warning, not one per sensor")
    check(AnomalyDetector.describe(pack.anomalies, unit: .celsius)?.title == "Battery: 4 sensors are running hot on their own", "and one sentence")
    var charging = AnomalyDetector()
    events = run(&charging, from: t0, seconds: 200, charge: .charging) { parts(battery: 47, board: 33, storage: 33, cpu: 40) }
    check(events.isEmpty, "the same battery while charging is allowed that")

    // Learning: a sensor that always sits 8 above the rest.
    func learned(_ extra: Double) -> [SensorReading] {
        var list = parts(board: 40, cpu: 45)
        list[list.firstIndex { $0.id == "charger" }!].value = 41 + extra
        return list
    }
    var usual = AnomalyDetector()
    events = run(&usual, from: t0, seconds: 300) { learned(25) }
    check(events.isEmpty && usual.anomalies.isEmpty, "nothing to compare with yet: stays quiet")
    var teach = AnomalyDetector()
    run(&teach, from: t0, seconds: 2000) { learned(8) }
    check(teach.ready > 0, "half an hour in a condition makes it usable")
    let learnedAt = teach.baseline.sensors["charger"]
    events = run(&teach, from: t0.addingTimeInterval(2000), seconds: 200) { learned(8) }
    check(events.isEmpty, "its usual reading is fine")
    events = run(&teach, from: t0.addingTimeInterval(2200), seconds: 200) { learned(25) }
    check(events == [AnomalyEvent(group: .power, started: true)], "well above its usual reading warns")
    check(teach.anomalies.first?.reason == .learned, "for having learned so")
    let during = teach.baseline.sensors["charger"]?.values.first?.m ?? 0
    run(&teach, from: t0.addingTimeInterval(2400), seconds: 3600) { learned(25) }
    check(abs((teach.baseline.sensors["charger"]?.values.first?.m ?? 0) - during) < 0.5, "a fault doesn't teach it that the fault is normal")
    check(learnedAt != nil, "what's learned is kept per sensor")
    teach.relearn("charger")
    check(teach.anomalies.isEmpty && teach.baseline.sensors["charger"] == nil, "'It's normal' starts that sensor over")

    // Conditions are learned apart: what's usual on charge says nothing unplugged.
    var plug = AnomalyDetector()
    run(&plug, from: t0, seconds: 2000, charge: .charging) { learned(8) }
    run(&plug, from: t0.addingTimeInterval(2000), seconds: 100) { learned(25) }
    check(plug.anomalies.isEmpty, "learned on charge doesn't apply on battery")

    // Sleep.
    var nap = AnomalyDetector()
    run(&nap, from: t0, seconds: 100) { parts(gauge: 60) }
    run(&nap, from: t0.addingTimeInterval(7300), seconds: 30) { parts(gauge: 60) }
    check(nap.anomalies.isEmpty, "a sleep restarts the hold")

    // Settings.
    var settings = DetectorSettings(); settings.ignored = ["gauge"]
    var told = AnomalyDetector()
    events = run(&told, from: t0, seconds: 300, settings: settings) { parts(gauge: 60) }
    check(events.isEmpty, "an ignored sensor is ignored")
    settings = DetectorSettings(); settings.holdSeconds = 10
    var quick = AnomalyDetector()
    events = run(&quick, from: t0, seconds: 20, settings: settings) { parts(gauge: 60) }
    check(!events.isEmpty, "the hold can be shortened")
    settings = DetectorSettings(); settings.enabled = false
    var off = AnomalyDetector()
    events = run(&off, from: t0, seconds: 300, settings: settings) { parts(gauge: 60) }
    check(events.isEmpty && off.baseline.sensors.isEmpty, "off means off, and it learns nothing")
    var edge = AnomalyDetector()
    settings = DetectorSettings(); settings.sensitivity = .relaxed
    events = run(&edge, from: t0, seconds: 300, settings: settings) { parts(gauge: 44.5) }
    check(events.isEmpty, "relaxed needs more")
    edge = AnomalyDetector()
    settings = DetectorSettings(); settings.sensitivity = .keen
    events = run(&edge, from: t0, seconds: 300, settings: settings) { parts(gauge: 44.5) }
    check(!events.isEmpty, "keen needs less")

    // Found on a real M4 Pro: TVMR reads 94° and isn't a part at all.
    var reference = AnomalyDetector()
    events = run(&reference, from: t0, seconds: 300) {
        parts() + [SensorReading(id: "smc:TVMR", key: "TVMR", name: "Reference TVMR", group: .power, value: 94, countsTowardHottest: false)]
    }
    check(events.isEmpty && reference.anomalies.isEmpty, "a reference value isn't a part running hot")
    check(reference.baseline.sensors["smc:TVMR"] == nil, "and isn't learned as one")
    // Real keys, from the same Mac: gauges and board sensors don't count toward "hottest", but they are parts.
    var gauges = AnomalyDetector()
    events = run(&gauges, from: t0, seconds: 300) {
        parts().map { reading in
            var copy = reading
            copy.countsTowardHottest = reading.group != .battery && reading.group != .board
            if reading.id == "gauge" { copy.value = 62 }
            return copy
        }
    }
    check(events == [AnomalyEvent(group: .battery, started: true)], "a battery gauge is watched though it doesn't count toward hottest")
    check(gauges.watched >= 14, "and so are board sensors")

    // Few sensors: an older Mac, or a desktop without a battery.
    var few = AnomalyDetector()
    let two = [SensorReading(id: "a", key: "a", name: "a", group: .board, value: 70, countsTowardHottest: true),
               SensorReading(id: "b", key: "b", name: "b", group: .board, value: 30, countsTowardHottest: true)]
    events = run(&few, from: t0, seconds: 300) { two }
    check(events.isEmpty, "too few sensors to compare says nothing")

    let base = teach.baseline
    let saved = try JSONDecoder().decode(DetectorBaseline.self, from: JSONEncoder().encode(base))
    check(saved == base, "what's learned survives saving")
    let oldFile = try JSONDecoder().decode(Settings.self, from: Data(#"{"unit":"celsius"}"#.utf8))
    check(oldFile.detector.enabled && oldFile.detector.holdSeconds == 120, "older settings get the detector, on")
    let empty = try JSONDecoder().decode(DetectorSettings.self, from: Data("{}".utf8))
    check(empty.sensitivity == .normal, "and its defaults")

    // Diagnostics.
    let input = Diagnostics.Input(readsSensors: true, sensors: [], fans: [], hottest: nil, battery: nil, thermal: .nominal, helperInstalled: true, helperCurrent: true,
                                  anomalies: d.anomalies, detectorWatched: 10, detectorReady: 2)
    let found = Diagnostics.run(input).filter { $0.area == "Smart detector" }
    check(found.count == 1 && found[0].level == .problem, "a battery out of line is a problem in Diagnostics")
    var calm = input; calm.anomalies = []
    check(Diagnostics.run(calm).filter { $0.area == "Smart detector" }.first?.level == .ok, "and calm says so")
    var cli = calm; cli.detectorWatched = nil
    check(Diagnostics.run(cli).filter { $0.area == "Smart detector" }.isEmpty, "a one-off look from the command line doesn't claim to have watched")
}

func testBatteryNotice() {
    var b = BatteryInfo(percent: 100, cycles: 228, designCycles: 1000, designCapacity: 6249, maxCapacity: 5677, temperature: 34, volts: 13, amps: 0, isCharging: false, onAdapter: true)
    check(b.notice == nil, "no condition, nothing to say")
    b.systemCondition = ""
    check(b.notice == nil, "a healthy MacBook reports an empty condition: nothing to say")
    b.systemCondition = "Normal"
    check(b.notice == nil, "normal is nothing to say")
    b.systemCondition = "Check Battery"
    check(b.notice == "Check Battery", "macOS's own warning is passed on")
    b.permanentFailure = true
    check(b.notice == "Permanent fault", "a permanent fault comes first")
}

func testMenuBarLines() {
    var s = Settings()
    check(s.menuBarLayout == .twoLines && s.menuBarIcon == .thermometer, "new installs get temperatures above, RPM below")
    s.menuBar = [.temperature(.cpu)]; s.menuBarLayout = .row; s.menuBarIcon = .fan
    s.useTwoLines(hasGPU: true, firstFan: 0)
    check(s.menuBar == [.icon, .temperature(.cpu), .temperature(.group(.gpu)), .fan(0)], "choosing two lines fills in what it needs")
    s.useTwoLines(hasGPU: true, firstFan: 0)
    check(s.menuBar.count == 4, "and doesn't add them twice")
    s.menuBar = [.fan(1)]
    s.useTwoLines(hasGPU: false, firstFan: nil)
    check(s.menuBar == [.icon, .fan(1), .temperature(.cpu)], "keeps what was chosen, and copes without a GPU")
    let apple = Catalog.Chip(brand: "Apple M4 Pro")
    check(Catalog.entry(forSMCKey: "TG0H", chip: apple)?.name == "Battery gauge TG0H", "on Apple silicon TG keys aren't named as Intel GPUs")
    check(Catalog.entry(forSMCKey: "TG0H", chip: apple)?.group == .battery, "and stay with the battery")
}

@main enum Run {
    static func main() throws {
        testCurves(); testSnapshot(); testCatalog(); testRuleHysteresis(); testRuleZeroHold(); testFallingRule()
        testRuleConditions(); testMissingSensor(); testCombining(); testProfileSwitching(); testCurvePlan()
        testRamp(); testFailsafe(); testPreview(); testUnits(); try testConfigFile(); testDiagnostics(); testGuard(); testSMCValues()
        testSensorNames(); testAverage(); testDrives(); testLogFile(); testMail(); try testOlderFiles(); try testOnboardingFlag(); try testDetector(); testMenuBarLines(); testBatteryNotice()
        if failures.isEmpty {
            print("✓ \(passed) checks passed")
        } else {
            print("✗ \(failures.count) failed, \(passed) passed")
            failures.forEach { print("  \($0)") }
            exit(1)
        }
    }
}
