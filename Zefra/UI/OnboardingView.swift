import AppKit
import SwiftUI

/// The first time Zefra opens: the one thing it can't do on its own, and the one time it asks.
struct OnboardingView: View {
    var model: AppModel

    private var done: Bool { model.canControlFans }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.window
            VStack(alignment: .leading, spacing: 26) {
                if let icon = NSImage(named: "AppIcon") {
                    Image(nsImage: icon).resizable().frame(width: 44, height: 44)
                }
                if done { finished } else { asking }
            }
            .frame(width: 470, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            WindowDragArea().frame(height: 28)
        }
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 30, weight: .light)).tracking(-0.8).foregroundStyle(Theme.ink)
            Text(detail).font(.system(size: 14, weight: .light)).foregroundStyle(Theme.secondary)
                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var asking: some View {
        VStack(alignment: .leading, spacing: 26) {
            heading("Let Zefra set your fans",
                    "Zefra reads temperatures on its own. To change a fan's speed it needs a small helper, and macOS asks for your password to install it. You only do this once.")
            VStack(alignment: .leading, spacing: 0) {
                promise("Only fan speed", "The helper can't change anything else.")
                promise("Only Zefra", "It refuses every other app.")
                promise("Never stuck", "If Zefra quits or crashes, the fans go back to macOS.")
                Hairline()
            }
            if let error = model.lastError {
                Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 16) {
                Button(model.helperWorking ? "Installing…" : model.lastError == nil ? "Install helper" : "Try again") { model.installHelper() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.helperWorking)
                Button("Not now") { model.finishOnboarding() }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    .disabled(model.helperWorking)
                    .help("You can install it later from Fans or Settings")
            }
        }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 26) {
            heading("Fan control is on", "Profiles and rules now reach the fans. You won't need to enter your password for this again.")
            Button("Get started") { model.finishOnboarding() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }

    private func promise(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Hairline()
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.ink).frame(width: 130, alignment: .leading)
                Text(detail).font(.system(size: 13, weight: .light)).foregroundStyle(Theme.secondary)
            }
            .padding(.vertical, 11)
        }
    }
}
