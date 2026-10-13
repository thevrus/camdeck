import Foundation
import IOKit

/// Fires `handler` (on `queue`) whenever a USB device arrives or leaves.
/// The camera re-enumerates when it switches modes, so callers should rebuild their UVCDevice.
public final class UVCHotplugMonitor: @unchecked Sendable {
    private final class Box { let handler: @Sendable () -> Void; init(_ h: @escaping @Sendable () -> Void) { handler = h } }
    private let port: IONotificationPortRef
    private var iterators: [io_iterator_t] = []
    private let box: Box

    public init(queue: DispatchQueue = .main, handler: @escaping @Sendable () -> Void) {
        box = Box(handler)
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, queue)
        let refcon = Unmanaged.passUnretained(box).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            while case let s = IOIteratorNext(iterator), s != 0 { IOObjectRelease(s) }
            guard let refcon else { return }
            Unmanaged<Box>.fromOpaque(refcon).takeUnretainedValue().handler()
        }
        for kind in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var it: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, kind, IOServiceMatching("IOUSBHostDevice"), callback, refcon, &it) == KERN_SUCCESS {
                while case let s = IOIteratorNext(it), s != 0 { IOObjectRelease(s) } // arm
                iterators.append(it)
            }
        }
    }

    deinit {
        iterators.forEach { IOObjectRelease($0) }
        IONotificationPortDestroy(port)
    }
}
