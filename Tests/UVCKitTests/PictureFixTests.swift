import CoreVideo
import XCTest
@testable import UVCKit

final class PictureFixTests: XCTestCase {
    typealias K = PictureFix.Knob

    // MARK: exposureStep

    func testNoWriteInsideTolerance() {
        let c = PictureFix.ExposureControls(ev: K(0, -3 ... 3), brightness: K(50, 0 ... 100))
        XCTAssertTrue(PictureFix.exposureStep(faceLuma: 0.53, frameLuma: 0.2, controls: c).isEmpty)
        XCTAssertTrue(PictureFix.exposureStep(faceLuma: nil, frameLuma: 0.42, controls: c).isEmpty)
    }

    func testEVStepIsLog2AndClampedToOneStop() {
        let c = PictureFix.ExposureControls(ev: K(0.5, -3 ... 3), brightness: K(50, 0 ... 100))
        // Face at 0.25: one stop under.
        let s = PictureFix.exposureStep(faceLuma: 0.25, frameLuma: 0.3, controls: c)
        XCTAssertEqual(s.ev ?? .nan, 1.5, accuracy: 1e-9)
        XCTAssertNil(s.brightness)
        // Very dark face: clamped to +1 per iteration.
        XCTAssertEqual(PictureFix.exposureStep(faceLuma: 0.05, frameLuma: 0.1, controls: c).ev ?? .nan, 1.5, accuracy: 1e-9)
        // Too bright: down, and clamped to the control range.
        let high = PictureFix.ExposureControls(ev: K(-2.8, -3 ... 3))
        XCTAssertEqual(PictureFix.exposureStep(faceLuma: 0.9, frameLuma: 0.9, controls: high).ev ?? .nan, -3, accuracy: 1e-9)
    }

    func testNoFaceUsesFrameTarget() {
        let c = PictureFix.ExposureControls(ev: K(0, -3 ... 3))
        let s = PictureFix.exposureStep(faceLuma: nil, frameLuma: 0.225, controls: c)
        XCTAssertEqual(s.ev ?? .nan, 1, accuracy: 1e-9) // log2(0.45 / 0.225)
    }

    func testWithoutEVUsesBacklightAndBrightness() {
        let c = PictureFix.ExposureControls(backlight: K(0, 0 ... 2), brightness: K(50, 0 ... 100))
        // Backlit face: frame much brighter than the face.
        let s = PictureFix.exposureStep(faceLuma: 0.30, frameLuma: 0.60, controls: c)
        XCTAssertEqual(s.backlight, 1)
        XCTAssertEqual(s.brightness, 66) // 50 + 0.2 * 100 * 0.8
        // Not backlit: brightness only.
        let t = PictureFix.exposureStep(faceLuma: 0.30, frameLuma: 0.35, controls: c)
        XCTAssertNil(t.backlight)
        XCTAssertEqual(t.brightness, 66)
        // Backlight already at max; brightness clamps to its range.
        let maxed = PictureFix.ExposureControls(backlight: K(2, 0 ... 2), brightness: K(95, 0 ... 100))
        let u = PictureFix.exposureStep(faceLuma: 0.30, frameLuma: 0.60, controls: maxed)
        XCTAssertNil(u.backlight)
        XCTAssertEqual(u.brightness, 100)
    }

    func testPinnedEVFallsBackToBrightness() {
        let c = PictureFix.ExposureControls(ev: K(3, -3 ... 3), brightness: K(50, 0 ... 100))
        let s = PictureFix.exposureStep(faceLuma: 0.30, frameLuma: 0.30, controls: c)
        XCTAssertNil(s.ev)
        XCTAssertEqual(s.brightness, 66)
    }

    // MARK: flickerScore

    /// Rolling bands: a sine across the rows whose phase moves every frame, on a lit gradient.
    private func frames(banding: Double, count: Int = 8, rows: Int = 120) -> [[Double]] {
        (0 ..< count).map { f in
            (0 ..< rows).map { r in
                let base = 0.3 + 0.3 * Double(r) / Double(rows) + 0.01 * Double(f) // scene gradient + AE drift
                return base + banding * sin(2 * .pi * (Double(r) / 20 + Double(f) * 0.37))
            }
        }
    }

    func testFlickerScoreSeparatesBandedFromFlat() {
        let flat = PictureFix.flickerScore(frames(banding: 0))
        let banded = PictureFix.flickerScore(frames(banding: 0.03))
        XCTAssertLessThan(flat, 1e-6)
        XCTAssertGreaterThan(banded, 100 * max(flat, 1e-9))
        XCTAssertEqual(PictureFix.flickerScore([[0.5, 0.5]]), 0)
    }

    // MARK: pickPowerline

    func testPickPowerline() {
        XCTAssertEqual(PictureFix.pickPowerline(score50: 1.0, score60: 0.5, current: 1), 2)
        XCTAssertEqual(PictureFix.pickPowerline(score50: 0.5, score60: 1.0, current: 3), 1)
        XCTAssertNil(PictureFix.pickPowerline(score50: 1.0, score60: 0.9, current: 3)) // under 15%
        XCTAssertNil(PictureFix.pickPowerline(score50: 0, score60: 0, current: 2)) // no flicker either way
        XCTAssertNil(PictureFix.pickPowerline(score50: 0.5, score60: 1.0, current: 1)) // already 50 Hz
    }

    // MARK: stats

    func testStatsFromVideoRangeBuffer() throws {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
        let buf = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddressOfPlane(buf, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
        // Black background (Y 16), white face square (Y 235) in the middle.
        for y in 0 ..< 240 { for x in 0 ..< 320 { base[y * stride + x] = (80 ..< 160).contains(y) && (120 ..< 200).contains(x) ? 235 : 16 } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        let face = CGRect(x: 120.0 / 320, y: 80.0 / 240, width: 80.0 / 320, height: 80.0 / 240)
        let s = try XCTUnwrap(PictureFix.stats(buf, face: face))
        XCTAssertEqual(s.faceLuma ?? .nan, 1, accuracy: 1e-9)
        XCTAssertEqual(s.rowMeans.count, 120)
        XCTAssertEqual(s.rowMeans[0], 0, accuracy: 1e-9)
        XCTAssertEqual(s.frameLuma, 80.0 * 80 / (320 * 240), accuracy: 0.02)
        XCTAssertNil(PictureFix.stats(buf, face: nil)?.faceLuma)
    }
}
