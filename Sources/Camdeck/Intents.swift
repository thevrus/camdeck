import AppIntents
import Foundation
import UVCKit

/// Shortcuts actions. Each one runs through the same command queue the URL scheme uses.
@MainActor
private func send(_ command: URLCommand) {
    URLCommandHandler.shared.enqueue(command)
}

struct ApplyPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Camdeck Preset"
    static let description = IntentDescription("Applies a saved camera preset by name, or by 1-based number.")

    @Parameter(title: "Preset Name")
    var name: String

    @MainActor
    func perform() async throws -> some IntentResult {
        send(.preset(name))
        return .result()
    }
}

struct ResetViewIntent: AppIntent {
    static let title: LocalizedStringResource = "Reset Camdeck View"
    static let description = IntentDescription("Resets zoom, pan and tilt.")

    @MainActor
    func perform() async throws -> some IntentResult {
        send(.resetView)
        return .result()
    }
}

struct ResetImageIntent: AppIntent {
    static let title: LocalizedStringResource = "Reset Camdeck Image"
    static let description = IntentDescription("Resets exposure, color and other image settings.")

    @MainActor
    func perform() async throws -> some IntentResult {
        send(.resetImage)
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
