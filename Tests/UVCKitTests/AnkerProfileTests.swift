import XCTest
@testable import UVCKit

/// Offset-in-GET_LEN-buffer encodings and the Anker profiles that use them.
final class AnkerProfileTests: XCTestCase {
    // GUIDs as raw descriptor bytes (first three fields little-endian on the wire).
    // C310: cameractrls.py ANKERWORK_GUID, verbatim. C200: lsusb {6CB3ABAC-B431-5316-C4AC-D27A1F11A12E}, unit 6.
    static let c310GUIDBytes: [UInt8] = [0xa2, 0x9e, 0x76, 0x41, 0xde, 0x04, 0x47, 0xe3, 0x8b, 0x2b, 0xf4, 0x34, 0x1a, 0xff, 0x00, 0x3b]
    static let c200GUIDBytes: [UInt8] = [0xac, 0xab, 0xb3, 0x6c, 0x31, 0xb4, 0x16, 0x53, 0xc4, 0xac, 0xd2, 0x7a, 0x1f, 0x11, 0xa1, 0x2e]

    /// Minimal config descriptor: a VideoControl interface with one extension unit.
    func topology(unit: UInt8, guid: [UInt8]) -> UVCTopology {
        let interface: [UInt8] = [0x09, 0x04, 0x00, 0x00, 0x00, 0x0E, 0x01, 0x00, 0x00]
        let xu: [UInt8] = [28, 0x24, 0x06, unit] + guid + [15, 1, 4, 3, 0x00, 0xf8, 0x27, 0]
        return UVCDescriptorParser.parse(interface + xu)
    }

    func profile(_ pid: UInt16) throws -> DeviceProfile {
        try XCTUnwrap(VendorProfiles.all.first { $0.matches(vendorID: 0x291A, productID: pid) })
    }

    // MARK: Encoding

    func testU8AtOffset() {
        let e = ProfileEncoding.u8AtOffset(offset: 1)
        XCTAssertNil(e.size, "length comes from GET_LEN")
        XCTAssertEqual(e.decode([0x01, 0x23]), 0x23)
        XCTAssertNil(e.decode([0x01]), "buffer too short")
        XCTAssertNil(e.encode(50, current: nil), "offset writes need the current buffer")
        XCTAssertNil(e.encode(50, current: [0x01]))
        XCTAssertEqual(e.encode(50, current: [0x01, 0x23, 0xAA]), [0x01, 50, 0xAA])
        XCTAssertEqual(e.encode(300, current: [0, 0]), [0, 255], "clamps to a byte")
    }

    func testU16leAtOffset() {
        let e = ProfileEncoding.u16leAtOffset(offset: 2)
        XCTAssertNil(e.size)
        let buf: [UInt8] = [0x00, 0x01, 0x5f, 0x00] + [UInt8](repeating: 0xEE, count: 56)
        XCTAssertEqual(e.decode(buf), 95)
        XCTAssertNil(e.decode([0x00, 0x01, 0x5f]))
        XCTAssertNil(e.encode(65, current: nil))
        XCTAssertNil(e.encode(65, current: [0x00, 0x01, 0x5f]))
        let out = try? XCTUnwrap(e.encode(0x1234, current: buf))
        XCTAssertEqual(out?.count, 60, "the whole device-sized buffer goes back")
        XCTAssertEqual(out.map { Array($0[2 ... 3]) }, [0x34, 0x12])
        XCTAssertEqual(out.map { Array($0[0 ... 1]) }, [0x00, 0x01])
        XCTAssertEqual(out.map { Array($0[4...]) }, Array(buf[4...]))
        XCTAssertEqual(out.flatMap(e.decode), 0x1234)
    }

    func testFixedSizesUnchanged() {
        XCTAssertEqual(ProfileEncoding.u8.size, 1)
        XCTAssertEqual(ProfileEncoding.u16le.size, 2)
        XCTAssertEqual(ProfileEncoding.i16le.size, 2)
        XCTAssertEqual(ProfileEncoding.bitInU16le(bit: 3).size, 2)
    }

    func testOffsetEncodingJSON() throws {
        let a = try JSONDecoder().decode(ProfileEncoding.self, from: Data(#"{"type": "u8-at-offset", "offset": 3}"#.utf8))
        XCTAssertEqual(a, .u8AtOffset(offset: 3))
        let b = try JSONDecoder().decode(ProfileEncoding.self, from: Data(#"{"type": "u16le-at-offset", "offset": 2}"#.utf8))
        XCTAssertEqual(b, .u16leAtOffset(offset: 2))
        for e in [a, b] {
            XCTAssertEqual(try JSONDecoder().decode(ProfileEncoding.self, from: JSONEncoder().encode(e)), e)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(ProfileEncoding.self, from: Data(#"{"type": "u8-at-offset", "offset": -1}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(ProfileEncoding.self, from: Data(#"{"type": "u8-at-offset"}"#.utf8)))
    }

    func testValidationRejectsOffsetWithoutRMW() throws {
        for pid: UInt16 in [0x3367, 0x3369] {
            var p = try profile(pid)
            XCTAssertNoThrow(try p.validate())
            p.controls[0].rmw = nil
            XCTAssertThrowsError(try p.validate())
            p.controls[0].rmw = false
            XCTAssertThrowsError(try p.validate())
        }
    }

    // MARK: Bundled profiles

    func testBundledAnkerProfilesDecode() throws {
        let c310 = try profile(0x3367), c200 = try profile(0x3369)
        XCTAssertEqual(c310.name, "AnkerWork C310")
        XCTAssertEqual(c310.controls.map(\.id), ["fov", "faceFocus", "faceExposure", "faceExposureAmount", "micNoiseReduction", "micPickup"])
        XCTAssertEqual(c200.name, "Anker PowerConf C200")
        XCTAssertEqual(c200.controls.map(\.id), ["fov", "hdr", "horizontalFlip"])
        XCTAssertFalse(c310.matches(vendorID: 0x291A, productID: 0x3369))
        XCTAssertFalse(c200.matches(vendorID: 0x291A, productID: 0x3367))
        // Known-broken C310 selectors (HDR 0x13, flip 0x11) are not offered.
        XCTAssertFalse(c310.controls.contains { [0x11, 0x13].contains($0.selector) })
    }

    func testProfileGUIDsMatchDescriptorBytes() throws {
        let c310 = try profile(0x3367), c200 = try profile(0x3369)
        XCTAssertEqual(topology(unit: 4, guid: Self.c310GUIDBytes).extensionUnits.first?.guid, c310.guid(for: "xu"))
        XCTAssertEqual(topology(unit: 6, guid: Self.c200GUIDBytes).extensionUnits.first?.guid, c200.guid(for: "xu6"))
    }

    // MARK: UVCDevice, dynamic GET_LEN

    func testC200FOVReadsAndWritesWithinGETLENBuffer() throws {
        let ch = FakeChannel()
        let key: UInt16 = 0x0610 // unit 6, selector 0x10
        let buf: [UInt8] = [0x00, 0x01, 78, 0x00] + (4 ..< 60).map { UInt8($0) }
        ch.cur[key] = buf
        let dev = UVCDevice(vendorID: 0x291A, productID: 0x3369, name: "Anker PowerConf C200",
                            topology: topology(unit: 6, guid: Self.c200GUIDBytes), channel: ch, scheduler: instantScheduler)
        let fov = try XCTUnwrap(dev.profile.control("fov"))
        XCTAssertTrue(dev.supports(fov))

        XCTAssertEqual(try dev.readProfile(fov), 78)
        XCTAssertEqual(ch.requests, 2, "GET_LEN then GET_CUR")

        try dev.writeProfile(fov, wire: 95)
        let w = try XCTUnwrap(ch.sets.last)
        XCTAssertEqual(w.unit, 6); XCTAssertEqual(w.selector, 0x10)
        XCTAssertEqual(w.data.count, 60, "SET_CUR uses the device-reported length")
        XCTAssertEqual(Array(w.data[2 ... 3]), [95, 0])
        for i in 0 ..< 60 where !(2 ... 3).contains(i) { XCTAssertEqual(w.data[i], buf[i], "byte \(i) changed") }
        XCTAssertEqual(try dev.readProfile(fov), 95)
    }

    func testC310FaceExposureFieldsShareOneSelector() throws {
        let ch = FakeChannel()
        ch.cur[0x040B] = [0x01, 35] // enabled, amount 35 (0 EV)
        let dev = UVCDevice(vendorID: 0x291A, productID: 0x3367, name: "AnkerWork C310",
                            topology: topology(unit: 4, guid: Self.c310GUIDBytes), channel: ch, scheduler: instantScheduler)
        let on = try XCTUnwrap(dev.profile.control("faceExposure"))
        let amount = try XCTUnwrap(dev.profile.control("faceExposureAmount"))
        XCTAssertEqual(try dev.readProfile(on), 1)
        XCTAssertEqual(try dev.readProfile(amount), 35)
        try dev.writeProfile(amount, wire: 60)
        XCTAssertEqual(ch.sets.last?.data, [0x01, 60], "amount write keeps the enable byte")
        try dev.writeProfile(on, wire: 0)
        XCTAssertEqual(ch.sets.last?.data, [0x00, 60], "enable write keeps the amount byte")
    }

    func testShortReadIsNotWrittenBack() throws {
        final class ShortChannel: UVCRequestChannel, @unchecked Sendable {
            var sets = 0
            func deviceRequest(requestType: UInt8, request: UInt8, value: UInt16, index: UInt16, data: [UInt8]) throws -> [UInt8] {
                if requestType == 0x21 { sets += 1; return [] }
                if request == UVCRequest.len.rawValue { return [60, 0] }
                return [0x00, 0x01, 78, 0x00] // device returns fewer bytes than GET_LEN promised
            }
        }
        let ch = ShortChannel()
        let dev = UVCDevice(vendorID: 0x291A, productID: 0x3369, name: "C200",
                            topology: topology(unit: 6, guid: Self.c200GUIDBytes), channel: ch, scheduler: instantScheduler)
        let fov = try XCTUnwrap(dev.profile.control("fov"))
        XCTAssertThrowsError(try dev.writeProfile(fov, wire: 95))
        XCTAssertEqual(ch.sets, 0)
    }

    /// Fixed-size encodings must not pick up a GET_LEN round trip.
    func testFixedSizeProfileReadSkipsGETLEN() throws {
        let ch = FakeChannel()
        ch.cur[0x091E] = [2] // XU9 sel 30, AE mode auto
        let dev = UVCDevice(vendorID: 0x2E1A, productID: 0x4C03, name: "Insta360 Link 2C",
                            topology: try link2CTopology(), channel: ch, scheduler: instantScheduler)
        XCTAssertEqual(try dev.readProfile(try XCTUnwrap(dev.profile.control("aeMode"))), 2)
        XCTAssertEqual(ch.requests, 1)
    }
}
