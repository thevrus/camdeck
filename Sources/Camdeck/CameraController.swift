import AVFoundation
import AppKit
import Observation
import UVCKit
import os

/// Reframe state of the current camera. `center` is in -1...1 of the travel available at the current zoom
/// (x + = view right, y + = view down). `travel` is that travel as a fraction of the 1x frame.
struct ReframeState: Equatable {
    var center: CGPoint
    var travel: CGVector
    /// False at zoom levels with no travel (e.g. Link 2C at 1x).
    var canMove: Bool { travel.dx > 0 || travel.dy > 0 }
}

@MainActor @Observable
final class CameraController {
    var cameras: [AVCaptureDevice] = []
    private(set) var selectedID: String?
    var formats: [FormatOption] = []
    var selectedFormatID: String?
    var states: [UVCControlState] = []
    var values: [String: [Int]] = [:]
    /// Profile controls this device supports, in profile order (UI surface).
    private(set) var profileControls: [ProfileControl] = []
    /// Wire values of the profile's controls, read once per attach.
    private var vendorValues: [String: Int] = [:]
    /// Current profile values in display units (EV in stops, toggle 0/1, picker option value).
    var profileValues: [String: Double] {
        return Dictionary(uniqueKeysWithValues: profileControls.compactMap { c in vendorValues[c.id].map { (c.id, c.displayValue($0)) } })
    }
    var mirrored = true
    var authorized: Bool? = nil
    var profile: DeviceProfile = .generic
    var hasUVC: Bool { uvc != nil }

    // MARK: Capabilities (ADR-001)
    /// Nil when the camera cannot reframe.
    private(set) var reframe: ReframeState?
    /// Name, serial, firmware, model. Nil until the camera is attached.
    private(set) var deviceInfo: DeviceInfo?
    /// Set when a USB 3 camera linked at USB 2 speed; read once per attach.
    private(set) var usbWarning: USBLinkWarning?
    /// Which driver provides each capability (diagnostics).
    private(set) var capabilityProviders: [String: String] = [:]
    // MARK: Presets, settings lock, zebra
    /// Named presets of the selected camera. Nil until a camera is attached.
    private(set) var presets: PresetStore?
    /// Re-asserts the user's settings when other apps change them. Off by default; nil until a camera is attached.
    private(set) var settingsLock: SettingsLock?
    /// Overexposure mask from the live frames; off by default.
    let zebra = ZebraAnalyzer()
    /// > 0 while the lock re-asserts its snapshot: those writes are not user edits.
    @ObservationIgnored private var quietWrites = 0
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    /// KVO on `isInUseByAnotherApplication` of the attached camera; replaced on every attach.
    @ObservationIgnored private var usage: NSKeyValueObservation?
    /// Observed: zoomFactorRange, zoomFactor and the auto framing UI depend on it.
    private var camera: CameraDevice?
    @ObservationIgnored private var pendingReframe: CGPoint?
    @ObservationIgnored private var lastReframeWrite = Date.distantPast
    @ObservationIgnored private var reframeFlushScheduled = false
    @ObservationIgnored private static let log = Logger(subsystem: "app.camdeck", category: "uvc-write")

    /// Zoom factor, 1.0 = widest. 1.0 when the camera has no zoom.
    var zoomFactor: Double {
        guard let z = camera?.zoom else { return 1 }
        return z.factor(fromRaw: value("zoom").first ?? z.rawRange.lowerBound)
    }
    var zoomFactorRange: ClosedRange<Double> { camera?.zoom?.factorRange ?? 1 ... 1 }
    /// Auto framing needs a camera that can zoom.
    var canAutoFrame: Bool { zoomFactorRange.upperBound > 1 }

    func setZoomFactor(_ f: Double) {
        guard let z = camera?.zoom else { return }
        set("zoom", [z.raw(fromFactor: f)]) // set() reports the user change
    }

    /// Tells the settings lock that the user changed something (never called for auto-framer or lock writes).
    private func userEdited() {
        if quietWrites == 0 { settingsLock?.userDidChange() }
    }

    private func quietly<T>(_ body: (CameraController) -> T) -> T {
        quietWrites += 1
        defer { quietWrites -= 1 }
        return body(self)
    }

    private var controlsByID: [String: UVCControl] { Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0.control) }) }

    // MARK: Auto-exposure readout

    /// "Auto: 1/60 s · gain 32" while auto exposure is on and the camera reports it; nil otherwise.
    private(set) var autoReadout: String?
    @ObservationIgnored private var readoutTask: Task<Void, Never>?
    private static let exposureEditIDs: Set<String> = ["ae-mode", "exposure", "gain", "backlight", "lowlight", "powerline"]

    /// Debounced (~0.5 s) one-shot refresh after an exposure-related edit. Never repeats on its own.
    private func scheduleAutoReadout() {
        readoutTask?.cancel()
        readoutTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.refreshAutoReadout()
        }
    }

    /// Reads the auto shutter and gain once. Standard exposure/gain first; Insta360-style profile shutter/iso otherwise.
    func refreshAutoReadout() async {
        guard let id = selectedID else { autoReadout = nil; return }
        var text: String?
        if state("exposure") != nil || state("gain") != nil {
            let r = await readStandard(["ae-mode", "exposure", "gain"])
            if let mode = r["ae-mode"]?.first, UVCControl.isAutoExposure(mode) {
                text = ExposureFormat.readout(
                    shutter: r["exposure"]?.first.flatMap { ExposureFormat.shutter(exposure100us: $0) },
                    gainLabel: r["gain"]?.first.map { "gain \($0)" })
            }
        } else if let pc = camera?.profileControls,
                  let ae = pc.controls.first(where: { $0.id == "aeMode" }) {
            let sh = pc.controls.first { $0.id == "shutter" }, iso = pc.controls.first { $0.id == "iso" }
            let r: [String: Int] = await withCheckedContinuation { k in
                io.async {
                    var out: [String: Int] = [:]
                    for c in [ae, sh, iso].compactMap({ $0 }) { if let v = try? pc.read(c) { out[c.id] = v } }
                    k.resume(returning: out)
                }
            }
            if r["aeMode"] == 2 {
                text = ExposureFormat.readout(
                    shutter: r["shutter"].flatMap { ExposureFormat.shutter(denominator: $0) },
                    gainLabel: r["iso"].map { "ISO \($0)" })
            }
        }
        guard selectedID == id else { return }
        autoReadout = text
    }

    func readStandard(_ ids: [String]) async -> [String: [Int]] {
        guard let dev = uvc else { return [:] }
        let controls = controlsByID
        let wanted = ids.compactMap { id in controls[id].map { (id, $0) } }
        return await withCheckedContinuation { k in
            io.async {
                var out: [String: [Int]] = [:]
                for (id, c) in wanted { if let v = try? dev.read(c) { out[id] = v } }
                k.resume(returning: out)
            }
        }
    }

    /// Replaces the preset store and lock for the camera that just attached.
    private func stopUsageMonitor() { usage?.invalidate(); usage = nil }

    private func attachPresetsAndLock(_ id: String) {
        let store = PresetStore(uniqueID: id, controller: self)
        let lock = SettingsLock(
            uniqueID: id, observeAppActivation: false,
            capture: { [weak self] in self?.captureSettings() ?? CameraSettings() },
            apply: { [weak self] s in self?.quietly { $0.apply(s) } ?? 0 },
            read: { [weak self] ids in await self?.readStandard(ids) ?? [:] },
            write: { [weak self] id, v in self?.quietly { $0.set(id, v) } },
            isAutoFramingActive: { [weak self] in self?.autoFraming != .off })
        store.onApplied = { [weak lock] in lock?.userDidChange() }
        presets = store
        settingsLock = lock
        stopUsageMonitor()
        // Another app (Zoom, Teams) started using the camera. Documented KVO-observable and excludes Camdeck's own
        // session, so this fires whether or not our preview is running. No polling.
        usage = currentDevice?.observe(\.isInUseByAnotherApplication, options: [.old, .new]) { [weak self, weak lock, weak store] _, change in
            guard change.newValue == true, change.oldValue != true else { return }
            Task { @MainActor in
                guard let lock else { return }
                guard let store, !store.appBindings.isEmpty else { lock.cameraStartedElsewhere(); return }
                // macOS does not say which app opened the camera: use the frontmost one if it is bound.
                let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
                let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                guard let preset = store.preset(forRunning: running, frontmost: front) else {
                    lock.cameraStartedElsewhere(); return
                }
                // Zoom/Teams write their own values right after opening; apply after they settle.
                try? await Task.sleep(for: .seconds(2))
                // The camera may have been switched meanwhile.
                guard self?.presets === store else { return }
                store.apply(preset.id)   // onApplied -> lock.userDidChange() recaptures the snapshot
                lock.cameraStartedElsewhere()
            }
        }
        if lock.isEnabled { lock.attached() } else { store.applyStartup() }
    }

    /// Brief confirmation shown over the preview; clears itself.
    private(set) var toast: String?
    private var toastTask: Task<Void, Never>?
    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    /// ⌘S: store the current look as a new preset.
    func quickSavePreset() {
        guard let presets else { return }
        let name = presets.defaultName
        _ = presets.save(name: name)
        showToast("Saved as \(name)")
    }

    /// Set by the menu and inspector; ContentView shows the confirmation.
    var confirmingReset = false

    /// Image settings before the last "Describe a look" request; nil when there is nothing to undo.
    var lookUndo: CameraSettings?

    /// Public "Reset all settings": natural format, image and exposure controls, framing and auto framing. Presets are kept.
    func restoreDefaults() {
        autoFraming = .off
        resetView()
        for id in ["exposure", "wb-temp", "focus"] { reset(id) }
        applyNaturalDefaults()
        showToast("Settings reset")
    }

    /// "Reset Image & Color": image, color and exposure back to defaults. Format, framing and presets are kept.
    func resetImage() {
        for id in ["exposure", "wb-temp", "focus"] { reset(id) }
        applyNaturalDefaults(includeFormat: false)
        showToast("Image reset")
    }

    /// Moves the view; writes are coalesced and throttled to <= 10 Hz. Counts as manual input.
    func setReframe(center: CGPoint) {
        framer.noteManualInput()
        applyReframe(center.clampedToUnitSquare)
        syncFramer()
        userEdited()
    }

    private func applyReframe(_ c: CGPoint) {
        guard var r = reframe else { return }
        r.center = c
        reframe = r
        pendingReframe = c
        scheduleReframeFlush()
    }

    private func scheduleReframeFlush() {
        guard !reframeFlushScheduled else { return }
        reframeFlushScheduled = true
        let wait = max(0, 0.1 - Date().timeIntervalSince(lastReframeWrite))
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(wait * 1000) + 1))
            self?.flushReframe()
        }
    }

    private func flushReframe() {
        reframeFlushScheduled = false
        guard let c = pendingReframe, let cap = camera?.reframe else { return }
        pendingReframe = nil
        lastReframeWrite = Date()
        let z = zoomFactor
        Self.log.debug("write reframe \(Double(c.x)) \(Double(c.y)) @\(z)x")
        io.async { do { try cap.write(c, zoomFactor: z) } catch { NSLog("reframe write failed: \(error)") } }
    }

    private func refreshReframeTravel() {
        guard var r = reframe, let cap = camera?.reframe else { return }
        r.travel = cap.travel.offset(atZoom: zoomFactor)
        if r != reframe { reframe = r }
    }

    /// Deprecated shim: on cameras whose CT pan/tilt is a no-op but which can reframe (Link 2C), the
    /// legacy "pantilt" control (FramingPad) is routed to Reframe, mapped piecewise so 0 stays center.
    private var panTiltRoutesToReframe: Bool { camera?.quirks.contains(.ctPanTiltIneffective) == true && reframe != nil }

    private func panTiltShimCenter(_ v: [Int]) -> CGPoint? {
        guard let st = state("pantilt"), let lo = st.min, let hi = st.max, lo.count == 2, hi.count == 2, v.count == 2,
              lo[0] <= hi[0], lo[1] <= hi[1] else { return nil }
        // UVC tilt is positive up; reframe y is positive down.
        return CGPoint(x: CTPanTiltReframe.fromRaw(v[0], lo[0] ... hi[0]), y: -CTPanTiltReframe.fromRaw(v[1], lo[1] ... hi[1])).clampedToUnitSquare
    }

    private func panTiltShimValue() -> [Int]? {
        guard panTiltRoutesToReframe, let c = reframe?.center, let st = state("pantilt"), let lo = st.min, let hi = st.max, lo.count == 2, hi.count == 2,
              lo[0] <= hi[0], lo[1] <= hi[1] else { return nil }
        return [CTPanTiltReframe.toRaw(Double(c.x), lo[0] ... hi[0]), CTPanTiltReframe.toRaw(-Double(c.y), lo[1] ... hi[1])]
    }

    // MARK: Auto framing surface
    var autoFraming: AutoFramingMode = AutoFramingMode(rawValue: UserDefaults.standard.string(forKey: "autoFramingMode") ?? "") ?? .off {
        didSet {
            UserDefaults.standard.set(autoFraming.rawValue, forKey: "autoFramingMode")
            framer.configure(mode: autoFraming.framing)
            if autoFraming == .off { isSubjectDetected = false; subjectBox = nil }
            updateSessionRunning()
        }
    }

    // MARK: Session lifetime
    /// True while the main window shows the preview. The capture session runs only while it is visible or auto
    /// framing needs frames, so a closed window leaves the camera off and other apps' camera use is detectable.
    var previewVisible = false { didSet { if oldValue != previewVisible { updateSessionRunning() } } }
    private var wantsSession: Bool { previewVisible || autoFraming != .off }

    private func updateSessionRunning() {
        let session = self.session, run = wantsSession && currentDevice != nil
        sessionQueue.async {
            if run, !session.isRunning { session.startRunning() }
            else if !run, session.isRunning { session.stopRunning() }
        }
    }
    // MARK: Center Stage (Continuity Camera / Apple cameras)
    // Apple's own framing. Apps get no zoom or image controls on an iPhone, so this is its auto framing.
    // Per-app setting; cooperative mode lets both Camdeck and Control Center change it.

    /// True when the selected camera can do Center Stage in some format.
    var centerStageSupported: Bool { currentDevice?.formats.contains { $0.isCenterStageSupported } ?? false }

    private(set) var centerStageEnabled = AVCaptureDevice.isCenterStageEnabled

    func setCenterStage(_ on: Bool) {
        if AVCaptureDevice.centerStageControlMode == .user { AVCaptureDevice.centerStageControlMode = .cooperative }
        AVCaptureDevice.isCenterStageEnabled = on
        syncCenterStage()
    }

    /// Re-read after selection or activation; Control Center can change it behind our back.
    private func syncCenterStage() {
        let v = AVCaptureDevice.isCenterStageEnabled
        if v != centerStageEnabled { centerStageEnabled = v }
    }

    private(set) var isSubjectDetected = false
    /// Subject box, normalized, top-left origin, in preview coordinates (mirrored when `mirrored`).
    private(set) var subjectBox: CGRect?
    @ObservationIgnored private let framer = AutoFramer()
    @ObservationIgnored private var framerAttached = false
    @ObservationIgnored private var lastAutoWrite = Date.distantPast

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private var uvc: UVCDevice?
    @ObservationIgnored private var monitor: UVCHotplugMonitor?
    @ObservationIgnored private let io = DispatchQueue(label: "app.camdeck.uvc")
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "app.camdeck.session")
    @ObservationIgnored private var pending: [String: [Int]] = [:]
    @ObservationIgnored private var pendingVendor: [String: Int] = [:]
    @ObservationIgnored private var rereads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var refreshWork: Task<Void, Never>?
    @ObservationIgnored private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor = UVCHotplugMonitor { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        for n in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            }
        }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.syncCenterStage()
                await self?.settingsLock?.appDidBecomeActive()
                await self?.refreshAutoReadout()
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorized = true; refresh()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                Task { @MainActor in self.authorized = ok; self.refresh() }
            }
        default: authorized = false
        }
    }

    // MARK: Cameras

    private func scheduleRefresh() {
        refreshWork?.cancel()
        refreshWork = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func refresh() {
        guard authorized == true else { return }
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        if selectedID == nil || !cameras.contains(where: { $0.uniqueID == selectedID }) {
            if selectedID == nil, let first = cameras.first { select(first.uniqueID) }
            return
        }
        // Same camera, possibly re-enumerated: rebuild the USB handle and restore the stream.
        // select() attaches the USB handle itself, so attach here only when it will not run.
        if !session.isRunning || session.inputs.isEmpty { select(selectedID!) }
        else {
            attachUVC()
            if let cam = currentDevice { formats = FormatOption.options(for: cam); syncFormat(cam) }
        }
    }

    var currentDevice: AVCaptureDevice? { cameras.first { $0.uniqueID == selectedID } }

    func select(_ id: String) {
        guard let cam = cameras.first(where: { $0.uniqueID == id }) else { return }
        selectedID = id
        let session = self.session
        let framer = self.framer, attachOutput = framerAttached, mode = autoFraming.framing, run = wantsSession
        framerAttached = true
        if !attachOutput {
            framer.zebra = zebra
            framer.onStep = { [weak self] box, cmd in self?.autoFramerStep(box, cmd) }
            zebra.onEnabledChange = { [sessionQueue, weak framer] in sessionQueue.async { framer?.updateConnection() } }
        }
        sessionQueue.async {
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            if let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) { session.addInput(input) }
            if !attachOutput, session.canAddOutput(framer.output) { session.addOutput(framer.output) }
            framer.configure(mode: mode)
            session.commitConfiguration()
            if run, !session.isRunning { session.startRunning() }
        }
        formats = FormatOption.options(for: cam)
        syncFormat(cam)
        syncCenterStage()
        attachUVC()
    }

    private func syncFormat(_ cam: AVCaptureDevice) {
        let d = CMVideoFormatDescriptionGetDimensions(cam.activeFormat.formatDescription)
        let fps = cam.activeVideoMinFrameDuration.seconds > 0 ? Int((1 / cam.activeVideoMinFrameDuration.seconds).rounded()) : 0
        selectedFormatID = formats.first { $0.width == Int(d.width) && $0.height == Int(d.height) && $0.fps == fps }?.id
            ?? formats.first { $0.width == Int(d.width) && $0.height == Int(d.height) }?.id
    }

    func selectFormat(_ id: String) {
        guard let opt = formats.first(where: { $0.id == id }), let cam = currentDevice else { return }
        selectedFormatID = id
        userEdited()
        let format = opt.format
        let t = Self.frameDuration(fps: opt.fps, in: format)
        // On the session queue, so it lands after any pending (re)configuration instead of being reset by it.
        sessionQueue.async {
            do {
                try cam.lockForConfiguration()
                cam.activeFormat = format
                if let t {
                    cam.activeVideoMinFrameDuration = t
                    cam.activeVideoMaxFrameDuration = t
                }
                cam.unlockForConfiguration()
            } catch { NSLog("format change failed: \(error)") }
        }
    }

    /// A frame duration AVFoundation accepts for `fps` in `format`. Discrete ranges must use the device's own
    /// CMTime: the Link 2C's "30 fps" is not exactly 1/30 s, and setting 1/30 throws an uncatchable ObjC exception.
    static func frameDuration(fps: Int, in format: AVCaptureDevice.Format) -> CMTime? {
        let f = Double(fps)
        guard let r = format.videoSupportedFrameRateRanges.first(where: { f >= $0.minFrameRate - 0.5 && f <= $0.maxFrameRate + 0.5 })
        else { return nil }
        if abs(r.maxFrameRate - f) < 0.5 { return r.minFrameDuration }
        if abs(r.minFrameRate - f) < 0.5 { return r.maxFrameDuration }
        let t = CMTime(value: 1, timescale: CMTimeScale(fps))
        return CMTimeClampToRange(t, range: CMTimeRange(start: r.minFrameDuration, end: r.maxFrameDuration))
    }

    // MARK: UVC

    /// Match AVCaptureDevice to USB: uniqueID ends with VID+PID hex (e.g. 0x1000002e1a4c03).
    private static func usbIDs(_ uniqueID: String) -> (UInt16, UInt16)? {
        guard uniqueID.hasPrefix("0x"), uniqueID.count >= 10 else { return nil }
        let t = uniqueID.suffix(8)
        guard let v = UInt16(t.prefix(4), radix: 16), let p = UInt16(t.suffix(4), radix: 16) else { return nil }
        return (v, p)
    }

    private func attachUVC() {
        uvc = nil; camera = nil; reframe = nil; deviceInfo = nil; usbWarning = nil; presets = nil; settingsLock = nil; stopUsageMonitor(); capabilityProviders = [:]; pendingReframe = nil
        states = []; values = [:]; vendorValues = [:]; profileControls = []; profile = .generic
        autoReadout = nil; readoutTask?.cancel(); lookUndo = nil
        pendingVendor = [:]; rereads.values.forEach { $0.cancel() }; rereads = [:]
        guard let id = selectedID, let (v, p) = Self.usbIDs(id) else { return }
        io.async { [weak self] in
            // Reads only: attaching never writes to the camera.
            let dev = UVCDevice(vendorID: v, productID: p)
            let cam = dev.map { DriverRegistry.standard.compose($0) }
            let s = cam?.imageControls?.readStates() ?? []
            let prof = cam?.profileControls?.profile ?? dev?.profile ?? .generic
            let supported = cam?.profileControls?.controls ?? []
            // One read per control, no polling: the vendor app crashed under fast XU polling.
            var vv: [String: Int] = [:]
            if let pc = cam?.profileControls { for c in supported { vv[c.id] = try? pc.read(c) } }
            let info = try? cam?.deviceInfo?.readInfo()
            let zRaw = s.first { $0.id == "zoom" }?.cur?.first
            let zf = cam?.zoom.map { z in z.factor(fromRaw: zRaw ?? z.rawRange.lowerBound) } ?? 1
            let center = cam?.reframe.flatMap { try? $0.read(zoomFactor: zf) }
            Task { @MainActor in
                guard let self, self.selectedID == id else { return }
                self.uvc = dev
                self.usbWarning = dev?.usbWarning
                self.camera = cam
                self.deviceInfo = info
                self.capabilityProviders = Dictionary(uniqueKeysWithValues: (cam?.plan.providers ?? [:]).map { ($0.key.rawValue, $0.value) })
                if let r = cam?.reframe { self.reframe = ReframeState(center: center ?? .zero, travel: r.travel.offset(atZoom: zf)) }
                self.framer.configureGeometry(travel: cam?.reframe?.travel)
                self.states = s
                self.values = Dictionary(uniqueKeysWithValues: s.compactMap { st in st.cur.map { (st.id, $0) } })
                self.profile = prof
                self.profileControls = supported
                self.vendorValues = vv
                self.syncFramer()
                self.applyNaturalDefaultsOnFirstAttach(id)
                self.attachPresetsAndLock(id)
                self.scheduleAutoReadout()
            }
        }
    }

    func state(_ id: String) -> UVCControlState? { states.first { $0.id == id } }

    private func snap(_ st: UVCControlState, _ v: [Int]) -> [Int] {
        v.enumerated().map { i, x in
            var x = x
            if let lo = st.min?[safe: i], let hi = st.max?[safe: i] {
                if let r = st.res?[safe: i], r > 1 { x = lo + Int((Double(x - lo) / Double(r)).rounded()) * r }
                x = Swift.min(Swift.max(x, lo), hi)
            }
            return x
        }
    }

    /// Optimistic UI update; the device write is coalesced to ~30 Hz.
    func set(_ id: String, _ v: [Int]) {
        guard let st = state(id) else { return }
        if id == "pantilt", panTiltRoutesToReframe, let c = panTiltShimCenter(snap(st, v)) {
            setReframe(center: c)
            return
        }
        let value = snap(st, v)
        guard values[id] != value else { return } // unchanged: no USB write
        values[id] = value
        pending[id] = value
        scheduleFlush()
        userEdited()
        if Self.exposureEditIDs.contains(id) { scheduleAutoReadout() }
        if id == "zoom" { refreshReframeTravel() }
        if ["zoom", "pantilt", "roll"].contains(id) { framer.noteManualInput(); syncFramer() }
    }

    // MARK: Auto framing

    /// Framing state in normalized units (ReframeUnits): zoom factor x 100, reframe offset in micro-frames.
    private var currentPTZ: PTZ {
        let z = zoomFactor
        var p = PTZ(zoom: Int((z * 100).rounded()), pan: 0, tilt: 0)
        if let r = reframe, let cap = camera?.reframe {
            let o = ReframeUnits.offset(center: r.center, travel: cap.travel, zoomFactor: z)
            p.pan = o.pan; p.tilt = o.tilt
        }
        return p
    }

    private func syncFramer() {
        let r: PTZRanges? = camera?.zoom == nil && camera?.reframe == nil ? nil : ReframeUnits.ranges(maxZoomFactor: zoomFactorRange.upperBound)
        framer.update(ptz: currentPTZ, ranges: r)
    }

    /// One processed frame. Writes zoom/pan/tilt at <= 10 Hz without counting as manual input.
    private func autoFramerStep(_ box: CGRect?, _ cmd: PTZ) {
        guard autoFraming != .off, camera?.zoom != nil || camera?.reframe != nil else { return }
        let detected = box != nil
        let newBox = box.map { b in mirrored ? CGRect(x: 1 - b.maxX, y: b.minY, width: b.width, height: b.height) : b }
        if detected != isSubjectDetected { isSubjectDetected = detected }
        if newBox != subjectBox { subjectBox = newBox }
        let cur = currentPTZ
        guard cmd != cur, Date().timeIntervalSince(lastAutoWrite) >= 0.1, uvc != nil else { return }
        lastAutoWrite = Date()
        let zf = Double(cmd.zoom) / 100
        if cmd.zoom != cur.zoom, let z = camera?.zoom, let st = state("zoom") {
            let v = snap(st, [z.raw(fromFactor: zf)]); values["zoom"] = v; pending["zoom"] = v
            refreshReframeTravel()
            scheduleFlush()
        }
        if (cmd.pan, cmd.tilt) != (cur.pan, cur.tilt), let cap = camera?.reframe {
            applyReframe(ReframeUnits.center(pan: cmd.pan, tilt: cmd.tilt, travel: cap.travel, zoomFactor: zf))
        }
        syncFramer()
    }

    private static let autoFirst = ["ae-mode", "wb-auto", "focus-auto"]

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(33))
            self?.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        let batch = pending; pending = [:]
        let vendorBatch = pendingVendor; pendingVendor = [:]
        guard let dev = uvc else { return }
        let controls = controlsByID
        let vendor = Dictionary(uniqueKeysWithValues: profileControls.map { ($0.id, $0) })
        let log = Self.log
        // Auto toggles first: a manual value written while its auto is still on is rejected by some cameras.
        let ordered = batch.sorted { a, b in
            let fa = Self.autoFirst.firstIndex(of: a.key) ?? Self.autoFirst.count, fb = Self.autoFirst.firstIndex(of: b.key) ?? Self.autoFirst.count
            return fa != fb ? fa < fb : a.key < b.key
        }
        io.async {
            for (id, v) in ordered {
                guard let c = controls[id] else { continue }
                log.debug("write \(id, privacy: .public) = \(v.description, privacy: .public)")
                do { try dev.write(c, v) } catch { log.error("write \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)") }
            }
            for (id, v) in vendorBatch {
                guard let c = vendor[id] else { continue }
                log.debug("write profile \(id, privacy: .public) = \(v)")
                do { try dev.writeProfile(c, wire: v) } catch { log.error("write \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)") }
            }
        }
        for id in vendorBatch.keys { scheduleReread(id) }
    }

    func value(_ id: String) -> [Int] {
        if id == "pantilt", let v = panTiltShimValue() { return v }
        return values[id] ?? state(id)?.def ?? [0]
    }
    func reset(_ id: String) { if let d = state(id)?.def { set(id, d) } }
    func resetView() {
        for id in ["zoom", "pantilt", "roll"] { reset(id) }
        if reframe != nil { setReframe(center: .zero) }
    }

    /// Zoom by one tenth of the minimum (same step as the +/- buttons in the framing pad).
    func stepZoom(_ dir: Int) {
        guard let z = state("zoom"), let lo = z.min?.first, let hi = z.max?.first else { return }
        let cur = value("zoom").first ?? lo
        set("zoom", [min(max(cur + dir * max(lo / 10, 1), lo), hi)])
    }

    /// Optimistic update; the write rides the same ~30 Hz coalescing as the standard controls.
    func setProfileValue(_ id: String, _ value: Double) {
        guard let c = profileControls.first(where: { $0.id == id }) else { return }
        setVendor(c, c.wire(fromDisplayValue: value))
    }

    private func setVendor(_ c: ProfileControl, _ wire: Int) {
        let v = c.normalize(wire)
        guard vendorValues[c.id] != v else { return } // unchanged: no USB write
        vendorValues[c.id] = v
        pendingVendor[c.id] = v
        scheduleFlush()
        userEdited()
        scheduleAutoReadout()
    }

    /// False while the control's `enabledWhen` is unmet or its value could not be read.
    func isProfileControlEnabled(_ id: String) -> Bool {
        guard let c = profileControls.first(where: { $0.id == id }) else { return false }
        return vendorValues[id] != nil && c.isEnabled(values: vendorValues)
    }

    /// One read ~300 ms after the last write, so quantization (shutter 30 -> 29) shows up. Not polling.
    private func scheduleReread(_ id: String) {
        rereads[id]?.cancel()
        guard let dev = uvc, let c = profileControls.first(where: { $0.id == id }) else { return }
        rereads[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            guard let q = self?.io else { return }
            let got: Int? = await withCheckedContinuation { k in
                q.async { k.resume(returning: try? dev.readProfile(c)) }
            }
            guard let self, !Task.isCancelled, self.pendingVendor[id] == nil, let got else { return }
            self.vendorValues[id] = got
        }
    }

    // MARK: Natural defaults

    /// Applied once per camera uniqueID on first attach; the IDs persist across launches.
    private func applyNaturalDefaultsOnFirstAttach(_ id: String) {
        let key = "naturalDefaultsApplied"
        var seen = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !seen.contains(id) else { return }
        seen.append(id)
        UserDefaults.standard.set(seen, forKey: key)
        applyNaturalDefaults()
    }

    /// "Restore defaults": natural format plus image controls. Profile `naturalDefaults` win over
    /// GET_DEF. Zoom/pan/tilt are left as they are. Writes ride the coalesced write path.
    func applyNaturalDefaults(includeFormat: Bool = true) {
        if includeFormat, let f = Self.naturalFormat(formats, minFPS: 30) { selectFormat(f.id) }
        let nd = profile.naturalDefaults
        let std = nd?.standard ?? [:]
        for st in states where st.canSet {
            let id = st.id
            guard !["zoom", "pantilt", "roll", "focus", "exposure", "wb-temp"].contains(id) else { continue }
            if let v = std[id] { set(id, [v]); continue }
            switch id {
            case "focus-auto", "wb-auto": set(id, [1])
            case "ae-mode": setAutoExposure(true)
            case "powerline":
                if (st.max?.first ?? 0) >= 3 { set(id, [3]) }
                else { set(id, [Self.mainsIs50Hz ? 1 : 2]) }
            default: if let d = st.def { set(id, d) }
            }
        }
        let prof = nd?.profile ?? ["aeMode": 2, "ev": 0, "hdr": 0]
        // aeMode first: ev is only honored while AE is auto.
        if let ae = prof["aeMode"] { setProfileValue("aeMode", ae) }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            for (k, v) in prof where k != "aeMode" { self?.setProfileValue(k, v) }
        }
    }

    /// Highest resolution with a >= minFPS mode; 16:9 preferred; 30 over 60 at the same size.
    static func naturalFormat(_ formats: [FormatOption], minFPS: Int) -> FormatOption? {
        let pick = VideoModeChooser.natural(formats.map { VideoMode(width: $0.width, height: $0.height, fps: $0.fps) }, minFPS: minFPS)
        return formats.first { $0.id == pick?.id }
    }

    private static var mainsIs50Hz: Bool {
        guard let c = Locale.current.region?.continent?.identifier else { return false }
        return ["150", "142", "002", "009"].contains(c) // Europe, Asia, Africa, Oceania (UN M.49)
    }

    // MARK: Auto exposure helper (bitmask: 1 manual, 2 auto, 8 aperture priority)

    func autoExposureOn() -> Bool { value("ae-mode").first.map(UVCControl.isAutoExposure) ?? false }
    func setAutoExposure(_ on: Bool) {
        let supported = state("ae-mode")?.res?.first ?? 0x09
        set("ae-mode", [on ? (supported & 8 != 0 ? 8 : 2) : 1])
    }
}
