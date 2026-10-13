import Sparkle
import SwiftUI

/// Sparkle auto-update. Feed URL and public key live in Info.plist (scripts/bundle.sh).
@MainActor
final class Updater {
    static let shared = Updater()
    let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
}

struct CheckForUpdatesButton: View {
    var body: some View {
        Button("Check for Updates…") { Updater.shared.controller.checkForUpdates(nil) }
    }
}
