import Foundation
import UVCKit

func fmt(_ v: [Int]?) -> String { v.map { $0.count == 1 ? "\($0[0])" : "(\($0.map(String.init).joined(separator: ", ")))" } ?? "-" }

func fail(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }

/// `uvcctl get <id>` / `uvcctl set <id> <value>` against the first device whose profile defines <id>.
func runProfileCommand(_ args: [String]) -> Never {
    guard args.count >= 2, args[0] == "get" || (args[0] == "set" && args.count >= 3) else {
        fail("usage: uvcctl [get <control> | set <control> <value> | framing-calibrate | framing-run [seconds] [close|medium|wide]]")
    }
    guard let dev = UVCDevice.enumerate().first(where: { $0.profile.control(args[1]) != nil && $0.supports($0.profile.control(args[1])!) }),
          let c = dev.profile.control(args[1]) else {
        fail("no connected device has profile control '\(args[1])'")
    }
    func line(_ w: Int) -> String { "\(c.id) = \(c.displayText(w))  (wire \(w))" }
    do {
        if args[0] == "get" { print(line(try dev.readProfile(c))); exit(0) }
        guard let wire = c.wire(fromDisplay: args[2]) else { fail("cannot parse '\(args[2])' for \(c.id)") }
        if let w = c.enabledWhen, let dep = dev.profile.control(w.control), try dev.readProfile(dep) != w.equals {
            fail("\(c.id) is disabled while \(dep.id) != \(dep.displayText(w.equals))")
        }
        try dev.writeProfile(c, wire: wire)
        Thread.sleep(forTimeInterval: 0.3)
        print("set  " + line(try dev.readProfile(c)))
        exit(0)
    } catch { fail("\(c.id): \(error)") }
}

let cliArgs = Array(CommandLine.arguments.dropFirst())
if cliArgs.first == "framing-calibrate" { FramingTool.calibrate() }
if cliArgs.first == "pt-test" {
    // Diagnostics: `uvcctl pt-test z200 p36000,0 ...` writes each step 0.6 s apart, reading back zoom and pan/tilt.
    guard let d = UVCDevice(vendorID: Insta360LinkDriver.vendorID, productID: Insta360LinkDriver.link2CProductID) else { fail("no link 2c") }
    let z = UVCControl.zoomControl, pt = UVCControl.panTiltControl
    func show(_ l: String) { print("\(l): zoom \((try? d.read(z)) ?? []) pantilt \((try? d.read(pt)) ?? [])") }
    show("start")
    for op in cliArgs.dropFirst() {
        do {
            if op.hasPrefix("z") { try d.write(z, [Int(op.dropFirst())!]) }
            else if op.hasPrefix("p") { let v = op.dropFirst().split(separator: ",").map { Int($0)! }; try d.write(pt, v) }
        } catch { print("\(op) error \(error)") }
        Thread.sleep(forTimeInterval: 0.6); show(op)
    }
    try? d.write(pt, [0, 0]); Thread.sleep(forTimeInterval: 0.4); try? d.write(z, [100]); Thread.sleep(forTimeInterval: 0.4)
    show("restored")
    exit(0)
}
if cliArgs.first == "xu-dump" { ReframeTool.dump(Array(cliArgs.dropFirst())) }
if cliArgs.first == "reframe-calibrate" { ReframeTool.calibrate(Array(cliArgs.dropFirst())) }
if cliArgs.first == "reframe-probe" { ReframeTool.probe(Array(cliArgs.dropFirst())) }
if cliArgs.first == "reframe-chain" { ReframeTool.chain(Array(cliArgs.dropFirst())) }
if cliArgs.first == "zoom-mirror" { ReframeTool.zoomMirror(Array(cliArgs.dropFirst())) }
if cliArgs.first == "zoom-edge" { ReframeTool.zoomEdge(Array(cliArgs.dropFirst())) }
if cliArgs.first == "ramp-test" { ReframeTool.rampTest(Array(cliArgs.dropFirst())) }
if cliArgs.first == "framing-probe" { FramingTool.probeOnce(Array(cliArgs.dropFirst())) }
if cliArgs.first == "framing-run" {
    let secs = cliArgs.count > 1 ? Double(cliArgs[1]) ?? 20 : 20
    let mode = cliArgs.count > 2 ? FramingMode(rawValue: cliArgs[2]) ?? .medium : .medium
    FramingTool.liveRun(seconds: secs, mode: mode)
}
if CommandLine.arguments.count > 1 { runProfileCommand(Array(CommandLine.arguments.dropFirst())) }

let devices = UVCDevice.enumerate()
if devices.isEmpty { print("no UVC devices found"); exit(1) }
for d in devices {
    print(String(format: "%@  %04x:%04x  profile: %@", d.name, d.vendorID, d.productID, d.profile.name))
    let t = d.topology
    print("  VC interface \(t.controlInterface)")
    if let ct = t.cameraTerminal { print(String(format: "  camera terminal  id %d  bmControls 0x%06X", ct.id, ct.bmControls)) }
    if let pu = t.processingUnit { print(String(format: "  processing unit  id %d  bmControls 0x%04X", pu.id, pu.bmControls)) }
    for xu in t.extensionUnits { print("  extension unit   id \(xu.id)  \(xu.guid)  controls \(xu.numControls)  (not queried)") }
    if !d.profile.controls.isEmpty { print("  profile controls: " + d.profile.controls.map(\.id).joined(separator: ", ")) }
    print("  controls:")
    for s in d.readControls() {
        print("    \(s.control.name.padding(toLength: 20, withPad: " ", startingAt: 0)) min \(fmt(s.min))  max \(fmt(s.max))  res \(fmt(s.res))  def \(fmt(s.def))  cur \(fmt(s.cur))")
    }
}
