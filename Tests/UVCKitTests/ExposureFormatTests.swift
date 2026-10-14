import XCTest
@testable import UVCKit

final class ExposureFormatTests: XCTestCase {
    func testShutter() {
        XCTAssertEqual(ExposureFormat.shutter(exposure100us: 167), "1/60 s")
        XCTAssertEqual(ExposureFormat.shutter(exposure100us: 333), "1/30 s")
        XCTAssertEqual(ExposureFormat.shutter(exposure100us: 10000), "1 s")
        XCTAssertEqual(ExposureFormat.shutter(exposure100us: 8000), "0.8 s")
        XCTAssertNil(ExposureFormat.shutter(exposure100us: 0))
        XCTAssertEqual(ExposureFormat.shutter(denominator: 29), "1/30 s")
    }

    func testReadout() {
        XCTAssertEqual(ExposureFormat.readout(shutter: "1/60 s", gainLabel: "gain 32"), "Auto: 1/60 s · gain 32")
        XCTAssertEqual(ExposureFormat.readout(shutter: nil, gainLabel: "ISO 400"), "Auto: ISO 400")
        XCTAssertNil(ExposureFormat.readout(shutter: nil, gainLabel: nil))
    }
}
