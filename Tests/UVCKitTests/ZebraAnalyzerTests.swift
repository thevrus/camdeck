import XCTest
import CoreVideo
@testable import UVCKit

final class ZebraAnalyzerTests: XCTestCase {
    func buffer(_ fmt: OSType, w: Int = 640, h: Int = 360) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, fmt, nil, &pb)
        return pb!
    }

    /// Top-left quarter bright, rest dark.
    func fillPlanar(_ pb: CVPixelBuffer, bright: UInt8, dark: UInt8) {
        CVPixelBufferLockBaseAddress(pb, [])
        let p = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let s = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        for y in 0 ..< CVPixelBufferGetHeightOfPlane(pb, 0) { for x in 0 ..< CVPixelBufferGetWidthOfPlane(pb, 0) {
            p[y * s + x] = (x < 320 && y < 180) ? bright : dark } }
        CVPixelBufferUnlockBaseAddress(pb, [])
    }

    func testPlanarVideoAndFullRange() throws {
        for (fmt, bright, dark) in [(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, UInt8(235), UInt8(16)),
                                    (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, UInt8(255), UInt8(0))] {
            let pb = buffer(fmt); fillPlanar(pb, bright: bright, dark: dark)
            let r = try XCTUnwrap(ZebraAnalyzer.analyze(pb, threshold: 0.95))
            XCTAssertEqual(r.mask.width, 320); XCTAssertEqual(r.mask.height, 180)
            XCTAssertEqual(r.clipped, 0.25, accuracy: 0.001)
        }
    }

    func testBGRA() throws {
        let pb = buffer(kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(pb, [])
        let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let s = CVPixelBufferGetBytesPerRow(pb)
        for y in 0 ..< 360 { for x in 0 ..< 640 {
            let v: UInt8 = (x >= 320 && y >= 180) ? 255 : 20
            for k in 0 ..< 3 { p[y * s + x * 4 + k] = v }; p[y * s + x * 4 + 3] = 255 } }
        CVPixelBufferUnlockBaseAddress(pb, [])
        let r = try XCTUnwrap(ZebraAnalyzer.analyze(pb, threshold: 0.95))
        XCTAssertEqual(r.clipped, 0.25, accuracy: 0.001)
        XCTAssertEqual(r.mask.width, 320)
    }

    func testDisabledNoWorkEnabledPublishes() throws {
        let d = UserDefaults(suiteName: "zebra-\(UUID())")!
        let z = ZebraAnalyzer(defaults: d, minInterval: 0)
        let pb = buffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange); fillPlanar(pb, bright: 235, dark: 16)
        z.process(pb)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(z.processedCount, 0); XCTAssertNil(z.mask)
        z.isEnabled = true
        z.process(pb)
        let end = Date().addingTimeInterval(3)
        while z.mask == nil && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(z.processedCount, 1)
        XCTAssertEqual(z.clippedFraction, 0.25, accuracy: 0.001)
    }
}
