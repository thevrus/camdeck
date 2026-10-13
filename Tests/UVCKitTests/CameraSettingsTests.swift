import XCTest
@testable import UVCKit

final class CameraSettingsTests: XCTestCase {
    func sample() -> CameraSettings {
        CameraSettings(standard: ["brightness": [10], "wb-auto": [1], "zoom": [200], "pantilt": [5, -5]],
                       profile: ["ev": 0.5, "aeMode": 1],
                       format: .init(width: 1920, height: 1080, fps: 30), autoFraming: "track")
    }

    func testCodableRoundTrip() throws {
        let s = sample()
        XCTAssertEqual(s.zoom, 200); XCTAssertEqual(s.pan, 5); XCTAssertEqual(s.tilt, -5)
        XCTAssertNil(s.controls["zoom"])
        let back = try JSONDecoder().decode(CameraSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        let bare = try JSONDecoder().decode(CameraSettings.self, from: JSONEncoder().encode(CameraSettings()))
        XCTAssertNil(bare.autoFraming)
    }

    func testApplyWritesOnlyChanges() {
        var log: [String] = []
        let w = CameraSettings.Writer(setControl: { log.append("c:\($0)=\($1)") },
                                      setProfile: { log.append("p:\($0)=\($1)") },
                                      setFormat: { log.append("f:\($0.id)") })
        let cur = sample()
        XCTAssertEqual(CameraSettings.apply(cur, current: cur, writer: w), 0)
        XCTAssertTrue(log.isEmpty)
        var target = cur
        target.controls["brightness"] = [20]
        target.controls["wb-auto"] = [0]
        target.controls["unsupported"] = [1]
        target.tilt = 9
        target.profile["ev"] = 1.0
        target.format = .init(width: 1280, height: 720, fps: 60)
        XCTAssertEqual(CameraSettings.apply(target, current: cur, writer: w), 5 + 0)
        XCTAssertEqual(log, ["c:wb-auto=[0]", "c:brightness=[20]", "c:pantilt=[5, 9]", "p:ev=1.0", "f:1280x720@60"])
    }
}
