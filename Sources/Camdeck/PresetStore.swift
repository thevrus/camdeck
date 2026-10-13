import Foundation
import UVCKit

extension PresetStore {
    /// Store bound to a controller. Weak reference, so it never extends the controller's life.
    @MainActor
    convenience init(uniqueID: String, controller: CameraController, directory: URL = PresetStore.defaultDirectory) {
        self.init(uniqueID: uniqueID, directory: directory,
                  capture: { [weak controller] in controller?.captureSettings() ?? CameraSettings() },
                  apply: { [weak controller] in controller?.apply($0) })
    }
}
