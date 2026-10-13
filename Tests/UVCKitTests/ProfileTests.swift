import XCTest
@testable import UVCKit

final class ProfileTests: XCTestCase {
    func topology() throws -> UVCTopology {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "link2c_config", withExtension: "txt", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let bytes = text.split(whereSeparator: \.isNewline).flatMap { line in
            line.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        }
        return UVCDescriptorParser.parse(bytes)
    }

    func link() throws -> DeviceProfile {
        try XCTUnwrap(VendorProfiles.all.first { $0.matches(vendorID: 0x2E1A, productID: 0x4C03) })
    }

    func control(_ id: String) throws -> ProfileControl { try XCTUnwrap(link().control(id)) }

    func testBundledProfileDecodes() throws {
        let p = try link()
        XCTAssertEqual(p.name, "Insta360 Link")
        XCTAssertEqual(p.controls.map(\.id), ["aeMode", "ev", "iso", "shutter", "hdr"])
        XCTAssertEqual(VendorProfiles.profile(vendorID: 1, productID: 1), .generic)
        XCTAssertTrue(DeviceProfile.generic.controls.isEmpty)
    }

    func testEveryControlUnitIsInFixture() throws {
        let guids = Set(try topology().extensionUnits.map(\.guid))
        let p = try link()
        for c in p.controls { XCTAssertTrue(guids.contains(p.guid(for: c.unit)), "\(c.id) unit missing from descriptor") }
        for f in p.forbiddenSelectors { XCTAssertTrue(guids.contains(p.guid(for: f.unit))) }
    }

    func testI16leEV() throws {
        let ev = try control("ev")
        XCTAssertEqual(ev.encoding.encode(-200, current: nil), [0x38, 0xFF])
        XCTAssertEqual(ev.encoding.decode([0x38, 0xFF]), -200)
        XCTAssertEqual(ev.encoding.encode(60, current: nil), [60, 0])
        XCTAssertEqual(ev.wire(fromDisplay: "-2.0"), -200)
        XCTAssertEqual(ev.displayText(60), "+0.6 EV")
        XCTAssertEqual(ev.normalize(999), 300)
        XCTAssertEqual(ev.normalize(-97), -100)
    }

    func testU16le() throws {
        let iso = try control("iso")
        XCTAssertEqual(iso.encoding.encode(800, current: nil), [0x20, 0x03])
        XCTAssertEqual(iso.encoding.decode([0x20, 0x03]), 800)
    }

    func testShutterReadbackSnapsToNearestOption() throws {
        let s = try control("shutter")
        XCTAssertEqual(s.normalize(29), 30)
        XCTAssertEqual(s.displayText(250), "1/250")
        XCTAssertEqual(s.wire(fromDisplay: "250"), 250)
        XCTAssertEqual(s.wire(fromDisplay: "1/250"), 250)
    }

    func testBitRMW() throws {
        let hdr = try control("hdr")
        XCTAssertTrue(hdr.needsReadModifyWrite)
        XCTAssertNil(hdr.encoding.encode(1, current: nil), "bit writes need the current mask")
        XCTAssertEqual(hdr.encoding.encode(1, current: [0xC0, 0x01]), [0xC4, 0x01])
        XCTAssertEqual(hdr.encoding.encode(0, current: [0xC4, 0x01]), [0xC0, 0x01])
        // Other bits survive in both directions.
        XCTAssertEqual(hdr.encoding.encode(1, current: [0xFB, 0xFF]), [0xFF, 0xFF])
        XCTAssertEqual(hdr.encoding.encode(0, current: [0xFF, 0xFF]), [0xFB, 0xFF])
        XCTAssertEqual(hdr.encoding.decode([0xC4, 0x01]), 1)
        XCTAssertEqual(hdr.encoding.decode([0xC0, 0x01]), 0)
    }

    func testEnabledWhen() throws {
        let ev = try control("ev"), iso = try control("iso")
        XCTAssertTrue(ev.isEnabled(values: ["aeMode": 2]))
        XCTAssertFalse(ev.isEnabled(values: ["aeMode": 1]))
        XCTAssertTrue(iso.isEnabled(values: ["aeMode": 1]))
        XCTAssertFalse(iso.isEnabled(values: [:]))
    }

    func testValidationRejectsBitWithoutRMW() throws {
        var p = try link()
        let i = try XCTUnwrap(p.controls.firstIndex { $0.id == "hdr" })
        p.controls[i].rmw = nil
        XCTAssertThrowsError(try p.validate())
    }

    func testForbiddenSelectorGuard() throws {
        let t = try topology()
        let xu9 = try XCTUnwrap(t.extensionUnits.first { $0.guid == "faf1672d-b71b-4793-8c91-7b1c9b7f95f8" })
        XCTAssertTrue(try link().isForbidden(unitGUID: xu9.guid, selector: 17))
        XCTAssertThrowsError(try UVCDevice.guardWrite(topology: t, unit: xu9.id, selector: 17)) { e in
            guard case UVCError.forbidden = e else { return XCTFail("wrong error \(e)") }
        }
        XCTAssertNoThrow(try UVCDevice.guardWrite(topology: t, unit: xu9.id, selector: 27))
        // Standard units are never extension units, so they pass.
        XCTAssertNoThrow(try UVCDevice.guardWrite(topology: t, unit: 5, selector: 17))
    }

    func testNaturalDefaultsDecode() throws {
        let nd = try XCTUnwrap(link().naturalDefaults)
        XCTAssertEqual(nd.standard?["sharpness"], 26)
        XCTAssertEqual(nd.standard?["powerline"], 2)
        XCTAssertEqual(nd.standard?["focus-auto"], 1)
        XCTAssertEqual(nd.profile?["aeMode"], 2)
        XCTAssertEqual(nd.profile?["ev"], 0.6)
        XCTAssertEqual(nd.profile?["hdr"], 1)
        XCTAssertEqual(try control("ev").wire(fromDisplayValue: 0.6), 60)
        XCTAssertNil(DeviceProfile.generic.naturalDefaults)
    }

    func testNaturalDefaultsRejectUnknownIDs() throws {
        let json = #"""
        {"name":"X","units":{},"controls":[],"forbiddenSelectors":[],"naturalDefaults":{"standard":{"nope":1}}}
        """#
        XCTAssertThrowsError(try DeviceProfile.decode(Data(json.utf8)))
    }
}
