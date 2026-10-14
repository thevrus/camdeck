import AppKit
import Foundation
import Observation

/// Keeps a camera's settings pinned against other apps (Zoom/Teams) overriding them.
///
/// Re-applies the locked snapshot (a) on attach, (b) when Camdeck becomes active, (c) when another app starts
/// using the camera: `cameraStartedElsewhere()` runs two drift checks (default +2 s and +6 s, since Zoom/Teams
/// write their own values shortly after opening the camera), each reading <= 11 standard controls. There is no
/// timer and no polling while idle. Never fights in-app edits: a pending `userDidChange()` debounce suppresses
/// all re-asserts, and zoom/pan/tilt are skipped while auto framing runs.
@MainActor @Observable
public final class SettingsLock {
    /// Drift-prone controls read by the drift check.
    public static let verifiedControlIDs = ["wb-auto", "wb-temp", "focus-auto", "ae-mode", "exposure",
                                            "brightness", "contrast", "saturation", "powerline"]

    public var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            defaults.set(isEnabled, forKey: enabledKey)
            if isEnabled { snapshot = capture(); saveSnapshot() } else { cancelEventChecks(); snapshot = nil; saveSnapshot() }
        }
    }
    public private(set) var lastReassert: Date?
    public private(set) var reassertCount = 0

    @ObservationIgnored private var snapshot: CameraSettings?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let enabledKey: String
    @ObservationIgnored private let snapshotKey: String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let eventDelays: [Duration]
    @ObservationIgnored private let minCheckGap: TimeInterval
    @ObservationIgnored private let capture: () -> CameraSettings
    @ObservationIgnored private let applySettings: (CameraSettings) -> Int
    @ObservationIgnored private let read: ([String]) async -> [String: [Int]]
    @ObservationIgnored private let write: (String, [Int]) -> Void
    /// Closure so auto framing (another feature) can veto zoom/pan/tilt handling.
    @ObservationIgnored public var isAutoFramingActive: () -> Bool
    @ObservationIgnored private var lastCheck: Date?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private(set) var eventChecks: Task<Void, Never>?
    /// Test hook: replaces the wall-clock wait for each camera-start check; gets that check's offset from the start event.
    @ObservationIgnored var eventSleep: ((Duration) async throws -> Void)?
    @ObservationIgnored private nonisolated(unsafe) var observer: NSObjectProtocol?

    /// - capture: current settings (CameraController.captureSettings).
    /// - apply: diff-apply, returns number of writes (CameraController.apply).
    /// - read: reads the given standard control ids from the device (one USB request each); missing = unreadable.
    /// - write: writes one standard control through the throttled setter (CameraController.set).
    public init(uniqueID: String, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
                debounce: Duration = .seconds(1), eventDelays: [Duration] = [.seconds(2), .seconds(6)], minCheckGap: TimeInterval = 10,
                observeAppActivation: Bool = true,
                capture: @escaping () -> CameraSettings, apply: @escaping (CameraSettings) -> Int,
                read: @escaping ([String]) async -> [String: [Int]], write: @escaping (String, [Int]) -> Void,
                isAutoFramingActive: @escaping () -> Bool = { false }) {
        self.defaults = defaults; self.now = now; self.debounce = debounce; self.eventDelays = eventDelays
        self.minCheckGap = minCheckGap; self.capture = capture; self.applySettings = apply; self.read = read
        self.write = write; self.isAutoFramingActive = isAutoFramingActive
        enabledKey = "settingsLock.enabled.\(uniqueID)"
        snapshotKey = "settingsLock.snapshot.\(uniqueID)"
        isEnabled = defaults.bool(forKey: enabledKey)
        if let d = defaults.data(forKey: snapshotKey) { snapshot = try? JSONDecoder().decode(CameraSettings.self, from: d) }
        if observeAppActivation {
            observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.appDidBecomeActive() }
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        eventChecks?.cancel(); debounceTask?.cancel()
    }

    // MARK: Hooks

    /// (a) Call after the camera attached / re-enumerated and its values were read.
    public func attached() {
        guard isEnabled else { return }
        guard let s = snapshot else { snapshot = capture(); saveSnapshot(); return }
        record(applySettings(filtered(s)))
    }

    /// Call whenever the user changes a control in Camdeck. Recaptures after the debounce.
    public func userDidChange() {
        guard isEnabled else { return }
        cancelEventChecks()
        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            self.snapshot = self.capture()
            self.saveSnapshot()
            self.debounceTask = nil
        }
    }

    /// (b) App became active: read every snapshot control (<= 20 requests), fix drift, then diff-apply the rest.
    public func appDidBecomeActive() async {
        guard isEnabled, let s = snapshot, debounceTask == nil else { return }
        lastCheck = now()
        let ids = Array(readableIDs(s, only: nil).prefix(20))
        var n = await fixDrift(s, ids: ids)
        guard isEnabled, debounceTask == nil else { record(n); return }
        n += applySettings(filtered(s))
        record(n)
    }

    /// (c) Another app started using the camera: schedules drift checks at each `eventDelays` offset from now
    /// (default +2 s, +6 s). They bypass `minCheckGap`. A newer start event replaces the pending ones; they are
    /// also cancelled on disable and `userDidChange()`.
    public func cameraStartedElsewhere() {
        guard isEnabled else { return }
        eventChecks?.cancel()
        let delays = eventDelays, sleep = eventSleep
        eventChecks = Task { [weak self] in
            let clock = ContinuousClock()
            let start = clock.now
            for d in delays {
                if let sleep { try? await sleep(d) } else { try? await clock.sleep(until: start + d) }
                guard !Task.isCancelled, let self else { return }
                await self.verify(force: true)
                guard !Task.isCancelled else { return }
            }
        }
    }

    /// Drift check: reads <= 11 controls, rewrites only the drifted ones. Safe to call often;
    /// calls closer than `minCheckGap` are ignored.
    public func verify() async { await verify(force: false) }

    /// `force` skips the `minCheckGap` throttle (used by the camera-start checks).
    func verify(force: Bool) async {
        guard isEnabled, let s = snapshot, debounceTask == nil else { return }
        let t = now()
        if !force, let last = lastCheck, t.timeIntervalSince(last) < minCheckGap { return }
        lastCheck = t
        let ids = readableIDs(s, only: Self.verifiedControlIDs + (isAutoFramingActive() ? [] : ["zoom", "pantilt"]))
        record(await fixDrift(s, ids: ids))
    }

    // MARK: Internals

    private func filtered(_ s: CameraSettings) -> CameraSettings { isAutoFramingActive() ? s.withoutView() : s }

    /// Ids present in the snapshot, minus controls that legitimately move on their own (auto modes) and view controls under auto framing.
    private func readableIDs(_ s: CameraSettings, only: [String]?) -> [String] {
        let aeAuto = s.value(of: "ae-mode")?.first.map(UVCControl.isAutoExposure) ?? false
        let wbAuto = s.value(of: "wb-auto")?.first.map { $0 != 0 } ?? false
        let afAuto = s.value(of: "focus-auto")?.first.map { $0 != 0 } ?? false
        var ids = Set(s.controls.keys)
        if s.zoom != nil { ids.insert("zoom") }
        if s.pan != nil, s.tilt != nil { ids.insert("pantilt") }
        if let only { ids.formIntersection(only) }
        if isAutoFramingActive() { ids.subtract(["zoom", "pantilt"]) }
        if aeAuto { ids.remove("exposure") }
        if wbAuto { ids.remove("wb-temp") }
        if afAuto { ids.remove("focus") }
        return ids.sorted()
    }

    private func fixDrift(_ s: CameraSettings, ids: [String]) async -> Int {
        guard !ids.isEmpty else { return 0 }
        let got = await read(ids)
        // A user edit during the read wins.
        guard isEnabled, debounceTask == nil else { return 0 }
        var n = 0
        for id in ids {
            guard let cur = got[id], let want = s.value(of: id), cur != want else { continue }
            write(id, want); n += 1
        }
        return n
    }

    private func record(_ writes: Int) {
        guard writes > 0 else { return }
        lastReassert = now()
        reassertCount += 1
    }

    private func saveSnapshot() {
        if let s = snapshot, let d = try? JSONEncoder().encode(s) { defaults.set(d, forKey: snapshotKey) }
        else { defaults.removeObject(forKey: snapshotKey) }
    }

    private func cancelEventChecks() { eventChecks?.cancel(); eventChecks = nil }
}
