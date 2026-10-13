import XCTest
@testable import UVCKit

final class DescriptorTests: XCTestCase {
    func testCameraTerminal() throws {
        let t = try link2CTopology()
        XCTAssertTrue(t.hasVideoControl)
        XCTAssertEqual(t.controlInterface, 0)
        XCTAssertEqual(t.cameraTerminal?.id, 1)
        XCTAssertEqual(t.cameraTerminal?.bmControls, 0x027A20)
    }

    func testProcessingUnit() throws {
        let t = try link2CTopology()
        XCTAssertEqual(t.processingUnit?.id, 5)
        XCTAssertEqual(t.processingUnit?.bmControls, 0x145F)
    }

    func testExtensionUnits() throws {
        let t = try link2CTopology()
        XCTAssertEqual(t.extensionUnits.map(\.id), [9, 10, 11])
        XCTAssertEqual(t.extensionUnits.map(\.guid), [
            "faf1672d-b71b-4793-8c91-7b1c9b7f95f8",
            "e307e649-4618-a3ff-82fc-2d8b5f216773",
            "a8bd5df2-1a98-474e-8dd0-d92672d194fa",
        ])
    }

    func testAvailableControls() throws {
        let ids = Set(UVCControl.availableControls(in: try link2CTopology()).map(\.id))
        for want in ["zoom", "focus", "focus-auto", "pantilt", "roll", "brightness", "wb-temp"] {
            XCTAssertTrue(ids.contains(want), "missing \(want)")
        }
        XCTAssertFalse(ids.contains("exposure"))
        XCTAssertFalse(ids.contains("gain"))
    }

    func testPanTiltCodec() {
        let c = UVCControl.panTiltControl
        let bytes = c.encode([-36000, 72000])
        XCTAssertEqual(bytes.count, 8)
        XCTAssertEqual(c.decode(bytes), [-36000, 72000])
    }

}
