import AVFoundation
import AppKit
import Observation

/// System video effects (Portrait, Studio Light, Edge Light, Background). macOS exposes them
/// read-only; the only action is opening Control Center's Video Effects panel.
@Observable @MainActor
final class VideoEffects {
    struct Item: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let on: Bool
    }

    static let shared = VideoEffects()

    private(set) var items: [Item] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []

    private init() {
        refresh()
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh(); self?.startPolling() }
        })
        tokens.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stopPolling() }
        })
        if NSApplication.shared.isActive { startPolling() }
    }

    /// Control Center panel may change flags while we are frontmost; cheap to poll, no KVO on class props.
    private func startPolling() {
        stopPolling()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    private func stopPolling() { timer?.invalidate(); timer = nil }

    func refresh() {
        var out: [Item] = []
        if #available(macOS 12, *) {
            out.append(Item(id: "portrait", title: "Portrait", symbol: "person.crop.rectangle", on: AVCaptureDevice.isPortraitEffectEnabled))
        }
        if #available(macOS 13, *) {
            out.append(Item(id: "studio", title: "Studio Light", symbol: "lamp.desk", on: AVCaptureDevice.isStudioLightEnabled))
        }
        if #available(macOS 26.2, *) {
            out.append(Item(id: "edge", title: "Edge Light", symbol: "rectangle.inset.filled", on: AVCaptureDevice.isEdgeLightEnabled))
        }
        if #available(macOS 15, *) {
            out.append(Item(id: "background", title: "Background", symbol: "photo.on.rectangle", on: AVCaptureDevice.isBackgroundReplacementEnabled))
        }
        if out.map(\.on) != items.map(\.on) || out.count != items.count { items = out }
    }

    func openSystemPanel() {
        if #available(macOS 12, *) { AVCaptureDevice.showSystemUserInterface(.videoEffects) }
    }
}
