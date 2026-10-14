import SwiftUI

struct SettingsView: View {
    @State private var launch = LaunchAtLogin()
    @AppStorage("showInMenuBar") private var showMenuBar = true
    @AppStorage("globalHotkeys") private var globalHotkeys = false
    @AppStorage("showAllControls") private var showAll = false

    var body: some View {
        Form {
            Section {
                Toggle("Open at Login", isOn: Binding(get: { launch.isEnabled }, set: { launch.set($0) }))
                Toggle("Show in Menu Bar", isOn: $showMenuBar)
            } footer: {
                if let message = launch.errorMessage {
                    Text(message)
                } else {
                    Text("The menu bar item gives quick access to camera, mirror, and reset.")
                }
            }
            Section {
                Toggle("Global shortcuts", isOn: $globalHotkeys)
            } footer: {
                Text("Works in any app: ⌃⌥⌘1–5 apply presets 1–5, ⌃⌥⌘0 resets the view.")
            }
            Section {
                Toggle("Show All Controls", isOn: $showAll)
            } footer: {
                Text("Shows every setting your camera supports: manual exposure, color fine-tuning, device details and preset tools.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear { launch.refresh() }
    }
}
