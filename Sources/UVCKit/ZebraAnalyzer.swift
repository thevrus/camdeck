import CoreGraphics
import CoreVideo
import Foundation
import Observation
import os

/// Overexposure ("zebra") analysis of camera frames. `process` is safe to call from any queue.
@Observable
public final class ZebraAnalyzer: @unchecked Sendable {
    public var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            defaults.set(isEnabled, forKey: "zebra.enabled")
            state.withLock { $0.enabled = isEnabled }
            if !isEnabled { DispatchQueue.main.async { self.mask = nil; self.clippedFraction = 0 } }
            onEnabledChange?()
        }
    }
    /// Luma fraction (0...1) at or above which a pixel counts as clipped.
    public var threshold: Double {
        didSet { defaults.set(threshold, forKey: "zebra.threshold"); state.withLock { $0.threshold = threshold } }
    }
    /// Overexposed pixels opaque white, rest transparent. ~320 px wide, top-left origin like the frame.
    public private(set) var mask: CGImage?
    public private(set) var clippedFraction: Double = 0

    private struct State { var enabled: Bool; var threshold: Double; var last: UInt64 = 0; var busy = false; var processed = 0 }
    /// Called after `isEnabled` changes, on the caller's thread (frame sources use it to start or stop frames).
    @ObservationIgnored public var onEnabledChange: (() -> Void)?
    @ObservationIgnored private let state: OSAllocatedUnfairLock<State>
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let minInterval: TimeInterval
    @ObservationIgnored private let queue = DispatchQueue(label: "app.camdeck.zebra", qos: .utility)

    /// Number of frames actually analyzed (diagnostics / tests).
    public var processedCount: Int { state.withLock { $0.processed } }

    public init(defaults: UserDefaults = .standard, minInterval: TimeInterval = 0.2) {
        self.defaults = defaults; self.minInterval = minInterval
        let en = defaults.bool(forKey: "zebra.enabled")
        let th = defaults.object(forKey: "zebra.threshold") as? Double ?? 0.95
        isEnabled = en; threshold = th
        state = OSAllocatedUnfairLock(initialState: State(enabled: en, threshold: th))
    }

    /// Rate-limited to ~5 fps; returns immediately when disabled.
    public func process(_ pixelBuffer: CVPixelBuffer) {
        let go: Double? = state.withLock { s in
            guard s.enabled, !s.busy else { return nil }
            let t = DispatchTime.now().uptimeNanoseconds
            guard s.last == 0 || Double(t &- s.last) / 1e9 >= minInterval else { return nil }
            s.last = t; s.busy = true
            return s.threshold
        }
        guard let threshold = go else { return }
        queue.async { [self] in
            let r = Self.analyze(pixelBuffer, threshold: threshold)
            state.withLock { $0.busy = false; if r != nil { $0.processed += 1 } }
            guard let r else { return }
            DispatchQueue.main.async {
                guard self.isEnabled else { return }
                self.mask = r.mask; self.clippedFraction = r.clipped
            }
        }
    }

    private static let rgb = CGColorSpaceCreateDeviceRGB()

    /// Pure analysis. Handles 420v / 420f (Y plane) and BGRA; nil for other formats.
    public static func analyze(_ pb: CVPixelBuffer, threshold: Double, targetWidth: Int = 320) -> (mask: CGImage, clipped: Double)? {
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let planar = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard planar || fmt == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = planar ? CVPixelBufferGetWidthOfPlane(pb, 0) : CVPixelBufferGetWidth(pb)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pb, 0) : CVPixelBufferGetHeight(pb)
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0) : CVPixelBufferGetBytesPerRow(pb)
        guard w > 0, h > 0, let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pb, 0) : CVPixelBufferGetBaseAddress(pb) else { return nil }
        let p = base.assumingMemoryBound(to: UInt8.self)
        let step = max(1, w / targetWidth)
        let ow = w / step, oh = h / step
        guard ow > 0, oh > 0 else { return nil }
        let th = min(max(threshold, 0), 1)
        let cutoff: Int
        if fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange { cutoff = 16 + Int((th * 219).rounded(.up)) }
        else { cutoff = Int((th * 255).rounded(.up)) }
        var data = Data(count: ow * oh * 4)
        var count = 0
        data.withUnsafeMutableBytes { raw in
        let out = raw.bindMemory(to: UInt8.self)
        for y in 0 ..< oh {
            let row = p + y * step * stride
            for x in 0 ..< ow {
                let luma: Int
                if planar { luma = Int(row[x * step]) }
                else {
                    let px = row + x * step * 4   // B G R A
                    luma = (19 * Int(px[0]) + 183 * Int(px[1]) + 54 * Int(px[2])) >> 8
                }
                if luma >= cutoff {
                    let o = (y * ow + x) * 4
                    out[o] = 255; out[o + 1] = 255; out[o + 2] = 255; out[o + 3] = 255
                    count += 1
                }
            }
        }
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let img = CGImage(width: ow, height: oh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: ow * 4,
                                space: Self.rgb,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return (img, Double(count) / Double(ow * oh))
    }
}
