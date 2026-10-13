import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Vision

/// Finds the framing subject in a video frame. Not thread-safe: call from one serial queue.
/// Requests are created once and reused; Vision wants a fresh VNImageRequestHandler per image.
public final class SubjectDetector: @unchecked Sendable {
    private let human = VNDetectHumanRectanglesRequest()
    private let face = VNDetectFaceRectanglesRequest()
    private var previous: CGRect?

    public init() {
        human.revision = VNDetectHumanRectanglesRequestRevision2
    }

    public func reset() { previous = nil }

    /// Subject box in the frame, normalized, top-left origin. Nil if nobody is visible.
    public func detect(_ pixelBuffer: CVPixelBuffer, upperBodyOnly: Bool) -> CGRect? {
        human.upperBodyOnly = upperBodyOnly
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        var boxes: [CGRect] = []
        do {
            try handler.perform([human])
            boxes = (human.results ?? []).filter { $0.confidence > 0.3 }.map { Self.topLeft($0.boundingBox) }
            if boxes.isEmpty {
                try handler.perform([face])
                boxes = (face.results ?? []).filter { $0.confidence > 0.5 }.map { Self.bodyFromFace(Self.topLeft($0.boundingBox), upperBodyOnly: upperBodyOnly) }
            }
        } catch {
            return nil
        }
        let pick = Self.select(boxes, previous: previous)
        previous = pick ?? previous
        return pick
    }

    /// Largest face box (normalized, top-left origin). Used by calibration: faces are small,
    /// so their centers stay unclipped when the body fills the frame.
    public func detectFace(_ pixelBuffer: CVPixelBuffer) -> CGRect? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        guard (try? handler.perform([face])) != nil else { return nil }
        return Self.select((face.results ?? []).filter { $0.confidence > 0.5 }.map { Self.topLeft($0.boundingBox) }, previous: nil)
    }

    /// Best IoU with the previous subject, else the largest box.
    public static func select(_ boxes: [CGRect], previous: CGRect?) -> CGRect? {
        if let p = previous, let best = boxes.max(by: { iou($0, p) < iou($1, p) }), iou(best, p) > 0.1 { return best }
        return boxes.max { $0.width * $0.height < $1.width * $1.height }
    }

    public static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let inter = i.width * i.height
        return inter / (a.width * a.height + b.width * b.height - inter)
    }

    static func topLeft(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height) }

    /// Rough upper-body (or full-body) box around a face, clipped to the frame, so the fallback
    /// feeds the controller boxes of the same scale as the human detector.
    static func bodyFromFace(_ f: CGRect, upperBodyOnly: Bool) -> CGRect {
        let w = f.width * (upperBodyOnly ? 2.6 : 3.0)
        let h = f.height * (upperBodyOnly ? 2.6 : 7.0)
        let r = CGRect(x: f.midX - w / 2, y: f.minY - f.height * 0.35, width: w, height: h)
        return r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

/// Detector + controller + rate limiting: the whole per-frame loop, shared by the app's
/// AutoFramer and `uvcctl framing-run`, so the CLI exercises the same code as the app.
public final class FramingEngine: @unchecked Sendable {
    public let detector = SubjectDetector()
    public var controller = FramingController()
    /// Frames closer together than this are dropped (~10 fps processing).
    public var minFrameInterval: Double = 0.1
    private var lastFrame: Double?

    public init() {}

    public func reset() { detector.reset(); controller.reset(); lastFrame = nil }

    public struct Step: Sendable {
        public var box: CGRect?
        public var command: PTZ
    }

    /// Returns nil when the frame was skipped by the frame-rate limit.
    public func process(_ pixelBuffer: CVPixelBuffer, time: Double, current: PTZ, ranges: PTZRanges, mode: FramingMode) -> Step? {
        if let l = lastFrame, time - l < minFrameInterval, time >= l { return nil }
        let dt = lastFrame.map { min(max(time - $0, 0), 0.5) } ?? minFrameInterval
        lastFrame = time
        let box = detector.detect(pixelBuffer, upperBodyOnly: mode.upperBodyOnly)
        let cmd = controller.update(box: box, current: current, ranges: ranges, mode: mode, dt: dt)
        return Step(box: box, command: cmd)
    }
}
