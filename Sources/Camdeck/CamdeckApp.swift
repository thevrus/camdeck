import AVFoundation
import SwiftUI

@main
struct CamdeckApp: App {
    @State private var cam = CameraController()
    private var effects: VideoEffects { .shared }
    @AppStorage("advancedControls") private var advanced = false
    @AppStorage("showInMenuBar") private var showMenuBar = true
    @State private var live = false

    /// Red dot on the Dock icon and a filled menu bar glyph while the camera is on.
    private func setLive(_ on: Bool) {
        live = on
        NSApp.dockTile.badgeLabel = on ? "●" : nil
    }

    var body: some Scene {
        Window("Camdeck", id: "main") {
            ContentView(cam: cam)
                .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.didStartRunningNotification)) { _ in setLive(true) }
                .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.didStopRunningNotification)) { _ in setLive(false) }
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
                FramingModeControls(cam: cam)
                Divider()
                Button("Save Preset") { cam.quickSavePreset() }
                    .keyboardShortcut("s")
                    .disabled(cam.presets == nil)
                PresetMenuItems(cam: cam, shortcuts: true)
                Divider()
                @Bindable var zebra = cam.zebra
                Toggle("Show Clipping", isOn: $zebra.isEnabled)
                Button("Reset All Settings…") { cam.confirmingReset = true }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(cam.currentDevice == nil)
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

        MenuBarExtra("Camdeck", systemImage: live ? "web.camera.fill" : "web.camera", isInserted: $showMenuBar) {
            @Bindable var cam = cam
            Picker("Camera", selection: Binding(get: { cam.selectedID }, set: { if let id = $0 { cam.select(id) } })) {
                ForEach(cam.cameras, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
            }
            Toggle("Mirror Preview", isOn: $cam.mirrored)
            Button("Reset View") { cam.resetView() }
            FramingModeControls(cam: cam)
            Divider()
            PresetMenuItems(cam: cam, shortcuts: false)
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

/// Center Stage toggle and auto framing modes, each hidden when the camera lacks it. Shared by the menus and the inspector.
struct FramingModeControls: View {
    @Bindable var cam: CameraController
    var body: some View {
        if cam.centerStageSupported {
            Toggle("Center Stage", isOn: Binding(get: { cam.centerStageEnabled }, set: { cam.setCenterStage($0) }))
                .help("Keeps you centered as you move. Done by the camera itself.")
        }
        if cam.canAutoFrame {
            Picker("Auto Framing", selection: $cam.autoFraming) {
                ForEach(AutoFramingMode.allCases) { Text($0.title).tag($0) }
            }
            .help("Keeps you in frame by zooming and reframing automatically. Close, Medium and Wide set how tight.")
        }
    }
}

/// Presets (first five on ⌘1…⌘5 in the main menu) plus the settings lock.
private struct PresetMenuItems: View {
    var cam: CameraController
    var shortcuts: Bool
    var body: some View {
        if let presets = cam.presets, !presets.items.isEmpty {
            ForEach(Array(presets.items.enumerated()), id: \.element.id) { i, p in
                Button(p.name) { presets.apply(p.id) }
                    .keyboardShortcut(shortcuts && i < 5 ? KeyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command) : nil)
            }
        }
        if let lock = cam.settingsLock {
            @Bindable var lock = lock
            Toggle("Keep These Settings", isOn: $lock.isEnabled)
        }
    }
}
