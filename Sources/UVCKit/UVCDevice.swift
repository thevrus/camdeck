import Foundation
import IOKit
import IOKit.usb
import IOKit.usb.IOUSBLib

public enum UVCRequest: UInt8, Sendable {
    case cur = 0x81, min = 0x82, max = 0x83, res = 0x84, len = 0x85, info = 0x86, def = 0x87
}

public enum UVCError: Error, CustomStringConvertible {
    case io(Int32)
    case noUnit(String)
    case forbidden(String)
    public var description: String {
        switch self {
        case .io(let r): return String(format: "IOReturn 0x%08x", UInt32(bitPattern: r))
        case .noUnit(let n): return "unit for \(n) not present in descriptor"
        case .forbidden(let n): return "write refused: \(n) is on the forbidden list"
        }
    }
}

private let kIOUSBDeviceUserClientTypeID = CFUUIDGetConstantUUIDWithBytes(nil, 0x9d, 0xc7, 0xb7, 0x80, 0x9e, 0xc0, 0x11, 0xD4, 0xa5, 0x4f, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)
private let kIOCFPlugInInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
private let kIOUSBDeviceInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil, 0x5c, 0x81, 0x87, 0xd0, 0x9e, 0xf3, 0x11, 0xD4, 0x8b, 0x45, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)

/// IOKit EP0 DeviceRequest on the IOUSBDeviceInterface; never opens or seizes the device.
final class IOKitChannel: UVCRequestChannel, @unchecked Sendable {
    private let dev: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>>
    init(_ dev: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>>) { self.dev = dev }
    deinit { _ = dev.pointee.pointee.Release(dev) }

    func deviceRequest(requestType: UInt8, request: UInt8, value: UInt16, index: UInt16, data: [UInt8]) throws -> [UInt8] {
        var buf = data
        var r = IOUSBDevRequest(bmRequestType: requestType, bRequest: request, wValue: value, wIndex: index,
                                wLength: UInt16(buf.count), pData: nil, wLenDone: 0)
        let kr = buf.withUnsafeMutableBytes { p -> IOReturn in
            r.pData = p.baseAddress
            return dev.pointee.pointee.DeviceRequest(dev, &r)
        }
        guard kr == KERN_SUCCESS else { throw UVCError.io(kr) }
        return Array(buf.prefix(Int(r.wLenDone)))
    }
}

/// A UVC camera reached through plain control transfers on the IOUSBDeviceInterface.
/// The device is never opened or seized, so this works alongside the system's streaming.
/// All requests go through `transport` (serial, rate-limited, forbidden-selector guard).
public final class UVCDevice: @unchecked Sendable {
    public let vendorID: UInt16
    public let productID: UInt16
    public let name: String
    public let topology: UVCTopology
    public let availableControls: [UVCControl]
    public let profile: DeviceProfile
    public let transport: UVCTransport
    /// iSerialNumber string from the USB device descriptor, if the device reports one.
    public let serialNumber: String?

    public convenience init?(vendorID: UInt16, productID: UInt16) {
        for s in UVCDevice.services() {
            defer { IOObjectRelease(s) }
            if UVCDevice.intProp(s, "idVendor") == Int(vendorID), UVCDevice.intProp(s, "idProduct") == Int(productID) {
                self.init(service: s)
                return
            }
        }
        return nil
    }

    /// All connected UVC devices (device class 0xEF or a VideoControl interface).
    public static func enumerate() -> [UVCDevice] {
        var out: [UVCDevice] = []
        for s in services() {
            defer { IOObjectRelease(s) }
            if let d = UVCDevice(service: s) { out.append(d) }
        }
        return out
    }

    private static func services() -> [io_service_t] {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var r: [io_service_t] = []
        while case let s = IOIteratorNext(it), s != 0 { r.append(s) }
        return r
    }

    private static func intProp(_ s: io_service_t, _ key: String) -> Int? {
        IORegistryEntryCreateCFProperty(s, key as CFString, nil, 0)?.takeRetainedValue() as? Int
    }

    convenience init?(service s: io_service_t) {
        guard let vid = UVCDevice.intProp(s, "idVendor"), let pid = UVCDevice.intProp(s, "idProduct") else { return nil }
        var plug: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        let kr = IOCreatePlugInInterfaceForService(s, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score)
        guard kr == KERN_SUCCESS, let p = plug?.pointee?.pointee else { return nil }
        var raw: UnsafeMutableRawPointer?
        _ = withUnsafeMutablePointer(to: &raw) { ptr in
            p.QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), UnsafeMutablePointer<LPVOID?>(OpaquePointer(ptr)))
        }
        IODestroyPlugInInterface(plug)
        guard let raw else { return nil }
        let dev = raw.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBDeviceInterface>.self)

        // Cached configuration descriptor (no open required).
        var topo = UVCTopology()
        var cfg: IOUSBConfigurationDescriptorPtr?
        if dev.pointee.pointee.GetConfigurationDescriptorPtr(dev, 0, &cfg) == KERN_SUCCESS, let cfg {
            let total = Int(UInt16(littleEndian: cfg.pointee.wTotalLength))
            let bytes = Array(UnsafeBufferPointer(start: UnsafeRawPointer(cfg).assumingMemoryBound(to: UInt8.self), count: total))
            topo = UVCDescriptorParser.parse(bytes)
        }
        let devClass = UVCDevice.intProp(s, "bDeviceClass") ?? 0
        guard topo.hasVideoControl || devClass == 0xEF else {
            _ = dev.pointee.pointee.Release(dev)
            return nil
        }
        let name = (IORegistryEntryCreateCFProperty(s, "USB Product Name" as CFString, nil, 0)?.takeRetainedValue() as? String) ?? "UVC Camera"
        let serial = IORegistryEntryCreateCFProperty(s, "USB Serial Number" as CFString, nil, 0)?.takeRetainedValue() as? String
        self.init(vendorID: UInt16(vid), productID: UInt16(pid), name: name, serialNumber: serial, topology: topo, channel: IOKitChannel(dev))
    }

    /// Any channel (tests use a fake device).
    public init(vendorID: UInt16, productID: UInt16, name: String, serialNumber: String? = nil, topology: UVCTopology,
                channel: UVCRequestChannel, scheduler: UVCRequestScheduler = .shared) {
        self.serialNumber = serialNumber
        self.vendorID = vendorID
        self.productID = productID
        self.name = name
        self.topology = topology
        self.availableControls = UVCControl.availableControls(in: topology)
        self.profile = VendorProfiles.profile(vendorID: vendorID, productID: productID)
        self.transport = UVCTransport(channel: channel, topology: topology, scheduler: scheduler)
    }

    /// bcdUSB and link speed (USBDeviceSpeed numbering) from the registry; nil if the device is gone.
    /// Looked up by vendor/product ID, so two identical cameras read the first match.
    public var usbLink: (bcdUSB: Int, speed: Int)? {
        for s in UVCDevice.services() {
            defer { IOObjectRelease(s) }
            if UVCDevice.intProp(s, "idVendor") == Int(vendorID), UVCDevice.intProp(s, "idProduct") == Int(productID) {
                return USBLink.read(s)
            }
        }
        return nil
    }

    /// Warning for a USB 3 camera linked at USB 2 speed or below.
    public var usbWarning: USBLinkWarning? { usbLink.flatMap { USBLink.assess(bcdUSB: $0.bcdUSB, speed: $0.speed) } }

    /// Pure description used by driver matching.
    public var descriptor: CameraDescriptor {
        CameraDescriptor(vendorID: vendorID, productID: productID, name: name, topology: topology)
    }

    // MARK: Raw requests (all through the transport)

    public func get(unit: UInt8, selector: UInt8, length: Int, request: UVCRequest = .cur) throws -> [UInt8] {
        try transport.get(unit: unit, selector: selector, length: length, request: request)
    }

    /// Throws if (unit, selector) resolves to an extension unit selector that any profile or driver forbids.
    public static func guardWrite(topology: UVCTopology, unit: UInt8, selector: UInt8) throws {
        try UVCTransport.guardWrite(topology: topology, forbidden: DriverRegistry.allForbiddenSelectors, unit: unit, selector: selector)
    }

    /// SET_CUR. The transport refuses forbidden extension-unit selectors.
    public func set(unit: UInt8, selector: UInt8, data: [UInt8]) throws {
        try transport.set(unit: unit, selector: selector, data: data)
    }

    // MARK: Typed standard controls

    public func unitID(for c: UVCControl) -> UInt8? {
        switch c.unit {
        case .cameraTerminal: return topology.cameraTerminal?.id
        case .processingUnit: return topology.processingUnit?.id
        }
    }

    public func read(_ c: UVCControl, _ request: UVCRequest = .cur) throws -> [Int] {
        guard let u = unitID(for: c) else { throw UVCError.noUnit(c.name) }
        let b = try get(unit: u, selector: c.selector, length: c.size, request: request)
        guard let v = c.decode(b) else { throw UVCError.io(-1) }
        return v
    }

    public func write(_ c: UVCControl, _ values: [Int]) throws {
        guard let u = unitID(for: c) else { throw UVCError.noUnit(c.name) }
        try set(unit: u, selector: c.selector, data: c.encode(values))
    }

    /// Reads min/max/res/def/cur/info for every available standard control.
    public func readControls() -> [UVCControlState] {
        availableControls.map { c in
            UVCControlState(
                control: c,
                min: try? read(c, .min), max: try? read(c, .max), res: try? read(c, .res),
                def: try? read(c, .def), cur: try? read(c, .cur),
                info: (try? get(unit: unitID(for: c) ?? 0, selector: c.selector, length: 1, request: .info))?.first
            )
        }
    }

    // MARK: Profile controls

    public func unitID(forGUID guid: String) -> UInt8? {
        topology.extensionUnits.first { $0.guid == guid.lowercased() }?.id
    }

    /// Whether this device's descriptor has the unit the control needs.
    public func supports(_ c: ProfileControl) -> Bool { unitID(forGUID: profile.guid(for: c.unit)) != nil }

    /// Bytes to transfer for a profile control: the encoding's fixed size, or GET_LEN when the device decides.
    private func profileLength(_ c: ProfileControl, unit u: UInt8, selector sel: UInt8) throws -> Int {
        if let n = c.encoding.size { return n }
        return try transport.length(unit: u, selector: sel)
    }

    /// Reads one profile control; returns the normalized wire value.
    public func readProfile(_ c: ProfileControl) throws -> Int {
        guard let u = unitID(forGUID: profile.guid(for: c.unit)) else { throw UVCError.noUnit(c.id) }
        let sel = UInt8(c.selector)
        let b = try get(unit: u, selector: sel, length: profileLength(c, unit: u, selector: sel))
        guard let v = c.encoding.decode(b) else { throw UVCError.io(-1) }
        return c.normalize(v)
    }

    /// Writes one profile control from a wire value, doing read-modify-write when the profile asks for it.
    public func writeProfile(_ c: ProfileControl, wire: Int) throws {
        guard let u = unitID(forGUID: profile.guid(for: c.unit)) else { throw UVCError.noUnit(c.id) }
        let sel = UInt8(c.selector)
        let encode = { (current: [UInt8]?) throws -> [UInt8] in
            guard let data = c.encoding.encode(c.normalize(wire), current: current) else { throw UVCError.io(-1) }
            return data
        }
        if c.needsReadModifyWrite {
            // readModifyWrite rejects a short read, so a device-sized buffer never goes back truncated.
            try transport.readModifyWrite(unit: u, selector: sel, length: profileLength(c, unit: u, selector: sel), encode)
        } else {
            try set(unit: u, selector: sel, data: encode(nil))
        }
    }
}
