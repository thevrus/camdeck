import AVFoundation
import CoreImage
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
    private var snapshotWaiters: [SnapshotWaiter] = []
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])
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
        // Under the lock: a waiter added between the read and the write must not see its frames switched off.
        lock.lock(); defer { lock.unlock() }
        output.connection(with: .video)?.isEnabled = mode != nil || !snapshotWaiters.isEmpty || zebra?.isEnabled == true
    }

    /// The next frame as an image no larger than `maxSide` on its long edge, for the language model to look at.
    /// Turns frame delivery on for that one frame. Nil when no frame arrives within a second (preview stopped).
    func snapshot(maxSide: CGFloat = 512) async -> CGImage? {
        await withCheckedContinuation { (c: CheckedContinuation<CGImage?, Never>) in
            let w = SnapshotWaiter(c, maxSide: maxSide)
            lock.lock(); snapshotWaiters.append(w); lock.unlock()
            updateConnection()
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                w.resume(nil)
                guard let self else { return }
                self.lock.lock(); self.snapshotWaiters.removeAll { $0 === w }; self.lock.unlock()
                self.updateConnection()
            }
        }
    }

    /// Copies the frame out: the capture pool reuses its buffers.
    private static func image(from pb: CVPixelBuffer, maxSide: CGFloat) -> CGImage? {
        var img = CIImage(cvPixelBuffer: pb)
        let scale = min(1, maxSide / max(img.extent.width, img.extent.height))
        if scale < 1 { img = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        return ciContext.createCGImage(img, from: img.extent)
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
        let waiters = snapshotWaiters; snapshotWaiters = []
        lock.unlock()
        if let tuning { engine.controller.tuning = tuning }
        if !waiters.isEmpty {
            let pb = CMSampleBufferGetImageBuffer(sb)
            for w in waiters { w.resume(pb.flatMap { Self.image(from: $0, maxSide: w.maxSide) }) }
            updateConnection()
        }
        zebra?.process(sampleBuffer: sb)
        guard let mode, !paused, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        if reset { engine.reset() }
        let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        guard let step = engine.process(pb, time: t.isFinite ? t : CACurrentMediaTime(), current: ptz, ranges: ranges, mode: mode) else { return }
        let box = step.box, cmd = step.command
        Task { @MainActor [weak self] in self?.onStep?(box, cmd) }
    }
}

/// One pending `snapshot()` call; resumes exactly once, from a frame or from the timeout.
private final class SnapshotWaiter: @unchecked Sendable {
    let maxSide: CGFloat
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private let lock = NSLock()
    init(_ c: CheckedContinuation<CGImage?, Never>, maxSide: CGFloat) { continuation = c; self.maxSide = maxSide }
    func resume(_ image: CGImage?) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(returning: image)
    }
}
