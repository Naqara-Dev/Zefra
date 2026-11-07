import AppKit
import Foundation
import Observation
import ServiceManagement
import UserNotifications

enum Page: String, CaseIterable, Identifiable {
    case overview, sensors, fans, rules, diagnostics, settings
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .sensors: "thermometer.medium"
        case .fans: "fan"
        case .rules: "arrow.triangle.branch"
        case .diagnostics: "stethoscope"
        case .settings: "gearshape"
        }
    }
}

/// A running record of values, one array per name, all the same length.
struct History {
    private(set) var series: [String: [Float]] = [:]
    var capacity = 1800

    mutating func add(_ values: [String: Double]) {
        for (name, value) in values {
            var line = series[name] ?? []
            line.append(Float(value))
            // Trimmed in batches: removing one from the front every time would copy the whole array.
            if line.count > capacity + 120 { line.removeFirst(line.count - capacity) }
            series[name] = line
        }
    }

    func recent(_ name: String, count: Int) -> [Float] {
        guard let line = series[name] else { return [] }
        return Array(line.suffix(count))
    }
}

@MainActor @Observable
final class AppModel {
    var page = Page.overview
    var config: Config {
        didSet {
            guard config != oldValue else { return }
            engine.config = config
            if config.settings.showWindowKey != oldValue.settings.showWindowKey || config.settings.toggleBoostKey != oldValue.settings.toggleBoostKey
                || config.settings.nextProfileKey != oldValue.settings.nextProfileKey { applyHotKeys() }
            // What just came from the file is already in it. Writing it back would undo a second
            // command that arrives in the meantime.
            if !loadingFromFile { scheduleSave() }
        }
    }
    private(set) var sample: MachineSample?
    private(set) var stats: [String: SensorStats] = [:]
    private(set) var fans: [FanStatus] = []
    private(set) var decisions: [FanDecision] = []
    private(set) var failsafe = false
    private(set) var effectiveProfile: UUID?
    private(set) var ruleLog: [RuleLogEntry] = []
    private(set) var history = History()
    private(set) var helperInstalled = false
    private(set) var helperAnswering = false
    private(set) var helperVersion: String?
    private(set) var anomalies: [Anomaly] = []
    private(set) var detectorWatched = 0
    private(set) var detectorReady = 0
    /// The first answer about the helper has come back. Before it, "not answering" means nothing yet.
    private(set) var helperChecked = false
    private(set) var helperWorking = false
    private(set) var onboardingOpen = false
    private(set) var lastError: String?
    /// Fans set by hand on the Fans page.
    var manual: [Int: Double] = [:]
    private(set) var fanTestRunning = false
    private(set) var fanTestFindings: [Finding] = []
    private(set) var loginItemEnabled = SMAppService.mainApp.status == .enabled
    private(set) var lastShutdown = LastShutdown.unknown
    private(set) var takenHotKeys: [HotKeys.Action] = []
    private(set) var mailStatus: String?
    private(set) var mailSending = false
    /// Every fan at full speed until turned off, from the menu bar or a hot key.
    private(set) var boosting = false
    let updates = Updates()

    struct RuleLogEntry: Identifiable {
        let id = UUID()
        var date: Date
        var text: String
    }

    @ObservationIgnored private var engine: Engine
    @ObservationIgnored private var detector = AnomalyDetector()
    @ObservationIgnored private var lastBaselineSave = Date.now
    @ObservationIgnored private var lastSeen: [String: Date] = [:]
    @ObservationIgnored private let reader = SensorReader()
    @ObservationIgnored private let helper = HelperClient()
    @ObservationIgnored private var control: FanControl
    @ObservationIgnored private var forcing = Set<Int>()
    @ObservationIgnored private var lastSent: [Int: Double] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var watchedSince = Date.now
    @ObservationIgnored private var lastLogRow = Date.distantPast
    @ObservationIgnored private var lastHelperCheck = Date.distantPast
    @ObservationIgnored private var authorizedNotifications = false
    @ObservationIgnored private let hotKeys = HotKeys()
    @ObservationIgnored private var manualBeforeBoost: [Int: Double] = [:]
    @ObservationIgnored private var lastFileDate: Date?
    @ObservationIgnored private var sleepObservers: [NSObjectProtocol] = []
    @ObservationIgnored private let launched = Date.now
    @ObservationIgnored private var checkedEvents = false
    @ObservationIgnored private var replacedLog = false
    @ObservationIgnored private var loadingFromFile = false
    #if DEBUG
    @ObservationIgnored private var fakeTemp: Double?
    #endif

    init() {
        let loaded = ConfigStore.load()
        config = loaded
        engine = Engine(config: loaded)
        control = helper
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "ZefraFakeFans") { control = FakeFanControl() }
        let temp = UserDefaults.standard.double(forKey: "ZefraFakeTemp")
        fakeTemp = temp > 0 ? temp : nil
        if let raw = UserDefaults.standard.string(forKey: "ZefraPage"), let page = Page(rawValue: raw) { self.page = page }
        #endif
    }

    func start() {
        guard loop == nil else { return }
        // Without this macOS naps a hidden app, its heartbeat stops, and the helper lets go of the fans.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Watching temperatures and fans")
        applyDockPolicy()
        detector.baseline = ConfigStore.loadBaseline()
        helper.onDropped = { [weak self] in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                self?.refreshHelper()
            }
        }
        refreshHelper()
        lastFileDate = Self.fileDate()
        hotKeys.onAction = { [weak self] action in self?.perform(action) }
        applyHotKeys()
        watchSleep()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(for: .seconds(max(self.config.settings.interval, 0.5)))
            }
        }
    }

    /// Fans go back to macOS on the way out. If this never runs, the helper does it anyway.
    func quitting() {
        control.releaseAll()
        saveNow()
        ConfigStore.saveBaseline(detector.baseline)
    }

    private func tick() async {
        var sample = await reader.sample()
        #if DEBUG
        // `-ZefraFakeTempFile path` lets a test change the temperature while the app runs.
        if let path = UserDefaults.standard.string(forKey: "ZefraFakeTempFile"),
           let text = try? String(contentsOfFile: path, encoding: .utf8), let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            fakeTemp = value
        }
        if let fakeTemp {
            let readings = sample.temps.readings.map { reading -> SensorReading in
                var copy = reading
                if reading.group == .cpuPerformance || reading.group == .cpuEfficiency { copy.value = fakeTemp }
                return copy
            }
            sample.temps = TempSnapshot(readings: readings)
        }
        // `-ZefraFakeSensorFile path` holds lines of "sensor-id value": one part heating up on its own.
        if let path = UserDefaults.standard.string(forKey: "ZefraFakeSensorFile"), let text = try? String(contentsOfFile: path, encoding: .utf8) {
            var fake: [String: Double] = [:]
            for line in text.split(separator: "\n") {
                let words = line.split(separator: " ")
                if words.count == 2, let value = Double(words[1]) { fake[String(words[0])] = value }
            }
            let readings = sample.temps.readings.map { reading -> SensorReading in
                var copy = reading
                if let value = fake[reading.id] { copy.value = value }
                return copy
            }
            sample.temps = TempSnapshot(readings: readings)
        }
        #endif
        reloadIfChangedOutside()
        self.sample = sample
        updateStats(sample)
        updateHistory(sample)
        let specs = sample.fans.map { FanSpec(index: $0.index, minRPM: $0.minRPM, maxRPM: $0.maxRPM) }
        let calendar = Calendar.current
        let now = Date.now
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let output = engine.step(EngineInput(now: now, temps: sample.temps, power: sample.power, fans: specs, minuteOfDay: minute, manual: manual))
        decisions = output.decisions
        failsafe = output.failsafe
        effectiveProfile = output.activeProfile
        handle(output.events)
        apply(output.decisions, sample: sample)
        fans = sample.fans.map { fan in
            FanStatus(spec: FanSpec(index: fan.index, minRPM: fan.minRPM, maxRPM: fan.maxRPM), name: fanName(fan.index), rpm: fan.rpm,
                      target: forcing.contains(fan.index) ? fan.target : nil)
        }
        writeLogRow(sample, output: output)
        checkEvents(sample)
        watchForAnomalies(sample)
        if now.timeIntervalSince(lastHelperCheck) > 20 { refreshHelper() }
    }

    private func apply(_ decisions: [FanDecision], sample: MachineSample) {
        guard control.isAvailable else {
            forcing.removeAll()
            return
        }
        control.heartbeat(failsafe: config.settings.failsafe)
        for decision in decisions {
            let raw = sample.fans.first { $0.index == decision.index }
            if let rpm = decision.rpm {
                // Sleep can reset a fan to automatic behind our back, so the mode is checked too.
                let drifted = control.changesHardware && (raw.map { forcing.contains(decision.index) && $0.mode != 1 } ?? false)
                let changed = abs((lastSent[decision.index] ?? -1000) - rpm) >= 25
                guard changed || drifted || !forcing.contains(decision.index) else { continue }
                lastSent[decision.index] = rpm
                forcing.insert(decision.index)
                control.set(decision.index, rpm: rpm) { [weak self] error in self?.lastError = error }
            } else if forcing.contains(decision.index) {
                forcing.remove(decision.index)
                lastSent[decision.index] = nil
                control.release(decision.index) { [weak self] error in self?.lastError = error }
            }
        }
    }

    private func updateStats(_ sample: MachineSample) {
        let watched = Date.now.timeIntervalSince(watchedSince)
        for reading in sample.temps.readings {
            var stat = stats[reading.id] ?? SensorStats(id: reading.id, name: reading.name, group: reading.group, value: reading.value,
                                                        low: reading.value, high: reading.value, watched: 0)
            stat.value = reading.value
            stat.low = min(stat.low, reading.value)
            stat.high = max(stat.high, reading.value)
            stat.watched = watched
            stats[reading.id] = stat
            lastSeen[reading.id] = .now
        }
    }

    private func updateHistory(_ sample: MachineSample) {
        history.capacity = max(Int(Double(config.settings.historyMinutes) * 60 / max(config.settings.interval, 0.5)), 60)
        var values: [String: Double] = [:]
        for reading in sample.temps.readings { values[reading.id] = reading.value }
        if let value = sample.temps.value(of: .hottest) { values["@hottest"] = value }
        if let value = sample.temps.value(of: .cpu) { values["@cpu"] = value }
        for group in SensorGroup.allCases {
            if let value = sample.temps.value(of: .group(group)) { values["@\(group.rawValue)"] = value }
        }
        for fan in sample.fans { values["@fan\(fan.index)"] = fan.rpm }
        if let watts = sample.systemWatts { values["@watts"] = watts }
        history.add(values)
    }

    private func handle(_ events: [RuleEvent]) {
        for event in events {
            guard let rule = config.rules.first(where: { $0.id == event.ruleID }) else { continue }
            let temp = config.settings.unit.text(event.temp)
            ruleLog.insert(RuleLogEntry(date: .now, text: "\(event.name) \(event.turnedOn ? "started" : "ended") at \(temp)"), at: 0)
            if ruleLog.count > 50 { ruleLog.removeLast() }
            let text = "\(title(of: rule.source)) is at \(temp)."
            if config.settings.notifications, event.turnedOn ? rule.notifyOn : rule.notifyOff {
                notify(title: rule.name, body: text, sound: rule.sound)
            }
            if rule.email, event.turnedOn { sendMail(subject: "Zefra: \(rule.name)", text: text) }
        }
    }

    private func notify(title: String, body: String, sound: Bool) {
        let center = UNUserNotificationCenter.current()
        let request: @Sendable () -> Void = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        // Played here rather than by the notification, so any sound in the Sounds folders can be used.
        if sound { playAlertSound() }
        if authorizedNotifications {
            request()
        } else {
            center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                Task { @MainActor in self?.authorizedNotifications = granted }
                if granted { request() }
            }
        }
    }

    func playAlertSound() {
        if let name = config.settings.alertSound, let sound = NSSound(named: NSSound.Name(name)) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    /// Every sound in the system's and the user's Sounds folders.
    static var soundNames: [String] {
        let folders = ["/System/Library/Sounds", "/Library/Sounds", ("~/Library/Sounds" as NSString).expandingTildeInPath]
        let names = folders.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
        return Set(names.filter { !$0.hasPrefix(".") }.map { ($0 as NSString).deletingPathExtension }).sorted()
    }

    /// Things that happened while Zefra wasn't looking: a forced shutdown, a crash, a battery or drive
    /// that wants attention. Each is told once.
    private func checkEvents(_ sample: MachineSample) {
        guard !sample.drives.isEmpty || checkedEvents == false else { return }
        var seen = config.seen
        if !checkedEvents {
            checkedEvents = true
            let panic = DriveReader.newestPanicReport()
            lastShutdown = LastShutdown.judge(drives: sample.drives, newestPanic: panic, seen: seen)
            if config.settings.notifyAbnormalShutdown {
                switch lastShutdown {
                case .unsafe: alert(title: "The Mac didn't shut down cleanly", text: "It lost power or was forced off since Zefra last looked.")
                case .panic(let report): alert(title: "macOS crashed and restarted", text: "It left a report: \(report).")
                default: break
                }
            }
            seen.lastPanicReport = panic ?? seen.lastPanicReport
            for drive in sample.drives where drive.isInternal { seen.unsafeShutdowns[drive.name] = drive.unsafeShutdowns }
        }
        if let battery = sample.battery {
            let notice = battery.notice
            if notice != seen.batteryNotice {
                seen.batteryNotice = notice
                if let notice, config.settings.notifyBatteryService { alert(title: "The battery needs attention", text: notice) }
            }
        }
        for drive in sample.drives {
            let notice: String? = drive.criticalWarning != 0 ? "reports a critical warning" : drive.mediaErrors > 0 ? "has \(drive.mediaErrors) media errors" : nil
            if notice != seen.driveNotices[drive.name] {
                seen.driveNotices[drive.name] = notice
                if let notice, config.settings.notifyDriveProblem { alert(title: "\(drive.name) \(notice)", text: "Back it up.") }
            }
        }
        if seen != config.seen { config.seen = seen }
    }

    private func watchForAnomalies(_ sample: MachineSample) {
        let charge: ChargeState = sample.battery?.isCharging == true ? .charging : sample.power == .battery ? .battery : .adapter
        let events = detector.step(now: .now, readings: sample.temps.readings, charge: charge, settings: config.settings.detector)
        anomalies = detector.anomalies
        detectorWatched = detector.watched
        detectorReady = detector.ready
        for event in events {
            debugNote("ZEFRA_ANOMALY \(event.started ? "start" : "end") \(event.group.rawValue)")
            guard event.started else {
                ruleLog.insert(RuleLogEntry(date: .now, text: "\(event.group.title) is back in line with the rest of the Mac"), at: 0)
                continue
            }
            guard let text = AnomalyDetector.describe(anomalies.filter { $0.group == event.group }, unit: config.settings.unit) else { continue }
            if config.settings.detector.notify {
                alert(title: text.title, text: text.detail)
            } else {
                ruleLog.insert(RuleLogEntry(date: .now, text: text.title), at: 0)
            }
        }
        if Date.now.timeIntervalSince(lastBaselineSave) > 300 {
            lastBaselineSave = .now
            ConfigStore.saveBaseline(detector.baseline)
        }
    }

    /// "This is fine." What it learned gets thrown away and learned again; if nothing was learned
    /// (the sensor tripped a fixed limit, or disagreed with its siblings) it's simply not watched any more.
    func markNormal(_ anomaly: Anomaly) {
        if anomaly.reason == .learned {
            detector.relearn(anomaly.id)
        } else if !config.settings.detector.ignored.contains(anomaly.id) {
            config.settings.detector.ignored.append(anomaly.id)
        }
        anomalies.removeAll { $0.id == anomaly.id }
    }

    func forgetLearning() {
        detector.baseline = DetectorBaseline()
        ConfigStore.saveBaseline(detector.baseline)
    }

    private func alert(title: String, text: String) {
        debugNote("ZEFRA_ALERT \(title): \(text)")
        ruleLog.insert(RuleLogEntry(date: .now, text: title), at: 0)
        if config.settings.notifications { notify(title: title, body: text, sound: true) }
        sendMail(subject: "Zefra: \(title)", text: text)
    }

    private func sendMail(subject: String, text: String, isTest: Bool = false) {
        let settings = config.settings.mail
        guard settings.enabled || isTest else { return }
        mailSending = true
        Task.detached(priority: .utility) { [weak self] in
            let password = settings.usesPassword ? MailPassword.read(account: settings.username) : nil
            let error = Mailer.send(settings: settings, password: password, subject: subject, body: Mailer.body(text))
            await self?.mailFinished(error: error, isTest: isTest)
        }
    }

    private func mailFinished(error: String?, isTest: Bool) {
        mailSending = false
        if let error {
            mailStatus = error
        } else if isTest {
            mailStatus = "Sent."
        } else {
            mailStatus = nil
        }
    }

    func sendTestMail() {
        mailStatus = nil
        sendMail(subject: "Zefra test", text: "This is a test from Zefra.", isTest: true)
    }

    // MARK: Boost, hot keys, sleep

    func toggleBoost() {
        if boosting {
            manual = manualBeforeBoost
            boosting = false
        } else {
            manualBeforeBoost = manual
            for fan in fans { manual[fan.spec.index] = 100 }
            boosting = true
        }
    }

    private func applyHotKeys() {
        var keys: [HotKeys.Action: HotKey] = [:]
        if let key = config.settings.showWindowKey { keys[.showWindow] = key }
        if let key = config.settings.toggleBoostKey { keys[.toggleBoost] = key }
        if let key = config.settings.nextProfileKey { keys[.nextProfile] = key }
        takenHotKeys = hotKeys.set(keys)
    }

    private func perform(_ action: HotKeys.Action) {
        switch action {
        case .showWindow:
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        case .toggleBoost:
            toggleBoost()
        case .nextProfile:
            guard let index = config.profiles.firstIndex(where: { $0.id == config.activeProfile }) else { return }
            config.activeProfile = config.profiles[(index + 1) % config.profiles.count].id
        }
    }

    private func watchSleep() {
        guard sleepObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.config.settings.releaseDuringSleep else { return }
                self.control.releaseAll()
                // Waking finds nothing forced, so whatever's wanted then gets set again.
                self.forcing.removeAll()
                self.lastSent.removeAll()
            }
        })
    }

    private static func fileDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: ConfigStore.file.path))?[.modificationDate] as? Date
    }

    /// The command line changes the same file; a change from outside is picked up here.
    private func reloadIfChangedOutside() {
        guard saveTask == nil, let date = Self.fileDate(), date != lastFileDate else { return }
        lastFileDate = date
        guard let data = try? Data(contentsOf: ConfigStore.file), let loaded = try? JSONDecoder().decode(Config.self, from: data), loaded != config else { return }
        loadingFromFile = true
        config = loaded
        loadingFromFile = false
    }

    // MARK: Names

    func name(ofSensor id: String) -> String {
        config.sensorNames[id] ?? stats[id]?.name ?? id
    }

    func fanName(_ index: Int) -> String {
        config.fanNames[index] ?? "Fan \(index + 1)"
    }

    func title(of source: TempSource) -> String {
        switch source {
        case .hottest: "Hottest part"
        case .cpu: "CPU, hottest"
        case .cpuAverage: "CPU, average"
        case .group(let group): group.title
        case .sensor(let id): name(ofSensor: id)
        }
    }

    func text(_ celsius: Double?) -> String { config.settings.unit.text(celsius) }

    /// Sensors that have moved since Zefra started: the ones worth offering as a rule's source.
    var movingSensors: [SensorStats] {
        stats.values.filter { $0.high - $0.low > 0.01 && !config.hiddenSensors.contains($0.id) }
            .sorted { $0.group.rawValue == $1.group.rawValue ? name(ofSensor: $0.id) < name(ofSensor: $1.id) : $0.group.rawValue < $1.group.rawValue }
    }

    // MARK: Profiles and rules

    var activeProfile: Profile {
        config.profiles.first { $0.id == config.activeProfile } ?? config.profiles[0]
    }

    func updateActiveProfile(_ change: (inout Profile) -> Void) {
        guard let index = config.profiles.firstIndex(where: { $0.id == config.activeProfile }) else { return }
        change(&config.profiles[index])
    }

    func addProfile() {
        var copy = activeProfile
        copy.id = UUID()
        copy.name = "\(copy.name) copy"
        config.profiles.append(copy)
        config.activeProfile = copy.id
    }

    func deleteProfile(_ id: UUID) {
        guard config.profiles.count > 1 else { return }
        config.profiles.removeAll { $0.id == id }
        if config.activeProfile == id { config.activeProfile = config.profiles[0].id }
    }

    func saveRule(_ rule: Rule) {
        if let index = config.rules.firstIndex(where: { $0.id == rule.id }) {
            config.rules[index] = rule
        } else {
            config.rules.append(rule)
        }
    }

    func runtime(of rule: Rule) -> RuleRuntime { engine.runtime(of: rule) }

    /// What the fans would do at this temperature, holds and all waited out.
    func preview(temp: Double, source: TempSource?) -> [FanDecision] {
        guard let sample else { return [] }
        let specs = sample.fans.map { FanSpec(index: $0.index, minRPM: $0.minRPM, maxRPM: $0.maxRPM) }
        return engine.preview(temp: temp, source: source, input: EngineInput(now: .now, temps: sample.temps, power: sample.power, fans: specs, minuteOfDay: 720))
    }

    // MARK: Helper

    func refreshHelper() {
        lastHelperCheck = .now
        #if DEBUG
        if control is FakeFanControl { return helperWasChecked() }
        #endif
        helper.refresh { [weak self] in
            guard let self else { return }
            self.helperInstalled = self.helper.isInstalled
            self.helperAnswering = self.helper.answering
            self.helperVersion = self.helper.version
            self.helperWasChecked()
        }
    }

    private func helperWasChecked() {
        guard !helperChecked else { return }
        helperChecked = true
        guard !config.seen.onboarded else { return }
        // Someone who already has the helper has nothing left to set up.
        if helperInstalled || canControlFans {
            config.seen.onboarded = true
        } else {
            onboardingOpen = true
            debugNote("ZEFRA_ONBOARDING open")
            #if DEBUG
            if UserDefaults.standard.string(forKey: "ZefraFakeInstall") != nil { installHelper() }
            #endif
        }
    }

    func finishOnboarding() {
        onboardingOpen = false
        config.seen.onboarded = true
    }

    /// Asks macOS for the password, then waits until the new helper really answers.
    func installHelper() {
        guard !helperWorking else { return }
        helperWorking = true
        lastError = nil
        Task {
            defer { helperWorking = false }
            // macOS's password dialog holds up this thread, so what's happening has to be drawn first.
            try? await Task.sleep(for: .milliseconds(100))
            #if DEBUG
            if let fake = control as? FakeFanControl {
                try? await Task.sleep(for: .seconds(2))
                switch UserDefaults.standard.string(forKey: "ZefraFakeInstall") {
                case "fail": lastError = "The helper's install script failed."
                case "cancel": break
                default: fake.isAvailable = true
                }
                debugNote("ZEFRA_ONBOARDING \(fake.isAvailable ? "installed" : lastError == nil ? "cancelled" : "failed")")
                return
            }
            #endif
            do {
                try HelperInstaller.install()
            } catch HelperInstaller.Failure.cancelled {
                return
            } catch {
                lastError = error.localizedDescription
                return
            }
            for _ in 0..<20 {
                refreshHelper()
                try? await Task.sleep(for: .milliseconds(500))
                if helperAnswering { return }
            }
            lastError = "The helper was installed, but it isn't answering. Restart the Mac and try again."
        }
    }

    private func debugNote(_ text: String) {
        #if DEBUG
        print(text)
        fflush(stdout)
        #endif
    }

    func uninstallHelper() {
        control.releaseAll()
        do {
            try HelperInstaller.uninstall()
            lastError = nil
        } catch HelperInstaller.Failure.cancelled {
        } catch {
            lastError = error.localizedDescription
        }
        forcing.removeAll()
        Task {
            try? await Task.sleep(for: .seconds(1))
            refreshHelper()
        }
    }

    var canControlFans: Bool { control.isAvailable }
    var showsHelperBanner: Bool { helperChecked && !canControlFans }

    // MARK: Diagnostics

    func runDiagnostics() -> [Finding] {
        guard let sample else { return [] }
        return Diagnostics.run(Diagnostics.Input(readsSensors: sample.readsSMC || !sample.temps.readings.isEmpty, sensors: Array(stats.values), fans: fans,
                                                 hottest: sample.temps.value(of: .hottest), battery: sample.battery, thermal: sample.thermal,
                                                 helperInstalled: helperInstalled || canControlFans, helperCurrent: canControlFans,
                                                 drives: sample.drives, lastShutdown: lastShutdown, flaggedFans: sample.flaggedFans,
                                                 silentSensors: silentSensors(sample), anomalies: anomalies,
                                                 detectorWatched: detectorWatched, detectorReady: detectorReady, unit: config.settings.unit))
    }

    /// Parts that read fine earlier and have given nothing for a good while. Chips and board sensors
    /// come and go on their own: an idle core is powered down, and its sensor goes with it.
    private func silentSensors(_ sample: MachineSample) -> [String] {
        let comeAndGo: Set<SensorGroup> = [.board, .cpuPerformance, .cpuEfficiency, .gpu, .soc]
        return stats.values.filter { stat in
            guard !comeAndGo.contains(stat.group), let seen = lastSeen[stat.id] else { return false }
            return Date.now.timeIntervalSince(seen) > 300
        }
        .map { name(ofSensor: $0.id) }.sorted()
    }

    /// Runs each fan to full speed for a few seconds, then hands it back.
    func runFanTest() async {
        guard !fanTestRunning, canControlFans else { return }
        fanTestRunning = true
        defer { fanTestRunning = false }
        var results: [Finding] = []
        for fan in fans {
            let index = fan.spec.index
            manual[index] = 100
            try? await Task.sleep(for: .seconds(10))
            let reached = fans.first { $0.spec.index == index }?.rpm ?? 0
            manual[index] = nil
            let good = reached >= fan.spec.maxRPM * 0.8
            results.append(Finding(area: "Fan test", level: good ? .ok : .warning, title: "\(fan.name) reached \(Int(reached)) RPM",
                                   detail: good ? "Its maximum is \(Int(fan.spec.maxRPM)) RPM." : "It should get close to \(Int(fan.spec.maxRPM)) RPM. Check for dust, or test again."))
        }
        fanTestFindings = results
    }

    // MARK: Settings that reach outside the app

    func applyDockPolicy() {
        NSApp.setActivationPolicy(config.settings.showInDock ? .regular : .accessory)
    }

    func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        loginItemEnabled = SMAppService.mainApp.status == .enabled
    }

    func duplicateRule(_ rule: Rule) {
        var copy = rule
        copy.id = UUID()
        copy.name = "\(rule.name) copy"
        // Turned off, so it doesn't start acting before it's been changed.
        copy.enabled = false
        guard let index = config.rules.firstIndex(where: { $0.id == rule.id }) else { return }
        config.rules.insert(copy, at: index + 1)
    }

    func moveRule(_ rule: Rule, by offset: Int) {
        guard let index = config.rules.firstIndex(where: { $0.id == rule.id }), config.rules.indices.contains(index + offset) else { return }
        config.rules.swapAt(index, index + offset)
    }

    func resetStats() {
        stats.removeAll()
        lastSeen.removeAll()
        watchedSince = .now
    }

    func historyCSV() -> String {
        let names = ["@hottest", "@cpu", "@gpu", "@soc", "@battery", "@storage"] + fans.map { "@fan\($0.spec.index)" } + ["@watts"]
        let present = names.filter { history.series[$0] != nil }
        var lines = ["sample," + present.map { String($0.dropFirst()) }.joined(separator: ",")]
        let length = present.compactMap { history.series[$0]?.count }.max() ?? 0
        for row in 0..<length {
            let cells = present.map { name -> String in
                guard let line = history.series[name] else { return "" }
                let offset = length - line.count
                return row >= offset ? String(format: "%.1f", line[row - offset]) : ""
            }
            lines.append("\(row)," + cells.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    var logFolder: URL {
        config.settings.logFolder.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? ConfigStore.home.appending(path: "Logs", directoryHint: .isDirectory)
    }

    private func writeLogRow(_ sample: MachineSample, output: EngineOutput) {
        let settings = config.settings
        guard settings.logging, Date.now.timeIntervalSince(lastLogRow) >= settings.logEverySeconds else { return }
        lastLogRow = .now
        let file = logFolder.appending(path: LogFile.name(schedule: settings.logSchedule, dated: settings.logDatedName, launch: launched, now: .now))
        let manager = FileManager.default
        try? manager.createDirectory(at: logFolder, withIntermediateDirectories: true)
        // A fresh file each launch without a date in its name replaces the last one, once.
        if settings.logSchedule == .eachLaunch, !settings.logDatedName, !replacedLog {
            try? manager.removeItem(at: file)
            replacedLog = true
        }
        if !manager.fileExists(atPath: file.path) {
            manager.createFile(atPath: file.path, contents: Data(LogFile.header(fans: sample.fans.map(\.index)).utf8))
        }
        let t = sample.temps
        let active = config.rules.filter { $0.enabled && engine.runtime(of: $0).active }
        let row = LogFile.row(time: Date.now.formatted(.iso8601),
                              values: [t.value(of: .hottest), t.value(of: .cpu), t.value(of: .cpuAverage), t.value(of: .group(.gpu)), t.value(of: .group(.storage)), t.value(of: .group(.battery))]
                                + sample.fans.map(\.rpm) + [sample.systemWatts],
                              rules: active.map(\.name), alert: output.failsafe || active.contains { $0.notifyOn })
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(row.utf8))
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        saveTask = nil
        ConfigStore.save(config)
        lastFileDate = Self.fileDate()
    }
}
