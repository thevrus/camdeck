import CoreGraphics
import Foundation

/// Insta360 Link family (VID 0x2E1A with XU {faf1672d-...}). See docs/link2c-protocol.md.
/// - DeviceInfo from XU9 sel 3 (hardware IDs) and sel 12 (serial), on every matching model.
/// - Reframe via XU9 sel 2 bytes 38-41, and the CT pan/tilt no-op quirk, only on models verified on
///   hardware (`reframeProductIDs`). Gimbal models may use CT pan/tilt mechanically and may lay
///   out sel 2 differently, so they keep the generic behaviour until measured.
public struct Insta360LinkDriver: CameraDriver {
    public static let vendorID: UInt16 = 0x2E1A
    public static let xuGUID = "faf1672d-b71b-4793-8c91-7b1c9b7f95f8"
    public static let reframeSelector: UInt8 = 2
    public static let infoSelector: UInt8 = 3
    public static let serialSelector: UInt8 = 12
    /// USB mode switch / firmware path. Never written.
    public static let modeSwitchSelector = 17
    public static let link2CProductID: UInt16 = 0x4C03
    /// Models verified for reframe: Link 2C.
    public static let reframeProductIDs: Set<UInt16> = [link2CProductID]

    public let name = "Insta360Link"
    public let specificity = 20
    public init() {}

    public func matches(_ d: CameraDescriptor) -> Bool { d.vendorID == Self.vendorID && d.hasExtensionUnit(Self.xuGUID) }

    public func quirks(for d: CameraDescriptor) -> Set<CameraQuirk> {
        Self.reframeProductIDs.contains(d.productID) ? [.ctPanTiltIneffective] : []
    }

    public func capabilities(for d: CameraDescriptor, quirks: Set<CameraQuirk>) -> [CapabilityKind: CapabilityFactory] {
        var out: [CapabilityKind: CapabilityFactory] = [.deviceInfo: { dev in StaticDeviceInfo(try Self.readInfo(dev)) }]
        if Self.reframeProductIDs.contains(d.productID) { out[.reframe] = { dev in try LinkReframe(dev) } }
        return out
    }

    public var forbiddenSelectors: [ForbiddenSelectorKey] { [ForbiddenSelectorKey(guid: Self.xuGUID, selector: Self.modeSwitchSelector)] }

    // MARK: Wire helpers (pure, unit-tested)

    /// GET_LEN; the record size is never assumed.
    public static func length(_ t: UVCTransport, unit: UInt8, selector: UInt8) throws -> Int {
        let n = try t.length(unit: unit, selector: selector)
        guard n > 0, n <= 1024 else { throw UVCError.io(-2) }
        return n
    }

    public static let reframeXOffset = 38
    public static let reframeYOffset = 40
    public static let reframeCenter: UInt16 = 0x7FFF

    /// Byte 50 mirrors CT zoom (u16, 100 = 1x). Writing back a stale read there snaps zoom to the old value
    /// (seen 380->360, 399->100 during calibration), so callers pass the zoom they commanded.
    public static let zoomMirrorOffset = 50

    /// `record` with bytes 38-41 replaced by X and Y (u16 LE) and, if `zoom` is given, bytes 50-51 replaced
    /// by it. Every other byte, including byte 0 (AI mode), is returned exactly as read.
    public static func reframeRecord(_ record: [UInt8], x: UInt16, y: UInt16, zoom: UInt16? = nil) -> [UInt8] {
        var r = record
        guard r.count >= reframeYOffset + 2 else { return r }
        r[reframeXOffset] = UInt8(x & 0xFF); r[reframeXOffset + 1] = UInt8(x >> 8)
        r[reframeYOffset] = UInt8(y & 0xFF); r[reframeYOffset + 1] = UInt8(y >> 8)
        if let zoom, r.count >= zoomMirrorOffset + 2 {
            r[zoomMirrorOffset] = UInt8(zoom & 0xFF); r[zoomMirrorOffset + 1] = UInt8(zoom >> 8)
        }
        return r
    }

    public static func reframeXY(_ record: [UInt8]) -> (x: UInt16, y: UInt16)? {
        guard record.count >= reframeYOffset + 2 else { return nil }
        return (UInt16(record[reframeXOffset]) | UInt16(record[reframeXOffset + 1]) << 8,
                UInt16(record[reframeYOffset]) | UInt16(record[reframeYOffset + 1]) << 8)
    }

    /// NUL/space-trimmed ASCII field; nil if empty or out of range.
    public static func ascii(_ b: [UInt8], offset: Int, length: Int) -> String? {
        guard offset >= 0, offset < b.count else { return nil }
        let slice = b[offset ..< min(offset + length, b.count)]
        let bytes = slice.prefix { $0 != 0 }.filter { $0 >= 0x20 && $0 < 0x7F }
        let s = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    /// Reads sel 3 and sel 12 once (two GET_LEN + two GET_CUR) at composition time.
    static func readInfo(_ dev: UVCDevice) throws -> DeviceInfo {
        guard let xu = dev.unitID(forGUID: xuGUID) else { throw UVCError.noUnit("Insta360 XU") }
        let t = dev.transport
        let ids = try t.get(unit: xu, selector: infoSelector, length: length(t, unit: xu, selector: infoSelector))
        let serial = try? t.get(unit: xu, selector: serialSelector, length: length(t, unit: xu, selector: serialSelector))
        var i = parseInfo(name: dev.name, hardwareIDs: ids, serial: serial)
        if i.serial == nil { i.serial = dev.serialNumber }
        return i
    }

    /// sel 3: firmware @97 len 15, UUID @33 len 36, model @170 len 10. sel 12: serial, 32 bytes.
    public static func parseInfo(name: String, hardwareIDs: [UInt8], serial: [UInt8]?) -> DeviceInfo {
        DeviceInfo(name: name,
                   serial: serial.flatMap { ascii($0, offset: 0, length: 32) },
                   firmware: ascii(hardwareIDs, offset: 97, length: 15),
                   model: ascii(hardwareIDs, offset: 170, length: 10),
                   uuid: ascii(hardwareIDs, offset: 33, length: 36))
    }
}

/// Link 2C digital reframe: XU9 sel 2 read-modify-write of X (byte 38) and Y (byte 40).
final class LinkReframe: ReframeCapability, @unchecked Sendable {
    let dev: UVCDevice
    let unit: UInt8
    let length: Int
    var travel: ReframeTravel { Link2CReframeMapping.travel }
    /// Last (x, y, zoom word) written; an identical write is skipped without USB traffic. Cleared on failure.
    private let memoLock = NSLock()
    private var lastWritten: (x: UInt16, y: UInt16, zoom: UInt16)?

    init(_ dev: UVCDevice) throws {
        guard let xu = dev.unitID(forGUID: Insta360LinkDriver.xuGUID) else { throw UVCError.noUnit("Insta360 XU") }
        self.dev = dev
        unit = xu
        length = try Insta360LinkDriver.length(dev.transport, unit: xu, selector: Insta360LinkDriver.reframeSelector)
        guard length >= Insta360LinkDriver.reframeYOffset + 2 else { throw UVCError.io(-2) }
    }

    func read(zoomFactor: Double) throws -> CGPoint {
        let r = try dev.transport.get(unit: unit, selector: Insta360LinkDriver.reframeSelector, length: length)
        guard let xy = Insta360LinkDriver.reframeXY(r) else { throw UVCError.io(-1) }
        return Link2CReframeMapping.normalized(x: xy.x, y: xy.y, zoomFactor: zoomFactor)
    }

    func write(_ center: CGPoint, zoomFactor: Double) throws {
        let raw = Link2CReframeMapping.raw(center.clampedToUnitSquare, zoomFactor: zoomFactor)
        let zoom = UInt16((zoomFactor * 100).rounded())
        memoLock.lock(); defer { memoLock.unlock() }
        if let l = lastWritten, l.x == raw.x, l.y == raw.y, l.zoom == zoom { return }
        lastWritten = nil
        try dev.transport.readModifyWrite(unit: unit, selector: Insta360LinkDriver.reframeSelector, length: length) { cur in
            Insta360LinkDriver.reframeRecord(cur, x: raw.x, y: raw.y, zoom: zoom)
        }
        lastWritten = (raw.x, raw.y, zoom)
    }
}

/// Normalized center <-> raw X/Y for the Link 2C, from hardware calibration (2026-10-13, firmware
/// v3.2.7.8_build2, `uvcctl reframe-calibrate` / `reframe-chain`, Vision translational registration):
/// - Raw is an absolute crop-center position: shift in 1x-frame units = (raw - 0x7FFF) / 65536, the same
///   at every zoom (2x: 0x800 -> 0.0625 output frame = 0.031 of 1x; 3x: 0x800 -> 0.0935 output = 0.031 of 1x;
///   4x: 0x1000 -> 0.125 output = 0.031 of 1x). Linear within the frame quantization (~1/32 output frame).
/// - Sign: raw above 0x7FFF moves the view right (X) / down (Y); content moves the other way.
/// - The firmware clamps (read-back) at 0x7FFF +- 65536 * ((1 - 1/z)/2 - 0.01): 1x 0 (no reframe at all),
///   2x 15728 (0x3D70), 3x 21190, 4x 23920 (0x5D70), i.e. the crop edge minus 1% of the frame.
/// - Y uses the frame height the same way X uses the width. Writes persist (3 s, across zoom changes).
/// Normalized center c in -1...1 is relative to the clamp at the given zoom: raw = 0x7FFF + c * clamp(z).
public enum Link2CReframeMapping {
    public static let inset = 0.01
    public static let travel = ReframeTravel.digitalCrop(scaleX: 1, scaleY: 1, inset: inset)

    /// Raw half-range the firmware accepts at zoom factor `z`.
    public static func clamp(zoomFactor z: Double) -> Double { 65536 * travel.offset(atZoom: z).dx }

    public static func raw(_ c: CGPoint, zoomFactor: Double) -> (x: UInt16, y: UInt16) {
        let k = clamp(zoomFactor: zoomFactor)
        func f(_ v: Double) -> UInt16 { UInt16(clamping: Int((Double(0x7FFF) + min(max(v, -1), 1) * k).rounded())) }
        return (f(c.x), f(c.y))
    }

    public static func normalized(x: UInt16, y: UInt16, zoomFactor: Double) -> CGPoint {
        let k = clamp(zoomFactor: zoomFactor)
        func f(_ v: UInt16) -> Double { k < 1 ? 0 : min(max((Double(v) - Double(0x7FFF)) / k, -1), 1) }
        return CGPoint(x: f(x), y: f(y))
    }
}
