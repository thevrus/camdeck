import AVFoundation
import CoreImage
import Foundation
import UVCKit

/// Link 2C digital reframe tools. The only XU write here is XU9 selector 2, read-modify-write of
/// bytes 38-41 (X, Y as u16 LE). Every other byte of the record is written back exactly as read.
/// Writes are spaced >= 400 ms. Exit, error and Ctrl-C always restore X = Y = 0x7FFF and zoom 100.
enum ReframeTool {
    static let gap: TimeInterval = 0.4
    static let center = Int(Insta360LinkDriver.reframeCenter)

    /// Zoom (u16, 100 = 1x) mirrored in byte 50 of the reframe record; 0 if the record is too short.
    static func zoomMirror(_ r: [UInt8]) -> Int {
        let o = Insta360LinkDriver.zoomMirrorOffset
        return r.count >= o + 2 ? Int(r[o]) | Int(r[o + 1]) << 8 : 0
    }

    /// `uvcctl xu-dump <selector> [file]`: GET_LEN + GET_CUR of XU9 `selector` (read-only), hex output.
    static func dump(_ a: [String]) -> Never {
        guard let sel = a.first.flatMap({ UInt8($0) }) else { fail("usage: uvcctl xu-dump <selector> [file]") }
        guard let d = UVCDevice(vendorID: Insta360LinkDriver.vendorID, productID: Insta360LinkDriver.link2CProductID) else { fail("no link 2c") }
        do {
            let xu = try XCTXU.unit(d)
            let len = try Insta360LinkDriver.length(d.transport, unit: xu, selector: sel)
            let b = try d.transport.get(unit: xu, selector: sel, length: len)
            let hex = stride(from: 0, to: b.count, by: 16).map { i in b[i ..< min(i + 16, b.count)].map { String(format: "%02x", $0) }.joined(separator: " ") }.joined(separator: "\n")
            print("XU9 sel \(sel) len \(len) got \(b.count)")
            print(hex)
            if a.count > 1 { try (hex + "\n").write(toFile: a[1], atomically: true, encoding: .utf8) }
            exit(0)
        } catch { fail("xu-dump: \(error)") }
    }

    enum XCTXU {
        static func unit(_ d: UVCDevice) throws -> UInt8 {
            guard let u = d.unitID(forGUID: Insta360LinkDriver.xuGUID) else { throw UVCError.noUnit("XU9") }
            return u
        }
    }

    final class Rig: @unchecked Sendable {
        let dev: UVCDevice
        let xu: UInt8
        let len: Int
        let zoomC = UVCControl.zoomControl
        private var last = Date.distantPast
        private let lock = NSLock()
        private var restored = false

        init() throws {
            guard let d = UVCDevice(vendorID: Insta360LinkDriver.vendorID, productID: Insta360LinkDriver.link2CProductID) else { throw UVCError.noUnit("Link 2C") }
            dev = d
            xu = try XCTXU.unit(d)
            len = try Insta360LinkDriver.length(d.transport, unit: xu, selector: Insta360LinkDriver.reframeSelector)
            guard len >= Insta360LinkDriver.reframeYOffset + 2 else { throw UVCError.io(-2) }
        }

        private func wait() {
            let w = ReframeTool.gap - Date().timeIntervalSince(last)
            if w > 0 { Thread.sleep(forTimeInterval: w) }
            last = Date()
        }

        func record() throws -> [UInt8] { try dev.transport.get(unit: xu, selector: Insta360LinkDriver.reframeSelector, length: len) }

        func xy() throws -> (Int, Int) {
            guard let p = Insta360LinkDriver.reframeXY(try record()) else { throw UVCError.io(-1) }
            return (Int(p.x), Int(p.y))
        }

        func setXY(_ x: Int, _ y: Int) throws {
            lock.lock(); defer { lock.unlock() }
            wait()
            let cur = try record()
            let next = Insta360LinkDriver.reframeRecord(cur, x: UInt16(clamping: x), y: UInt16(clamping: y))
            precondition(zip(cur, next).enumerated().allSatisfy { i, p in (38 ... 41).contains(i) || p.0 == p.1 })
            try dev.transport.set(unit: xu, selector: Insta360LinkDriver.reframeSelector, data: next)
        }

        func setZoom(_ z: Int) throws { lock.lock(); defer { lock.unlock() }; wait(); try dev.write(zoomC, [z]) }

        func restore() {
            lock.lock(); let done = restored; restored = true; lock.unlock()
            guard !done else { return }
            try? setXY(ReframeTool.center, ReframeTool.center)
            try? setZoom(100)
            Thread.sleep(forTimeInterval: ReframeTool.gap)
            let p = try? xy()
            print("restored: zoom \((try? dev.read(zoomC)) ?? []) xy \(p.map { String(format: "0x%04X 0x%04X", $0.0, $0.1) } ?? "?")")
        }
    }

    static func run(_ body: @escaping @Sendable (Rig, FramingTool.Grabber) throws -> Void) -> Never {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized || {
            let s = DispatchSemaphore(value: 0); var ok = false
            AVCaptureDevice.requestAccess(for: .video) { ok = $0; s.signal() }
            s.wait(); return ok
        }() else { fail("camera access denied") }
        let rig: Rig, grab: FramingTool.Grabber
        do { rig = try Rig(); grab = try FramingTool.Grabber(device: try FramingTool.camera()) } catch { fail("setup: \(error)") }
        signal(SIGINT, SIG_IGN)
        let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sig.setEventHandler { print("\ninterrupted"); rig.restore(); exit(130) }
        sig.resume()
        DispatchQueue.global().async {
            var code: Int32 = 0
            do { try body(rig, grab) } catch { print("error: \(error)"); code = 1 }
            rig.restore()
            grab.session.stopRunning()
            exit(code)
        }
        dispatchMain()
    }

    /// Median content motion of 3 frames vs `ref` (normalized output frame, +x right, +y down).
    static func measure(_ g: FramingTool.Grabber, ref: CGImage, after seq: inout Int) -> CGPoint? {
        var xs: [Double] = [], ys: [Double] = []
        for _ in 0 ..< 3 {
            guard let (pb, s) = g.next(after: seq), let im = FramingTool.image(pb) else { continue }
            seq = s
            if let m = FramingTool.motion(ref, im) { xs.append(m.x); ys.append(m.y) }
        }
        guard !xs.isEmpty else { return nil }
        return CGPoint(x: xs.sorted()[xs.count / 2], y: ys.sorted()[ys.count / 2])
    }

    /// `uvcctl reframe-calibrate [zooms]`: sweeps X then Y at each zoom, prints content motion per raw delta.
    static func calibrate(_ a: [String]) -> Never {
        let zooms = a.first.map { $0.split(separator: ",").compactMap { Int($0) } } ?? [100, 200, 400]
        let deltas = (ProcessInfo.processInfo.environment["DELTAS"]?.split(separator: ",").compactMap { Int($0, radix: 16) })
            ?? [0x1000, 0x2000, 0x4000, 0x6000, 0x7FFF]
        let settle = Double(ProcessInfo.processInfo.environment["SETTLE"] ?? "") ?? 1.2
        run { rig, g in
            print(String(format: "record len %d  start xy 0x%04X 0x%04X", rig.len, try rig.xy().0, try rig.xy().1))
            Thread.sleep(forTimeInterval: 1.5)
            print("zoom axis  raw-delta  raw      dx       dy      readback")
            for z in zooms {
                try rig.setZoom(z); try rig.setXY(ReframeTool.center, ReframeTool.center)
                Thread.sleep(forTimeInterval: 1.5)
                for axis in ["X", "Y"] {
                    guard let (pb0, s0) = g.next(after: 0), let ref = FramingTool.image(pb0) else { continue }
                    if FramingTool.convention == nil { FramingTool.convention = FramingTool.learnConvention(ref) }
                    var seq = s0
                    for sign in [1, -1] {
                        for d in deltas {
                            let raw = min(max(ReframeTool.center + sign * d, 0), 0xFFFF)
                            if axis == "X" { try rig.setXY(raw, ReframeTool.center) } else { try rig.setXY(ReframeTool.center, raw) }
                            Thread.sleep(forTimeInterval: settle)
                            let m = measure(g, ref: ref, after: &seq)
                            let rb = try rig.xy()
                            print(String(format: "%4d  %@   %+7d   0x%04X  %@  %@  rb 0x%04X 0x%04X", z, axis, sign * d, raw,
                                         m.map { String(format: "%+.4f", $0.x) } ?? "  n/a  ",
                                         m.map { String(format: "%+.4f", $0.y) } ?? "  n/a  ", rb.0, rb.1))
                        }
                        try rig.setXY(ReframeTool.center, ReframeTool.center)
                        Thread.sleep(forTimeInterval: settle)
                        let m = measure(g, ref: ref, after: &seq)
                        print(String(format: "%4d  %@   back to center      %@  %@", z, axis,
                                     m.map { String(format: "%+.4f", $0.x) } ?? "n/a", m.map { String(format: "%+.4f", $0.y) } ?? "n/a"))
                    }
                }
            }
            // Persistence: does a write survive a zoom change, and is it kept after 3 s?
            try rig.setZoom(200); try rig.setXY(ReframeTool.center + 0x4000, ReframeTool.center)
            Thread.sleep(forTimeInterval: 3)
            print(String(format: "persist after 3 s @2x: 0x%04X 0x%04X", try rig.xy().0, try rig.xy().1))
            try rig.setZoom(300)
            Thread.sleep(forTimeInterval: 1)
            print(String(format: "after zoom 2x->3x: 0x%04X 0x%04X", try rig.xy().0, try rig.xy().1))
        }
    }

    /// `uvcctl reframe-probe <zoom> <X|Y> <hexDeltas,...> [seconds]`: time series of content motion after
    /// each step from center (fresh reference per step), then back to center.
    static func probe(_ a: [String]) -> Never {
        let z = Int(a[safe: 0] ?? "") ?? 200
        let axis = a[safe: 1] ?? "X"
        let deltas = (a[safe: 2] ?? "1000").split(separator: ",").compactMap { Int($0, radix: 16) }
        let secs = Double(a[safe: 3] ?? "") ?? 4
        run { rig, g in
            try rig.setZoom(z); try rig.setXY(ReframeTool.center, ReframeTool.center)
            Thread.sleep(forTimeInterval: 2)
            for d in deltas {
                Thread.sleep(forTimeInterval: 1.5)
                guard let (pb0, s0) = g.next(after: 0), let ref = FramingTool.image(pb0) else { continue }
                if FramingTool.convention == nil { FramingTool.convention = FramingTool.learnConvention(ref) }
                var seq = s0
                let raw = min(max(ReframeTool.center + d, 0), 0xFFFF)
                if axis == "X" { try rig.setXY(raw, ReframeTool.center) } else { try rig.setXY(ReframeTool.center, raw) }
                let t0 = Date()
                var series: [String] = []
                for target in stride(from: 0.25, through: secs, by: 0.25) {
                    let w = target - Date().timeIntervalSince(t0)
                    if w > 0 { Thread.sleep(forTimeInterval: w) }
                    guard let (pb, s) = g.next(after: seq), let im = FramingTool.image(pb) else { continue }
                    seq = s
                    if let m = FramingTool.motion(ref, im) { series.append(String(format: "%.2f:%+.3f,%+.3f", target, m.x, m.y)) }
                }
                let rb = try rig.xy()
                print(String(format: "zoom %d %@ %+d (rb 0x%04X 0x%04X): ", z, axis, d, rb.0, rb.1) + series.joined(separator: " "))
                try rig.setXY(ReframeTool.center, ReframeTool.center)
            }
        }
    }

    /// `uvcctl reframe-chain <zoom> <X|Y> <stepHex> <steps>`: walks from center in small steps, registering
    /// each frame against the frame just before the step (small shifts register reliably), and sums.
    static func chain(_ a: [String]) -> Never {
        let z = Int(a[safe: 0] ?? "") ?? 200
        let axis = a[safe: 1] ?? "X"
        let step = Int(a[safe: 2] ?? "", radix: 16) ?? 0x400
        let n = Int(a[safe: 3] ?? "") ?? 10
        let settle = Double(ProcessInfo.processInfo.environment["SETTLE"] ?? "") ?? 0.9
        run { rig, g in
            try rig.setZoom(z); try rig.setXY(ReframeTool.center, ReframeTool.center)
            Thread.sleep(forTimeInterval: 2)
            var seq = 0
            for dir in [1, -1] {
                var sum = 0.0, raw = ReframeTool.center
                print("zoom \(z) axis \(axis) dir \(dir > 0 ? "+" : "-")")
                for i in 1 ... n {
                    guard let (pb0, s0) = g.next(after: seq), let ref = FramingTool.image(pb0) else { continue }
                    if FramingTool.convention == nil { FramingTool.convention = FramingTool.learnConvention(ref) }
                    seq = s0
                    raw = min(max(ReframeTool.center + dir * i * step, 0), 0xFFFF)
                    if axis == "X" { try rig.setXY(raw, ReframeTool.center) } else { try rig.setXY(ReframeTool.center, raw) }
                    Thread.sleep(forTimeInterval: settle)
                    let m = measure(g, ref: ref, after: &seq)
                    let rb = try rig.xy()
                    let d = axis == "X" ? Double(m?.x ?? .nan) : Double(m?.y ?? .nan)
                    let o = axis == "X" ? Double(m?.y ?? .nan) : Double(m?.x ?? .nan)
                    if d.isFinite { sum += d }
                    print(String(format: "  delta %+6d rb %+6d  step %+.4f (other %+.4f)  cum %+.4f", dir * i * step,
                                 Int(axis == "X" ? rb.0 : rb.1) - ReframeTool.center, d, o, sum))
                }
                try rig.setXY(ReframeTool.center, ReframeTool.center)
                Thread.sleep(forTimeInterval: 1.5)
                if let (_, s) = g.next(after: seq) { seq = s }
            }
        }
    }

    /// `uvcctl zoom-mirror <zoom>`: CT zoom write, then reads CT zoom and XU9 sel 2 byte 50 every 100 ms (reads only).
    static func zoomMirror(_ a: [String]) -> Never {
        let zs = (a[safe: 0] ?? "400").split(separator: ",").compactMap { Int($0) }
        run { rig, _ in
          for z in zs {
            Thread.sleep(forTimeInterval: 1)
            print("-> zoom \(z)")
            try rig.setZoom(z)
            let t0 = Date()
            for _ in 0 ..< 15 {
                let r = try rig.record()
                let ct = (try? rig.dev.read(rig.zoomC).first) ?? -1
                print(String(format: "%.2fs CT %d byte50 %d", Date().timeIntervalSince(t0), ct, ReframeTool.zoomMirror(r)))
                Thread.sleep(forTimeInterval: 0.1)
            }
          }
        }
    }

    /// `uvcctl zoom-edge z1,z2,...`: at each zoom, face height and whether X = center+0x1000 is accepted (read-back).
    static func zoomEdge(_ a: [String]) -> Never {
        let zs = (a[safe: 0] ?? "390,395,399,400").split(separator: ",").compactMap { Int($0) }
        run { rig, g in
            let det = SubjectDetector()
            for z in zs {
                try rig.setZoom(z); try rig.setXY(ReframeTool.center, ReframeTool.center)
                let face = FramingTool.measure(g, det, useFace: true, settle: 1.2, duration: 1.0)
                try rig.setXY(ReframeTool.center + 0x1000, ReframeTool.center)
                Thread.sleep(forTimeInterval: 0.6)
                let rb = try rig.xy()
                let r = try rig.record()
                print(String(format: "zoom %d  face h %.3f  X write +0x1000 -> rb %+d  byte50 %d", z, face?.h ?? .nan, Int(rb.0) - ReframeTool.center, ReframeTool.zoomMirror(r)))
            }
        }
    }

    /// `uvcctl ramp-test from to d1,d2,...`: zoom from->to, then a center reframe write after d seconds;
    /// reports the zoom left in byte 50 / CT one second later (a write mid-ramp freezes the zoom).
    static func rampTest(_ a: [String]) -> Never {
        let from = Int(a[safe: 0] ?? "") ?? 200, to = Int(a[safe: 1] ?? "") ?? 300
        let ds = (a[safe: 2] ?? "0.4,0.8,1.2,1.6,2.4").split(separator: ",").compactMap { Double($0) }
        run { rig, _ in
            for d in ds {
                try rig.setZoom(from); Thread.sleep(forTimeInterval: 2.5)
                try rig.setZoom(to)
                Thread.sleep(forTimeInterval: max(d - ReframeTool.gap, 0))
                try rig.setXY(ReframeTool.center, ReframeTool.center)
                Thread.sleep(forTimeInterval: 1)
                let r = try rig.record()
                print(String(format: "%d->%d write at %.1fs: byte50 %d CT %d", from, to, d, ReframeTool.zoomMirror(r), (try? rig.dev.read(rig.zoomC).first) ?? -1))
            }
        }
    }
}
