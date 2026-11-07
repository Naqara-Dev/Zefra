import Foundation
import Sparkle

/// In-place updates. Each one is checked against the public key in Info.plist, whoever serves it.
@MainActor
final class Updates {
    private let controller: SPUStandardUpdaterController

    init() {
        // Debug builds never go looking for updates.
        #if DEBUG
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        #else
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
    }

    var checksAutomatically: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Seconds between checks.
    var interval: TimeInterval {
        get { controller.updater.updateCheckInterval }
        set { controller.updater.updateCheckInterval = newValue }
    }

    func checkNow() { controller.checkForUpdates(nil) }
}
