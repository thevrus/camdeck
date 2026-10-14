import CoreMediaIO
import Foundation

/// Reports when any process starts or stops using one camera (CoreMediaIO `DeviceIsRunningSomewhere`).
/// Event-driven: one property listener on the main queue, no polling. The flag includes this process, so
/// callers that run their own capture session must account for it. Does nothing if the device is not found.
@MainActor
public final class CameraUsageMonitor {
    /// Current value of the flag, updated before `onChange` fires.
    public private(set) var isRunningSomewhere = false
    /// Called on the main queue whenever the flag changes.
    public var onChange: ((Bool) -> Void)?

    private var deviceID: CMIOObjectID?
    private var listener: CMIOObjectPropertyListenerBlock?

    private static var runningAddress = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))

    /// - uniqueID: `AVCaptureDevice.uniqueID`, which equals the CMIO device UID.
    public init(uniqueID: String) {
        guard let id = Self.findDevice(uid: uniqueID) else { return }
        deviceID = id
        isRunningSomewhere = Self.readRunning(id)
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            // Delivered on the main queue (see below).
            MainActor.assumeIsolated { self?.refresh() }
        }
        listener = block
        var addr = Self.runningAddress
        let status = CMIOObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main, block)
        if status != 0 { listener = nil; deviceID = nil }
    }

    /// Removes the listener. Also done on deinit.
    public func stop() {
        guard let id = deviceID, let block = listener else { return }
        var addr = Self.runningAddress
        CMIOObjectRemovePropertyListenerBlock(id, &addr, DispatchQueue.main, block)
        listener = nil
        deviceID = nil
        onChange = nil
    }

    deinit {
        // Not isolated: capture plain values only.
        if let id = deviceID, let block = listener {
            var addr = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            CMIOObjectRemovePropertyListenerBlock(id, &addr, DispatchQueue.main, block)
        }
    }

    private func refresh() {
        guard let id = deviceID else { return }
        let now = Self.readRunning(id)
        guard now != isRunningSomewhere else { return }
        isRunningSomewhere = now
        onChange?(now)
    }

    // MARK: CoreMediaIO

    private static func readRunning(_ id: CMIOObjectID) -> Bool {
        var addr = runningAddress
        var value: UInt32 = 0
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        guard CMIOObjectGetPropertyData(id, &addr, 0, nil, size, &used, &value) == 0 else { return false }
        return value != 0
    }

    private static func findDevice(uid: String) -> CMIOObjectID? {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == 0, size > 0 else { return nil }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &ids) == 0 else { return nil }
        return ids.first { deviceUID($0) == uid }
    }

    private static func deviceUID(_ id: CMIOObjectID) -> String? {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == 0, size > 0 else { return nil }
        var used: UInt32 = 0
        var uid: Unmanaged<CFString>?
        guard CMIOObjectGetPropertyData(id, &addr, 0, nil, size, &used, &uid) == 0 else { return nil }
        return uid?.takeRetainedValue() as String?
    }
}
