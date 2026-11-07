import SwiftUI

enum PlanKind: Hashable {
    case system, fixed, curve

    init(_ plan: FanPlan) {
        switch plan {
        case .system: self = .system
        case .fixed: self = .fixed
        case .curve: self = .curve
        }
    }

    var title: String {
        switch self {
        case .system: "macOS decides"
        case .fixed: "Set speed"
        case .curve: "Curve"
        }
    }
}

struct FansPage: View {
    @Bindable var model: AppModel
    @State private var renaming = false
    @State private var perFan = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                PageHeader("Fans", subtitle: "A profile says what the fans do. Rules can step in on top of it.")
                if model.showsHelperBanner { HelperBanner(model: model) }
                if let error = model.lastError {
                    Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.danger)
                }
                profiles
                plans
                now
            }
            .padding(.horizontal, 36).padding(.top, 44).padding(.bottom, 32)
        }
        .scrollIndicators(.never)
        .onAppear { perFan = !model.activeProfile.perFan.isEmpty }
        .onChange(of: model.config.activeProfile) {
            perFan = !model.activeProfile.perFan.isEmpty
            renaming = false
        }
    }

    private var profiles: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(model.config.profiles) { profile in
                    ProfileChip(profile: profile, isOn: model.config.activeProfile == profile.id,
                                isInForce: model.effectiveProfile == profile.id) { model.config.activeProfile = profile.id }
                        .zefraContextMenu {
                            [.item("Rename", icon: "pencil") {
                                model.config.activeProfile = profile.id
                                renaming = true
                             },
                             .item("Duplicate", icon: "plus.square.on.square") {
                                model.config.activeProfile = profile.id
                                model.addProfile()
                            },
                             .divider("delete"),
                             .item("Delete", icon: "trash", tint: Theme.danger) { model.deleteProfile(profile.id) }]
                        }
                }
                Button { model.addProfile() } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .light)).foregroundStyle(Theme.secondary)
                        .frame(width: 34, height: 34).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New profile, starting from this one")
                Spacer()
            }
            HStack(spacing: 10) {
                if renaming {
                    RenameField(current: model.activeProfile.name, placeholder: "Profile name") { name in
                        if !name.isEmpty { model.updateActiveProfile { $0.name = name } }
                    } close: {
                        renaming = false
                    }
                    .frame(width: 200)
                } else {
                    Button { renaming = true } label: {
                        Label("Rename", systemImage: "pencil").labelStyle(QuietLabelStyle())
                    }
                    .buttonStyle(QuietButtonStyle(tint: Theme.secondary))
                }
                MenuButton(minWidth: 180) {
                    ["sparkles", "moon", "wind", "snowflake", "tornado", "fan", "bolt", "leaf", "flame", "headphones", "gamecontroller", "desktopcomputer"].map { icon in
                        .item(icon.capitalized, icon: icon, isOn: model.activeProfile.icon == icon, id: "icon:\(icon)") { model.updateActiveProfile { $0.icon = icon } }
                    }
                } label: {
                    Label("Icon", systemImage: model.activeProfile.icon).labelStyle(QuietLabelStyle())
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 14).frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))
                }
                .fixedSize()
                if model.config.profiles.count > 1 {
                    Button("Delete") { model.deleteProfile(model.config.activeProfile) }.buttonStyle(QuietButtonStyle(tint: Theme.danger))
                }
                Spacer()
                if model.fans.count > 1 {
                    Toggle("A plan for each fan", isOn: Binding(get: { perFan }, set: { on in
                        perFan = on
                        model.updateActiveProfile { profile in
                            if on {
                                for fan in model.fans { profile.perFan[fan.spec.index] = profile.plan }
                            } else {
                                profile.perFan = [:]
                            }
                        }
                    }))
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
        }
    }

    @ViewBuilder private var plans: some View {
        if perFan {
            ForEach(model.fans, id: \.spec.index) { fan in
                PlanEditor(model: model, title: fan.name, plan: Binding(
                    get: { model.activeProfile.plan(forFan: fan.spec.index) },
                    set: { plan in model.updateActiveProfile { $0.perFan[fan.spec.index] = plan } }))
            }
        } else {
            PlanEditor(model: model, title: "Every fan", plan: Binding(
                get: { model.activeProfile.plan },
                set: { plan in model.updateActiveProfile { $0.plan = plan } }))
        }
    }

    private var now: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Right now")
            ForEach(model.fans, id: \.spec.index) { fan in
                FanRow(model: model, fan: fan)
            }
        }
    }
}

private struct ProfileChip: View {
    var profile: Profile
    var isOn: Bool
    var isInForce: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: profile.icon).font(.system(size: 12, weight: .light))
                Text(profile.name).font(.system(size: 13))
                if isInForce && !isOn {
                    Circle().fill(Theme.accent).frame(width: 5, height: 5).help("A rule has switched to this profile")
                }
            }
            .foregroundStyle(isOn ? Theme.window : hovering ? Theme.ink : Theme.secondary)
            .padding(.horizontal, 13).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(isOn ? Theme.ink : Theme.card.opacity(hovering ? 1 : 0.5)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Icon and word, with the icon a touch lighter than the word.
struct QuietLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon.font(.system(size: 12, weight: .light))
            configuration.title
        }
    }
}

struct HelperBanner: View {
    var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.helperInstalled ? "The fan helper isn't answering" : "Fan control is off")
                    .font(.system(size: 13.5)).foregroundStyle(Theme.ink)
                Text("You can plan everything here, but it won't reach the fans until the helper is installed. macOS asks for your password once.")
                    .font(.system(size: 12, weight: .light)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(model.helperWorking ? "Installing…" : model.helperInstalled ? "Reinstall" : "Install") { model.installHelper() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.helperWorking)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Hairline() }
        .overlay(alignment: .bottom) { Hairline() }
    }
}

private struct PlanEditor: View {
    @Bindable var model: AppModel
    var title: String
    @Binding var plan: FanPlan

    private var kind: Binding<PlanKind> {
        Binding(get: { PlanKind(plan) }, set: { new in
            guard new != PlanKind(plan) else { return }
            switch new {
            case .system: plan = .system
            case .fixed: plan = .fixed(percent: 40)
            case .curve:
                plan = .curve(Curve(source: .cpu, points: [
                    CurvePoint(temp: 55, percent: 0), CurvePoint(temp: 70, percent: 40), CurvePoint(temp: 85, percent: 100),
                ]))
            }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.system(size: 14)).foregroundStyle(Theme.ink)
                Spacer()
                Segments(options: [PlanKind.system, .fixed, .curve], selection: kind) { $0.title }
            }
            switch plan {
            case .system:
                Text("macOS runs the fans, and stops them when it's cool. Nothing is forced.")
                    .font(.system(size: 12.5, weight: .light)).foregroundStyle(Theme.tertiary)
            case .fixed(let percent):
                FixedEditor(percent: Binding(get: { percent }, set: { plan = .fixed(percent: $0) }), spec: model.fans.first?.spec)
            case .curve(let curve):
                CurveEditor(model: model, curve: Binding(get: { curve }, set: { plan = .curve($0) }))
            }
        }
    }
}

private struct FixedEditor: View {
    @Binding var percent: Double
    var spec: FanSpec?

    var body: some View {
        HStack(spacing: 14) {
            ThinSlider(value: $percent, range: 0...100)
            NumberBox(value: $percent, unit: "%", range: 0...100, width: 34)
            if let spec {
                Text("\(Int(spec.rpm(forPercent: percent))) RPM").font(.system(size: 12)).foregroundStyle(Theme.tertiary).monospacedDigit().frame(width: 74, alignment: .trailing)
            }
        }
    }
}

private struct FanRow: View {
    @Bindable var model: AppModel
    var fan: FanStatus
    @State private var renaming = false
    @State private var hovering = false

    var body: some View {
        let index = fan.spec.index
        let decision = model.decisions.first { $0.index == index }
        let byHand = Binding(get: { model.manual[index] != nil }, set: { on in
            model.manual[index] = on ? fan.spec.percent(forRPM: max(fan.rpm, fan.spec.minRPM)) : nil
        })
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Group {
                    if renaming {
                        RenameField(current: model.config.fanNames[index] ?? "", placeholder: "Fan \(index + 1)") { name in
                            model.config.fanNames[index] = name.isEmpty ? nil : name
                        } close: {
                            renaming = false
                        }
                    } else {
                        HStack(spacing: 6) {
                            Text(fan.name).font(.system(size: 13)).foregroundStyle(Theme.ink).lineLimit(1)
                            Button { renaming = true } label: {
                                Image(systemName: "pencil").font(.system(size: 11, weight: .light)).foregroundStyle(Theme.tertiary)
                                    .frame(width: 18, height: 18).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .opacity(hovering ? 1 : 0)
                            .help("Rename")
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .onHover { hovering = $0 }
                    }
                }
                .frame(width: 130)
                Text(fan.rpm < 1 ? "Stopped" : "\(Int(fan.rpm)) RPM").font(.system(size: 18, weight: .light)).foregroundStyle(Theme.ink).monospacedDigit().frame(width: 110, alignment: .leading)
                Text(decision?.reason.text ?? "").font(.system(size: 12, weight: .light)).foregroundStyle(Theme.tertiary).lineLimit(1)
                Spacer()
                Text("\(Int(fan.spec.minRPM))–\(Int(fan.spec.maxRPM))").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).monospacedDigit()
                Toggle("By hand", isOn: byHand).toggleStyle(.switch).controlSize(.mini).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            if let percent = model.manual[index] {
                HStack(spacing: 14) {
                    ThinSlider(value: Binding(get: { percent }, set: { model.manual[index] = $0 }), range: 0...100)
                    Text("\(Int(fan.spec.rpm(forPercent: percent))) RPM").font(.system(size: 12)).foregroundStyle(Theme.secondary).monospacedDigit().frame(width: 74, alignment: .trailing)
                }
            }
            Hairline()
        }
    }
}

/// Fan speed against temperature: drag a point, double-click to add one, right-click to remove one.
/// The marker shows where the source is right now.
struct CurveEditor: View {
    @Bindable var model: AppModel
    @Binding var curve: Curve
    @State private var dragging: Int?

    private let tempRange = 30.0...110.0
    private var unit: TemperatureUnit { model.config.settings.unit }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SourcePicker(model: model, source: $curve.source)
                    .frame(width: 240)
                Toggle("Stop below the first point", isOn: $curve.releasesBelowFirstPoint)
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .help("Below the first point the fan goes back to macOS, which can stop it. It takes \(Int(Curve.releaseBand))° of cooling past the point, so it doesn't flap.")
                Spacer()
                Text("Double-click to add. Right-click to remove.").font(.system(size: 11.5, weight: .light)).foregroundStyle(Theme.tertiary)
            }
            GeometryReader { geometry in
                canvas(in: geometry.size)
            }
            .frame(height: 230)
            HStack(spacing: 14) {
                ForEach(Array(curve.points.enumerated()), id: \.offset) { index, point in
                    HStack(spacing: 4) {
                        TempBox(celsius: Binding(get: { point.temp }, set: { value in update(index) { $0.temp = value } }), unit: unit)
                        Image(systemName: "arrow.right").font(.system(size: 9, weight: .light)).foregroundStyle(Theme.tertiary)
                        NumberBox(value: Binding(get: { point.percent }, set: { value in update(index) { $0.percent = value } }), unit: "%", range: 0...100, width: 28)
                    }
                }
            }
        }
    }

    private func update(_ index: Int, _ change: (inout CurvePoint) -> Void) {
        guard curve.points.indices.contains(index) else { return }
        change(&curve.points[index])
    }

    private func x(_ temp: Double, _ size: CGSize) -> CGFloat {
        (temp - tempRange.lowerBound) / (tempRange.upperBound - tempRange.lowerBound) * (size.width - 44) + 34
    }

    private func y(_ percent: Double, _ size: CGSize) -> CGFloat {
        (1 - percent / 100) * (size.height - 28) + 6
    }

    private func point(from location: CGPoint, _ size: CGSize) -> CurvePoint {
        let temp = (location.x - 34) / (size.width - 44) * (tempRange.upperBound - tempRange.lowerBound) + tempRange.lowerBound
        let percent = (1 - (location.y - 6) / (size.height - 28)) * 100
        return CurvePoint(temp: min(max(temp.rounded(), tempRange.lowerBound), tempRange.upperBound), percent: min(max(percent.rounded(), 0), 100))
    }

    private func canvas(in size: CGSize) -> some View {
        let points = curve.cleaned.points
        let current = model.sample?.temps.value(of: curve.source)
        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for percent in stride(from: 0.0, through: 100, by: 25) {
                    var line = Path()
                    line.move(to: CGPoint(x: 34, y: y(percent, size)))
                    line.addLine(to: CGPoint(x: size.width - 10, y: y(percent, size)))
                    context.stroke(line, with: .color(Theme.line), lineWidth: 1)
                    context.draw(context.resolve(Text("\(Int(percent))").font(.system(size: 10)).foregroundStyle(Theme.tertiary)),
                                 at: CGPoint(x: 26, y: y(percent, size)), anchor: .trailing)
                }
                for temp in stride(from: tempRange.lowerBound, through: tempRange.upperBound, by: 10) {
                    context.draw(context.resolve(Text(unit.text(temp)).font(.system(size: 10)).foregroundStyle(Theme.tertiary)),
                                 at: CGPoint(x: x(temp, size), y: size.height - 8))
                }
                guard let first = points.first, let last = points.last else { return }
                var path = Path()
                path.move(to: CGPoint(x: x(first.temp, size), y: y(first.percent, size)))
                for point in points.dropFirst() { path.addLine(to: CGPoint(x: x(point.temp, size), y: y(point.percent, size))) }
                path.addLine(to: CGPoint(x: x(tempRange.upperBound, size), y: y(last.percent, size)))
                context.stroke(path, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                // What's below the first point: either macOS, or the first point's speed held flat.
                var below = Path()
                below.move(to: CGPoint(x: x(tempRange.lowerBound, size), y: y(first.percent, size)))
                below.addLine(to: CGPoint(x: x(first.temp, size), y: y(first.percent, size)))
                context.stroke(below, with: .color(curve.releasesBelowFirstPoint ? Theme.tertiary : Theme.accent),
                               style: StrokeStyle(lineWidth: 1, dash: curve.releasesBelowFirstPoint ? [3, 4] : []))
                if let current, tempRange.contains(current) {
                    var mark = Path()
                    mark.move(to: CGPoint(x: x(current, size), y: 6))
                    mark.addLine(to: CGPoint(x: x(current, size), y: size.height - 22))
                    context.stroke(mark, with: .color(Theme.heat(current).opacity(0.7)), lineWidth: 1)
                }
            }
            // Empty space: double-click adds.
            Color.clear.contentShape(Rectangle())
                .gesture(SpatialTapGesture(count: 2).onEnded { tap in
                    curve.points.append(point(from: tap.location, size))
                    curve = curve.cleaned
                })
            ForEach(Array(curve.points.enumerated()), id: \.offset) { index, item in
                Circle().fill(dragging == index ? Theme.accent : Theme.ink)
                    .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 1.5))
                    .frame(width: 12, height: 12)
                    .contentShape(Circle().inset(by: -6))
                    .position(x: x(item.temp, size), y: y(item.percent, size))
                    .gesture(DragGesture(coordinateSpace: .named("curve")).onChanged { drag in
                        dragging = index
                        var moved = point(from: drag.location, size)
                        // A point stays between its neighbours, so dragging can't reorder them.
                        if index > 0 { moved.temp = max(moved.temp, curve.points[index - 1].temp + 1) }
                        if index + 1 < curve.points.count { moved.temp = min(moved.temp, curve.points[index + 1].temp - 1) }
                        curve.points[index] = moved
                    }.onEnded { _ in dragging = nil })
                    .zefraContextMenu {
                        curve.points.count > 2
                            ? [.item("Remove point", icon: "minus.circle", tint: Theme.danger) { curve.points.remove(at: index) }]
                            : []
                    }
            }
        }
        .coordinateSpace(name: "curve")
    }
}

/// Picks what a curve or rule watches.
struct SourcePicker: View {
    var model: AppModel
    @Binding var source: TempSource

    var body: some View {
        let value = model.sample?.temps.value(of: source)
        Dropdown(icon: "thermometer.medium", title: model.title(of: source), detail: nil, height: 32) {
            var entries: [DropdownEntry] = []
            @MainActor func add(_ option: TempSource) {
                entries.append(.item(model.title(of: option), detail: model.text(model.sample?.temps.value(of: option)), isOn: source == option,
                                     id: "source:\(option)") { source = option })
            }
            add(.hottest)
            add(.cpu)
            add(.cpuAverage)
            for group in SensorGroup.allCases where model.sample?.temps.value(of: .group(group)) != nil { add(.group(group)) }
            entries.append(.divider("one"))
            entries.append(.heading("One sensor"))
            for stat in model.movingSensors { add(.sensor(stat.id)) }
            return entries
        }
        .help(value.map { "Now \(model.text($0))" } ?? "")
    }
}
