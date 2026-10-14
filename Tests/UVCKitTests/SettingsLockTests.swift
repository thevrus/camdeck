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

    /// Stands in for the camera-start waits: each check parks in `sleep` until the test resumes it, so no wall clock is involved.
    final class Gate {
        private var waiting = AsyncStream<(Duration, CheckedContinuation<Void, Error>)>.makeStream()
        private lazy var iterator = waiting.stream.makeAsyncIterator()
        func sleep(_ d: Duration) async throws {
            try await withCheckedThrowingContinuation { waiting.continuation.yield((d, $0)) }
        }
        /// Returns once the check task is parked in `sleep` (so every earlier check has finished).
        @MainActor func next() async -> (Duration, CheckedContinuation<Void, Error>) { await iterator.next()! }
    }

    func gated(_ lock: SettingsLock) -> Gate {
        let gate = Gate()
        lock.eventSleep = gate.sleep
        return gate
    }

    func testCameraStartCheckFixesDriftTwiceBypassingGap() async throws {
        let lock = make(name: "d")
        let gate = gated(lock)
        lock.isEnabled = true
        lock.cameraStartedElsewhere()
        let task = try XCTUnwrap(lock.eventChecks)
        let (d1, first) = await gate.next()
        XCTAssertEqual(d1, .milliseconds(40))
        XCTAssertTrue(reads.isEmpty)  // nothing before the first delay
        device["brightness"] = [50]
        first.resume()
        let (d2, second) = await gate.next()  // first check done
        XCTAssertEqual(d2, .milliseconds(120))  // offset from the start event, not from the first check
        XCTAssertEqual(writes, ["brightness"])
        XCTAssertEqual(reads.count, 1)
        device["contrast"] = [9]  // clock unchanged, so the 10 s gap would block a normal verify()
        second.resume()
        await task.value
        XCTAssertEqual(writes, ["brightness", "contrast"])
        XCTAssertEqual(reads.count, 2)
    }

    func testNewerStartEventReplacesPending() async throws {
        let lock = make(name: "e")
        let gate = gated(lock)
        lock.isEnabled = true
        lock.cameraStartedElsewhere()
        let old = try XCTUnwrap(lock.eventChecks)
        let (_, parked) = await gate.next()
        lock.cameraStartedElsewhere()  // restarts the schedule
        parked.resume()  // the replaced task wakes cancelled
        await old.value
        XCTAssertTrue(reads.isEmpty)
        let task = try XCTUnwrap(lock.eventChecks)
        await gate.next().1.resume()
        await gate.next().1.resume()
        await task.value
        XCTAssertEqual(reads.count, 2)  // not 4
    }

    func testPendingChecksCancelledOnUserChangeAndDisable() async throws {
        let lock = make(name: "f")
        let gate = gated(lock)
        lock.isEnabled = true
        lock.cameraStartedElsewhere()
        var task = try XCTUnwrap(lock.eventChecks)
        lock.userDidChange()
        XCTAssertNil(lock.eventChecks)
        await gate.next().1.resume()
        await task.value
        XCTAssertTrue(reads.isEmpty)
        lock.cameraStartedElsewhere()
        task = try XCTUnwrap(lock.eventChecks)
        lock.isEnabled = false
        XCTAssertNil(lock.eventChecks)
        await gate.next().1.resume()
        await task.value
        XCTAssertTrue(reads.isEmpty)
        lock.cameraStartedElsewhere()  // disabled: no-op
        XCTAssertNil(lock.eventChecks)
        XCTAssertTrue(reads.isEmpty)
    }

    func testDisabledDoesNothing() async {
        let lock = make(name: "c")
        clock += 20
        await lock.verify()
        XCTAssertTrue(reads.isEmpty)
    }
}
