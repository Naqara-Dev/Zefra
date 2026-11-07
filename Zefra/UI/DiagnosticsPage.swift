import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        let findings = model.runDiagnostics() + model.fanTestFindings
        return ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                PageHeader("Diagnostics", subtitle: "What's normal, what isn't, and what to do about it.") {
                    Button("Save Report…") { save(findings) }.buttonStyle(QuietButtonStyle())
                    Button(model.fanTestRunning ? "Testing fans…" : "Test Fans") { Task { await model.runFanTest() } }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(model.fanTestRunning || !model.canControlFans)
                        .opacity(model.canControlFans ? 1 : 0.4)
                        .help(model.canControlFans ? "Runs each fan at full speed for 10 seconds, then hands it back" : "Needs the fan helper")
                }
                VStack(alignment: .leading, spacing: 0) {
                    Hairline()
                    ForEach(findings) { finding in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Circle().fill(color(finding.level)).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(finding.title).font(.system(size: 13.5)).foregroundStyle(Theme.ink)
                                Text(finding.detail).font(.system(size: 12, weight: .light)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Text(finding.area).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                        }
                        .padding(.vertical, 11)
                        Hairline()
                    }
                }
                if !model.anomalies.isEmpty { hotOnItsOwn }
                if let drives = model.sample?.drives, !drives.isEmpty { driveDetail(drives) }
                if let battery = model.sample?.battery { batteryDetail(battery) }
            }
            .padding(.horizontal, 36).padding(.top, 44).padding(.bottom, 32)
        }
        .scrollIndicators(.never)
    }

    private func color(_ level: Finding.Level) -> Color {
        switch level {
        case .ok: Theme.mild
        case .note: Theme.tertiary
        case .warning: Theme.warm
        case .problem: Theme.danger
        }
    }

    private var hotOnItsOwn: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Running hot on its own")
            ForEach(model.anomalies) { anomaly in
                HStack(spacing: 14) {
                    Text(anomaly.name).font(.system(size: 13)).foregroundStyle(Theme.ink)
                    Text(model.text(anomaly.value)).font(.system(size: 13)).foregroundStyle(Theme.danger).monospacedDigit()
                    if let rest = anomaly.rest {
                        Text("Rest of the Mac \(model.text(rest))").font(.system(size: 12, weight: .light)).foregroundStyle(Theme.tertiary).monospacedDigit()
                    }
                    Spacer()
                    Button("It's Normal") { model.markNormal(anomaly) }
                        .buttonStyle(QuietButtonStyle())
                        .help(anomaly.reason == .learned ? "Forgets what this sensor usually reads and learns it again" : "Stops watching this sensor. You can undo this in Settings")
                }
            }
        }
    }

    private func driveDetail(_ drives: [DriveHealth]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Drives")
            Grid(alignment: .leading, horizontalSpacing: 40, verticalSpacing: 12) {
                ForEach(drives) { drive in
                    GridRow {
                        item(drive.isInternal ? "Internal" : "External", drive.name)
                        item("Temperature", model.text(drive.temperature))
                        item("Writes used", "\(drive.percentUsed)%")
                        item("Spare", "\(drive.availableSpare)%")
                        item("Hours on", "\(drive.powerOnHours)")
                        item("Forced shutdowns", "\(drive.unsafeShutdowns)")
                        item("Errors", "\(drive.mediaErrors)")
                    }
                }
            }
        }
    }

    private func batteryDetail(_ battery: BatteryInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Battery")
            Grid(alignment: .leading, horizontalSpacing: 40, verticalSpacing: 8) {
                GridRow {
                    item("Charge", "\(Int(battery.percent.rounded()))%")
                    item("Health", "\(Int(battery.health.rounded()))%")
                    item("Cycles", battery.designCycles > 0 ? "\(battery.cycles) of \(battery.designCycles)" : "\(battery.cycles)")
                    item("Temperature", model.text(battery.temperature))
                }
                GridRow {
                    item("Capacity", "\(Int(battery.maxCapacity)) of \(Int(battery.designCapacity)) mAh")
                    item("Voltage", String(format: "%.2f V", battery.volts))
                    item("Flow", String(format: "%.1f W", battery.watts))
                    item("Power", battery.onAdapter ? (battery.isCharging ? "Charging" : "Plugged in") : "On battery")
                }
            }
        }
    }

    private func item(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 14, weight: .light)).foregroundStyle(Theme.ink).monospacedDigit()
            Text(title).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
        }
    }

    private func save(_ findings: [Finding]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Zefra diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var raw = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &raw, &size, nil, 0)
        let model = String(decoding: raw.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let report = Diagnostics.report(findings, model: model, system: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)", date: .now)
        try? report.write(to: url, atomically: true, encoding: .utf8)
    }
}
