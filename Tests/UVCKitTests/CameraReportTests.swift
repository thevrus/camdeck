import XCTest
@testable import UVCKit

final class CameraReportTests: XCTestCase {
    private func topology(units: [(UInt8, String)]) -> UVCTopology {
        var t = UVCTopology()
        t.extensionUnits = units.map { UVCExtensionUnit(id: $0.0, guid: $0.1, numControls: 4, bmControls: []) }
        return t
    }

    func testStarterProfileIsValidAndMatchesTheCamera() throws {
        let t = topology(units: [(6, "6cb3abac-b431-5316-c4ac-d27a1f11a12e"), (9, "a8e5782b-36e6-4fa1-87f8-83e32b323a2e")])
        let json = CameraReport.starterProfile(name: "Cam \"Pro\"", vendorID: 0x046D, productID: 0x085E, topology: t)
        let p = try DeviceProfile.decode(Data(json.utf8))
        XCTAssertEqual(p.name, "Cam \"Pro\"")
        XCTAssertTrue(p.matches(vendorID: 0x046D, productID: 0x085E))
        XCTAssertFalse(p.matches(vendorID: 0x046D, productID: 0x0001))
        XCTAssertEqual(p.units, ["xu6": "6cb3abac-b431-5316-c4ac-d27a1f11a12e", "xu9": "a8e5782b-36e6-4fa1-87f8-83e32b323a2e"])
        XCTAssertTrue(p.controls.isEmpty)
    }

    func testStarterProfileWithoutExtensionUnitsDecodes() throws {
        let json = CameraReport.starterProfile(name: "Plain", vendorID: 1, productID: 2, topology: UVCTopology())
        XCTAssertEqual(try DeviceProfile.decode(Data(json.utf8)).units, [:])
    }
}
