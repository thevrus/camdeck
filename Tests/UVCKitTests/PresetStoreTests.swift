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

    func testAppBindingResolution() {
        let s = make()
        let meet = s.save(name: "Meeting"), stream = s.save(name: "Stream")
        s.bind(app: "us.zoom.xos", to: meet.id)
        s.bind(app: "com.obsproject.obs-studio", to: stream.id)
        XCTAssertNil(s.preset(frontmost: nil))
        // Zoom idling in the background while Photo Booth (frontmost, unbound) opens the camera.
        XCTAssertNil(s.preset(frontmost: "com.apple.Photo-Booth"))
        XCTAssertEqual(s.preset(frontmost: "us.zoom.xos")?.id, meet.id)
        XCTAssertEqual(s.preset(frontmost: "com.obsproject.obs-studio")?.id, stream.id)
        XCTAssertNil(s.preset(frontmost: "com.apple.finder"))
    }

    func testAppBindingPersistenceAndDelete() throws {
        let s = make()
        let a = s.save(name: "A"), b = s.save(name: "B")
        s.bind(app: "x.one", to: a.id)
        s.bind(app: "x.two", to: b.id)
        XCTAssertEqual(make().appBindings, ["x.one": a.id, "x.two": b.id])
        s.delete(a.id)
        XCTAssertEqual(make().appBindings, ["x.two": b.id])
        s.unbind(app: "x.two")
        XCTAssertTrue(make().appBindings.isEmpty)
    }

    func testLegacyFileWithoutBindingsLoads() throws {
        let s = make()
        s.save(name: "Old")
        let url = dir.appendingPathComponent("presets-0x1_abc.json")
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        obj.removeValue(forKey: "appBindings")
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
        let again = make()
        XCTAssertEqual(again.items.map(\.name), ["Old"])
        XCTAssertTrue(again.appBindings.isEmpty)
    }

    func testExportImportRoundTrip() throws {
        let a = make()
        a.save(name: "A")
        current.controls["future-control"] = [9]
        a.save(name: "B")
        let data = try a.exportData()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["camdeck"] as? Int, 1)
        XCTAssertEqual((json["presets"] as? [Any])?.count, 2)

        let b = PresetStore(uniqueID: "other", directory: dir, capture: { self.current }, apply: { _ in })
        b.save(name: "A")
        XCTAssertEqual(try b.importData(data), 2)
        XCTAssertEqual(b.items.map(\.name), ["A", "A 2", "B"])
        XCTAssertEqual(Set(b.items.map(\.id)).count, 3)
        XCTAssertEqual(try b.importData(data), 2)
        XCTAssertEqual(b.items.map(\.name), ["A", "A 2", "B", "A 3", "B 2"])
        XCTAssertEqual(b.items[2].settings.controls["future-control"], [9])
        let reloaded = PresetStore(uniqueID: "other", directory: dir, capture: { self.current }, apply: { _ in })
        XCTAssertEqual(reloaded.items.count, 5)
    }

    func testImportRejectsGarbage() {
        let s = make()
        XCTAssertThrowsError(try s.importData(Data("nope".utf8)))
        XCTAssertThrowsError(try s.importData(Data(#"{"presets": []}"#.utf8)))
        XCTAssertEqual(s.items.count, 0)
    }
}
