import Foundation
import IOKit

/// A USB 3 camera that enumerated at USB 2 speed or lower.
public struct USBLinkWarning: Equatable, Sendable {
    public var message: String { "Connected at USB 2 speed. Use a USB 3 port or cable for full quality." }
}

public enum USBLink {
    /// `speed` uses IOKit's `USBDeviceSpeed` numbering (USB.h): 0 low, 1 full, 2 high, 3 super, 4 super+.
    /// Warns only for a device that advertises USB 3 (bcdUSB >= 0x0300) but linked below SuperSpeed.
    public static func assess(bcdUSB: Int, speed: Int) -> USBLinkWarning? {
        bcdUSB >= 0x0300 && speed < 3 ? USBLinkWarning() : nil
    }

    /// bcdUSB and link speed from the device's IOUSBHostDevice registry entry. Registry reads only.
    /// "Device Speed" is `kUSBDevicePropertySpeed` (USBDeviceSpeed numbering). "UsbLinkSpeed" (bits/s) is the
    /// fallback. "USBSpeed" is never used: it is Apple-internal and uses a different enum (3 = high, 4 = super).
    static func read(_ s: io_service_t) -> (bcdUSB: Int, speed: Int)? {
        func int(_ k: String) -> Int? { UVCDevice.intProp(s, k) }
        guard let bcd = int("bcdUSB") else { return nil }
        if let speed = int("Device Speed") { return (bcd, speed) }
        if let bps = int("UsbLinkSpeed") { return (bcd, bps >= 5_000_000_000 ? 3 : bps >= 480_000_000 ? 2 : 1) }
        return nil
    }
}
