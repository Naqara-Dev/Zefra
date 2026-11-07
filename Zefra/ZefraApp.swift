import AppKit
import SwiftUI

struct ZefraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Zefra", id: "main") {
            RootView(model: model)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(scheme)
                .onAppear {
                    delegate.model = model
                    model.start()
                    debugHooks()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .sidebar) {
                ForEach(Array(Page.allCases.enumerated()), id: \.element) { index, page in
                    Button(page.title) { model.page = page }.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
            }
        }

        // The status item reports its visibility back through this binding every time it's updated, and
        // an @Observable write redraws even when the value is the same: only a real change may write.
        MenuBarExtra(isInserted: Binding(get: { model.config.settings.showInMenuBar }, set: { shown in
            if model.config.settings.showInMenuBar != shown { model.config.settings.showInMenuBar = shown }
        })) {
            MenuBarPanel(model: model)
                .preferredColorScheme(scheme)
                .onAppear { model.start() }
        } label: {
            MenuBarLabel(model: model)
                .task {
                    // The menu bar item exists before any window does, and the app can start hidden.
                    delegate.model = model
                    model.start()
                }
        }
        .menuBarExtraStyle(.window)
    }

    /// Lets a test look at the app without touching the desktop it's running on.
    private func debugHooks() {
        #if DEBUG
        let defaults = UserDefaults.standard
        if let tall = Optional(defaults.double(forKey: "ZefraTall")), tall > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let window = NSApp.windows.first(where: { $0.frame.width > 600 }) else { return }
                window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - tall, width: window.frame.width, height: tall), display: true)
            }
        }
        // `-ZefraDumpMenuBar path` and `-ZefraDumpPanel path` draw those two into a PNG.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            func write(_ image: NSImage?, _ path: String) {
                guard let image, let data = image.tiffRepresentation, let rep = NSBitmapImageRep(data: data),
                      let png = rep.representation(using: .png, properties: [:]) else { return }
                try? png.write(to: URL(fileURLWithPath: path))
            }
            if let path = defaults.string(forKey: "ZefraDumpMenuBar") {
                write(MenuBarLabel(model: model).rendered, path)
            }
            if let path = defaults.string(forKey: "ZefraDumpPanel") {
                let renderer = ImageRenderer(content: MenuBarPanel(model: model).environment(\.colorScheme, .dark))
                renderer.scale = 2
                write(renderer.nsImage, path)
            }
        }
        #endif
    }

    private var scheme: ColorScheme? {
        switch model.config.settings.appearance {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        model?.quitting()
    }

    /// With a menu bar item the app keeps working when its window closes, unless the bar item is off.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(model?.config.settings.showInMenuBar ?? true)
    }
}

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.onboardingOpen {
                OnboardingView(model: model)
            } else {
                content
            }
        }
        .background(FocusReset(page: model.page))
        .background(Theme.window)
        .ignoresSafeArea()
        .id(Theme.accentChoice)
        .tint(Theme.accent)
    }

    private var content: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
            Rectangle().fill(Theme.line).frame(width: 1)
            ZStack(alignment: .top) {
                Group {
                    switch model.page {
                    case .overview: OverviewPage(model: model)
                    case .sensors: SensorsPage(model: model)
                    case .fans: FansPage(model: model)
                    case .rules: RulesPage(model: model)
                    case .diagnostics: DiagnosticsPage(model: model)
                    case .settings: SettingsPage(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                WindowDragArea().frame(height: 28)
            }
            .background(Theme.window)
        }
    }
}

private struct Sidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ZStack { WindowDragArea() }.frame(height: 44)
            HStack(spacing: 9) {
                if let icon = NSImage(named: "AppIcon") {
                    Image(nsImage: icon).resizable().frame(width: 24, height: 24)
                }
                Text("Zefra").font(.system(size: 15)).tracking(-0.2).foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 12).padding(.bottom, 16)
            ForEach(Page.allCases) { page in
                SidebarRow(page: page, isOn: model.page == page) { model.page = page }
            }
            Spacer()
            footer
        }
        .padding(.horizontal, 10).padding(.bottom, 14)
        .frame(width: 190)
        .background(Theme.sidebar)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            let hottest = model.sample?.temps.value(of: .hottest)
            HStack {
                Text("Hottest").foregroundStyle(Theme.tertiary)
                Spacer()
                Text(model.text(hottest)).foregroundStyle(Theme.heat(hottest)).monospacedDigit()
            }
            ForEach(model.fans.prefix(4), id: \.spec.index) { fan in
                HStack {
                    Text(fan.name).foregroundStyle(Theme.tertiary).lineLimit(1)
                    Spacer()
                    Text(fan.rpm < 1 ? "Off" : "\(Int(fan.rpm))").foregroundStyle(Theme.secondary).monospacedDigit()
                }
            }
            if model.failsafe {
                Text("Too hot: macOS has the fans").foregroundStyle(Theme.danger)
            }
            if let first = model.anomalies.first {
                Button { model.page = .diagnostics } label: {
                    Text("\(first.name) is hot on its own").foregroundStyle(Theme.danger).multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 12)
    }
}

private struct SidebarRow: View {
    var page: Page
    var isOn: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.icon).font(.system(size: 13, weight: .light)).frame(width: 18)
                    .foregroundStyle(isOn ? Theme.accent : Theme.secondary)
                Text(page.title).font(.system(size: 13)).foregroundStyle(isOn ? Theme.ink : Theme.secondary)
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isOn ? Theme.card : hovering ? Theme.card.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// What sits in the menu bar, in the order and layout chosen in Settings. A menu bar item ignores
/// fonts and stacking, so anything but the plain row is drawn into an image.
struct MenuBarLabel: View {
    var model: AppModel

    var body: some View {
        let settings = model.config.settings
        if settings.menuBarLayout == .row, !settings.menuBarSmallText {
            HStack(spacing: 4) {
                ForEach(Array(settings.menuBar.enumerated()), id: \.offset) { _, item in
                    switch item {
                    case .icon: Image(systemName: settings.menuBarIcon.symbol)
                    default: Text(text(of: item)).monospacedDigit()
                    }
                }
            }
        } else if let image = rendered {
            Image(nsImage: image)
        } else {
            Image(systemName: model.config.settings.menuBarIcon.symbol)
        }
    }

    private func text(of item: MenuBarItem) -> String {
        switch item {
        case .icon: ""
        case .temperature(let source): model.text(model.sample?.temps.value(of: source))
        case .fan(let index):
            { (rpm: Double) in rpm < 1 ? "Off" : "\(Int(rpm))" }(model.fans.first { $0.spec.index == index }?.rpm ?? 0)
        case .power: model.sample?.systemWatts.map { "\(Int($0.rounded()))W" } ?? "–"
        }
    }

    /// "64°C / 48°C" above, "3129 RPM" below.
    private var twoLines: (top: String, bottom: String) {
        let settings = model.config.settings
        var temperatures: [String] = []
        var rpms: [String] = []
        var watts: String?
        for item in settings.menuBar {
            switch item {
            case .icon: break
            case .temperature(let source):
                guard let value = model.sample?.temps.value(of: source) else { continue }
                temperatures.append("\(Int(settings.unit.display(value).rounded()))\(settings.unit.symbol)")
            case .fan(let index):
                guard let fan = model.fans.first(where: { $0.spec.index == index }) else { continue }
                rpms.append(fan.rpm < 1 ? "Off" : "\(Int(fan.rpm))")
            case .power: watts = text(of: .power)
            }
        }
        // Stopped is normal when it's cool, and "Off RPM" isn't a thing anyone would say.
        var bottom = rpms.isEmpty ? "" : rpms.allSatisfy { $0 == "Off" } ? "Fans off" : rpms.joined(separator: " / ") + " RPM"
        if let watts { bottom += bottom.isEmpty ? watts : " · " + watts }
        return (temperatures.joined(separator: " / "), bottom)
    }

    /// The label as a template image, so macOS tints it for a light or dark menu bar.
    var rendered: NSImage? {
        let settings = model.config.settings
        if settings.menuBarLayout == .twoLines {
            let lines = twoLines
            let view = HStack(spacing: 5) {
                if settings.menuBar.contains(.icon) { Image(systemName: settings.menuBarIcon.symbol).font(.system(size: 15, weight: .light)) }
                VStack(alignment: .leading, spacing: -1) {
                    if !lines.top.isEmpty { Text(lines.top) }
                    if !lines.bottom.isEmpty { Text(lines.bottom) }
                }
            }
            .font(.system(size: 10, weight: .medium)).monospacedDigit()
            .foregroundStyle(.black)
            .frame(height: 22)
            let renderer = ImageRenderer(content: view)
            renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
            let image = renderer.nsImage
            image?.isTemplate = true
            return image
        }
        let values = settings.menuBar.filter { $0 != .icon }.map(text)
        let hasIcon = settings.menuBar.contains(.icon)
        let size: CGFloat = settings.menuBarLayout == .stacked ? 9.5 : 11
        let view = HStack(spacing: 4) {
            if hasIcon { Image(systemName: settings.menuBarIcon.symbol).font(.system(size: 13)) }
            if settings.menuBarLayout == .stacked {
                // Pairs, one above the other.
                HStack(spacing: 5) {
                    ForEach(Array(stride(from: 0, to: values.count, by: 2)), id: \.self) { start in
                        VStack(alignment: .trailing, spacing: -1) {
                            ForEach(values[start..<min(start + 2, values.count)], id: \.self) { Text($0) }
                        }
                    }
                }
            } else {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in Text(value) }
            }
        }
        .font(.system(size: size, weight: .medium)).monospacedDigit()
        .foregroundStyle(.black)
        .frame(height: 22)
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage
        image?.isTemplate = true
        return image
    }
}

/// The panel under the menu bar item.
struct MenuBarPanel: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    private let sources: [TempSource] = [.cpu, .group(.gpu), .group(.soc), .group(.storage), .group(.battery)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let first = model.anomalies.first {
                Text("\(first.name) is hot on its own: \(model.text(first.value))")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                Hairline()
            }
            if model.config.settings.panelFansOnTop {
                fans
                Hairline()
                temperatures
            } else {
                temperatures
                Hairline()
                fans
            }
            Hairline()
            profiles
            Hairline()
            HStack {
                Button("Open Zefra") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Theme.ink)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(16)
        .frame(width: 290)
        .background(Theme.window)
    }

    private var temperatures: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                let hottest = model.sample?.temps.value(of: .hottest)
                Text(model.text(hottest)).font(.system(size: 34, weight: .light)).tracking(-1).foregroundStyle(Theme.heat(hottest)).monospacedDigit()
                Text("hottest").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                Spacer()
                if let watts = model.sample?.systemWatts {
                    Text("\(Int(watts.rounded())) W").font(.system(size: 12)).foregroundStyle(Theme.secondary).monospacedDigit()
                }
            }
            VStack(spacing: 5) {
                ForEach(sources, id: \.self) { source in
                    if let value = model.sample?.temps.value(of: source) {
                        row(model.title(of: source), model.text(value), Theme.heat(value))
                    }
                }
            }
        }
    }

    private var fans: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Fans").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                Spacer()
                Button(model.boosting ? "Stop Max" : "Max") { model.toggleBoost() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(model.boosting ? Theme.accent : Theme.secondary)
                    .disabled(!model.canControlFans)
                    .help(model.canControlFans ? "Every fan at full speed until you stop it" : "Needs the fan helper, in Settings")
            }
            ForEach(model.fans, id: \.spec.index) { fan in
                let index = fan.spec.index
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        Text(fan.name).foregroundStyle(Theme.secondary)
                        Spacer()
                        Text(fan.rpm < 1 ? "Off" : "\(Int(fan.rpm)) RPM").foregroundStyle(Theme.ink).monospacedDigit()
                        Toggle("", isOn: Binding(get: { model.manual[index] != nil }, set: { on in
                            model.manual[index] = on ? fan.spec.percent(forRPM: max(fan.rpm, fan.spec.minRPM)) : nil
                        }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini).disabled(!model.canControlFans)
                        .help("Set this fan by hand")
                    }
                    .font(.system(size: 12.5))
                    if let percent = model.manual[index] {
                        ThinSlider(value: Binding(get: { percent }, set: { model.manual[index] = $0 }), range: 0...100)
                    }
                }
            }
        }
    }

    private var profiles: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.config.profiles) { profile in
                Button {
                    model.config.activeProfile = profile.id
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: profile.icon).font(.system(size: 11.5, weight: .light)).frame(width: 16).foregroundStyle(Theme.secondary)
                        Text(profile.name).font(.system(size: 12.5)).foregroundStyle(Theme.ink)
                        Spacer()
                        if model.config.activeProfile == profile.id {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.accent)
                        }
                    }
                    .frame(height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func row(_ title: String, _ value: String, _ tint: Color) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.secondary)
            Spacer()
            Text(value).foregroundStyle(tint).monospacedDigit()
        }
        .font(.system(size: 12.5))
    }
}
