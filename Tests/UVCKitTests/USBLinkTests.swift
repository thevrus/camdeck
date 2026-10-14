import XCTest
@testable import UVCKit

final class USBLinkTests: XCTestCase {
    func testUSB3DeviceBelowSuperSpeedWarns() {
        XCTAssertNotNil(USBLink.assess(bcdUSB: 0x0300, speed: 2))
        XCTAssertNotNil(USBLink.assess(bcdUSB: 0x0320, speed: 1))
        XCTAssertNotNil(USBLink.assess(bcdUSB: 0x0310, speed: 0))
    }

    func testUSB3DeviceAtSuperSpeedDoesNotWarn() {
        XCTAssertNil(USBLink.assess(bcdUSB: 0x0300, speed: 3))
        XCTAssertNil(USBLink.assess(bcdUSB: 0x0320, speed: 4))
    }

    func testUSB2DeviceNeverWarns() {
        XCTAssertNil(USBLink.assess(bcdUSB: 0x0200, speed: 2))
        XCTAssertNil(USBLink.assess(bcdUSB: 0x0210, speed: 2))
        XCTAssertNil(USBLink.assess(bcdUSB: 0x0110, speed: 1))
    }

    func testMessage() {
        XCTAssertEqual(USBLink.assess(bcdUSB: 0x0300, speed: 2)?.message,
                       "Connected at USB 2 speed. Use a USB 3 port or cable for full quality.")
    }
}
