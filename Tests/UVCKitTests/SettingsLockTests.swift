import XCTest
@testable import UVCKit

@MainActor
final class SettingsLockTests: XCTestCase {
    var device: [String: [Int]] = ["wb-auto": [0], "wb-temp": [5000], "brightness": [10], "contrast": [3], "exposure": [100], "ae-mode": [1], "zoom": [100]]
    var writes: [String] = []
    var clock = Date(timeIntervalSince1970: 1000)
    var autoFraming = false
    var reads: [[String]] = []

    func make(name: String, eventDelays: [Duration] = [.milliseconds(40), .milliseconds(120)]) -> SettingsLock {
        let d = UserDefaults(suiteName: "lock-test-\(name)-\(UUID())")!
        return SettingsLock(uniqueID: name, defaults: d, now: { self.clock }, debounce: .milliseconds(50), eventDelays: eventDelays,
                            observeAppActivation: false,
                            capture: { CameraSettings(standard: self.device, profile: [:], format: nil) },
                            apply: { _ in 0 },
                            read: { ids in self.reads.append(ids); return self.device.filter { ids.contains($0.key) } },
                            write: { self.writes.append($0); self.device[$0] = $1 },
                            isAutoFramingActive: { self.autoFraming })
    }

    func testReassertsOnlyDrifted() async {
        let lock = make(name: "a")
        lock.isEnabled = true
        device["brightness"] = [50]
        device["contrast"] = [9]
        clock += 20
        await lock.verify()
        XCTAssertEqual(writes, ["brightness", "contrast"])
        XCTAssertEqual(lock.reassertCount, 1)
        XCTAssertEqual(lock.lastReassert, clock)
        XCTAssertLessThanOrEqual(reads[0].count, 11)
        XCTAssertTrue(reads[0].contains("exposure"))  // AE manual: exposure is verified
        clock += 20
        await lock.verify()
        XCTAssertEqual(lock.reassertCount, 1)  // nothing drifted
    }

    func testPolitenessAutoFramingAndUserChange() async throws {
        let lock = make(name: "b")
        lock.isEnabled = true
        clock += 20
        await lock.verify()
        await lock.verify()  // < 10 s later: ignored
        XCTAssertEqual(reads.count, 1)
        XCTAssertTrue(reads[0].contains("zoom"))
        autoFraming = true
        clock += 20
        device["zoom"] = [300]
        await lock.verify()
        XCTAssertFalse(reads[1].contains("zoom"))
        XCTAssertTrue(writes.isEmpty)
        autoFraming = false
        // user edit pending: no fighting
        device["brightness"] = [77]
        lock.userDidChange()
        clock += 20
        await lock.verify()
        XCTAssertTrue(writes.isEmpty)
        try await Task.sleep(for: .milliseconds(150))
        clock += 20
        await lock.verify()
        XCTAssertTrue(writes.isEmpty)  // snapshot recaptured with the user's value
    }

    func testCameraStartCheckFixesDriftTwiceBypassingGap() async throws {
        let lock = make(name: "d")
        lock.isEnabled = true
        lock.cameraStartedElsewhere()
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(reads.isEmpty)  // nothing before the first delay
        device["brightness"] = [50]
        try await Task.sleep(for: .milliseconds(70))  // ~80 ms: first check
        XCTAssertEqual(writes, ["brightness"])
        XCTAssertEqual(reads.count, 1)
        device["contrast"] = [9]  // clock unchanged, so the 10 s gap would block a normal verify()
        try await Task.sleep(for: .milliseconds(150))  // ~230 ms: second check
        XCTAssertEqual(writes, ["brightness", "contrast"])
        XCTAssertEqual(reads.count, 2)
    }

    func testNewerStartEventReplacesPending() async throws {
        let lock = make(name: "e")
        lock.isEnabled = true
        lock.cameraStartedElsewhere()
        try await Task.sleep(for: .milliseconds(20))
        lock.cameraStartedElsewhere()  // restarts the schedule
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(reads.count, 2)  // not 4
    }

    func testPendingChecksCancelledOnUserChangeAndDisable() async throws {
        let lock = make(name: "f")
        lock.isEnabled = true
        lock.cameraStartedElsewhere()
        lock.userDidChange()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(reads.isEmpty)
        lock.cameraStartedElsewhere()
        lock.isEnabled = false
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(reads.isEmpty)
        lock.cameraStartedElsewhere()  // disabled: no-op
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(reads.isEmpty)
    }

    func testDisabledDoesNothing() async {
        let lock = make(name: "c")
        clock += 20
        await lock.verify()
        XCTAssertTrue(reads.isEmpty)
    }
}
