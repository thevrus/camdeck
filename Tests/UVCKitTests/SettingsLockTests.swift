import XCTest
@testable import UVCKit

@MainActor
final class SettingsLockTests: XCTestCase {
    var device: [String: [Int]] = ["wb-auto": [0], "wb-temp": [5000], "brightness": [10], "contrast": [3], "exposure": [100], "ae-mode": [1], "zoom": [100]]
    var writes: [String] = []
    var clock = Date(timeIntervalSince1970: 1000)
    var autoFraming = false
    var reads: [[String]] = []

    func make(name: String) -> SettingsLock {
        let d = UserDefaults(suiteName: "lock-test-\(name)-\(UUID())")!
        return SettingsLock(uniqueID: name, defaults: d, now: { self.clock }, debounce: .milliseconds(50),
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

    func testDisabledDoesNothing() async {
        let lock = make(name: "c")
        clock += 20
        await lock.verify()
        XCTAssertTrue(reads.isEmpty)
    }
}
