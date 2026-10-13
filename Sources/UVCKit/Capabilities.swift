import CoreGraphics
import Foundation

// Capability protocols (ADR-001). The app talks only to these; drivers provide them.
// A capability that is nil on `CameraDevice` is unsupported on that camera.

/// What driver matching sees: everything known about a camera without talking to it.
public struct CameraDescriptor: Equatable, Sendable {
    public var vendorID: UInt16
    public var productID: UInt16
    public var name: String
    public var topology: UVCTopology
    public init(vendorID: UInt16, productID: UInt16, name: String, topology: UVCTopology) {
        self.vendorID = vendorID; self.productID = productID; self.name = name; self.topology = topology
    }
    public func hasExtensionUnit(_ guid: String) -> Bool { topology.extensionUnits.contains { $0.guid == guid.lowercased() } }
}

public enum CapabilityKind: String, CaseIterable, Sendable {
    case imageControls, zoom, reframe, deviceInfo, profileControls
}

/// Per-device facts a code driver knows that the descriptor does not tell.
public enum CameraQuirk: String, Sendable {
    /// CT pan/tilt (0x0D) is accepted and read back but does not move the image (Link 2C).
    case ctPanTiltIneffective
}

public struct DeviceInfo: Equatable, Sendable {
    public var name: String
    public var serial: String?
    public var firmware: String?
    public var model: String?
    public var uuid: String?
    public init(name: String, serial: String? = nil, firmware: String? = nil, model: String? = nil, uuid: String? = nil) {
        self.name = name; self.serial = serial; self.firmware = firmware; self.model = model; self.uuid = uuid
    }
}

/// Standard camera-terminal / processing-unit controls from the descriptor bitmaps.
public protocol ImageControlsCapability: AnyObject, Sendable {
    var controls: [UVCControl] { get }
    /// min/max/res/def/cur/info for every control (reads only).
    func readStates() -> [UVCControlState]
    func read(_ c: UVCControl, _ request: UVCRequest) throws -> [Int]
    func write(_ c: UVCControl, _ values: [Int]) throws
}

/// Zoom. Factor 1.0 is the widest view; factor = raw / rawRange.lowerBound.
public protocol ZoomCapability: AnyObject, Sendable {
    var rawRange: ClosedRange<Int> { get }
    func readRaw() throws -> Int
    func writeRaw(_ raw: Int) throws
}

public extension ZoomCapability {
    var factorRange: ClosedRange<Double> { 1.0 ... factor(fromRaw: rawRange.upperBound) }
    func factor(fromRaw raw: Int) -> Double { max(Double(raw) / Double(max(rawRange.lowerBound, 1)), 1) }
    func raw(fromFactor f: Double) -> Int {
        let r = Int((f * Double(max(rawRange.lowerBound, 1))).rounded())
        return min(max(r, rawRange.lowerBound), rawRange.upperBound)
    }
}

/// How far the view can move. Offsets are crop-center displacement from the sensor center in
/// fractions of the full 1x frame (width for x, height for y) when the normalized center is +-1.
public enum ReframeTravel: Equatable, Sendable {
    /// Digital crop inside the 1x frame: offset = max(0, (1 - 1/zoom) / 2 - inset) * scale. No travel at 1x.
    case digitalCrop(scaleX: Double, scaleY: Double, inset: Double)
    /// Mechanical or zoom-independent travel.
    case fixed(x: Double, y: Double)

    public func offset(atZoom z: Double) -> CGVector {
        switch self {
        case let .digitalCrop(sx, sy, inset):
            let m = max(0, (1 - 1 / max(z, 1)) / 2 - inset)
            return CGVector(dx: m * sx, dy: m * sy)
        case let .fixed(x, y): return CGVector(dx: x, dy: y)
        }
    }
}

/// Reframe (pan/tilt of the view). `center` is in -1...1 of the travel available at the given zoom,
/// x positive = view moves right, y positive = view moves down (top-left image convention).
public protocol ReframeCapability: AnyObject, Sendable {
    var travel: ReframeTravel { get }
    func read(zoomFactor: Double) throws -> CGPoint
    func write(_ center: CGPoint, zoomFactor: Double) throws
}

public protocol DeviceInfoCapability: AnyObject, Sendable {
    func readInfo() throws -> DeviceInfo
}

/// JSON-profile controls (exposure mode, EV, ISO, shutter, HDR ...) through the ProfileControl path.
public protocol ProfileControlsCapability: AnyObject, Sendable {
    var profile: DeviceProfile { get }
    /// Controls whose unit is present in this device's descriptor, in profile order.
    var controls: [ProfileControl] { get }
    func read(_ c: ProfileControl) throws -> Int
    func write(_ c: ProfileControl, wire: Int) throws
}

public extension CGPoint {
    /// Clamped to the normalized reframe square.
    var clampedToUnitSquare: CGPoint { CGPoint(x: min(max(x, -1), 1), y: min(max(y, -1), 1)) }
}
