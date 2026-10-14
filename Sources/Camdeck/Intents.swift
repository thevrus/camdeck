import AppIntents
import Foundation

/// Shortcuts actions. Each one forwards to the same `camdeck://` handler the URL scheme uses.
@MainActor
private func send(_ url: String) {
    guard let u = URL(string: url) else { return }
    URLCommandHandler.shared.handle([u])
}

struct ApplyPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Camdeck Preset"
    static let description = IntentDescription("Applies a saved camera preset by name, or by 1-based number.")

    @Parameter(title: "Preset Name")
    var name: String

    @MainActor
    func perform() async throws -> some IntentResult {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? name
        send("camdeck://preset/\(encoded)")
        return .result()
    }
}

struct ResetViewIntent: AppIntent {
    static let title: LocalizedStringResource = "Reset Camdeck View"
    static let description = IntentDescription("Resets zoom, pan and tilt.")

    @MainActor
    func perform() async throws -> some IntentResult {
        send("camdeck://reset-view")
        return .result()
    }
}

struct ResetImageIntent: AppIntent {
    static let title: LocalizedStringResource = "Reset Camdeck Image"
    static let description = IntentDescription("Resets exposure, color and other image settings.")

    @MainActor
    func perform() async throws -> some IntentResult {
        send("camdeck://reset-image")
        return .result()
    }
}

struct CamdeckShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ApplyPresetIntent(), phrases: ["Apply a preset in \(.applicationName)"],
                    shortTitle: "Apply Preset", systemImageName: "camera.filters")
        AppShortcut(intent: ResetViewIntent(), phrases: ["Reset the view in \(.applicationName)"],
                    shortTitle: "Reset View", systemImageName: "arrow.counterclockwise")
        AppShortcut(intent: ResetImageIntent(), phrases: ["Reset the image in \(.applicationName)"],
                    shortTitle: "Reset Image", systemImageName: "photo")
    }
}
