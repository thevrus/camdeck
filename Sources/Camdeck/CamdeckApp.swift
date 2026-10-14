import AVFoundation
import SwiftUI

@main
struct CamdeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var cam: CameraController
    private var effects: VideoEffects { .shared }
    @AppStorage("advancedControls") private var advanced = false
    @AppStorage("showInMenuBar") private var showMenuBar = true
    @State private var live = false

    init() {
        let c = CameraController()
        _cam = State(initialValue: c)
        URLCommandHandler.shared.cam = c
    }

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
            CommandGroup(after: .appInfo) { CheckForUpdatesButton() }
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
                Button("Reset Image & Color") { cam.resetImage() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(cam.currentDevice == nil)
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
            CheckForUpdatesButton()
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
    var footnotes = false
    var body: some View {
        if cam.centerStageSupported {
            Toggle("Center Stage", isOn: Binding(get: { cam.centerStageEnabled }, set: { cam.setCenterStage($0) }))
                .help("Keeps you centered as you move. Done by the camera itself.")
            if footnotes {
                Text("Apple's built-in tracking. The camera pans and zooms to keep you centered as you move.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        if cam.canAutoFrame {
            Picker("Auto Framing", selection: $cam.autoFraming) {
                ForEach(AutoFramingMode.allCases) { Text($0.title).tag($0) }
            }
            .help("Keeps you in frame by zooming and reframing automatically. Close, Medium and Wide set how tight.")
            if footnotes {
                Text("Crops and zooms to keep you in frame as you move. Close is tightest, Wide leaves the most room around you.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
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

/// Receives `camdeck://` URLs. SwiftUI onOpenURL would open a window; this does not.
/// URL scheme and global shortcuts. Both work with the main window closed.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkeys = GlobalHotkeys()
    private var hotkeysOn = false

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in URLCommandHandler.shared.handle(urls) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        syncHotkeys()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncHotkeys() }
        }
    }

    /// ⌃⌥⌘0 resets the view, ⌃⌥⌘1…5 apply presets 1–5 (same order as ⌘1…⌘5).
    private func syncHotkeys() {
        let on = UserDefaults.standard.bool(forKey: "globalHotkeys")
        guard on != hotkeysOn else { return }
        hotkeysOn = on
        guard on else { hotkeys.disable(); return }
        hotkeys.enable { index in
            guard let cam = URLCommandHandler.shared.cam else { return }
            if index == 0 { cam.resetView(); cam.showToast("View reset"); return }
            guard let presets = cam.presets, presets.items.indices.contains(index - 1) else { return }
            let p = presets.items[index - 1]
            presets.apply(p.id)
            cam.showToast(p.name)
        }
    }
}
