import XCTest
@testable import UVCKit

final class UserProfileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(_ name: String, _ json: String) throws {
        try Data(json.utf8).write(to: dir.appendingPathComponent(name))
    }

    private func profile(named name: String, pid: String) -> String {
        """
        { "name": "\(name)", "match": { "vendorID": "0x1234", "productIDs": ["\(pid)"] },
          "units": {}, "forbiddenSelectors": [], "controls": [] }
        """
    }

    func testLoadsValidFilesInNameOrderAndSkipsBadOnes() throws {
        try write("b.json", profile(named: "B", pid: "0x0002"))
        try write("a.JSON", profile(named: "A", pid: "0x0001"))
        try write("broken.json", "{ not json")
        try write("notes.txt", "ignored")
        XCTAssertEqual(VendorProfiles.load(directory: dir).map(\.name), ["A", "B"])
    }

    func testMissingDirectoryYieldsNothing() {
        XCTAssertTrue(VendorProfiles.load(directory: dir.appendingPathComponent("nope")).isEmpty)
    }

    func testUserDirectoryIsUnderApplicationSupport() {
        XCTAssertTrue(VendorProfiles.userDirectory.path.hasSuffix("Application Support/Camdeck/Profiles"))
    }
}
