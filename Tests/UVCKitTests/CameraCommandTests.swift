import XCTest
@testable import UVCKit

final class CameraCommandTests: XCTestCase {
    func p(_ s: String) -> [CameraCommand] { CameraCommand.parse(s, presets: ["Meeting", "Warm Studio"], resolutions: ["4K", "1080p", "720p"]) }

    func testZoom() {
        XCTAssertEqual(p("zoom in"), [.zoom(.step(1))])
        XCTAssertEqual(p("zoom out a lot"), [.zoom(.step(-3))])
        XCTAssertEqual(p("zoom to 2x"), [.zoom(.factor(2))])
        XCTAssertEqual(p("zoom all the way out"), [.zoom(.widest)])
        XCTAssertEqual(p("closer"), [.zoom(.step(1))])
    }

    func testMove() {
        XCTAssertEqual(p("move the view left"), [.move(dx: -0.25, dy: 0)])
        XCTAssertEqual(p("pan right and tilt up"), [.move(dx: 0.25, dy: -0.25)])
        XCTAssertEqual(p("lower contrast"), [.look(LookAdjustment(moves: ["contrast": -0.15]))])
    }

    func testFormat() {
        XCTAssertEqual(p("switch to 1080p"), [.format(resolution: "1080p", fps: nil)])
        XCTAssertEqual(p("60 fps"), [.format(resolution: nil, fps: 60)])
        XCTAssertEqual(p("4k at 30fps"), [.format(resolution: "4K", fps: 30)])
    }

    func testFramingPresetsResetMirrorLock() {
        XCTAssertEqual(p("follow me"), [.autoFraming("medium")])
        XCTAssertEqual(p("track me close"), [.autoFraming("close")])
        XCTAssertEqual(p("stop following me"), [.autoFraming("off")])
        XCTAssertEqual(p("apply meeting"), [.preset("Meeting")])
        XCTAssertEqual(p("warm studio"), [.preset("Warm Studio")])
        XCTAssertEqual(p("save this as preset Podcast"), [.savePreset("Podcast")])
        XCTAssertEqual(p("save preset"), [.savePreset(nil)])
        XCTAssertEqual(p("reset the view"), [.reset(.view)])
        XCTAssertEqual(p("reset everything"), [.reset(.all)])
        XCTAssertEqual(p("reset colors"), [.reset(.image)])
        XCTAssertEqual(p("mirror off"), [.mirror(false)])
        XCTAssertEqual(p("keep my settings"), [.keepSettings(true)])
    }

    func testCombinedAndNothing() {
        XCTAssertEqual(p("warmer and zoom in"), [.zoom(.step(1)), .look(LookAdjustment(moves: ["wb-temp": -0.15]))])
        XCTAssertEqual(p("hello there"), [])
        XCTAssertEqual(p("don't mirror"), [.mirror(false)])
        XCTAssertEqual(p("don't follow me"), [.autoFraming("off")])
        XCTAssertEqual(p("warm it up a bit"), [.look(LookAdjustment(moves: ["wb-temp": -0.08]))])
        XCTAssertEqual(p("point the camera up"), [.move(dx: 0, dy: -0.25)])
    }
}
