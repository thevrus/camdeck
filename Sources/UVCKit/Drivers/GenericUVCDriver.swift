import CoreGraphics
import Foundation

/// Any UVC camera: standard CT/PU controls from the descriptor bitmaps, Zoom via CT 0x0B,
/// Reframe via CT pan/tilt 0x0D (only if the CT advertises it and no driver marks it ineffective).
public struct GenericUVCDriver: CameraDriver {
    public let name = "GenericUVC"
    public let specificity = 0
    public init() {}

    public func matches(_ d: CameraDescriptor) -> Bool { d.topology.hasVideoControl }

    public func capabilities(for d: CameraDescriptor, quirks: Set<CameraQuirk>) -> [CapabilityKind: CapabilityFactory] {
        var out: [CapabilityKind: CapabilityFactory] = [
            .imageControls: { dev in StandardImageControls(dev) },
            .deviceInfo: { dev in StaticDeviceInfo(DeviceInfo(name: dev.name, serial: dev.serialNumber)) },
        ]
        let ct = d.topology.cameraTerminal
        if ct?.supports(bit: UVCControl.zoomControl.bit) == true {
            out[.zoom] = { dev in try CTZoom(dev) }
        }
        if ct?.supports(bit: UVCControl.panTiltControl.bit) == true, !quirks.contains(.ctPanTiltIneffective) {
            out[.reframe] = { dev in try CTPanTiltReframe(dev) }
        }
        return out
    }
}

extension UVCControl {
    public static let zoomControl = all.first { $0.id == "zoom" }!
    public static let panTiltControl = all.first { $0.id == "pantilt" }!
}

final class StandardImageControls: ImageControlsCapability, @unchecked Sendable {
    let dev: UVCDevice
    init(_ dev: UVCDevice) { self.dev = dev }
    var controls: [UVCControl] { dev.availableControls }
    func readStates() -> [UVCControlState] { dev.readControls() }
    func read(_ c: UVCControl, _ request: UVCRequest) throws -> [Int] { try dev.read(c, request) }
    func write(_ c: UVCControl, _ values: [Int]) throws { try dev.write(c, values) }
}

final class StaticDeviceInfo: DeviceInfoCapability, @unchecked Sendable {
    let info: DeviceInfo
    init(_ info: DeviceInfo) { self.info = info }
    func readInfo() throws -> DeviceInfo { info }
}

/// CT zoom absolute. Range from GET_MIN/GET_MAX, read once at composition.
final class CTZoom: ZoomCapability, @unchecked Sendable {
    let dev: UVCDevice
    let rawRange: ClosedRange<Int>
    init(_ dev: UVCDevice) throws {
        self.dev = dev
        let lo = try dev.read(.zoomControl, .min).first ?? 0, hi = try dev.read(.zoomControl, .max).first ?? 0
        guard hi > lo, lo > 0 else { throw UVCError.io(-3) }
        rawRange = lo ... hi
    }
    func readRaw() throws -> Int { try dev.read(.zoomControl).first ?? rawRange.lowerBound }
    func writeRaw(_ raw: Int) throws { try dev.write(.zoomControl, [min(max(raw, rawRange.lowerBound), rawRange.upperBound)]) }
}

/// CT pan/tilt absolute (arcsec). Normalized center maps piecewise onto [min, 0] and [0, max] so 0 is
/// always the home position. Travel is zoom-independent; the arcsec-per-frame constants are geometric
/// placeholders (about 83 x 56 degree field of view), not measured on any camera.
public final class CTPanTiltReframe: ReframeCapability, @unchecked Sendable {
    static let panArcsecPerFrame = 300_000.0
    static let tiltArcsecPerFrame = 200_000.0
    let dev: UVCDevice
    let pan: ClosedRange<Int>, tilt: ClosedRange<Int>, res: Int
    public let travel: ReframeTravel

    init(_ dev: UVCDevice) throws {
        self.dev = dev
        let lo = try dev.read(.panTiltControl, .min), hi = try dev.read(.panTiltControl, .max)
        guard lo.count == 2, hi.count == 2, hi[0] > lo[0], hi[1] > lo[1] else { throw UVCError.io(-3) }
        pan = lo[0] ... hi[0]; tilt = lo[1] ... hi[1]
        res = max((try? dev.read(.panTiltControl, .res).first) ?? 1, 1)
        travel = .fixed(x: Double(max(-pan.lowerBound, pan.upperBound)) / Self.panArcsecPerFrame,
                        y: Double(max(-tilt.lowerBound, tilt.upperBound)) / Self.tiltArcsecPerFrame)
    }

    public static func toRaw(_ c: Double, _ r: ClosedRange<Int>) -> Int {
        let c = min(max(c, -1), 1)
        return Int((c >= 0 ? c * Double(r.upperBound) : -c * Double(r.lowerBound)).rounded())
    }

    public static func fromRaw(_ v: Int, _ r: ClosedRange<Int>) -> Double {
        if v >= 0 { return r.upperBound > 0 ? min(Double(v) / Double(r.upperBound), 1) : 0 }
        return r.lowerBound < 0 ? -min(Double(v) / Double(r.lowerBound), 1) : 0
    }

    public func read(zoomFactor: Double) throws -> CGPoint {
        let v = try dev.read(.panTiltControl)
        guard v.count == 2 else { throw UVCError.io(-1) }
        // UVC tilt is positive up; reframe y is positive down.
        return CGPoint(x: Self.fromRaw(v[0], pan), y: -Self.fromRaw(v[1], tilt))
    }

    public func write(_ center: CGPoint, zoomFactor: Double) throws {
        func snap(_ v: Int) -> Int { Int((Double(v) / Double(res)).rounded()) * res }
        try dev.write(.panTiltControl, [snap(Self.toRaw(center.x, pan)), snap(Self.toRaw(-center.y, tilt))])
    }
}
