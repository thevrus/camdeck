import CoreGraphics
import XCTest
@testable import UVCKit

/// In-memory camera: answers GET_LEN/GET_CUR/GET_MIN/GET_MAX from a table, records SET_CUR.
final class FakeChannel: UVCRequestChannel, @unchecked Sendable {
    var cur: [UInt16: [UInt8]] = [:]      // key: unit << 8 | selector
    var minV: [UInt16: [UInt8]] = [:], maxV: [UInt16: [UInt8]] = [:]
    var sets: [(unit: UInt8, selector: UInt8, data: [UInt8])] = []
    var requests = 0
    func deviceRequest(requestType: UInt8, request: UInt8, value: UInt16, index: UInt16, data: [UInt8]) throws -> [UInt8] {
        requests += 1
        let unit = UInt8(index >> 8), sel = UInt8(value >> 8), key = UInt16(unit) << 8 | UInt16(sel)
        if requestType == 0x21 { sets.append((unit, sel, data)); cur[key] = data; return [] }
        let table: [UInt16: [UInt8]]
        switch request {
        case UVCRequest.len.rawValue:
            guard let c = cur[key] else { throw UVCError.io(-1) }
            return [UInt8(c.count & 0xFF), UInt8(c.count >> 8)]
        case UVCRequest.min.rawValue: table = minV
        case UVCRequest.max.rawValue: table = maxV
        default: table = cur
        }
        guard let b = table[key] else { throw UVCError.io(-1) }
        return Array(b.prefix(data.count))
    }
}

func fixtureHex(_ name: String) throws -> [UInt8] {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8).split(whereSeparator: { $0 == " " || $0.isNewline }).compactMap { UInt8($0, radix: 16) }
}

func link2CTopology() throws -> UVCTopology { UVCDescriptorParser.parse(try fixtureHex("link2c_config")) }

/// Scheduler with no waiting, so tests stay fast.
let instantScheduler = UVCRequestScheduler(limiter: UVCRateLimiter(minSpacing: 0, maxPerSecond: 1_000_000), sleep: { _ in })

final class DriverTests: XCTestCase {
    /// The 61-byte sel 2 record captured from the Link 2C (zoom 100, X = Y = 0x7FFF).
    let sel2: [UInt8] = [0x00, 0x10] + [UInt8](repeating: 0, count: 36) + [0xff, 0x7f, 0xff, 0x7f] + [UInt8](repeating: 0, count: 8)
        + [0x64, 0x00, 0x3e, 0xfe, 0x22, 0x08, 0x00, 0x00, 0x00, 0x00, 0x01]

    func link2C(_ ch: FakeChannel) throws -> UVCDevice {
        let t = try link2CTopology()
        ch.cur[0x0902] = sel2
        ch.cur[0x0903] = try fixtureHex("link2c_xu9_sel3")
        ch.cur[0x090C] = try fixtureHex("link2c_xu9_sel12")
        ch.minV[0x010B] = [100, 0]; ch.maxV[0x010B] = [0x90, 0x01]; ch.cur[0x010B] = [100, 0]
        return UVCDevice(vendorID: 0x2E1A, productID: 0x4C03, name: "Insta360 Link 2C", topology: t, channel: ch, scheduler: instantScheduler)
    }

    func testLink2CPlanPicksInsta360ReframeOverCT() throws {
        let d = CameraDescriptor(vendorID: 0x2E1A, productID: 0x4C03, name: "Link 2C", topology: try link2CTopology())
        let plan = DriverRegistry.standard.plan(for: d)
        XCTAssertEqual(plan.drivers, ["GenericUVC", "Profile", "Insta360Link"])
        XCTAssertEqual(plan.providers[.reframe], "Insta360Link")
        XCTAssertEqual(plan.providers[.zoom], "GenericUVC")
        XCTAssertEqual(plan.providers[.deviceInfo], "Insta360Link")
        XCTAssertEqual(plan.providers[.profileControls], "Profile")
        XCTAssertTrue(plan.quirks.contains(.ctPanTiltIneffective))
    }

    func testUnknownCameraGetsGenericOnly() throws {
        let d = CameraDescriptor(vendorID: 0x1234, productID: 0x5678, name: "Webcam", topology: try link2CTopology())
        let plan = DriverRegistry.standard.plan(for: d)
        XCTAssertEqual(plan.drivers, ["GenericUVC"])
        XCTAssertEqual(Set(plan.providers.values), ["GenericUVC"])
        // Its CT advertises pan/tilt and nobody marks it ineffective: CT reframe is offered.
        XCTAssertEqual(plan.providers[.reframe], "GenericUVC")
        XCTAssertNil(plan.providers[.profileControls])
    }

    func testComposeLink2C() throws {
        let ch = FakeChannel()
        let cam = DriverRegistry.standard.compose(try link2C(ch))
        XCTAssertNotNil(cam.reframe as? LinkReframe)
        XCTAssertEqual(cam.zoom?.factorRange, 1.0 ... 4.0)
        XCTAssertEqual(try cam.deviceInfo?.readInfo().serial, "IBNLA25128JG3D")
        XCTAssertTrue(ch.sets.isEmpty, "composition must only read")
    }

    func testReframeWriteChangesOnlyXYAndCommandedZoom() throws {
        let ch = FakeChannel()
        let cam = DriverRegistry.standard.compose(try link2C(ch))
        try XCTUnwrap(cam.reframe).write(CGPoint(x: 1, y: -0.5), zoomFactor: 2)
        let w = try XCTUnwrap(ch.sets.last)
        XCTAssertEqual(w.selector, 2); XCTAssertEqual(w.unit, 9)
        XCTAssertEqual(w.data.count, 61)
        for i in 0 ..< 61 where !(38 ... 41).contains(i) && !(50 ... 51).contains(i) { XCTAssertEqual(w.data[i], sel2[i], "byte \(i) changed") }
        XCTAssertEqual(Array(w.data[50 ... 51]), [200, 0], "zoom mirror must carry the commanded zoom, not a stale read")
        let xy = try XCTUnwrap(Insta360LinkDriver.reframeXY(w.data))
        XCTAssertEqual(Double(xy.x), Double(0x7FFF + 15728), accuracy: 1)   // 2x clamp, measured
        XCTAssertEqual(Double(xy.y), Double(0x7FFF - 7864), accuracy: 1)
        XCTAssertEqual(ch.sets.count, 1)
    }

    func testIdenticalReframeWriteIsSkipped() throws {
        let ch = FakeChannel()
        let cam = DriverRegistry.standard.compose(try link2C(ch))
        let cap = try XCTUnwrap(cam.reframe)
        try cap.write(CGPoint(x: 0.5, y: 0), zoomFactor: 2)
        try cap.write(CGPoint(x: 0.5, y: 0), zoomFactor: 2)
        XCTAssertEqual(ch.sets.count, 1, "identical write must not reach USB")
        try cap.write(CGPoint(x: -0.5, y: 0), zoomFactor: 2)
        XCTAssertEqual(ch.sets.count, 2)
    }

    func testReframeRecordPreservesEverythingElse() {
        let rec = (0 ..< 61).map { UInt8($0) }
        let out = Insta360LinkDriver.reframeRecord(rec, x: 0x1234, y: 0xABCD)
        XCTAssertEqual(Array(out[38 ... 41]), [0x34, 0x12, 0xCD, 0xAB])
        XCTAssertEqual(Array(out[0 ..< 38]), Array(rec[0 ..< 38]))
        XCTAssertEqual(Array(out[42...]), Array(rec[42...]))
    }

    func testLink2CMappingMatchesCalibration() {
        XCTAssertEqual(Link2CReframeMapping.clamp(zoomFactor: 1), 0)
        XCTAssertEqual(Link2CReframeMapping.clamp(zoomFactor: 2), 15728, accuracy: 1)
        XCTAssertEqual(Link2CReframeMapping.clamp(zoomFactor: 3), 21190, accuracy: 1)
        XCTAssertEqual(Link2CReframeMapping.clamp(zoomFactor: 4), 23920, accuracy: 1)
        XCTAssertEqual(Link2CReframeMapping.raw(CGPoint(x: 1, y: 1), zoomFactor: 1).x, 0x7FFF)
        let r = Link2CReframeMapping.raw(CGPoint(x: -0.25, y: 0.5), zoomFactor: 3)
        let back = Link2CReframeMapping.normalized(x: r.x, y: r.y, zoomFactor: 3)
        XCTAssertEqual(Double(back.x), -0.25, accuracy: 0.001); XCTAssertEqual(Double(back.y), 0.5, accuracy: 0.001)
    }

    func testDeviceInfoFromCapturedFixture() throws {
        let ids = try fixtureHex("link2c_xu9_sel3"), serial = try fixtureHex("link2c_xu9_sel12")
        XCTAssertEqual(ids.count, 234); XCTAssertEqual(serial.count, 32)
        let i = Insta360LinkDriver.parseInfo(name: "Insta360 Link 2C", hardwareIDs: ids, serial: serial)
        XCTAssertEqual(i.firmware, "v3.2.7.8_build2")
        XCTAssertEqual(i.model, "Insta Puc2")
        XCTAssertEqual(i.uuid, "017C550B-2E0E-86B2-343A-267559154012")
        XCTAssertEqual(i.serial, "IBNLA25128JG3D")
    }

    func testTransportRefusesForbiddenSelector() throws {
        let ch = FakeChannel()
        let dev = try link2C(ch)
        XCTAssertThrowsError(try dev.transport.set(unit: 9, selector: 17, data: [0])) { e in
            guard case UVCError.forbidden = e else { return XCTFail("wrong error \(e)") }
        }
        XCTAssertThrowsError(try dev.transport.readModifyWrite(unit: 9, selector: 17, length: 1) { $0 })
        XCTAssertTrue(ch.sets.isEmpty)
        XCTAssertEqual(ch.requests, 0, "a forbidden selector is not even read")
        XCTAssertNoThrow(try dev.transport.set(unit: 9, selector: 2, data: sel2))
        XCTAssertTrue(DriverRegistry.allForbiddenSelectors.contains(ForbiddenSelectorKey(guid: Insta360LinkDriver.xuGUID, selector: 17)))
    }

    func testRateLimiterSpacingAndCap() {
        var l = UVCRateLimiter(minSpacing: 0.005, maxPerSecond: 100)
        let times = (0 ..< 250).map { _ in l.reserve(now: 0) }
        for (a, b) in zip(times, times.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, 0.005 - 1e-9) }
        for i in 100 ..< times.count { XCTAssertGreaterThanOrEqual(times[i] - times[i - 100], 1 - 1e-9, "more than 100 in a second at \(i)") }
        // An idle gap needs no wait.
        var m = UVCRateLimiter()
        XCTAssertEqual(m.reserve(now: 10), 10); XCTAssertEqual(m.reserve(now: 11), 11)
    }

    func testSchedulerSleepsPerLimiter() {
        final class Clock: @unchecked Sendable { var t = 0.0; var slept = 0.0 }
        let c = Clock()
        let s = UVCRequestScheduler(limiter: UVCRateLimiter(minSpacing: 0.005, maxPerSecond: 100),
                                    clock: { c.t }, sleep: { c.slept += $0; c.t += $0 })
        for _ in 0 ..< 101 { s.perform { } }
        XCTAssertGreaterThanOrEqual(c.slept, 1 - 1e-9)
    }

    func testSignedStandardControlRoundTrip() {
        let hue = UVCControl.all.first { $0.id == "hue" }!
        XCTAssertEqual(hue.encode([-15]), [0xF1, 0xFF])
        XCTAssertEqual(hue.decode([0xF1, 0xFF]), [-15])
        XCTAssertEqual(hue.decode(hue.encode([15])), [15])
        XCTAssertEqual(hue.decode(hue.encode([0])), [0])
        let pt = UVCControl.all.first { $0.id == "pantilt" }!
        XCTAssertEqual(pt.decode(pt.encode([-522_000, 360_000])), [-522_000, 360_000])
        let contrast = UVCControl.all.first { $0.id == "contrast" }!
        XCTAssertEqual(contrast.decode([0xFF, 0xFF]), [65535], "unsigned controls do not sign-extend")
    }

    func testNaturalFormatOnLink2CModes() {
        var modes: [VideoMode] = []
        for _ in ["420v", "2vuy"] {
            for f in [30, 25, 24] { modes.append(VideoMode(width: 3840, height: 2160, fps: f)) }
            for (w, h) in [(1920, 1440), (1920, 1080), (1280, 960), (1280, 720)] {
                for f in [60, 50, 30, 25, 24] { modes.append(VideoMode(width: w, height: h, fps: f)) }
            }
        }
        XCTAssertEqual(VideoModeChooser.natural(modes, minFPS: 30), VideoMode(width: 3840, height: 2160, fps: 30))
        XCTAssertEqual(VideoModeChooser.natural(modes.filter { $0.width < 3840 }, minFPS: 30), VideoMode(width: 1920, height: 1080, fps: 30))
        XCTAssertEqual(VideoModeChooser.offeredRates(minFrameRate: 30, maxFrameRate: 30), [30])
    }

    func testReframeUnitsRoundTrip() {
        let tr = Link2CReframeMapping.travel
        let o = ReframeUnits.offset(center: CGPoint(x: 0.5, y: -1), travel: tr, zoomFactor: 2)
        XCTAssertEqual(o.pan, 120_000); XCTAssertEqual(o.tilt, -240_000)
        let c = ReframeUnits.center(pan: o.pan, tilt: o.tilt, travel: tr, zoomFactor: 2)
        XCTAssertEqual(Double(c.x), 0.5, accuracy: 1e-6); XCTAssertEqual(Double(c.y), -1, accuracy: 1e-6)
    }
}
