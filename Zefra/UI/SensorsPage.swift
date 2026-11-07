import SwiftUI

struct SensorsPage: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @State private var open: Set<SensorGroup> = [.cpuPerformance, .gpu]
    @State private var showQuiet = false
    @State private var showHidden = false
    @State private var selected: String?

    private func sensors(in group: SensorGroup) -> [SensorStats] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return model.stats.values.filter { stat in
            guard stat.group == group else { return false }
            if !showHidden, model.config.hiddenSensors.contains(stat.id) { return false }
            if !q.isEmpty { return model.name(ofSensor: stat.id).lowercased().contains(q) || stat.id.lowercased().contains(q) }
            // Most Macs report a lot of sensors that never change; they're noise until asked for.
            return showQuiet || stat.high - stat.low > 0.01 || stat.watched < 20
        }
        .sorted { $0.value == $1.value ? $0.id < $1.id : $0.value > $1.value }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader("Sensors", subtitle: "\(model.stats.count) on this Mac. Names come from what each part reports; rename any of them.") {
                Button("Forget highs and lows") { model.resetStats() }.buttonStyle(QuietButtonStyle())
            }
            .padding(.horizontal, 36).padding(.top, 44)
            HStack(spacing: 14) {
                SoftField("Search sensors", text: $query).frame(maxWidth: 280)
                Toggle("Not moving", isOn: $showQuiet).toggleStyle(.switch).controlSize(.mini)
                Toggle("Hidden", isOn: $showHidden).toggleStyle(.switch).controlSize(.mini)
                Spacer()
            }
            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            .padding(.horizontal, 36).padding(.top, 18).padding(.bottom, 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(SensorGroup.allCases) { group in
                        let items = sensors(in: group)
                        if !items.isEmpty { section(group, items) }
                    }
                }
                .padding(.horizontal, 36).padding(.bottom, 30)
            }
            .scrollIndicators(.never)
        }
    }

    private func section(_ group: SensorGroup, _ items: [SensorStats]) -> some View {
        let isOpen = open.contains(group) || !query.isEmpty
        let peak = items.map(\.value).max()
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if open.contains(group) { open.remove(group) } else { open.insert(group) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .medium)).foregroundStyle(Theme.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Text(group.title).font(.system(size: 14)).foregroundStyle(Theme.ink)
                    Text("\(items.count)").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    Spacer()
                    Sparkline(values: model.history.recent("@\(group.rawValue)", count: 150), tint: Theme.heat(peak)).frame(width: 90, height: 16)
                    Text(model.text(peak)).font(.system(size: 14)).foregroundStyle(Theme.heat(peak)).monospacedDigit().frame(width: 48, alignment: .trailing)
                }
                .padding(.vertical, 11).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Hairline()
            if isOpen {
                ForEach(items, id: \.id) { stat in
                    row(stat)
                    if selected == stat.id { detail(stat) }
                }
            }
        }
    }

    private func row(_ stat: SensorStats) -> some View {
        Button {
            selected = selected == stat.id ? nil : stat.id
        } label: {
            HStack(spacing: 12) {
                Text(model.name(ofSensor: stat.id)).font(.system(size: 12.5, weight: .light))
                    .foregroundStyle(model.config.hiddenSensors.contains(stat.id) ? Theme.tertiary : Theme.ink).lineLimit(1)
                Spacer()
                Sparkline(values: model.history.recent(stat.id, count: 90), tint: Theme.tertiary).frame(width: 70, height: 12)
                figure(model.text(stat.low), "low")
                figure(model.text(stat.high), "high")
                Text(model.text(stat.value)).font(.system(size: 12.5)).foregroundStyle(Theme.heat(stat.value)).monospacedDigit().frame(width: 48, alignment: .trailing)
            }
            .padding(.leading, 20).frame(height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func figure(_ value: String, _ help: String) -> some View {
        Text(value).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).monospacedDigit().frame(width: 36, alignment: .trailing).help(help)
    }

    private func detail(_ stat: SensorStats) -> some View {
        SensorDetail(model: model, stat: stat).padding(.leading, 20).padding(.vertical, 12)
    }
}

private struct SensorDetail: View {
    @Bindable var model: AppModel
    var stat: SensorStats
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LineChart(series: [ChartSeries(name: stat.id, values: model.history.recent(stat.id, count: 900), tint: Theme.heat(stat.value))],
                      unit: model.config.settings.unit).frame(height: 110)
            HStack(spacing: 10) {
                SoftField(stat.name, text: $name).frame(width: 220)
                    .onSubmit(saveName)
                    .onChange(of: name) { saveName() }
                Text(stat.id.replacingOccurrences(of: "smc:", with: "").replacingOccurrences(of: "hid:", with: ""))
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.tertiary)
                Spacer()
                Button(model.config.hiddenSensors.contains(stat.id) ? "Show" : "Hide") {
                    if model.config.hiddenSensors.contains(stat.id) { model.config.hiddenSensors.remove(stat.id) } else { model.config.hiddenSensors.insert(stat.id) }
                }
                .buttonStyle(QuietButtonStyle())
                Button("Alert…") { addAlert() }.buttonStyle(QuietButtonStyle())
                    .help("Make a rule that tells you when this sensor gets hot")
            }
        }
        .onAppear { name = model.config.sensorNames[stat.id] ?? "" }
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        model.config.sensorNames[stat.id] = trimmed.isEmpty ? nil : trimmed
    }

    private func addAlert() {
        let at = (max(stat.high, stat.value) + 5).rounded()
        model.saveRule(Rule(name: "\(model.name(ofSensor: stat.id)) is hot", source: .sensor(stat.id), onAt: at, onHold: 10, offAt: at - 8, offHold: 30,
                            action: .notifyOnly, notifyOn: true, sound: true))
        model.page = .rules
    }
}
