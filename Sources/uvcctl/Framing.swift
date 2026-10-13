import AVFoundation
import CoreImage
import Vision
import Foundation
import UVCKit

/// Hardware calibration and a headless closed-loop run for software auto framing.
/// USB writes are spaced >= 350 ms apart; the original zoom/pan/tilt is always restored
/// (normal exit, thrown error, or Ctrl-C).
enum FramingTool {
    static let suffix = String(format: "%04x%04x", Insta360LinkDriver.vendorID, Insta360LinkDriver.link2CProductID)
    static let writeGap: TimeInterval = 0.35

    final class Grabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        let session = AVCaptureSession()
        private let q = DispatchQueue(label: "uvcctl.frames")
        private let lock = NSLock()
        private var latest: (CVPixelBuffer, Int)?
        private var seq = 0

        init(device: AVCaptureDevice) throws {
            super.init()
            let input = try AVCaptureDeviceInput(device: device)
            let out = AVCaptureVideoDataOutput()
            out.alwaysDiscardsLateVideoFrames = true
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            out.setSampleBufferDelegate(self, queue: q)
            session.beginConfiguration()
            guard session.canAddInput(input), session.canAddOutput(out) else { throw NSError(domain: "uvcctl", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot configure capture session"]) }
            session.addInput(input); session.addOutput(out)
            session.commitConfiguration()
            session.startRunning()
        }

        func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            lock.lock(); seq += 1; latest = (pb, seq); lock.unlock()
        }

        /// Blocks until a frame newer than `after` arrives.
        func next(after: Int, timeout: TimeInterval = 2) -> (CVPixelBuffer, Int)? {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                lock.lock(); let l = latest; lock.unlock()
                if let l, l.1 > after { return l }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return nil
        }
    }

    final class Rig: @unchecked Sendable {
        let dev: UVCDevice
        let zoomC = UVCControl.zoomControl
        let ptC = UVCControl.panTiltControl
        let original: PTZ
        let ranges: PTZRanges
        /// Digital reframe (Link 2C): when present, pan/tilt go here in ReframeUnits instead of CT pan/tilt.
        let reframe: (any ReframeCapability)?
        private var lastWrite = Date.distantPast
        private let lock = NSLock()
        private var restored = false

        init() throws {
            guard let d = UVCDevice(vendorID: Insta360LinkDriver.vendorID, productID: Insta360LinkDriver.link2CProductID) else { throw NSError(domain: "uvcctl", code: 2, userInfo: [NSLocalizedDescriptionKey: "Link 2C not found over USB"]) }
            dev = d
            let z = try d.read(zoomC), pt = try d.read(ptC)
            original = PTZ(zoom: z[0], pan: pt[0], tilt: pt[1])
            let zmin = try d.read(zoomC, .min)[0], zmax = try d.read(zoomC, .max)[0]
            let pmin = try d.read(ptC, .min), pmax = try d.read(ptC, .max), pres = try d.read(ptC, .res)
            reframe = DriverRegistry.standard.compose(d).reframe
            ranges = reframe != nil ? ReframeUnits.ranges(maxZoomFactor: Double(zmax) / 100)
                : PTZRanges(zoom: zmin ... zmax, pan: pmin[0] ... pmax[0], tilt: pmin[1] ... pmax[1], panTiltRes: pres[0])
        }

        private func gap() {
            let wait = FramingTool.writeGap - Date().timeIntervalSince(lastWrite)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            lastWrite = Date()
        }

        func setZoom(_ z: Int) throws { lock.lock(); defer { lock.unlock() }; gap(); try dev.write(zoomC, [z]) }
        func setPanTilt(_ p: Int, _ t: Int) throws { lock.lock(); defer { lock.unlock() }; gap(); try dev.write(ptC, [p, t]) }
        /// Pan/tilt in ReframeUnits micro-frames at zoom `z` (raw, 100 = 1x).
        func setReframe(_ p: Int, _ t: Int, zoom z: Int) throws {
            guard let reframe else { return try setPanTilt(p, t) }
            lock.lock(); defer { lock.unlock() }; gap()
            let zf = Double(z) / 100
            try reframe.write(ReframeUnits.center(pan: p, tilt: t, travel: reframe.travel, zoomFactor: zf), zoomFactor: zf)
        }

        func restore() {
            lock.lock(); let done = restored; restored = true; lock.unlock()
            guard !done else { return }
            try? setPanTilt(original.pan, original.tilt)
            if let reframe { lock.lock(); gap(); try? reframe.write(.zero, zoomFactor: Double(original.zoom) / 100); lock.unlock() }
            try? setZoom(original.zoom)
            Thread.sleep(forTimeInterval: FramingTool.writeGap)
            let z = (try? dev.read(zoomC)) ?? [], pt = (try? dev.read(ptC)) ?? []
            print("restored: zoom \(z) pantilt \(pt) (original \(original))")
        }
    }

    static func camera() throws -> AVCaptureDevice {
        let types: [AVCaptureDevice.DeviceType] = [.external, .builtInWideAngleCamera]
        let devs = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        guard let d = devs.first(where: { $0.uniqueID.lowercased().hasSuffix(suffix) }) else {
            throw NSError(domain: "uvcctl", code: 3, userInfo: [NSLocalizedDescriptionKey: "no capture device with uniqueID ending \(suffix): \(devs.map(\.uniqueID))"])
        }
        return d
    }

    /// Runs `body` off the main thread with Ctrl-C restoring the camera, then exits.
    static func run(_ body: @escaping @Sendable (Rig, Grabber) throws -> Void) -> Never {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized || {
            let s = DispatchSemaphore(value: 0); var ok = false
            AVCaptureDevice.requestAccess(for: .video) { ok = $0; s.signal() }
            s.wait(); return ok
        }() else { fail("camera access denied") }
        let rig: Rig, grab: Grabber
        do { rig = try Rig(); grab = try Grabber(device: try camera()) } catch { fail("setup: \(error.localizedDescription)") }
        print("ranges: \(rig.ranges)  original: \(rig.original)")
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

    struct Sample { var cx, cy, h: Double; var n: Int }

    /// Median subject center/height over `duration` seconds after `settle`.
    static func measure(_ g: Grabber, _ det: SubjectDetector, useFace: Bool = false, settle: TimeInterval = 1.2, duration: TimeInterval = 1.5) -> Sample? {
        Thread.sleep(forTimeInterval: settle)
        det.reset()
        var xs: [Double] = [], ys: [Double] = [], hs: [Double] = []
        var seq = 0
        let end = Date().addingTimeInterval(duration)
        while Date() < end, let (pb, s) = g.next(after: seq) {
            seq = s
            if let b = useFace ? det.detectFace(pb) : det.detect(pb, upperBodyOnly: true) { xs.append(b.midX); ys.append(b.midY); hs.append(b.height) }
        }
        guard xs.count >= 3 else { return nil }
        func med(_ a: [Double]) -> Double { a.sorted()[a.count / 2] }
        return Sample(cx: med(xs), cy: med(ys), h: med(hs), n: xs.count)
    }

    static func show(_ label: String, _ s: Sample?) -> String {
        guard let s else { return "\(label): NO SUBJECT" }
        return String(format: "%@: cx %.4f cy %.4f h %.4f (n=%d)", label, s.cx, s.cy, s.h, s.n)
    }

    static func calibrate() -> Never {
        run { rig, g in
            let det = SubjectDetector()
            let step = Int(ProcessInfo.processInfo.environment["STEP"] ?? "") ?? 36_000
            Thread.sleep(forTimeInterval: 1.5) // AE/stream warm-up
            func at(_ z: Int, _ p: Int, _ t: Int, _ label: String) throws -> Sample? {
                try rig.setZoom(z); try rig.setPanTilt(p, t)
                let body = measure(g, det, settle: 1.0, duration: 1.0)
                let s = measure(g, det, useFace: true, settle: 0, duration: 1.2)
                print(show(String(format: "zoom %3d pan %+7d tilt %+7d  %@ face", z, p, t, label), s) + "  | " + show("body", body))
                return s
            }
            guard let base = try at(200, 0, 0, "base") else { throw NSError(domain: "uvcctl", code: 4, userInfo: [NSLocalizedDescriptionKey: "BLOCKED: Vision detected no face/human at zoom 200"]) }
            let pp = try at(200, step, 0, "pan+"), pm = try at(200, -step, 0, "pan-")
            let tp = try at(200, 0, step, "tilt+"), tm = try at(200, 0, -step, "tilt-")
            let b3 = try at(300, 0, 0, "base3"), p3 = try at(300, step, 0, "pan+ @3x")
            let b1 = try at(100, 0, 0, "base1"), p1 = try at(100, step, 0, "pan+ @1x")
            func k(_ a: Sample?, _ b: Sample?, _ key: KeyPath<Sample, Double>, _ d: Int) -> String {
                guard let a, let b else { return "n/a" }
                let delta = b[keyPath: key] - a[keyPath: key]
                return String(format: "delta %+.4f  arcsec/unit %+.0f", delta, abs(delta) > 1e-4 ? Double(d) / delta : .nan)
            }
            print("--- results (arcsec per output-frame unit; sign: subject moves this way for +arcsec)")
            print("pan  @2x +: " + k(base, pp, \.cx, step) + "   -: " + k(base, pm, \.cx, -step))
            print("tilt @2x +: " + k(base, tp, \.cy, step) + "   -: " + k(base, tm, \.cy, -step))
            print("pan  @3x +: " + k(b3, p3, \.cx, step))
            print("pan  @1x +: " + k(b1, p1, \.cx, step))
            print("--- image registration (content motion, normalized output frame; final value after 1.8 s)")
            let s = Double(step)
            func rep(_ label: String, _ m: CGPoint?, _ z: Int) {
                guard let m else { print("\(label): n/a"); return }
                let zf = Double(z) / 100
                print(String(format: "%@: dx %+.4f dy %+.4f -> arcsec/unit@1x x %+.0f y %+.0f", label, m.x, m.y,
                             abs(m.x) > 0.003 ? s / Double(m.x) * zf : .nan, abs(m.y) > 0.003 ? s / Double(m.y) * zf : .nan))
            }
            rep("pan+ @2x", try probe(rig, g, zoom: 200, pan: step, tilt: 0, label: "pan+"), 200)
            rep("pan- @2x", try probe(rig, g, zoom: 200, pan: -step, tilt: 0, label: "pan-"), 200)
            rep("tilt+ @2x", try probe(rig, g, zoom: 200, pan: 0, tilt: step, label: "tilt+"), 200)
            rep("tilt- @2x", try probe(rig, g, zoom: 200, pan: 0, tilt: -step, label: "tilt-"), 200)
            rep("pan+ @3x", try probe(rig, g, zoom: 300, pan: step, tilt: 0, label: "pan+"), 300)
            rep("pan+ @4x", try probe(rig, g, zoom: 400, pan: step, tilt: 0, label: "pan+"), 400)
            rep("pan+ @1x", try probe(rig, g, zoom: 100, pan: step, tilt: 0, label: "pan+"), 100)
            rep("tilt+ @1x", try probe(rig, g, zoom: 100, pan: 0, tilt: step, label: "tilt+"), 100)
            rep("pan+3step @2x", try probe(rig, g, zoom: 200, pan: 3 * step, tilt: 0, label: "pan+3"), 200)
            print(String(format: "height ratio 3x/2x %.3f  2x/1x %.3f (expect 1.5, 2.0)", (b3?.h ?? .nan) / base.h, base.h / (b1?.h ?? .nan)))
        }
    }

    // MARK: Image registration (crop shift independent of subject detection)

    static let ci = CIContext(options: [.useSoftwareRenderer: false])

    static func image(_ pb: CVPixelBuffer) -> CGImage? {
        let im = CIImage(cvPixelBuffer: pb)
        return ci.createCGImage(im, from: im.extent)
    }

    /// Translation (pixels, Vision convention) that aligns `floating` onto `reference`.
    static func shift(_ reference: CGImage, _ floating: CGImage) -> CGPoint? {
        let req = VNTranslationalImageRegistrationRequest(targetedCGImage: floating, options: [:])
        let h = VNImageRequestHandler(cgImage: reference, options: [:])
        guard (try? h.perform([req])) != nil, let o = req.results?.first as? VNImageTranslationAlignmentObservation else { return nil }
        return CGPoint(x: o.alignmentTransform.tx, y: o.alignmentTransform.ty)
    }

    /// Converts a registration translation into the apparent motion of scene content in
    /// normalized top-left output coords, using a synthetic shift of known sign to fix the convention.
    nonisolated(unsafe) static var convention: (sx: CGFloat, sy: CGFloat)?

    static func learnConvention(_ img: CGImage) -> (CGFloat, CGFloat) {
        // Content moved +40 px right and +40 px down (top-left coords) between ref and floating.
        let w = img.width - 80, hgt = img.height - 80
        let ref = img.cropping(to: CGRect(x: 40, y: 40, width: w, height: hgt))!
        let flo = img.cropping(to: CGRect(x: 0, y: 0, width: w, height: hgt))!
        let t = shift(ref, flo) ?? .zero
        print(String(format: "registration convention probe: content +40,+40 px -> tx %.1f ty %.1f", t.x, t.y))
        return (t.x == 0 ? 1 : 40 / t.x, t.y == 0 ? 1 : 40 / t.y)
    }

    /// Normalized content motion (dx right, dy down) of `now` relative to `ref`.
    static func motion(_ ref: CGImage, _ now: CGImage) -> CGPoint? {
        guard let c = convention, let t = shift(ref, now) else { return nil }
        return CGPoint(x: t.x * c.sx / CGFloat(ref.width), y: t.y * c.sy / CGFloat(ref.height))
    }

    static func save(_ im: CGImage, _ path: String) {
        let small = CIImage(cgImage: im).transformed(by: CGAffineTransform(scaleX: 640 / CGFloat(im.width), y: 640 / CGFloat(im.width)))
        try? ci.writeJPEGRepresentation(of: small, to: URL(fileURLWithPath: path), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
    }

    nonisolated(unsafe) static var probeSeconds = 1.8

    /// `uvcctl framing-probe <zoom> <pan> <tilt> [seconds]`: one step, long observation, read-back.
    static func probeOnce(_ a: [String]) -> Never {
        let z = Int(a[safe: 0] ?? "") ?? 200, p = Int(a[safe: 1] ?? "") ?? 108_000, t = Int(a[safe: 2] ?? "") ?? 0
        probeSeconds = Double(a[safe: 3] ?? "") ?? 6
        run { rig, g in
            Thread.sleep(forTimeInterval: 1.0)
            let m = try probe(rig, g, zoom: z, pan: p, tilt: t, label: "probe")
            print("read-back zoom \((try? rig.dev.read(rig.zoomC)) ?? []) pantilt \((try? rig.dev.read(rig.ptC)) ?? [])  final motion \(m.map { "\($0)" } ?? "n/a")")
        }
    }

    static func probe(_ rig: Rig, _ g: Grabber, zoom: Int, pan: Int, tilt: Int, label: String) throws -> CGPoint? {
        try rig.setZoom(zoom); try rig.setPanTilt(0, 0)
        Thread.sleep(forTimeInterval: 1.2)
        guard let (pb0, s0) = g.next(after: 0), let ref = image(pb0) else { return nil }
        if convention == nil { convention = learnConvention(ref) }
        try rig.setPanTilt(pan, tilt)
        if ProcessInfo.processInfo.environment["REZOOM"] != nil { try rig.setZoom(zoom - 1) } // does a zoom write apply the pan?
        let t0 = Date()
        var series: [String] = []
        var last: CGPoint?
        var seq = s0
        for target in stride(from: 0.15, through: probeSeconds, by: probeSeconds > 2 ? 0.5 : 0.15) {
            let wait = target - Date().timeIntervalSince(t0)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            guard let (pb, s) = g.next(after: seq), let im = image(pb) else { continue }
            seq = s
            if let m = motion(ref, im) {
                last = m
                let rb = ProcessInfo.processInfo.environment["READBACK"] != nil ? " rb\((try? rig.dev.read(rig.ptC)) ?? [])" : ""
                series.append(String(format: "%.2fs:%+.3f,%+.3f", Date().timeIntervalSince(t0), m.x, m.y) + rb)
            }
        }
        print("\(label) zoom \(zoom) pan \(pan) tilt \(tilt): " + series.joined(separator: " "))
        if let dir = ProcessInfo.processInfo.environment["SAVE_DIR"], let (pb, _) = g.next(after: seq), let im = image(pb) {
            save(ref, "\(dir)/\(label)-z\(zoom)-p\(pan)-t\(tilt)-before.jpg"); save(im, "\(dir)/\(label)-z\(zoom)-p\(pan)-t\(tilt)-after.jpg")
        }
        return last
    }

    static func liveRun(seconds: Double, mode: FramingMode) -> Never {
        run { rig, g in
            let engine = FramingEngine()
            if let r = rig.reframe { engine.controller.tuning = ReframeUnits.tuning(travel: r.travel); print("pan/tilt via digital reframe") }
            // START_ZOOM lets the run begin zoomed in, to exercise zoom-out convergence.
            let z0 = Int(ProcessInfo.processInfo.environment["START_ZOOM"] ?? "") ?? rig.ranges.zoom.lowerBound
            try rig.setZoom(z0); try rig.setReframe(0, 0, zoom: z0)
            Thread.sleep(forTimeInterval: 1.0)
            var written = PTZ(zoom: z0, pan: 0, tilt: 0)
            var lastWrite = Date.distantPast, nextZoom = true
            var seq = 0, lastLog = -1, writes = 0
            var lastBox: CGRect?
            let t0 = Date()
            print("t  box(x y w h)  zoom pan tilt  [cmd]")
            while Date().timeIntervalSince(t0) < seconds, let (pb, s) = g.next(after: seq) {
                seq = s
                let now = Date().timeIntervalSince(t0)
                guard let st = engine.process(pb, time: now, current: written, ranges: rig.ranges, mode: mode) else { continue }
                lastBox = st.box
                let cmd = st.command
                if cmd != written, Date().timeIntervalSince(lastWrite) >= writeGap {
                    // One control per write, alternating, to keep transfers >= 350 ms apart.
                    let zoomDiff = cmd.zoom != written.zoom, ptDiff = cmd.pan != written.pan || cmd.tilt != written.tilt
                    if zoomDiff && (nextZoom || !ptDiff) { try rig.setZoom(cmd.zoom); written.zoom = cmd.zoom; nextZoom = false }
                    else if ptDiff { try rig.setReframe(cmd.pan, cmd.tilt, zoom: written.zoom); written.pan = cmd.pan; written.tilt = cmd.tilt; nextZoom = true }
                    lastWrite = Date(); writes += 1
                }
                if Int(now) != lastLog {
                    lastLog = Int(now)
                    let b = lastBox.map { String(format: "%.2f %.2f %.2f %.2f", $0.minX, $0.minY, $0.width, $0.height) } ?? "none"
                    print(String(format: "%2d  %@  %d %d %d  [%@]", lastLog, b, written.zoom, written.pan, written.tilt, cmd.description))
                }
            }
            print("writes: \(writes)")
        }
    }
}
