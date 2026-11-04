import Foundation

/// What a user pastes into a "support my camera" issue: identity, descriptor summary,
/// standard control ranges and a starter profile to fill in.
public enum CameraReport {
    /// JSON profile with the camera's IDs and every extension unit aliased as `xu<id>`.
    /// No controls: what a vendor selector does can't be read from the descriptor.
    public static func starterProfile(name: String, vendorID: UInt16, productID: UInt16, topology: UVCTopology) -> String {
        let profile = DeviceProfile(
            name: name, match: .init(vendorID: HexInt(Int(vendorID)), productIDs: [HexInt(Int(productID))]),
            units: Dictionary(topology.extensionUnits.map { ("xu\($0.id)", $0.guid) }, uniquingKeysWith: { a, _ in a }),
            controls: [], forbiddenSelectors: [], naturalDefaults: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(profile), as: UTF8.self)
    }

    /// Markdown report for one camera. Reads every standard control (min/max/res/def/cur),
    /// so call it off the main thread.
    public static func markdown(for device: UVCDevice, appVersion: String? = nil) -> String {
        let t = device.topology
        var out = ["### Camera", "",
                   "- Name: \(device.name)",
                   "- USB ID: \(hex(device.vendorID)):\(hex(device.productID))",
                   "- Camdeck profile: \(device.profile.name)"]
        if let link = device.usbLink { out.append("- USB: bcdUSB \(String(format: "0x%04X", link.bcdUSB)), speed \(link.speed)") }
        if let appVersion { out.append("- Camdeck: \(appVersion)") }
        out += ["", "### Descriptor", ""]
        if let ct = t.cameraTerminal { out.append(String(format: "- Camera terminal: id %d, bmControls 0x%06X", ct.id, ct.bmControls)) }
        if let pu = t.processingUnit { out.append(String(format: "- Processing unit: id %d, bmControls 0x%04X", pu.id, pu.bmControls)) }
        for xu in t.extensionUnits { out.append("- Extension unit: id \(xu.id), `\(xu.guid)`, \(xu.numControls) controls") }
        if t.cameraTerminal == nil, t.processingUnit == nil, t.extensionUnits.isEmpty { out.append("- No UVC units found") }
        out += ["", "### Standard controls", "", "| Control | Min | Max | Res | Default | Current |", "| --- | --- | --- | --- | --- | --- |"]
        for s in device.readControls() {
            out.append("| \(s.control.name) | \(fmt(s.min)) | \(fmt(s.max)) | \(fmt(s.res)) | \(fmt(s.def)) | \(fmt(s.cur)) |")
        }
        out += ["", "### Starter profile", "", "```json",
                starterProfile(name: device.name, vendorID: device.vendorID, productID: device.productID, topology: t),
                "```"]
        return out.joined(separator: "\n") + "\n"
    }

    static func hex(_ v: UInt16) -> String { String(format: "0x%04X", v) }

    /// `[Int]?` as "-", "n" or "(a, b)"; shared with uvcctl.
    public static func fmt(_ v: [Int]?) -> String {
        guard let v else { return "-" }
        return v.count == 1 ? "\(v[0])" : "(\(v.map(String.init).joined(separator: ", ")))"
    }
}
