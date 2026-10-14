import AppKit
import OSLog
import UVCKit

/// Runs `camdeck://` commands against the camera controller, without needing the window.
@MainActor
final class URLCommandHandler {
    static let shared = URLCommandHandler()
    /// Set once by CamdeckApp.
    var cam: CameraController?
    private static let log = Logger(subsystem: "app.camdeck", category: "url")

    /// Commands run one at a time, in arrival order, so a camera switch finishes before the next command.
    private var queue: Task<Void, Never>?

    func handle(_ urls: [URL]) {
        for url in urls {
            guard let parsed = URLCommand.parse(url) else {
                Self.log.error("Ignoring unrecognized URL: \(url.absoluteString, privacy: .public)")
                continue
            }
            let previous = queue
            queue = Task { await previous?.value; await run(parsed.command, camera: parsed.camera) }
        }
    }

    private func run(_ command: URLCommand, camera: String?) async {
        guard let cam else { return }
        cam.start() // idempotent; the window may never have appeared
        var target = camera
        if case .camera(let name) = command { target = name }
        if let target, !(await selectCamera(target, on: cam)) {
            return fail(cam, "Camera not found: \(target)")
        }
        switch command {
        case .camera:
            cam.showToast(cam.currentDevice?.localizedName ?? "Camera selected")
        case .resetView:
            guard await waitForCamera(cam) else { return fail(cam, "No camera available") }
            cam.resetView()
            cam.showToast("View reset")
        case .resetImage:
            guard await waitForCamera(cam) else { return fail(cam, "No camera available") }
            cam.resetImage()
        case .reset:
            guard await waitForCamera(cam) else { return fail(cam, "No camera available") }
            cam.restoreDefaults()
        case .lock(let on):
            guard await waitForCamera(cam), let lock = cam.settingsLock else { return fail(cam, "No camera available") }
            lock.isEnabled = on
            cam.showToast(on ? "Settings locked" : "Settings unlocked")
        case .preset(let name):
            guard await waitForCamera(cam), let store = cam.presets else { return fail(cam, "No camera available") }
            guard let preset = Self.match(name, in: store.items) else { return fail(cam, "No preset named \(name)") }
            store.apply(preset.id)
            cam.showToast("Applied \(preset.name)")
        }
    }

    /// Case-insensitive name first, then a 1-based index when the text is numeric.
    private static func match(_ name: String, in items: [Preset]) -> Preset? {
        if let p = items.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return p }
        if let i = Int(name), items.indices.contains(i - 1) { return items[i - 1] }
        return nil
    }

    private func selectCamera(_ query: String, on cam: CameraController) async -> Bool {
        // Cameras may not be enumerated yet right after launch.
        let deadline = ContinuousClock.now + .seconds(3)
        while true {
            let list = cam.cameras
            let found = list.first { $0.localizedName.caseInsensitiveCompare(query) == .orderedSame }
                ?? list.first { $0.uniqueID == query }
            if let found {
                if cam.selectedID != found.uniqueID { cam.select(found.uniqueID) }
                return await waitForCamera(cam)
            }
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Waits up to ~3 s for the selected camera to attach (presets and lock exist once it has).
    private func waitForCamera(_ cam: CameraController) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while cam.currentDevice == nil || cam.presets == nil {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    private func fail(_ cam: CameraController, _ message: String) {
        Self.log.error("\(message, privacy: .public)")
        cam.showToast(message)
    }
}
