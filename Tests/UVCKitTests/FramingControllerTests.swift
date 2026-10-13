import CoreGraphics
import XCTest
@testable import UVCKit

/// Tiny digital-PTZ camera: true subject in 1x frame coords, output = crop by zoom/pan/tilt.
struct SimCamera {
    var kPan: Double, kTilt: Double   // arcsec per output unit at 1x (same meaning as Tuning)
    var subject: CGRect               // 1x normalized, top-left
    var latencySteps = 2
    var queue: [PTZ] = []

    /// Observed box for the PTZ that was live `latencySteps` ago.
    mutating func observe(_ live: PTZ) -> CGRect? {
        queue.append(live)
        let p = queue.count > latencySteps ? queue.removeFirst() : queue[0]
        let z = Double(p.zoom) / 100
        // Crop center in 1x coords; content moves by zoom/K per arcsec.
        let cx = 0.5 - Double(p.pan) / kPan, cy = 0.5 - Double(p.tilt) / kTilt
        let x = (Double(subject.minX) - cx) * z + 0.5, y = (Double(subject.minY) - cy) * z + 0.5
        let r = CGRect(x: x, y: y, width: Double(subject.width) * z, height: Double(subject.height) * z)
        let c = r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return c.isNull || c.width < 0.02 ? nil : c
    }
}

final class FramingControllerTests: XCTestCase {
    let ranges = PTZRanges.link2C
    func panTuning() -> FramingController.Tuning {
        var t = FramingController.Tuning()
        t.panTiltEnabled = true; t.panArcsecPerUnit = -300_000; t.tiltArcsecPerUnit = 200_000
        return t
    }

    func testSubjectLeftPansTowardIt() {
        var c = FramingController(tuning: panTuning())
        let cur = PTZ(zoom: 200, pan: 0, tilt: 0)
        var out = cur
        for _ in 0 ..< 5 { out = c.update(box: CGRect(x: 0.1, y: 0.25, width: 0.25, height: 0.55), current: cur, ranges: ranges, mode: .medium, dt: 0.1) }
        // cx 0.225 < 0.5. K < 0 means +pan moves content left; centering a left subject moves content right: pan < 0.
        XCTAssertLessThan(out.pan, 0)
        XCTAssertEqual(out.pan % 3600, 0)
    }

    func testSmallSubjectZoomsIn() {
        var c = FramingController()
        let cur = PTZ(zoom: 100, pan: 0, tilt: 0)
        var out = cur
        for _ in 0 ..< 3 { out = c.update(box: CGRect(x: 0.4, y: 0.3, width: 0.15, height: 0.25), current: cur, ranges: ranges, mode: .medium, dt: 0.1) }
        XCTAssertGreaterThan(out.zoom, 100)
    }

    func testDeadZoneHolds() {
        var c = FramingController(tuning: panTuning())
        let cur = PTZ(zoom: 200, pan: 0, tilt: 0)
        // height 0.58 vs 0.55 (+5%), center offset 0.03: inside both dead zones.
        let box = CGRect(x: 0.53 - 0.15, y: 0.45 - 0.29, width: 0.3, height: 0.58)
        for _ in 0 ..< 20 { XCTAssertEqual(c.update(box: box, current: cur, ranges: ranges, mode: .medium, dt: 0.1), cur) }
    }

    func testClampsRespected() {
        var c = FramingController(tuning: panTuning())
        var cur = PTZ(zoom: 390, pan: 0, tilt: 0)
        for _ in 0 ..< 100 {
            cur = c.update(box: CGRect(x: 0.0, y: 0.3, width: 0.03, height: 0.05), current: cur, ranges: ranges, mode: .close, dt: 0.1)
            XCTAssertTrue(ranges.zoom.contains(cur.zoom)); XCTAssertTrue(ranges.pan.contains(cur.pan)); XCTAssertTrue(ranges.tilt.contains(cur.tilt))
        }
        XCTAssertEqual(cur.zoom, 400)
        // Crop-margin clamp at 4x: |pan| <= 300000 * 0.375.
        XCTAssertLessThanOrEqual(abs(cur.pan), 112_500 + 3600)
    }

    func testTopClippedBoxNeverZoomsIn() {
        var c = FramingController()
        let cur = PTZ(zoom: 200, pan: 0, tilt: 0)
        for _ in 0 ..< 20 { XCTAssertLessThanOrEqual(c.update(box: CGRect(x: 0.4, y: 0, width: 0.2, height: 0.2), current: cur, ranges: ranges, mode: .medium, dt: 0.1).zoom, 200) }
    }

    func testLostSubjectReturnsToWide() {
        var c = FramingController(tuning: panTuning())
        var cur = PTZ(zoom: 300, pan: 36000, tilt: -36000)
        _ = c.update(box: CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.55), current: cur, ranges: ranges, mode: .medium, dt: 0.1)
        for i in 0 ..< 150 {
            let next = c.update(box: nil, current: cur, ranges: ranges, mode: .medium, dt: 0.1)
            if i < 19 { XCTAssertEqual(next, cur, "holds during the first 2 s") }
            cur = next
        }
        XCTAssertEqual(cur, PTZ(zoom: 100, pan: 0, tilt: 0))
    }

    func testPanTiltDisabledIsZoomOnly() {
        var c = FramingController() // Link 2C defaults: pan/tilt have no effect on this camera
        let cur = PTZ(zoom: 200, pan: 0, tilt: 0)
        var out = cur
        for _ in 0 ..< 5 { out = c.update(box: CGRect(x: 0.05, y: 0.3, width: 0.2, height: 0.3), current: cur, ranges: ranges, mode: .medium, dt: 0.1) }
        XCTAssertEqual(out.pan, 0); XCTAssertEqual(out.tilt, 0)
        XCTAssertGreaterThan(out.zoom, 200)
    }

    /// 100-step closed loop through the simulator with 2 frames of latency: converges, no oscillation.
    func testClosedLoopConvergesWithoutOscillation() {
        for (tuning, label) in [(panTuning(), "ptz"), (FramingController.Tuning(), "zoom-only")] {
            var c = FramingController(tuning: tuning)
            var sim = SimCamera(kPan: -300_000, kTilt: 200_000, subject: CGRect(x: 0.42, y: 0.3, width: 0.16, height: 0.22))
            var cur = PTZ(zoom: 100, pan: 0, tilt: 0)
            var zooms: [Int] = [], pans: [Int] = []
            for _ in 0 ..< 100 {
                cur = c.update(box: sim.observe(cur), current: cur, ranges: ranges, mode: .medium, dt: 0.1)
                zooms.append(cur.zoom); pans.append(cur.pan)
            }
            let box = sim.observe(cur)!
            XCTAssertEqual(Double(box.height), 0.55, accuracy: 0.55 * 0.15, label)
            if label == "ptz" {
                XCTAssertEqual(Double(box.midX), 0.5, accuracy: 0.07, label)
                XCTAssertEqual(Double(box.midY), 0.45, accuracy: 0.07, label)
            }
            // Monotonic zoom (no overshoot-and-return) and at most one pan direction change.
            XCTAssertTrue(zip(zooms, zooms.dropFirst()).allSatisfy { $0 <= $1 }, "\(label) zoom not monotonic: \(zooms)")
            let d = zip(pans, pans.dropFirst()).map { $1 - $0 }.filter { $0 != 0 }
            XCTAssertLessThanOrEqual(zip(d, d.dropFirst()).filter { ($0 > 0) != ($1 > 0) }.count, 1, "\(label) pan reversals: \(pans)")
            // Settled: the last 30 steps do not move.
            XCTAssertEqual(Set(zooms.suffix(30)).count, 1, label)
        }
    }

    func testSubjectSelectionPrefersIoUThenLargest() {
        let prev = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3)
        let near = CGRect(x: 0.12, y: 0.1, width: 0.2, height: 0.3), big = CGRect(x: 0.5, y: 0.1, width: 0.4, height: 0.6)
        XCTAssertEqual(SubjectDetector.select([big, near], previous: prev), near)
        XCTAssertEqual(SubjectDetector.select([near, big], previous: nil), big)
    }
}

/// Same closed loop in normalized reframe units with the Link 2C's measured travel.
final class ReframeFramingTests: XCTestCase {
    func testLink2CReframeLoopConvergesWithoutOscillation() {
        var c = FramingController(tuning: ReframeUnits.tuning(travel: Link2CReframeMapping.travel))
        let ranges = ReframeUnits.ranges(maxZoomFactor: 4)
        // Subject left of center; content moves by -offset (view right = content left).
        var sim = SimCamera(kPan: -1_000_000, kTilt: -1_000_000, subject: CGRect(x: 0.25, y: 0.3, width: 0.16, height: 0.22))
        var cur = PTZ(zoom: 300, pan: 0, tilt: 0)
        var pans: [Int] = []
        for _ in 0 ..< 150 {
            cur = c.update(box: sim.observe(cur), current: cur, ranges: ranges, mode: .medium, dt: 0.1)
            pans.append(cur.pan)
            let lim = Link2CReframeMapping.travel.offset(atZoom: Double(cur.zoom) / 100).dx * ReframeUnits.perFrame
            XCTAssertLessThanOrEqual(Double(abs(cur.pan)), lim + 1)
        }
        XCTAssertLessThan(cur.pan, 0, "view moves left toward the subject")
        let box = sim.observe(cur)!
        XCTAssertEqual(Double(box.midX), 0.5, accuracy: 0.08)
        let d = zip(pans, pans.dropFirst()).map { $1 - $0 }.filter { $0 != 0 }
        XCTAssertLessThanOrEqual(zip(d, d.dropFirst()).filter { ($0 > 0) != ($1 > 0) }.count, 1, "pan reversals: \(pans)")
        XCTAssertEqual(Set(pans.suffix(30)).count, 1, "settled")
    }
}
