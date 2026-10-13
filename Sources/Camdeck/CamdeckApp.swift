import SwiftUI

@main
struct CamdeckApp: App {
    @State private var cam = CameraController()
    private var effects: VideoEffects { .shared }
    @AppStorage("advancedControls") private var advanced = false
    @AppStorage("showInMenuBar") private var showMenuBar = true

    var body: some Scene {
        Window("Camdeck", id: "main") {
            ContentView(cam: cam)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Camera") {
                @Bindable var cam = cam
                Button("Reset View") { cam.resetView() }
                    .keyboardShortcut("r")
                Toggle("Mirror Preview", isOn: $cam.mirrored)
                    .keyboardShortcut("m", modifiers: [.command, .option])
                Divider()
                Button("Zoom In") { cam.stepZoom(1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") { cam.stepZoom(-1) }
                    .keyboardShortcut("-", modifiers: .command)
                Divider()
                Toggle("Advanced Controls", isOn: $advanced)
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Divider()
                Button("Video Effects…") { effects.openSystemPanel() }
            }
            InspectorCommands()
        }

        Settings {
            SettingsView()
        }

        MenuBarExtra("Camdeck", systemImage: "web.camera", isInserted: $showMenuBar) {
            @Bindable var cam = cam
            Picker("Camera", selection: Binding(get: { cam.selectedID }, set: { if let id = $0 { cam.select(id) } })) {
                ForEach(cam.cameras, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
            }
            Toggle("Mirror Preview", isOn: $cam.mirrored)
            Button("Reset View") { cam.resetView() }
            Divider()
            Button("Video Effects…") { effects.openSystemPanel() }
            Divider()
            OpenMainWindowButton()
            Divider()
            Button("Quit Camdeck") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}

/// openWindow is a view environment value; read it from a View, not the App.
private struct OpenMainWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open Camdeck") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
