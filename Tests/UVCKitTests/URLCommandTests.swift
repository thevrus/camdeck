import XCTest
@testable import UVCKit

final class URLCommandTests: XCTestCase {
    private func parse(_ s: String) -> (command: URLCommand, camera: String?)? {
        URL(string: s).flatMap(URLCommand.parse)
    }

    func testPresetByNameDecodesPercentEscapes() {
        XCTAssertEqual(parse("camdeck://preset/Meeting")?.command, .preset("Meeting"))
        XCTAssertEqual(parse("camdeck://preset/Night%20Mode")?.command, .preset("Night Mode"))
        XCTAssertEqual(parse("camdeck://preset/2")?.command, .preset("2"))
    }

    func testSimpleCommands() {
        XCTAssertEqual(parse("camdeck://reset-view")?.command, .resetView)
        XCTAssertEqual(parse("camdeck://reset-image")?.command, .resetImage)
        XCTAssertEqual(parse("camdeck://reset")?.command, .reset)
        XCTAssertEqual(parse("camdeck://fix")?.command, .fix)
        XCTAssertEqual(parse("camdeck://FIX?camera=Brio")?.camera, "Brio")
        XCTAssertEqual(parse("camdeck://lock/on")?.command, .lock(true))
        XCTAssertEqual(parse("camdeck://lock/OFF")?.command, .lock(false))
        XCTAssertEqual(parse("camdeck://camera/Insta360%20Link%202C")?.command, .camera("Insta360 Link 2C"))
    }

    func testCameraQuery() {
        let r = parse("camdeck://preset/Meeting?camera=Brio%20500")
        XCTAssertEqual(r?.command, .preset("Meeting"))
        XCTAssertEqual(r?.camera, "Brio 500")
        XCTAssertNil(parse("camdeck://reset?camera=")?.camera)
    }

    func testUnknownInputIsNil() {
        for s in ["https://preset/Meeting", "camdeck://", "camdeck://nope", "camdeck://preset", "camdeck://preset/",
                  "camdeck://lock", "camdeck://lock/maybe", "camdeck://reset/now", "camdeck://fix/now", "camdeck://camera"] {
            XCTAssertNil(parse(s), s)
        }
    }
}
