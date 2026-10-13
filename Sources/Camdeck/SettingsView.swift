import SwiftUI

struct SettingsView: View {
    @State private var launch = LaunchAtLogin()
    @AppStorage("showInMenuBar") private var showMenuBar = true

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
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear { launch.refresh() }
    }
}
