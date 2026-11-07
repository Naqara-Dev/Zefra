import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsPage: View {
    @Bindable var model: AppModel
    @State private var accent = Theme.accentChoice

    private var settings: Binding<Settings> { $model.config.settings }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                PageHeader("Settings")
                section("Look") {
                    row("Temperature") { Segments(options: TemperatureUnit.allCases, selection: settings.unit) { $0.symbol } }
                    row("Appearance") { Segments(options: AppearanceChoice.allCases, selection: settings.appearance) { $0.title } }
                    row("Accent") {
                        HStack(spacing: 8) {
                            ForEach(Theme.Accent.allCases) { option in
                                Button {
                                    Theme.accentChoice = option
                                    accent = option
                                    // Anything that reads it draws again.
                                    model.page = .settings
                                } label: {
                                    Circle().fill(option.color).frame(width: 16, height: 16)
                                        .overlay(Circle().strokeBorder(Theme.ink, lineWidth: accent == option ? 1.5 : 0).padding(-3))
                                        .frame(width: 24, height: 24).contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .help(option.title)
                            }
                        }
                    }
                }
                section("Menu bar") {
                    row("Show in the menu bar") { Toggle("", isOn: settings.showInMenuBar).labelsHidden().toggleStyle(.switch).controlSize(.mini) }
                    if model.config.settings.showInMenuBar {
                        menuBarItems
                        row("Layout") {
                            Segments(options: MenuBarLayout.allCases, selection: Binding(get: { model.config.settings.menuBarLayout }, set: { layout in
                                if layout == .twoLines, model.config.settings.menuBarLayout != .twoLines {
                                    model.config.settings.useTwoLines(hasGPU: model.sample?.temps.value(of: .group(.gpu)) != nil, firstFan: model.fans.first?.spec.index)
                                } else {
                                    model.config.settings.menuBarLayout = layout
                                }
                            })) { $0.title }
                        }
                        row("Icon") { Segments(options: MenuBarIcon.allCases, selection: settings.menuBarIcon) { $0.title } }
                        if model.config.settings.menuBarLayout == .row {
                            row("Smaller text") { Toggle("", isOn: settings.menuBarSmallText).labelsHidden().toggleStyle(.switch).controlSize(.mini) }
                        }
                        row("Fan controls in the panel") {
                            Segments(options: [true, false], selection: settings.panelFansOnTop) { $0 ? "At the top" : "Below temperatures" }
                        }
                    }
                    row("Show in the Dock") {
                        Toggle("", isOn: Binding(get: { model.config.settings.showInDock }, set: {
                            model.config.settings.showInDock = $0
                            model.applyDockPolicy()
                        })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                    row("Open at login") {
                        Toggle("", isOn: Binding(get: { model.loginItemEnabled }, set: { model.setLoginItem($0) })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                }
                section("Keys") {
                    row("Show Zefra", note: "These work whichever app is in front.") { HotKeyField(key: settings.showWindowKey, taken: model.takenHotKeys.contains(.showWindow)) }
                    row("Fans to Max, and back") { HotKeyField(key: settings.toggleBoostKey, taken: model.takenHotKeys.contains(.toggleBoost)) }
                    row("Next profile") { HotKeyField(key: settings.nextProfileKey, taken: model.takenHotKeys.contains(.nextProfile)) }
                }
                section("Fans") {
                    row("Failsafe", note: "At this temperature every fan goes back to macOS, whatever a profile or rule says. It comes back after cooling \(Int(Engine.failsafeBand))°.") {
                        TempBox(celsius: Binding(get: { model.config.settings.failsafe }, set: { model.config.settings.failsafe = min(max($0, 60), FanGuard.highestFailsafe) }), unit: model.config.settings.unit)
                    }
                    row("Speeding up", note: "How fast fans may rise.") {
                        NumberBox(value: settings.rampUp, unit: "% / s", range: 1...100, width: 30)
                    }
                    row("Slowing down", note: "Slow is calmer: fans don't surge with every short burst of work.") {
                        NumberBox(value: settings.rampDown, unit: "% / s", range: 0.5...100, width: 30, decimals: 1)
                    }
                    row("Leave the fans to macOS during sleep") { Toggle("", isOn: settings.releaseDuringSleep).labelsHidden().toggleStyle(.switch).controlSize(.mini) }
                    helper
                }
                section("Alerts") {
                    row("Notifications") { Toggle("", isOn: settings.notifications).labelsHidden().toggleStyle(.switch).controlSize(.mini) }
                    row("Tell me about a forced shutdown or a crash") { Toggle("", isOn: settings.notifyAbnormalShutdown).labelsHidden().toggleStyle(.switch).controlSize(.mini) }
                    row("Tell me when the battery needs service") { Toggle("", isOn: settings.notifyBatteryService).labelsHidden().toggleStyle(.switch).controlSize(.mini) }
                    row("Tell me when a drive reports trouble") { Toggle("", isOn: settings.notifyDriveProblem).labelsHidden().toggleStyle(.switch).controlSize(.mini) }
                    row("Alert sound") {
                        HStack(spacing: 8) {
                            Dropdown(title: model.config.settings.alertSound ?? "System default", height: 32) {
                                var entries: [DropdownEntry] = [.item("System default", isOn: model.config.settings.alertSound == nil, id: "default") { model.config.settings.alertSound = nil }]
                                entries += AppModel.soundNames.map { name in
                                    .item(name, isOn: model.config.settings.alertSound == name, id: "sound:\(name)") {
                                        model.config.settings.alertSound = name
                                        model.playAlertSound()
                                    }
                                }
                                return entries
                            }
                            .frame(width: 180)
                            Button("Play") { model.playAlertSound() }.buttonStyle(QuietButtonStyle())
                        }
                    }
                    MailSection(model: model)
                }
                section("Smart detector") {
                    row("Watch for a part running hot on its own", note: "Learns what's usual on this Mac and warns when a battery, charger, drive or board sensor is out of line while the rest isn't. It all stays on this Mac. It can spot the heat, not the cause.") {
                        Toggle("", isOn: settings.detector.enabled).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                    if model.config.settings.detector.enabled {
                        row("Sensitivity", note: "How far above usual counts: \(Int(model.config.settings.detector.sensitivity.margin))°.") {
                            Segments(options: DetectorSensitivity.allCases, selection: settings.detector.sensitivity) { $0.title }
                        }
                        row("Wait before warning", note: "It has to stay out of line this long, so a passing spike says nothing.") {
                            NumberBox(value: settings.detector.holdSeconds, unit: "s", range: 10...1800, width: 38)
                        }
                        row("Notify me", note: "Also by email, if email is on above.") {
                            Toggle("", isOn: settings.detector.notify).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        }
                        if !model.config.settings.detector.ignored.isEmpty {
                            row("Not watching \(model.config.settings.detector.ignored.count) sensor\(model.config.settings.detector.ignored.count == 1 ? "" : "s")", note: "You said these are normal.") {
                                Button("Watch Again") { model.config.settings.detector.ignored = [] }.buttonStyle(QuietButtonStyle())
                            }
                        }
                        row("What it has learned", note: "It knows what's usual for \(model.detectorReady) of \(model.detectorWatched) sensors in the current conditions. This takes half an hour for each kind of use.") {
                            Button("Start Over") { model.forgetLearning() }.buttonStyle(QuietButtonStyle())
                        }
                    }
                }
                section("Readings") {
                    row("Read every", note: "1 to 60 seconds. Slower uses less power.") {
                        NumberBox(value: settings.interval, unit: "s", range: 1...60, width: 30)
                    }
                    row("Keep history for") {
                        Segments(options: [15, 60, 240], selection: settings.historyMinutes) { $0 < 60 ? "\($0) min" : "\($0 / 60) h" }
                    }
                    row("Write a log file", note: "Temperatures, fan speeds and power as CSV. Rows past an alert start with ALERT:.") {
                        Toggle("", isOn: settings.logging).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                    if model.config.settings.logging {
                        row("Every") { NumberBox(value: settings.logEverySeconds, unit: "s", range: 1...3600, width: 34) }
                        row("New file") { Segments(options: LogSchedule.allCases, selection: settings.logSchedule) { $0.title } }
                        if model.config.settings.logSchedule != .daily {
                            row("Date in the file's name") { Toggle("", isOn: settings.logDatedName).labelsHidden().toggleStyle(.switch).controlSize(.mini) }
                        }
                        row("Folder", note: model.logFolder.path) {
                            HStack(spacing: 8) {
                                Button("Choose…") { chooseLogFolder() }.buttonStyle(QuietButtonStyle())
                                Button("Show") {
                                    try? FileManager.default.createDirectory(at: model.logFolder, withIntermediateDirectories: true)
                                    NSWorkspace.shared.open(model.logFolder)
                                }
                                .buttonStyle(QuietButtonStyle())
                            }
                        }
                    }
                    row("History so far") {
                        Button("Export CSV…") { exportHistory() }.buttonStyle(QuietButtonStyle())
                    }
                }
                section("Updates") {
                    UpdatesSection(updates: model.updates)
                }
                section("Start over") {
                    row("Everything back to how it started", note: "Profiles, rules, names and settings.") {
                        Button("Reset") { model.config = .starter }.buttonStyle(QuietButtonStyle(tint: Theme.danger))
                    }
                }
            }
            .padding(.horizontal, 36).padding(.top, 44).padding(.bottom, 32)
        }
        .scrollIndicators(.never)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title)
            VStack(alignment: .leading, spacing: 14) { content() }
        }
    }

    private func row<Content: View>(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.ink)
                if let note {
                    Text(note).font(.system(size: 11.5, weight: .light)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 20)
            content()
        }
    }

    private var helper: some View {
        row("Fan helper", note: model.canControlFans ? "Running, version \(model.helperVersion ?? "?"). Lets Zefra set fan speeds." : model.helperInstalled ? "Installed, but not answering." : "Not installed. Reading temperatures doesn't need it.") {
            HStack(spacing: 10) {
                if model.helperInstalled {
                    Button("Remove") { model.uninstallHelper() }.buttonStyle(QuietButtonStyle(tint: Theme.danger))
                }
                Button(model.helperInstalled ? "Reinstall" : "Install") { model.installHelper() }.buttonStyle(QuietButtonStyle())
            }
        }
    }

    private var menuBarItems: some View {
        row("Shows", note: "In this order. Click one to remove it.") {
            HStack(spacing: 6) {
                ForEach(Array(model.config.settings.menuBar.enumerated()), id: \.offset) { index, item in
                    Button { model.config.settings.menuBar.remove(at: index) } label: {
                        Text(title(of: item)).font(.system(size: 12)).foregroundStyle(Theme.ink)
                            .padding(.horizontal, 9).frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.card))
                    }
                    .buttonStyle(.plain)
                }
                MenuButton(minWidth: 220, alignRight: true) { additions } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .light)).foregroundStyle(Theme.secondary).frame(width: 26, height: 26)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.line))
                }
                .fixedSize()
            }
        }
    }

    private func title(of item: MenuBarItem) -> String {
        switch item {
        case .icon: "Icon"
        case .temperature(let source): model.title(of: source)
        case .fan(let index): model.fanName(index)
        case .power: "Watts"
        }
    }

    private var additions: [DropdownEntry] {
        var options: [MenuBarItem] = [.icon, .temperature(.hottest), .temperature(.cpu)]
        for group in SensorGroup.allCases where model.sample?.temps.value(of: .group(group)) != nil { options.append(.temperature(.group(group))) }
        options += model.fans.map { .fan($0.spec.index) }
        options.append(.power)
        return options.map { option in
            .item(title(of: option), isOn: model.config.settings.menuBar.contains(option), id: "\(option)") {
                model.config.settings.menuBar.append(option)
            }
        }
    }

    private func chooseLogFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.logFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.config.settings.logFolder = url.path
    }

    private func exportHistory() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Zefra history.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? model.historyCSV().write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Records a key combination for a hot key. Click, press it; Escape cancels; the × clears it.
private struct HotKeyField: View {
    @Binding var key: HotKey?
    var taken: Bool
    @State private var recording = false
    @State private var monitor: Any?
    @State private var refused = false

    var body: some View {
        HStack(spacing: 6) {
            if taken { Text("Another app has this").font(.system(size: 11.5)).foregroundStyle(Theme.danger) }
            if refused { Text("Needs ⌘, ⌥ or ⌃").font(.system(size: 11.5)).foregroundStyle(Theme.warm) }
            Button(recording ? "Press keys…" : key?.label ?? "Set…") { recording ? stop() : start() }
                .buttonStyle(QuietButtonStyle(tint: recording ? Theme.accent : key == nil ? Theme.secondary : Theme.ink))
            if key != nil {
                Button { key = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .light)).foregroundStyle(Theme.tertiary).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        refused = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stop()
                return nil
            }
            if let hotKey = HotKeys.hotKey(from: event) {
                key = hotKey
                stop()
            } else {
                refused = true
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct MailSection: View {
    @Bindable var model: AppModel
    @State private var password = ""
    @State private var port = 587.0

    private var mail: Binding<MailSettings> { $model.config.settings.mail }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Email alerts").font(.system(size: 13)).foregroundStyle(Theme.ink)
                    Text("Shutdowns, batteries, drives, and any rule with Email on. The mail says which Mac and what happened; the password stays in your Keychain.")
                        .font(.system(size: 11.5, weight: .light)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 20)
                Toggle("", isOn: mail.enabled).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
            if model.config.settings.mail.enabled {
                HStack(spacing: 8) {
                    SoftField("Outgoing server", text: mail.host)
                    NumberBox(value: $port, unit: "port", range: 1...65535, width: 44)
                    Segments(options: MailSecurity.allCases, selection: mail.security) { $0.title }
                }
                HStack(spacing: 8) {
                    SoftField("User name", text: mail.username)
                    if model.config.settings.mail.usesPassword {
                        SecureField("", text: $password)
                            .textFieldStyle(.plain).font(.system(size: 13))
                            .overlay(alignment: .leading) {
                                if password.isEmpty { Text("Password").font(.system(size: 13)).foregroundStyle(Theme.tertiary).allowsHitTesting(false) }
                            }
                            .padding(.horizontal, 11).frame(height: 32)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))
                            .onChange(of: password) { MailPassword.save(password, account: model.config.settings.mail.username) }
                    }
                    Toggle("Needs a password", isOn: mail.usesPassword).toggleStyle(.switch).controlSize(.mini).font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize()
                }
                HStack(spacing: 8) {
                    SoftField("From", text: mail.from)
                    SoftField("To", text: mail.to)
                    Button(model.mailSending ? "Sending…" : "Send Test") { model.sendTestMail() }
                        .buttonStyle(QuietButtonStyle()).disabled(model.mailSending || !model.config.settings.mail.isComplete)
                }
                if let status = model.mailStatus {
                    Text(status).font(.system(size: 12)).foregroundStyle(status == "Sent." ? Theme.mild : Theme.danger).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear {
            port = Double(model.config.settings.mail.port)
            password = MailPassword.read(account: model.config.settings.mail.username) ?? ""
        }
        .onChange(of: port) { model.config.settings.mail.port = Int(port) }
        .onChange(of: model.config.settings.mail.security) { port = Double(model.config.settings.mail.security.defaultPort) }
    }
}

private struct UpdatesSection: View {
    var updates: Updates
    @State private var automatic = false
    @State private var interval = 86400.0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Check for updates").font(.system(size: 13)).foregroundStyle(Theme.ink)
                    Text("Asks before installing, and each update has to be signed by Naqara Dev.").font(.system(size: 11.5, weight: .light)).foregroundStyle(Theme.tertiary)
                }
                Spacer()
                Button("Check Now") { updates.checkNow() }.buttonStyle(QuietButtonStyle())
                Toggle("", isOn: $automatic).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
            if automatic {
                HStack {
                    Text("How often").font(.system(size: 13)).foregroundStyle(Theme.ink)
                    Spacer()
                    Segments(options: [3600.0, 86400.0, 604800.0, 2_592_000.0], selection: $interval) {
                        switch $0 {
                        case 3600: "Hourly"
                        case 86400: "Daily"
                        case 604800: "Weekly"
                        default: "Monthly"
                        }
                    }
                }
            }
        }
        .onAppear {
            automatic = updates.checksAutomatically
            interval = updates.interval
        }
        .onChange(of: automatic) { updates.checksAutomatically = automatic }
        .onChange(of: interval) { updates.interval = interval }
    }
}
