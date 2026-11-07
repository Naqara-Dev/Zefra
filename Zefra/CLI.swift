import AppKit
import Foundation

/// `zefra status`, `zefra fans set 60`, and the rest: everything a script or device management needs.
/// Commands change the settings file, and a running app picks the change up within a moment.
enum CLI {
    static let commands: Set<String> = ["status", "sensors", "fans", "drives", "profile", "rule", "set", "diagnostics", "config", "helper", "mail", "version", "help", "--help", "-h", "--version"]

    static let usage = """
    zefra: temperatures and fan control

      zefra status [--json]             temperatures, fans and power right now
      zefra sensors [--json]            every sensor
      zefra drives [--json]             SMART data of NVMe drives
      zefra diagnostics                 the same checks as the app
      zefra fans                        each fan's speed and range
      zefra fans set <percent>|max      every fan at a speed (the "Command line" profile)
      zefra fans auto                   back to Automatic
      zefra profile                     list profiles
      zefra profile <name>              switch profile
      zefra rule                        list rules
      zefra rule on|off <name>          turn a rule on or off
      zefra set failsafe|interval|unit <value>
      zefra config export|import <path>
      zefra helper status|install|uninstall
      zefra version

    Fan commands take effect through the app, which has to be running with its helper installed.

    """

    /// Runs a command if there is one. False means it's the app that's starting.
    @MainActor
    static func runIfCommand() -> Bool {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let first = args.first, commands.contains(first) else { return false }
        Task {
            let code = await run(args)
            exit(code)
        }
        dispatchMain()
    }

    private static func out(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
    private static func fail(_ text: String) -> Int32 {
        FileHandle.standardError.write(Data(("zefra: " + text + "\n").utf8))
        return 1
    }

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func rounded(_ value: Double?) -> Any { value.map { ($0 * 10).rounded() / 10 } ?? NSNull() }

    static func run(_ args: [String]) async -> Int32 {
        let wantsJSON = args.contains("--json")
        let words = args.filter { $0 != "--json" }
        switch words[0] {
        case "help", "--help", "-h":
            out(usage)
            return 0
        case "version", "--version":
            out(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
            return 0
        case "status": return await status(json: wantsJSON)
        case "sensors": return await sensors(json: wantsJSON)
        case "drives": return drives(json: wantsJSON)
        case "diagnostics": return await diagnostics()
        case "fans": return await fans(Array(words.dropFirst()))
        case "profile": return profile(Array(words.dropFirst()))
        case "rule": return rule(Array(words.dropFirst()))
        case "set": return set(Array(words.dropFirst()))
        case "config": return configFile(Array(words.dropFirst()))
        case "helper": return helper(Array(words.dropFirst()))
        case "mail": return mail(Array(words.dropFirst()))
        default: return fail("unknown command \(words[0])")
        }
    }

    private static func status(json wantsJSON: Bool) async -> Int32 {
        let sample = await SensorReader().sample()
        let config = ConfigStore.load()
        let unit = config.settings.unit
        let active = config.profiles.first { $0.id == config.activeProfile }?.name ?? "?"
        if wantsJSON {
            out(json([
                "hottest": rounded(sample.temps.value(of: .hottest)), "cpu": rounded(sample.temps.value(of: .cpu)),
                "cpu_average": rounded(sample.temps.value(of: .cpuAverage)), "gpu": rounded(sample.temps.value(of: .group(.gpu))),
                "ssd": rounded(sample.temps.value(of: .group(.storage))), "battery": rounded(sample.temps.value(of: .group(.battery))),
                "watts": rounded(sample.systemWatts), "profile": active,
                "fans": sample.fans.map { ["index": $0.index, "rpm": rounded($0.rpm), "min": rounded($0.minRPM), "max": rounded($0.maxRPM)] as [String: Any] },
            ]))
            return 0
        }
        out("Hottest  \(unit.text(sample.temps.value(of: .hottest)))")
        out("CPU      \(unit.text(sample.temps.value(of: .cpu))) peak, \(unit.text(sample.temps.value(of: .cpuAverage))) average")
        out("GPU      \(unit.text(sample.temps.value(of: .group(.gpu))))")
        out("SSD      \(unit.text(sample.temps.value(of: .group(.storage))))")
        out("Battery  \(unit.text(sample.temps.value(of: .group(.battery))))")
        for fan in sample.fans { out("Fan \(fan.index + 1)    \(fan.rpm < 1 ? "stopped" : "\(Int(fan.rpm)) RPM")") }
        if let watts = sample.systemWatts { out("Using    \(Int(watts.rounded())) W") }
        out("Profile  \(active)")
        return 0
    }

    private static func sensors(json wantsJSON: Bool) async -> Int32 {
        let sample = await SensorReader().sample()
        let config = ConfigStore.load()
        let rows = sample.temps.readings.sorted { $0.value > $1.value }
        if wantsJSON {
            out(json(rows.map { ["id": $0.id, "name": config.sensorNames[$0.id] ?? $0.name, "group": $0.group.rawValue, "celsius": rounded($0.value)] as [String: Any] }))
        } else {
            for row in rows {
                out("\(config.settings.unit.text(row.value).padding(toLength: 6, withPad: " ", startingAt: 0))\(row.group.title.padding(toLength: 18, withPad: " ", startingAt: 0))\(config.sensorNames[row.id] ?? row.name)")
            }
        }
        return 0
    }

    private static func drives(json wantsJSON: Bool) -> Int32 {
        let drives = DriveReader.read()
        if wantsJSON {
            out(json(drives.map { ["name": $0.name, "internal": $0.isInternal, "celsius": rounded($0.temperature), "percent_used": $0.percentUsed, "spare": $0.availableSpare,
                                   "hours": $0.powerOnHours, "unsafe_shutdowns": $0.unsafeShutdowns, "media_errors": $0.mediaErrors, "critical_warning": $0.criticalWarning] as [String: Any] }))
            return 0
        }
        if drives.isEmpty { out("No drives report SMART data.") }
        for drive in drives {
            out("\(drive.name)\(drive.isInternal ? "" : " (external)"): \(TemperatureUnit.celsius.text(drive.temperature)), \(drive.percentUsed)% used, \(drive.powerOnHours) hours, \(drive.unsafeShutdowns) unsafe shutdowns, \(drive.mediaErrors) media errors")
        }
        return 0
    }

    private static func diagnostics() async -> Int32 {
        let sample = await SensorReader().sample()
        let config = ConfigStore.load()
        let fans = sample.fans.map { FanStatus(spec: FanSpec(index: $0.index, minRPM: $0.minRPM, maxRPM: $0.maxRPM), name: config.fanNames[$0.index] ?? "Fan \($0.index + 1)", rpm: $0.rpm, target: nil) }
        let stats = sample.temps.readings.map { SensorStats(id: $0.id, name: $0.name, group: $0.group, value: $0.value, low: $0.value, high: $0.value, watched: 0) }
        let installed = FileManager.default.fileExists(atPath: HelperInfo.plistPath)
        let findings = Diagnostics.run(Diagnostics.Input(readsSensors: !stats.isEmpty, sensors: stats, fans: fans, hottest: sample.temps.value(of: .hottest), battery: sample.battery,
                                                         thermal: sample.thermal, helperInstalled: installed, helperCurrent: installed, drives: sample.drives,
                                                         lastShutdown: LastShutdown.judge(drives: sample.drives, newestPanic: DriveReader.newestPanicReport(), seen: config.seen),
                                                         flaggedFans: sample.flaggedFans))
        let version = ProcessInfo.processInfo.operatingSystemVersion
        FileHandle.standardOutput.write(Data(Diagnostics.report(findings, model: ProcessInfo.processInfo.hostName, system: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)", date: .now).utf8))
        return findings.contains { $0.level == .problem } ? 2 : 0
    }

    private static func fans(_ words: [String]) async -> Int32 {
        guard let verb = words.first else {
            let sample = await SensorReader().sample()
            if sample.fans.isEmpty { out("No fans on this Mac.") }
            for fan in sample.fans { out("Fan \(fan.index + 1): \(fan.rpm < 1 ? "stopped" : "\(Int(fan.rpm)) RPM"), \(Int(fan.minRPM))–\(Int(fan.maxRPM))") }
            return 0
        }
        var config = ConfigStore.load()
        switch verb {
        case "auto":
            guard let automatic = config.profiles.first(where: { $0.plan == .system && $0.perFan.isEmpty }) else { return fail("no profile leaves the fans to macOS") }
            config.activeProfile = automatic.id
            out("Profile: \(automatic.name)")
        case "set":
            guard words.count > 1, let percent = words[1] == "max" ? 100 : Double(words[1].replacingOccurrences(of: "%", with: "")), (0...100).contains(percent) else {
                return fail("fans set takes 0 to 100, or max")
            }
            let name = "Command line"
            if let index = config.profiles.firstIndex(where: { $0.name == name }) {
                config.profiles[index].plan = .fixed(percent: percent)
                config.profiles[index].perFan = [:]
                config.activeProfile = config.profiles[index].id
            } else {
                let profile = Profile(name: name, icon: "terminal", plan: .fixed(percent: percent))
                config.profiles.append(profile)
                config.activeProfile = profile.id
            }
            out("Every fan at \(Int(percent))%")
        default:
            return fail("fans takes set or auto")
        }
        return ConfigStore.save(config) ? 0 : fail("couldn't save the settings")
    }

    private static func profile(_ words: [String]) -> Int32 {
        var config = ConfigStore.load()
        let wanted = words.joined(separator: " ")
        if wanted.isEmpty || wanted == "list" {
            for profile in config.profiles { out((profile.id == config.activeProfile ? "* " : "  ") + profile.name) }
            return 0
        }
        guard let match = config.profiles.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) else { return fail("no profile called \(wanted)") }
        config.activeProfile = match.id
        out("Profile: \(match.name)")
        return ConfigStore.save(config) ? 0 : fail("couldn't save the settings")
    }

    private static func rule(_ words: [String]) -> Int32 {
        var config = ConfigStore.load()
        if words.isEmpty || words == ["list"] {
            if config.rules.isEmpty { out("No rules.") }
            for rule in config.rules { out("\(rule.enabled ? "on " : "off") \(rule.name)") }
            return 0
        }
        guard words.count >= 2, words[0] == "on" || words[0] == "off" else { return fail("rule takes on or off and a name") }
        let wanted = words.dropFirst().joined(separator: " ")
        guard let index = config.rules.firstIndex(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) else { return fail("no rule called \(wanted)") }
        config.rules[index].enabled = words[0] == "on"
        out("\(config.rules[index].name): \(words[0])")
        return ConfigStore.save(config) ? 0 : fail("couldn't save the settings")
    }

    private static func set(_ words: [String]) -> Int32 {
        guard words.count == 2 else { return fail("set takes a name and a value") }
        var config = ConfigStore.load()
        switch words[0] {
        case "failsafe":
            guard let value = Double(words[1]), (60...FanGuard.highestFailsafe).contains(value) else { return fail("failsafe takes 60 to \(Int(FanGuard.highestFailsafe))") }
            config.settings.failsafe = value
        case "interval":
            guard let value = Double(words[1]), (1...60).contains(value) else { return fail("interval takes 1 to 60 seconds") }
            config.settings.interval = value
        case "unit":
            switch words[1].lowercased() {
            case "c", "celsius": config.settings.unit = .celsius
            case "f", "fahrenheit": config.settings.unit = .fahrenheit
            default: return fail("unit takes c or f")
            }
        default:
            return fail("unknown setting \(words[0])")
        }
        return ConfigStore.save(config) ? 0 : fail("couldn't save the settings")
    }

    private static func configFile(_ words: [String]) -> Int32 {
        guard words.count == 2 else { return fail("config takes export or import, and a path") }
        let url = URL(fileURLWithPath: words[1])
        switch words[0] {
        case "export":
            guard let data = ConfigStore.encoded(ConfigStore.load()), (try? data.write(to: url, options: .atomic)) != nil else { return fail("couldn't write \(words[1])") }
            return 0
        case "import":
            guard let data = try? Data(contentsOf: url), let config = try? JSONDecoder().decode(Config.self, from: data) else { return fail("\(words[1]) isn't a Zefra settings file") }
            return ConfigStore.save(config) ? 0 : fail("couldn't save the settings")
        default:
            return fail("config takes export or import")
        }
    }

    private static func helper(_ words: [String]) -> Int32 {
        switch words.first {
        case "status", nil:
            out(FileManager.default.fileExists(atPath: HelperInfo.plistPath) ? "Installed" : "Not installed")
            return 0
        case "install":
            do { try HelperInstaller.install() } catch { return fail(error.localizedDescription) }
            return 0
        case "uninstall":
            do { try HelperInstaller.uninstall() } catch { return fail(error.localizedDescription) }
            return 0
        default:
            return fail("helper takes status, install or uninstall")
        }
    }

    private static func mail(_ words: [String]) -> Int32 {
        guard words.first == "test" else { return fail("mail takes test") }
        let settings = ConfigStore.load().settings.mail
        var password = MailPassword.read(account: settings.username)
        var extra = ""
        #if DEBUG
        // End-to-end tests point this at a local server with a throwaway certificate.
        if let test = ProcessInfo.processInfo.environment["ZEFRA_TEST_MAIL_PASSWORD"] {
            password = test
            extra = "insecure\n"
        }
        #endif
        if let error = Mailer.send(settings: settings, password: password, subject: "Zefra test", body: Mailer.body("This is a test from Zefra."), extraConfig: extra) {
            return fail(error)
        }
        out("Sent.")
        return 0
    }
}

@main
enum Entry {
    @MainActor
    static func main() {
        if CLI.runIfCommand() { return }
        ZefraApp.main()
    }
}
