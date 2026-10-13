import Foundation

/// A unit (terminal / processing unit) with its bmControls bitmap.
public struct UVCUnitInfo: Equatable, Sendable {
    public var id: UInt8
    public var bmControls: UInt32
    public init(id: UInt8, bmControls: UInt32) { self.id = id; self.bmControls = bmControls }
    public func supports(bit: Int) -> Bool { bmControls & (1 << UInt32(bit)) != 0 }
}

public struct UVCExtensionUnit: Equatable, Sendable {
    public var id: UInt8
    /// Canonical lowercase UUID string (first three GUID fields are little-endian on the wire).
    public var guid: String
    public var numControls: Int
    public var bmControls: [UInt8]
}

/// What the configuration descriptor says about the VideoControl interface.
public struct UVCTopology: Equatable, Sendable {
    public var hasVideoControl = false
    public var controlInterface: UInt8 = 0
    public var cameraTerminal: UVCUnitInfo?
    public var processingUnit: UVCUnitInfo?
    public var extensionUnits: [UVCExtensionUnit] = []
    public init() {}
}

public enum UVCDescriptorParser {
    /// Parse a full configuration descriptor blob (as returned by GetConfigurationDescriptorPtr).
    public static func parse(_ bytes: [UInt8]) -> UVCTopology {
        var topo = UVCTopology()
        var inVC = false
        var i = 0
        while i + 2 <= bytes.count {
            let len = Int(bytes[i])
            guard len >= 2, i + len <= bytes.count else { break }
            let d = Array(bytes[i ..< i + len])
            let type = d[1]
            if type == 0x04, len >= 9 { // interface
                let cls = d[5], sub = d[6]
                inVC = (cls == 0x0E && sub == 0x01)
                if inVC, !topo.hasVideoControl {
                    topo.hasVideoControl = true
                    topo.controlInterface = d[2]
                }
            } else if type == 0x24, inVC, len >= 4 { // CS_INTERFACE within VC
                switch d[2] {
                case 0x02: // INPUT_TERMINAL
                    if len >= 15, UInt16(d[4]) | UInt16(d[5]) << 8 == 0x0201, topo.cameraTerminal == nil {
                        let size = Int(d[14])
                        if let m = mask(d, from: 15, size: size) {
                            topo.cameraTerminal = UVCUnitInfo(id: d[3], bmControls: m)
                        }
                    }
                case 0x05: // PROCESSING_UNIT
                    if len >= 8, topo.processingUnit == nil {
                        let size = Int(d[7])
                        if let m = mask(d, from: 8, size: size) {
                            topo.processingUnit = UVCUnitInfo(id: d[3], bmControls: m)
                        }
                    }
                case 0x06: // EXTENSION_UNIT
                    if len >= 22 {
                        let nIn = Int(d[21])
                        let sizeIdx = 22 + nIn
                        if sizeIdx < len {
                            let size = Int(d[sizeIdx])
                            let start = sizeIdx + 1
                            let end = min(start + size, len)
                            topo.extensionUnits.append(UVCExtensionUnit(
                                id: d[3],
                                guid: guidString(Array(d[4 ..< 20])),
                                numControls: Int(d[20]),
                                bmControls: start <= end ? Array(d[start ..< end]) : []
                            ))
                        }
                    }
                default: break
                }
            }
            i += len
        }
        return topo
    }

    static func mask(_ d: [UInt8], from: Int, size: Int) -> UInt32? {
        guard size >= 0, from + size <= d.count else { return nil }
        var m: UInt32 = 0
        for k in 0 ..< min(size, 4) { m |= UInt32(d[from + k]) << UInt32(8 * k) }
        return m
    }

    static func guidString(_ g: [UInt8]) -> String {
        func h<S: Sequence>(_ s: S) -> String where S.Element == UInt8 { s.map { String(format: "%02x", $0) }.joined() }
        let a = h(g[0 ..< 4].reversed())
        let b = h(g[4 ..< 6].reversed())
        let c = h(g[6 ..< 8].reversed())
        return "\(a)-\(b)-\(c)-\(h(g[8 ..< 10]))-\(h(g[10 ..< 16]))"
    }
}
