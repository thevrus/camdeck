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
    /// One-shot frame grabs ("Fix My Picture"). Guarded by lock; served on the framer queue.
    private struct FrameRequest {
        let id: UInt64
        var remaining: Int
        var frames: [FrameStats] = []
        /// Face found on the request's first frame, reused for the rest so the frames stay close together.
        var face: CGRect?
        var faceChecked = false
        let completion: @Sendable ([FrameStats]) -> Void
    }
    private var frameRequests: [FrameRequest] = []
    private var nextRequestID: UInt64 = 0
    /// Framer queue only.
    private let faces = SubjectDetector()
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

    /// Call when auto framing or zebra turns on or off, and after a frame request finishes.
    func updateConnection() {
        lock.lock(); let framing = mode != nil, grabbing = !frameRequests.isEmpty; lock.unlock()
        output.connection(with: .video)?.isEnabled = framing || grabbing || zebra?.isEnabled == true
    }

    /// Stats of the next `count` frames, delivered on the framer queue. Keeps the output connection enabled
    /// while pending; the caller restores it with `updateConnection()` once done. Returns an id for `finishFrameRequest`.
    @discardableResult
    func requestFrames(count: Int, completion: @escaping @Sendable ([FrameStats]) -> Void) -> UInt64 {
        lock.lock()
        nextRequestID += 1
        let id = nextRequestID
        frameRequests.append(FrameRequest(id: id, remaining: max(count, 1), completion: completion))
        lock.unlock()
        updateConnection()
        return id
    }

    /// Ends a request early (timeout) with the frames collected so far. No-op if it already completed.
    func finishFrameRequest(_ id: UInt64) {
        lock.lock()
        let r = frameRequests.firstIndex { $0.id == id }.map { frameRequests.remove(at: $0) }
        lock.unlock()
        if let r { r.completion(r.frames) }
    }

    /// Framer queue. Face detection runs once per request, on its first frame.
    private func serveFrameRequests(_ pb: CVPixelBuffer) {
        lock.lock(); let pending = frameRequests; lock.unlock()
        guard !pending.isEmpty else { return }
        var detected: CGRect??
        var results: [UInt64: (face: CGRect?, stats: FrameStats?)] = [:]
        for r in pending {
            var face = r.face
            if !r.faceChecked {
                if detected == nil { detected = .some(faces.detectFace(pb)) }
                face = detected!
            }
            results[r.id] = (face, PictureFix.stats(pb, face: face))
        }
        var done: [FrameRequest] = []
        lock.lock()
        for i in frameRequests.indices.reversed() {
            guard let res = results[frameRequests[i].id] else { continue }
            frameRequests[i].face = res.face
            frameRequests[i].faceChecked = true
            if let st = res.stats { frameRequests[i].frames.append(st); frameRequests[i].remaining -= 1 }
            if frameRequests[i].remaining <= 0 { done.append(frameRequests.remove(at: i)) }
        }
        lock.unlock()
        for r in done { r.completion(r.frames) }
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
        if let pb = CMSampleBufferGetImageBuffer(sb) { serveFrameRequests(pb) }
        guard let mode, !paused, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        if reset { engine.reset() }
        let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        guard let step = engine.process(pb, time: t.isFinite ? t : CACurrentMediaTime(), current: ptz, ranges: ranges, mode: mode) else { return }
        let box = step.box, cmd = step.command
        Task { @MainActor [weak self] in self?.onStep?(box, cmd) }
    }
}
