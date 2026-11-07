import SwiftUI

struct OverviewPage: View {
    var model: AppModel
    @State private var minutes = 10

    private var unit: TemperatureUnit { model.config.settings.unit }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                hero
                chart
                fans
                vitals
                if !model.ruleLog.isEmpty { activity }
            }
            .padding(.horizontal, 36).padding(.top, 44).padding(.bottom, 32)
        }
        .scrollIndicators(.never)
    }

    private var hero: some View {
        let hottest = model.sample?.temps.hottest
        return HStack(alignment: .bottom, spacing: 40) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.text(hottest?.value))
                    .font(.system(size: 92, weight: .thin)).tracking(-4)
                    .foregroundStyle(Theme.heat(hottest?.value)).monospacedDigit()
                Text(hottest.map { "Hottest: \(model.name(ofSensor: $0.id))" } ?? "Reading sensors…")
                    .font(.system(size: 13, weight: .light)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            HStack(alignment: .bottom, spacing: 30) {
                reading("CPU", model.sample?.temps.value(of: .cpu))
                reading("GPU", model.sample?.temps.value(of: .group(.gpu)))
                reading("SSD", model.sample?.temps.value(of: .group(.storage)))
                reading("Battery", model.sample?.temps.value(of: .group(.battery)))
            }
            .padding(.bottom, 4)
        }
    }

    private func reading(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.text(value)).font(.system(size: 26, weight: .light)).tracking(-0.8).foregroundStyle(Theme.heat(value)).monospacedDigit()
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
        }
    }

    private var chart: some View {
        let count = Int(Double(minutes) * 60 / max(model.config.settings.interval, 0.5))
        let series = [
            ChartSeries(name: "CPU", values: model.history.recent("@cpu", count: count), tint: Theme.hot),
            ChartSeries(name: "GPU", values: model.history.recent("@gpu", count: count), tint: Theme.mild),
            ChartSeries(name: "SSD", values: model.history.recent("@storage", count: count), tint: Theme.cool),
            ChartSeries(name: "Battery", values: model.history.recent("@battery", count: count), tint: Theme.warm),
        ]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                ForEach(series) { line in
                    HStack(spacing: 6) {
                        Capsule().fill(line.tint).frame(width: 12, height: 2)
                        Text(line.name).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                }
                Spacer()
                Segments(options: [5, 10, 30, 60], selection: $minutes) { "\($0) min" }
            }
            LineChart(series: series, unit: unit).frame(height: 190)
        }
    }

    private var fans: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Fans").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Spacer()
                Text(model.activeProfile.name).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            }
            Hairline()
            if model.fans.isEmpty {
                Text("No fans found on this Mac.").font(.system(size: 13, weight: .light)).foregroundStyle(Theme.tertiary)
            }
            ForEach(model.fans, id: \.spec.index) { fan in
                let decision = model.decisions.first { $0.index == fan.spec.index }
                HStack(spacing: 18) {
                    Text(fan.name).font(.system(size: 13)).foregroundStyle(Theme.ink).frame(width: 110, alignment: .leading).lineLimit(1)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.line).frame(height: 3)
                            Capsule().fill(Theme.accent).frame(width: geometry.size.width * min(fan.rpm / max(fan.spec.maxRPM, 1), 1), height: 3)
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .frame(height: 18)
                    Text(fan.rpm < 1 ? "Stopped" : "\(Int(fan.rpm)) RPM").font(.system(size: 13)).foregroundStyle(Theme.ink).monospacedDigit()
                        .frame(width: 90, alignment: .trailing)
                    Text(decision?.reason.text ?? "").font(.system(size: 12, weight: .light)).foregroundStyle(Theme.tertiary)
                        .frame(width: 260, alignment: .leading).lineLimit(1)
                }
            }
        }
    }

    private var vitals: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This Mac").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            Hairline()
            HStack(spacing: 44) {
                vital("Using", model.sample?.systemWatts.map { "\(Int($0.rounded())) W" } ?? "–")
                vital("CPU load", model.sample?.cpuLoad.map { "\(Int($0.rounded()))%" } ?? "–")
                vital("Thermal", model.sample?.thermal.title ?? "–")
                if let battery = model.sample?.battery {
                    vital("Battery", "\(Int(battery.percent.rounded()))%")
                    vital("Health", "\(Int(battery.health.rounded()))%")
                    vital("Cycles", "\(battery.cycles)")
                }
                Spacer()
            }
        }
    }

    private func vital(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 17, weight: .light)).foregroundStyle(Theme.ink).monospacedDigit()
            Text(title).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rules, lately").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            Hairline()
            ForEach(model.ruleLog.prefix(5)) { entry in
                HStack {
                    Text(entry.text).font(.system(size: 12.5, weight: .light)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Text(entry.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                }
            }
        }
    }
}
