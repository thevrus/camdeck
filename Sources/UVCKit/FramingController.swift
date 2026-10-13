import CoreGraphics
import Foundation

/// Framing target. `.off` lives in the app's UI enum; the controller only knows active modes.
public enum FramingMode: String, CaseIterable, Sendable {
    case close, medium, wide

    /// Vision: upper-body boxes for close/medium, full body for wide.
    public var upperBodyOnly: Bool { self != .wide }
}

/// Zoom in device units (100 = 1x), pan/tilt in arcsec.
public struct PTZ: Equatable, Sendable, CustomStringConvertible {
    public var zoom: Int
    public var pan: Int
    public var tilt: Int
    public init(zoom: Int, pan: Int, tilt: Int) { self.zoom = zoom; self.pan = pan; self.tilt = tilt }
    public var description: String { "zoom \(zoom) pan \(pan) tilt \(tilt)" }
}

public struct PTZRanges: Equatable, Sendable {
    public var zoom: ClosedRange<Int>
    public var pan: ClosedRange<Int>
    public var tilt: ClosedRange<Int>
    public var panTiltRes: Int
    public init(zoom: ClosedRange<Int>, pan: ClosedRange<Int>, tilt: ClosedRange<Int>, panTiltRes: Int) {
        self.zoom = zoom; self.pan = pan; self.tilt = tilt; self.panTiltRes = max(panTiltRes, 1)
    }

    /// Insta360 Link 2C values read live via UVCKit (2026-10-13).
    public static let link2C = PTZRanges(zoom: 100 ... 400, pan: -522_000 ... 522_000, tilt: -324_000 ... 360_000, panTiltRes: 3600)
}

/// Closed-loop digital PTZ framing. Deterministic and free of Vision/AVFoundation types.
///
/// Input: the subject box in the CURRENT output frame (normalized, top-left origin), which the
/// camera has already cropped with the PTZ it was running when the frame was captured.
/// The box is lifted into crop-independent "1x world" coordinates (pan/tilt arcsec plus height at
/// 1x) using the PTZ commanded `frameLatency` seconds ago, smoothed there (EMA, so the estimate
/// does not jump when the crop moves), and turned into an absolute target. The commanded PTZ
/// eases toward the target first-order (zoom in log space, i.e. zoom x (target/zoom)^k), which
/// is overshoot-free, capped by slew limits and gated by dead zones with hysteresis.
public struct FramingController: Sendable {
    public struct Tuning: Sendable {
        /// Desired subject-box height as a fraction of the output frame.
        public var desiredHeight: [FramingMode: Double] = [.close: 0.75, .medium: 0.55, .wide: 0.35]
        /// Desired subject-box center y (top-left origin). 0.45 puts the head near the upper third.
        public var desiredCenterY: [FramingMode: Double] = [.close: 0.45, .medium: 0.45, .wide: 0.5]
        /// Calibrated: d(box center x in output frame)/d(pan) = zoomFactor / panArcsecPerUnit.
        /// Sign included. See `FramingCalibration`.
        public var panArcsecPerUnit: Double = FramingCalibration.panArcsecPerUnitAt1x
        public var tiltArcsecPerUnit: Double = FramingCalibration.tiltArcsecPerUnitAt1x
        /// Fraction of the sensor margin the crop may use when panning: |pan| <= |K| * (1 - 1/z) / 2 * this.
        /// The camera clamps the crop itself; clamping here prevents integrator wind-up.
        public var panMarginScale: Double = FramingCalibration.panMarginScale
        /// Pan/tilt framing on/off. Set per device: true when the camera has a Reframe capability.
        public var panTiltEnabled: Bool = FramingCalibration.panTiltEffective
        /// When set, pan/tilt are reframe offsets in micro-frames (see `ReframeUnits`) and the clamp
        /// comes from the device's travel instead of `panMarginScale`.
        public var reframeTravel: ReframeTravel?
        /// Center dead zone (normalized output frame) and size dead zone (relative height error).
        public var deadZoneCenter: Double = 0.06
        public var deadZoneSize: Double = 0.12
        /// Once outside a dead zone, keep correcting until the error falls below this fraction of it.
        public var hysteresis: Double = 0.4
        /// Time constants (s) of the first-order approach. Larger = calmer.
        public var zoomTau: Double = 1.2
        public var panTiltTau: Double = 0.8
        /// Slew limits.
        public var maxZoomRate: Double = 60          // zoom units / s (0.6x per second)
        public var maxPanTiltRate: Double = 90_000   // arcsec / s
        /// EMA time constant for the world-space subject estimate (s).
        public var boxTau: Double = 0.25
        /// Delay between a PTZ command and frames that show it (s).
        public var frameLatency: Double = 0.2
        /// After this long without a subject, ease back to wide (zoom min, pan/tilt 0).
        public var lostTimeout: Double = 2.0
        public init() {}
    }

    public var tuning: Tuning
    /// Smoothed subject in world coordinates (pan arcsec, tilt arcsec, height at 1x).
    private var world: (x: Double, y: Double, h: Double)?
    public var hasSubject: Bool { world != nil }
    private var lostFor: Double = 0
    private var clock: Double = 0
    private var history: [(t: Double, ptz: PTZ)] = []
    private var topClipped = false
    private var zoomActive = false
    private var centerActive = false

    public init(tuning: Tuning = Tuning()) { self.tuning = tuning }

    /// Forget the subject (e.g. after manual input, or when re-enabled).
    public mutating func reset() {
        world = nil; lostFor = 0; history = []
        zoomActive = false; centerActive = false
    }

    /// One step. `box` is nil when no subject was detected in this frame.
    public mutating func update(box: CGRect?, current: PTZ, ranges: PTZRanges, mode: FramingMode, dt: Double) -> PTZ {
        let dt = max(dt, 0)
        clock += dt
        let t = tuning
        let z0 = zf(current.zoom)

        if let box, box.height > 0.01, box.width > 0.01 {
            lostFor = 0
            // PTZ that was live when this frame was captured.
            let seen = commanded(at: clock - t.frameLatency) ?? current
            let zs = zf(seen.zoom)
            // A box cut by the top edge under-reports height and sits too low; trusting it would
            // zoom/tilt further into the cut (positive feedback). Rebuild it from the last estimate.
            topClipped = box.minY <= 0.005
            var midY = Double(box.midY), h = Double(box.height)
            if topClipped, let w = world {
                h = max(h, w.h * zs)
                midY = Double(box.maxY) - h / 2
            }
            let obs = (x: Double(seen.pan) - (Double(box.midX) - 0.5) * t.panArcsecPerUnit / zs,
                       y: Double(seen.tilt) - (midY - 0.5) * t.tiltArcsecPerUnit / zs,
                       h: h / zs)
            if let w = world {
                let a = 1 - exp(-dt / max(t.boxTau, 1e-3))
                world = (w.x + (obs.x - w.x) * a, w.y + (obs.y - w.y) * a, exp(log(w.h) + (log(obs.h) - log(w.h)) * a))
            } else {
                world = obs
                zoomActive = false; centerActive = false
            }
        } else {
            lostFor += dt
            if lostFor > t.lostTimeout { world = nil }
        }

        var next = current
        if let w = world {
            if lostFor > 0 { record(current); return current } // briefly lost: hold
            let desiredH = t.desiredHeight[mode] ?? 0.55
            let desiredY = t.desiredCenterY[mode] ?? 0.45

            // Errors as seen in the current output frame.
            let hNow = w.h * z0
            let sizeErr = abs(log(desiredH / hNow))
            let exNow = (Double(current.pan) - w.x) * z0 / t.panArcsecPerUnit
            let eyNow = (Double(current.tilt) - w.y) * z0 / t.tiltArcsecPerUnit + 0.5 - desiredY
            let centerErr = max(abs(exNow), abs(eyNow))

            let sizeDZ = log(1 + t.deadZoneSize)
            zoomActive = zoomActive ? sizeErr > sizeDZ * t.hysteresis : sizeErr > sizeDZ
            centerActive = centerActive ? centerErr > t.deadZoneCenter * t.hysteresis : centerErr > t.deadZoneCenter

            // Absolute targets.
            let zTargetUnits = clamp(desiredH / w.h * 100, Double(ranges.zoom.lowerBound), Double(ranges.zoom.upperBound))
            if zoomActive {
                let k = 1 - exp(-dt / t.zoomTau)
                var target = zTargetUnits
                if topClipped { target = min(target, Double(current.zoom)) } // head cut: never zoom in
                let raw = Double(current.zoom) * pow(target / Double(current.zoom), k)
                next.zoom = approach(current.zoom, slew(Double(current.zoom), raw, t.maxZoomRate * dt), target: target, minStep: 1)
            }
            if centerActive && t.panTiltEnabled {
                let zt = zf(next.zoom)
                let panT = w.x
                let tiltT = w.y + (desiredY - 0.5) * t.tiltArcsecPerUnit / zt
                let k = 1 - exp(-dt / t.panTiltTau)
                let res = ranges.panTiltRes
                next.pan = approach(current.pan, slew(Double(current.pan), Double(current.pan) + (panT - Double(current.pan)) * k, t.maxPanTiltRate * dt), target: panT, minStep: res)
                next.tilt = approach(current.tilt, slew(Double(current.tilt), Double(current.tilt) + (tiltT - Double(current.tilt)) * k, t.maxPanTiltRate * dt), target: tiltT, minStep: res)
            }
        } else if lostFor > t.lostTimeout {
            // Ease back to wide.
            let home = PTZ(zoom: ranges.zoom.lowerBound, pan: clampI(0, ranges.pan), tilt: clampI(0, ranges.tilt))
            let kz = 1 - exp(-dt / t.zoomTau), kp = 1 - exp(-dt / t.panTiltTau)
            let res = ranges.panTiltRes
            next.zoom = approach(current.zoom, slew(Double(current.zoom), Double(current.zoom) * pow(Double(home.zoom) / Double(current.zoom), kz), t.maxZoomRate * dt), target: Double(home.zoom), minStep: 1)
            next.pan = approach(current.pan, slew(Double(current.pan), Double(current.pan) + Double(home.pan - current.pan) * kp, t.maxPanTiltRate * dt), target: Double(home.pan), minStep: res)
            next.tilt = approach(current.tilt, slew(Double(current.tilt), Double(current.tilt) + Double(home.tilt - current.tilt) * kp, t.maxPanTiltRate * dt), target: Double(home.tilt), minStep: res)
        }

        next = constrain(next, current: current, ranges: ranges)
        record(current)
        return next
    }

    /// Clamp to device range and to the crop margin available at the commanded zoom, snap to res.
    /// A value that would snap back onto `current` stays put (no dither between two steps).
    private func constrain(_ p: PTZ, current: PTZ, ranges: PTZRanges) -> PTZ {
        var o = p
        o.zoom = clampI(o.zoom, ranges.zoom)
        let z = zf(o.zoom)
        let panLim: Double, tiltLim: Double
        if let tr = tuning.reframeTravel {
            let o = tr.offset(atZoom: z)
            panLim = o.dx * ReframeUnits.perFrame; tiltLim = o.dy * ReframeUnits.perFrame
        } else {
            let margin = max(0, (1 - 1 / z) / 2 * tuning.panMarginScale)
            panLim = abs(tuning.panArcsecPerUnit) * margin
            tiltLim = abs(tuning.tiltArcsecPerUnit) * margin
        }
        o.pan = snap(Int(clamp(Double(o.pan), -panLim, panLim)), current.pan, ranges.pan, ranges.panTiltRes)
        o.tilt = snap(Int(clamp(Double(o.tilt), -tiltLim, tiltLim)), current.tilt, ranges.tilt, ranges.panTiltRes)
        return o
    }

    // MARK: helpers

    /// Rounds `raw`, but always moves at least `minStep` toward `target` while at least
    /// `minStep` away, so quantization cannot stall the approach short of the target.
    private func approach(_ cur: Int, _ raw: Double, target: Double, minStep: Int) -> Int {
        var v = Int(raw.rounded())
        let gap = target - Double(cur)
        if abs(gap) >= Double(minStep), abs(v - cur) < minStep { v = cur + (gap > 0 ? minStep : -minStep) }
        return v
    }

    private func zf(_ zoom: Int) -> Double { max(Double(zoom) / 100, 0.01) }

    /// Records the PTZ that is live now (the caller's `current`), for latency compensation.
    private mutating func record(_ p: PTZ) {
        history.append((clock, p))
        // Keep one entry older than the latency window so `commanded(at:)` always has an answer.
        let horizon = clock - tuning.frameLatency - 0.5
        while history.count > 1, history[1].t < horizon { history.removeFirst() }
        if history.count > 256 { history.removeFirst(history.count - 256) }
    }

    /// PTZ that was live at time `t`.
    private func commanded(at t: Double) -> PTZ? { history.last(where: { $0.t <= t })?.ptz }

    private func snap(_ v: Int, _ cur: Int, _ r: ClosedRange<Int>, _ res: Int) -> Int {
        let lo = r.lowerBound
        var s = lo + Int((Double(v - lo) / Double(res)).rounded()) * res
        while s > r.upperBound { s -= res }
        while s < r.lowerBound { s += res }
        return abs(v - cur) < res / 2 ? cur : s
    }
}

private func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(max(x, lo), hi) }
private func clampI(_ x: Int, _ r: ClosedRange<Int>) -> Int { min(max(x, r.lowerBound), r.upperBound) }
private func slew(_ from: Double, _ to: Double, _ maxStep: Double) -> Double { from + clamp(to - from, -maxStep, maxStep) }

/// Normalized framing units for capability-driven cameras: PTZ.zoom = zoom factor x 100,
/// PTZ.pan/tilt = crop-center offset from the sensor center in micro-frames of the 1x frame
/// (+ = view right / down). The CameraController maps these to Zoom and Reframe capabilities.
public enum ReframeUnits {
    public static let perFrame = 1_000_000.0
    /// Tuning for a camera with a Reframe capability of the given travel.
    public static func tuning(travel: ReframeTravel?) -> FramingController.Tuning {
        var t = FramingController.Tuning()
        t.panTiltEnabled = travel != nil
        t.reframeTravel = travel
        // View right by +1 frame moves content left by one output frame at 1x.
        t.panArcsecPerUnit = -perFrame
        t.tiltArcsecPerUnit = -perFrame
        t.maxPanTiltRate = 0.3 * perFrame
        return t
    }
    /// Ranges for a camera whose zoom spans 1...maxFactor.
    public static func ranges(maxZoomFactor: Double) -> PTZRanges {
        PTZRanges(zoom: 100 ... max(100, Int((maxZoomFactor * 100).rounded())), pan: -500_000 ... 500_000, tilt: -500_000 ... 500_000, panTiltRes: 1)
    }
    /// Offset (micro-frames) <-> normalized center at zoom factor z.
    public static func center(pan: Int, tilt: Int, travel: ReframeTravel, zoomFactor z: Double) -> CGPoint {
        let o = travel.offset(atZoom: z)
        func n(_ v: Int, _ m: Double) -> Double { m <= 0 ? 0 : min(max(Double(v) / (m * perFrame), -1), 1) }
        return CGPoint(x: n(pan, o.dx), y: n(tilt, o.dy))
    }
    public static func offset(center c: CGPoint, travel: ReframeTravel, zoomFactor z: Double) -> (pan: Int, tilt: Int) {
        let o = travel.offset(atZoom: z)
        return (Int((Double(c.x) * o.dx * perFrame).rounded()), Int((Double(c.y) * o.dy * perFrame).rounded()))
    }
}

/// Constants for the Insta360 Link 2C, from `uvcctl framing-calibrate` / `framing-probe` (2026-10-13).
///
/// Measured: CT pan/tilt abs (0x0D) writes are accepted and read back (e.g. 252000 at zoom 400),
/// but the image does not move: Vision translational registration of before/after frames gave
/// |shift| < 0.003 frame for pan +-36000 at 2x, +36000 at 1x/3x/4x, +108000 at 2x and +252000 at 4x,
/// and saved before/after frames are visually identical. Pan values also revert to 0 after ~2 s.
/// So CT pan/tilt framing is disabled (Insta360LinkDriver marks it `.ctPanTiltIneffective`); the app
/// frames the 2C through its XU9 Reframe capability instead (see `ReframeUnits`, `Link2CReframeMapping`). The K values below
/// are geometric placeholders (not measured) kept so pan/tilt can be re-enabled if a firmware
/// update makes CT pan/tilt move the crop: re-run `uvcctl framing-calibrate` and replace them.
public enum FramingCalibration {
    public static let panTiltEffective = false
    /// Pan arcsec that shift the subject by one output-frame width at 1x (signed). Placeholder.
    public static let panArcsecPerUnitAt1x: Double = -300_000
    /// Tilt arcsec that shift the subject by one output-frame height at 1x (signed). Placeholder.
    public static let tiltArcsecPerUnitAt1x: Double = 200_000
    public static let panMarginScale: Double = 1.0
}
