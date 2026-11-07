import SwiftUI

struct RulesPage: View {
    @Bindable var model: AppModel
    @State private var editing: Rule?
    @State private var tryTemp = 70.0
    @State private var trySource = TempSource.cpu

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                PageHeader("Rules", subtitle: "\"At this temperature do this, at that temperature stop.\" Fans take the fastest thing anyone asks for.") {
                    MenuButton(minWidth: 240, alignRight: true) {
                        [.item("Fans up when hot", icon: "fan") { editing = Self.fansUp() },
                         .item("Tell me when hot", icon: "bell") { editing = Self.alert() },
                         .item("Switch profile when hot", icon: "arrow.triangle.swap") { editing = self.switchProfile() },
                         .item("Quiet at night", icon: "moon") { editing = self.night() }]
                    } label: {
                        Text("New rule").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.window)
                            .padding(.horizontal, 14).frame(height: 32)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.ink))
                    }
                    .fixedSize()
                }
                if model.showsHelperBanner { HelperBanner(model: model) }
                list
                tryIt
            }
            .padding(.horizontal, 36).padding(.top, 44).padding(.bottom, 32)
        }
        .scrollIndicators(.never)
        #if DEBUG
        // `-ZefraOpenRule YES` opens the editor on the first rule, for screenshots.
        .onAppear {
            if UserDefaults.standard.bool(forKey: "ZefraOpenRule") { editing = model.config.rules.first { if case .setFans = $0.action { true } else { false } } }
        }
        #endif
        .sheet(item: $editing) { rule in
            RuleEditor(model: model, rule: rule) { saved in model.saveRule(saved) }
        }
    }

    private static func fansUp() -> Rule {
        Rule(name: "Fans up when hot", source: .cpu, onAt: 80, onHold: 5, offAt: 65, offHold: 30, action: .setFans(percent: 80, fans: nil))
    }

    private static func alert() -> Rule {
        Rule(name: "Tell me when hot", source: .hottest, onAt: 90, onHold: 10, offAt: 80, offHold: 30, action: .notifyOnly, notifyOn: true, sound: true)
    }

    private func switchProfile() -> Rule {
        let target = model.config.profiles.first { $0.name == "Cool" } ?? model.config.profiles[0]
        return Rule(name: "Cool down when hot", source: .cpu, onAt: 75, onHold: 10, offAt: 60, offHold: 60, action: .switchProfile(target.id))
    }

    private func night() -> Rule {
        let target = model.config.profiles.first { $0.name == "Quiet" } ?? model.config.profiles[0]
        return Rule(name: "Quiet at night", source: .cpu, direction: .falls, onAt: 95, onHold: 0, offAt: 100, offHold: 0,
                    window: DailyWindow(from: 22 * 60, to: 7 * 60), action: .switchProfile(target.id))
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Hairline()
            if model.config.rules.isEmpty {
                Text("No rules yet.").font(.system(size: 13, weight: .light)).foregroundStyle(Theme.tertiary).padding(.vertical, 18)
            }
            ForEach($model.config.rules) { $rule in
                RuleRow(model: model, rule: $rule) { editing = rule }
                    .zefraContextMenu {
                        [.item("Edit", icon: "pencil") { editing = rule },
                         .item("Duplicate", icon: "plus.square.on.square") { model.duplicateRule(rule) },
                         .divider("move"),
                         .item("Move Up", icon: "arrow.up") { model.moveRule(rule, by: -1) },
                         .item("Move Down", icon: "arrow.down") { model.moveRule(rule, by: 1) },
                         .divider("delete"),
                         .item("Delete", icon: "trash", tint: Theme.danger) { model.config.rules.removeAll { $0.id == rule.id } }]
                    }
                Hairline()
            }
        }
    }

    private var tryIt: some View {
        let unit = model.config.settings.unit
        let results = model.preview(temp: tryTemp, source: trySource)
        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Try it")
            HStack(spacing: 14) {
                Text("If").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                SourcePicker(model: model, source: $trySource).frame(width: 200)
                Text("stayed at").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                ThinSlider(value: $tryTemp, range: 30...105).frame(maxWidth: 300)
                Text(unit.text(tryTemp)).font(.system(size: 22, weight: .light)).foregroundStyle(Theme.heat(tryTemp)).monospacedDigit().frame(width: 60, alignment: .leading)
                Spacer()
            }
            ForEach(results, id: \.index) { result in
                HStack(spacing: 14) {
                    Text(model.fanName(result.index)).font(.system(size: 13)).foregroundStyle(Theme.ink).frame(width: 110, alignment: .leading)
                    Text(result.rpm.map { "\(Int($0)) RPM" } ?? "macOS").font(.system(size: 13)).foregroundStyle(Theme.ink).monospacedDigit().frame(width: 90, alignment: .leading)
                    Text(result.reason.text).font(.system(size: 12, weight: .light)).foregroundStyle(Theme.tertiary)
                    Spacer()
                }
            }
        }
    }
}

private struct RuleRow: View {
    @Bindable var model: AppModel
    @Binding var rule: Rule
    var edit: () -> Void
    @State private var hovering = false

    private var sentence: String {
        let unit = model.config.settings.unit
        let source = model.title(of: rule.source)
        let word = rule.direction == .rises ? "above" : "below"
        let endWord = rule.direction == .rises ? "below" : "above"
        return "\(source) \(word) \(unit.text(rule.onAt)) for \(Int(rule.onHold)) s: \(RuleWords.action(rule.action, model: model)). Until \(endWord) \(unit.text(rule.offAt)) for \(Int(rule.offHold)) s."
    }

    private var state: (String, Color)? {
        guard rule.enabled else { return nil }
        let runtime = model.runtime(of: rule)
        if runtime.active { return ("Running", Theme.accent) }
        if runtime.pendingSince != nil { return ("Waiting out the hold", Theme.warm) }
        return nil
    }

    var body: some View {
        HStack(spacing: 14) {
            Toggle("", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            Button(action: edit) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(rule.name).font(.system(size: 13.5)).foregroundStyle(rule.enabled ? Theme.ink : Theme.tertiary)
                            if let state { Text(state.0).font(.system(size: 11.5)).foregroundStyle(state.1) }
                            if !rule.hasValidBand { Text("Its end crosses its start").font(.system(size: 11.5)).foregroundStyle(Theme.danger) }
                        }
                        Text(sentence).font(.system(size: 12, weight: .light)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let value = model.sample?.temps.value(of: rule.source) {
                        Text(model.text(value)).font(.system(size: 13)).foregroundStyle(Theme.heat(value)).monospacedDigit()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                model.config.rules.removeAll { $0.id == rule.id }
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .light)).foregroundStyle(Theme.tertiary).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Delete this rule")
        }
        .padding(.vertical, 11)
        .onHover { hovering = $0 }
    }
}

enum RuleWords {
    @MainActor static func action(_ action: RuleAction, model: AppModel) -> String {
        switch action {
        case .setFans(let percent, let fans):
            let who = fans.map { list in list.map(model.fanName).joined(separator: ", ") } ?? "fans"
            return "\(who) at \(Int(percent))%"
        case .switchProfile(let id):
            return "switch to \(model.config.profiles.first { $0.id == id }?.name ?? "a deleted profile")"
        case .notifyOnly:
            return "just tell me"
        }
    }
}

/// A rule, written out as what it does.
private struct RuleEditor: View {
    @Bindable var model: AppModel
    @State var rule: Rule
    var save: (Rule) -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Kind: Hashable { case fans, profile, notify }

    private var unit: TemperatureUnit { model.config.settings.unit }

    private var kind: Binding<Kind> {
        Binding(get: {
            switch rule.action {
            case .setFans: .fans
            case .switchProfile: .profile
            case .notifyOnly: .notify
            }
        }, set: { new in
            switch new {
            case .fans: rule.action = .setFans(percent: 80, fans: nil)
            case .profile: rule.action = .switchProfile(model.config.profiles[0].id)
            case .notify:
                rule.action = .notifyOnly
                rule.notifyOn = true
            }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SoftField("Name", text: $rule.name)
            VStack(alignment: .leading, spacing: 12) {
                label("Watch")
                HStack(spacing: 10) {
                    SourcePicker(model: model, source: $rule.source).frame(width: 240)
                    Segments(options: [RuleDirection.rises, .falls], selection: $rule.direction) { $0 == .rises ? "Getting hot" : "Cooling down" }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                label("Starts")
                HStack(spacing: 8) {
                    Text(rule.direction == .rises ? "At or above" : "At or below").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    TempBox(celsius: $rule.onAt, unit: unit)
                    Text("for").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    NumberBox(value: $rule.onHold, unit: "s", range: 0...3600, width: 34)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                label("Ends")
                HStack(spacing: 8) {
                    Text(rule.direction == .rises ? "At or below" : "At or above").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    TempBox(celsius: $rule.offAt, unit: unit)
                    Text("for").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    NumberBox(value: $rule.offHold, unit: "s", range: 0...3600, width: 34)
                    if !rule.hasValidBand {
                        Text(rule.direction == .rises ? "Must be below where it starts" : "Must be above where it starts")
                            .font(.system(size: 12)).foregroundStyle(Theme.danger)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                label("Does")
                Segments(options: [Kind.fans, .profile, .notify], selection: kind) {
                    switch $0 {
                    case .fans: "Set fan speed"
                    case .profile: "Switch profile"
                    case .notify: "Only tell me"
                    }
                }
                action
            }
            VStack(alignment: .leading, spacing: 12) {
                label("Only when")
                HStack(spacing: 10) {
                    Dropdown(title: rule.power.title, height: 32) {
                        PowerCondition.allCases.map { option in
                            .item(option.title, isOn: rule.power == option, id: option.rawValue) { rule.power = option }
                        }
                    }
                    .frame(width: 220)
                    Toggle("Between", isOn: Binding(get: { rule.window != nil }, set: { rule.window = $0 ? DailyWindow(from: 22 * 60, to: 7 * 60) : nil }))
                        .toggleStyle(.switch).controlSize(.mini).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    if let window = rule.window {
                        TimeBox(minute: Binding(get: { window.from }, set: { rule.window?.from = $0 }))
                        Text("and").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        TimeBox(minute: Binding(get: { window.to }, set: { rule.window?.to = $0 }))
                    }
                }
            }
            HStack(spacing: 18) {
                Toggle("Notify when it starts", isOn: $rule.notifyOn).toggleStyle(.switch).controlSize(.mini)
                Toggle("When it ends", isOn: $rule.notifyOff).toggleStyle(.switch).controlSize(.mini)
                Toggle("With a sound", isOn: $rule.sound).toggleStyle(.switch).controlSize(.mini)
                Toggle("Email", isOn: $rule.email).toggleStyle(.switch).controlSize(.mini)
                    .help("Sends an email when it starts, if email is set up in Settings")
            }
            .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(rule)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                .disabled(!rule.hasValidBand || rule.name.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(rule.hasValidBand ? 1 : 0.4)
            }
        }
        .padding(24)
        .frame(width: 640)
        .background(Theme.window)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
    }

    @ViewBuilder private var action: some View {
        switch rule.action {
        case .setFans(let percent, let fans):
            HStack(spacing: 12) {
                Dropdown(title: fans.map { $0.map(model.fanName).joined(separator: ", ") } ?? "Every fan", height: 32) {
                    var entries: [DropdownEntry] = [.item("Every fan", isOn: fans == nil, id: "all") { rule.action = .setFans(percent: percent, fans: nil) }]
                    for fan in model.fans {
                        entries.append(.item(fan.name, isOn: fans == [fan.spec.index], id: "fan\(fan.spec.index)") {
                            rule.action = .setFans(percent: percent, fans: [fan.spec.index])
                        })
                    }
                    return entries
                }
                .frame(width: 160)
                ThinSlider(value: Binding(get: { percent }, set: { rule.action = .setFans(percent: $0, fans: fans) }), range: 0...100)
                NumberBox(value: Binding(get: { percent }, set: { rule.action = .setFans(percent: $0, fans: fans) }), unit: "%", range: 0...100, width: 34)
            }
        case .switchProfile(let id):
            Dropdown(icon: model.config.profiles.first { $0.id == id }?.icon, title: model.config.profiles.first { $0.id == id }?.name ?? "Pick a profile", height: 32) {
                model.config.profiles.map { profile in
                    .item(profile.name, icon: profile.icon, isOn: profile.id == id, id: profile.id.uuidString) { rule.action = .switchProfile(profile.id) }
                }
            }
            .frame(width: 240)
        case .notifyOnly:
            EmptyView()
        }
    }
}

/// A time of day, as hours and minutes.
private struct TimeBox: View {
    @Binding var minute: Int

    var body: some View {
        DatePicker("", selection: Binding(get: {
            Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now) ?? .now
        }, set: { date in
            minute = Calendar.current.component(.hour, from: date) * 60 + Calendar.current.component(.minute, from: date)
        }), displayedComponents: .hourAndMinute)
        .labelsHidden()
        .datePickerStyle(.stepperField)
        .fixedSize()
    }
}
