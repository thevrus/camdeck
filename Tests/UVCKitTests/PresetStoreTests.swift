import XCTest
@testable import UVCKit

@MainActor
final class PresetStoreTests: XCTestCase {
    var dir: URL!
    var current = CameraSettings(controls: ["brightness": [1]])
    var applied: [CameraSettings] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("camdeck-\(UUID())")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func make() -> PresetStore {
        PresetStore(uniqueID: "0x1/abc", directory: dir, capture: { self.current }, apply: { self.applied.append($0) })
    }

    func testLifecycleAndPersistence() throws {
        let s = make()
        let a = s.save(name: "A")
        current.controls["brightness"] = [2]
        let b = s.save(name: "B")
        let c = s.save(name: "C")
        XCTAssertEqual(b.settings.controls["brightness"], [2])
        s.rename(a.id, to: "Alpha")
        s.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(s.items.map(\.name), ["B", "C", "Alpha"])
        s.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(s.items.map(\.name), ["Alpha", "B", "C"])
        s.startupPresetID = b.id
        s.apply(c.id)
        XCTAssertEqual(applied.count, 1)
        s.delete(c.id)
        s.apply(c.id)
        XCTAssertEqual(applied.count, 1)

        let again = make()
        XCTAssertEqual(again.items.map(\.name), ["Alpha", "B"])
        XCTAssertEqual(again.startupPresetID, b.id)
        again.applyStartup()
        XCTAssertEqual(applied.last, b.settings)
        again.delete(b.id)
        XCTAssertNil(make().startupPresetID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("presets-0x1_abc.json").path))
    }
}
