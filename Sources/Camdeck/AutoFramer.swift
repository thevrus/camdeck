import AVFoundation
import Foundation
import UVCKit

/// Auto framing mode exposed to the UI.
enum AutoFramingMode: String, CaseIterable, Identifiable {
    case off, close, medium, wide
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .close: return "Close"
        case .medium: return "Medium"
        case .wide: return "Wide"
        }
    }
    var symbol: String {
        switch self {
        case .off: return "person.crop.rectangle.badge.xmark"
        case .close: return "person.crop.square"
        case .medium: return "person.crop.rectangle"
        case .wide: return "person.2.crop.square.stack"
        }
    }
    var framing: FramingMode? { FramingMode(rawValue: rawValue) }
}

/// Frames from the session -> Vision -> FramingController -> CameraController writes.
/// Runs on its own serial queue at <= 10 fps; the output connection is disabled while neither framing nor zebra needs frames.
final class AutoFramer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "app.camdeck.autoframer")
    private let engine = FramingEngine()
    private let lock = NSLock()
    // Guarded by lock: snapshot from the main actor.
    private var mode: FramingMode?
    private var ptz = PTZ(zoom: 100, pan: 0, tilt: 0)
    private var ranges = ReframeUnits.ranges(maxZoomFactor: 4)
    private var pausedUntil = Date.distantPast
    private var needsReset = false
    private var pendingTuning: FramingController.Tuning?
    /// Called on the main actor with each processed frame's result.
    var onStep: (@MainActor (CGRect?, PTZ) -> Void)?
    /// Fed every frame (it rate-limits itself and returns at once while disabled).
    var zebra: ZebraAnalyzer?

    static let manualPause: TimeInterval = 3

    override init() {
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func configure(mode: FramingMode?) {
        lock.lock(); self.mode = mode; needsReset = true; lock.unlock()
        updateConnection()
    }

    /// Call when auto framing or zebra turns on or off.
    func updateConnection() {
        lock.lock(); let framing = mode != nil; lock.unlock()
        output.connection(with: .video)?.isEnabled = framing || zebra?.isEnabled == true
    }

    /// Per-device geometry: Reframe travel (nil = zoom-only framing), applied on the framer queue.
    func configureGeometry(travel: ReframeTravel?) {
        lock.lock(); pendingTuning = ReframeUnits.tuning(travel: travel); needsReset = true; lock.unlock()
    }

    func update(ptz: PTZ, ranges: PTZRanges?) {
        lock.lock(); self.ptz = ptz; if let ranges { self.ranges = ranges }; lock.unlock()
    }

    /// Zoom slider, pan/tilt pad or reset: hold off for 3 s, then reacquire from scratch.
    func noteManualInput() {
        lock.lock(); pausedUntil = Date().addingTimeInterval(Self.manualPause); needsReset = true; lock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock()
        let mode = self.mode, ptz = self.ptz, ranges = self.ranges, paused = Date() < pausedUntil, reset = needsReset && !paused
        if reset { needsReset = false }
        let tuning = pendingTuning; pendingTuning = nil
        lock.unlock()
        if let tuning { engine.controller.tuning = tuning }
        zebra?.process(sampleBuffer: sb)
        guard let mode, !paused, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        if reset { engine.reset() }
        let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        guard let step = engine.process(pb, time: t.isFinite ? t : CACurrentMediaTime(), current: ptz, ranges: ranges, mode: mode) else { return }
        let box = step.box, cmd = step.command
        Task { @MainActor [weak self] in self?.onStep?(box, cmd) }
    }
}
