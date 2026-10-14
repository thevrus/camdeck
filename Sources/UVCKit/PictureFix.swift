import CoreGraphics
import CoreVideo
import Foundation

/// Luma summary of one video frame. Luma is 0...1 (video range normalized).
public struct FrameStats: Sendable, Equatable {
    /// Mean luma inside the face box; nil when no face was found.
    public var faceLuma: Double?
    public var frameLuma: Double
    /// Mean luma of horizontal bands, top to bottom (flicker analysis).
    public var rowMeans: [Double]

    public init(faceLuma: Double?, frameLuma: Double, rowMeans: [Double]) {
        self.faceLuma = faceLuma; self.frameLuma = frameLuma; self.rowMeans = rowMeans
    }
}

/// One-shot "Fix My Picture" math. Pure; the app grabs a few frames, asks these for a step, writes it, and stops.
public enum PictureFix {
    public static let faceTarget = 0.50
    /// Used when no face was found: the whole frame is metered instead.
    public static let frameTarget = 0.45
    public static let tolerance = 0.04

    /// A control's current value and the range it may move in.
    public struct Knob<T: Comparable & Sendable>: Sendable, Equatable {
        public var value: T
        public var range: ClosedRange<T>
        public init(_ value: T, _ range: ClosedRange<T>) { self.value = value; self.range = range }
    }

    /// What the camera offers for exposure. `ev` only when the profile's EV control is usable (AE auto).
    public struct ExposureControls: Sendable, Equatable {
        public var ev: Knob<Double>?
        public var backlight: Knob<Int>?
        public var brightness: Knob<Int>?
        public init(ev: Knob<Double>? = nil, backlight: Knob<Int>? = nil, brightness: Knob<Int>? = nil) {
            self.ev = ev; self.backlight = backlight; self.brightness = brightness
        }
    }

    /// New values to write; nil fields stay as they are.
    public struct ExposureStep: Sendable, Equatable {
        public var ev: Double?
        public var backlight: Int?
        public var brightness: Int?
        public init(ev: Double? = nil, backlight: Int? = nil, brightness: Int? = nil) {
            self.ev = ev; self.backlight = backlight; self.brightness = brightness
        }
        public var isEmpty: Bool { ev == nil && backlight == nil && brightness == nil }
    }

    /// One exposure iteration. Meters the face (target 0.50) or, without a face, the whole frame (target 0.45).
    /// Empty once inside ±0.04 of the target.
    public static func exposureStep(faceLuma: Double?, frameLuma: Double, controls: ExposureControls) -> ExposureStep {
        let measured = faceLuma ?? frameLuma
        let target = faceLuma == nil ? frameTarget : faceTarget
        guard abs(target - measured) > tolerance else { return ExposureStep() }
        var step = ExposureStep()

        // EV in stops while AE is auto. Falls through to the other controls only when EV is pinned at its limit.
        if let ev = controls.ev {
            let delta = min(max(log2(target / max(measured, 0.01)), -1), 1)
            let next = min(max(ev.value + delta, ev.range.lowerBound), ev.range.upperBound)
            if abs(next - ev.value) >= 0.05 {
                step.ev = next
                return step
            }
        }

        if let bl = controls.backlight, let face = faceLuma, frameLuma - face > 0.12, bl.value < bl.range.upperBound {
            step.backlight = bl.value + 1
        }
        if let b = controls.brightness {
            let span = Double(b.range.upperBound - b.range.lowerBound)
            let delta = Int(((target - measured) * span * 0.8).rounded())
            let next = min(max(b.value + delta, b.range.lowerBound), b.range.upperBound)
            if next != b.value { step.brightness = next }
        }
        return step
    }

    /// Banding that moves between frames. Differences of consecutive row-mean profiles, each detrended with a
    /// moving average of ~1/8 of the height (removes scene and AE drift), then the mean residual variance.
    public static func flickerScore(_ frames: [[Double]]) -> Double {
        guard frames.count >= 2 else { return 0 }
        var total = 0.0, n = 0
        for i in 1 ..< frames.count {
            let a = frames[i - 1], b = frames[i]
            let len = min(a.count, b.count)
            guard len >= 2 else { continue }
            let d = (0 ..< len).map { b[$0] - a[$0] }
            let half = max(1, len / 16) // window ≈ len / 8
            var resid: [Double] = []
            resid.reserveCapacity(len)
            for j in 0 ..< len {
                let lo = max(0, j - half), hi = min(len - 1, j + half)
                var s = 0.0
                for k in lo ... hi { s += d[k] }
                resid.append(d[j] - s / Double(hi - lo + 1))
            }
            let mean = resid.reduce(0, +) / Double(len)
            total += resid.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(len)
            n += 1
        }
        return n == 0 ? 0 : total / Double(n)
    }

    /// UVC power line values.
    public static let hz50 = 1, hz60 = 2

    /// The setting (1 = 50 Hz, 2 = 60 Hz) that scored at least 15% lower; nil when neither clearly wins
    /// or the winner is already `current` (nil means: keep the original setting).
    public static func pickPowerline(score50: Double, score60: Double, current: Int) -> Int? {
        let (low, high, pick) = score50 <= score60 ? (score50, score60, hz50) : (score60, score50, hz60)
        guard high > 0, low <= high * 0.85, pick != current else { return nil }
        return pick
    }

    /// Stats from the Y plane of a 420v / 420f buffer, subsampled. `face` is normalized, top-left origin;
    /// its central 60% is metered so hair and background stay out. Nil for other pixel formats.
    public static func stats(_ pb: CVPixelBuffer, face: CGRect?, bands: Int = 120) -> FrameStats? {
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let video = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard video || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        guard w > 0, h > 0, bands > 0, let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        let p = base.assumingMemoryBound(to: UInt8.self)
        let nb = min(bands, h)
        let xStep = max(1, w / 160), yStep = max(1, h / (nb * 4))
        var fx0 = Int.max, fx1 = Int.min, fy0 = Int.max, fy1 = Int.min
        if let f = face {
            let inner = f.insetBy(dx: f.width * 0.2, dy: f.height * 0.2)
            fx0 = Int(inner.minX * CGFloat(w)); fx1 = Int(inner.maxX * CGFloat(w))
            fy0 = Int(inner.minY * CGFloat(h)); fy1 = Int(inner.maxY * CGFloat(h))
        }
        var bandSum = [Int](repeating: 0, count: nb), bandCount = [Int](repeating: 0, count: nb)
        var faceSum = 0, faceCount = 0
        var y = 0
        while y < h {
            let row = p + y * stride
            let b = min(y * nb / h, nb - 1)
            let inFaceRow = y >= fy0 && y < fy1
            var x = 0, s = 0, c = 0
            while x < w {
                let v = Int(row[x])
                s += v; c += 1
                if inFaceRow, x >= fx0, x < fx1 { faceSum += v; faceCount += 1 }
                x += xStep
            }
            bandSum[b] += s; bandCount[b] += c
            y += yStep
        }
        func norm(_ v: Double) -> Double { video ? min(max((v - 16) / 219, 0), 1) : min(max(v / 255, 0), 1) }
        let rows = (0 ..< nb).map { bandCount[$0] > 0 ? norm(Double(bandSum[$0]) / Double(bandCount[$0])) : 0 }
        let total = bandCount.reduce(0, +)
        guard total > 0 else { return nil }
        let frame = norm(Double(bandSum.reduce(0, +)) / Double(total))
        let faceLuma = faceCount > 0 ? norm(Double(faceSum) / Double(faceCount)) : nil
        return FrameStats(faceLuma: faceLuma, frameLuma: frame, rowMeans: rows)
    }
}
