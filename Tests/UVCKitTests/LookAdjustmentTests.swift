import XCTest
@testable import UVCKit

final class LookAdjustmentTests: XCTestCase {
    private func state(_ id: String, _ lo: Int, _ hi: Int, cur: Int, res: Int? = nil) -> UVCControlState {
        var s = UVCControlState(control: UVCControl.all.first { $0.id == id }!)
        s.min = [lo]; s.max = [hi]; s.cur = [cur]; s.def = [cur]; s.info = 0x03; s.res = res.map { [$0] }
        return s
    }

    private var states: [UVCControlState] {
        [state("brightness", -64, 64, cur: 0), state("saturation", 0, 200, cur: 100), state("wb-temp", 2800, 6500, cur: 4600),
         state("wb-auto", 0, 1, cur: 1), state("ae-mode", 1, 8, cur: 8, res: 9), state("exposure", 1, 1000, cur: 100)]
    }

    func testMoveIsFractionOfRange() {
        let out = LookAdjustment(moves: ["brightness": 0.25]).resolve(states: states, current: ["brightness": [10]])
        XCTAssertEqual(out, ["brightness": [42]])
    }

    func testLevelIsAbsoluteAndClamped() {
        let out = LookAdjustment(moves: ["brightness": 5], levels: ["saturation": 0]).resolve(states: states, current: [:])
        XCTAssertEqual(out["saturation"], [0])
        XCTAssertEqual(out["brightness"], [64])
    }

    func testManualWhiteBalanceTurnsAutoOff() {
        let out = LookAdjustment(moves: ["wb-temp": -0.15]).resolve(states: states, current: [:])
        XCTAssertEqual(out["wb-temp"], [4045])
        XCTAssertEqual(out["wb-auto"], [0])
        // The model sometimes adds "auto on" next to a manual value; the manual value wins.
        let keep = LookAdjustment(moves: ["wb-temp": -0.15], autos: ["wb-auto": true]).resolve(states: states, current: [:])
        XCTAssertEqual(keep["wb-auto"], [0])
    }

    func testManualExposureUsesSupportedAutoBits() {
        let out = LookAdjustment(moves: ["exposure": 0.1]).resolve(states: states, current: [:])
        XCTAssertEqual(out["ae-mode"], [1])
        XCTAssertEqual(LookAdjustment(autos: ["ae-mode": true]).resolve(states: states, current: [:])["ae-mode"], [8])
    }

    func testAutoOffWithoutManualValueIsIgnored() {
        let out = LookAdjustment(levels: ["saturation": 0], autos: ["ae-mode": false, "wb-auto": false]).resolve(states: states, current: [:])
        XCTAssertEqual(out, ["saturation": [0]])
    }

    func testUnsupportedAndUnknownControlsAreIgnored() {
        let out = LookAdjustment(moves: ["contrast": 0.5, "zoom": 1, "bogus": 1]).resolve(states: states, current: [:])
        XCTAssertTrue(out.isEmpty)
    }

    func testKeywordFallback() {
        XCTAssertEqual(LookAdjustment.parse("make it warmer"), LookAdjustment(moves: ["wb-temp": -0.15]))
        XCTAssertEqual(LookAdjustment.parse("much cooler"), LookAdjustment(moves: ["wb-temp": 0.3]))
        XCTAssertEqual(LookAdjustment.parse("Black and white please"), LookAdjustment(levels: ["saturation": 0]))
        XCTAssertEqual(LookAdjustment.parse("a bit brighter and more contrast"), LookAdjustment(moves: ["brightness": 0.08, "contrast": 0.08]))
        XCTAssertEqual(LookAdjustment.parse("too bright"), LookAdjustment(moves: ["brightness": -0.15]))
        XCTAssertEqual(LookAdjustment.parse("look natural"), LookAdjustment(autos: ["wb-auto": true, "ae-mode": true]))
        XCTAssertNil(LookAdjustment.parse("zoom in on my face"))
        XCTAssertEqual(LookAdjustment.parse("too much light"), LookAdjustment(moves: ["brightness": -0.3]))
        XCTAssertEqual(LookAdjustment.parse("too dim"), LookAdjustment(moves: ["brightness": 0.15]))
        XCTAssertEqual(LookAdjustment.parse("washed out"), LookAdjustment(moves: ["saturation": -0.15]))
        XCTAssertEqual(LookAdjustment.parse("warmer, less blue"), LookAdjustment(moves: ["wb-temp": -0.15]))
        XCTAssertEqual(LookAdjustment.parse("desaturate"), LookAdjustment(moves: ["saturation": -0.15]))
        XCTAssertNil(LookAdjustment.parse("fix the backlight"))
        XCTAssertEqual(LookAdjustment.parse("always softer"), LookAdjustment(moves: ["sharpness": -0.15]))
    }

    func testSummary() {
        XCTAssertEqual(LookAdjustment(moves: ["wb-temp": -0.2, "saturation": -0.1]).summary(), "less saturation, warmer")
        XCTAssertEqual(LookAdjustment(levels: ["saturation": 0]).summary(), "black and white")
    }
}
