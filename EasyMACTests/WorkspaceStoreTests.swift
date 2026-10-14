import XCTest

final class WorkspaceStoreTests: XCTestCase {
    private var dir: URL!
    private var store: WorkspaceStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("EasyMACTests-\(UUID().uuidString)")
        store = WorkspaceStore(fileURL: dir.appendingPathComponent("workspaces.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func sample() -> [Workspace] {
        [
            Workspace(name: "RentalX", colorHex: "#D22027", hotkeyIndex: 1, items: [
                WorkspaceItem(bundleID: "com.microsoft.VSCode", appName: "Code", appPath: "/Applications/Visual Studio Code.app",
                              titleContains: "RentalX", relativeFrame: CGRect(x: 0, y: 0, width: 0.6, height: 1), screenID: "ABC"),
                WorkspaceItem(bundleID: "com.google.Chrome", relativeFrame: CGRect(x: 0.6, y: 0, width: 0.4, height: 1)),
            ], layout: .sixtyForty),
            Workspace(name: "DTIS", colorHex: "#0A84FF"),
        ]
    }

    func testMissingFileLoadsEmpty() throws {
        XCTAssertEqual(try store.load(), [])
    }

    func testRoundTrip() throws {
        let workspaces = sample()
        try store.save(workspaces)
        XCTAssertEqual(try store.load(), workspaces)
    }

    func testFileHasVersion() throws {
        try store.save(sample())
        let data = try Data(contentsOf: store.fileURL)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["version"] as? Int, WorkspaceStore.currentVersion)
    }

    func testMigratesLegacyBareArray() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let workspaces = sample()
        try JSONEncoder().encode(workspaces).write(to: store.fileURL)

        XCTAssertEqual(try store.load(), workspaces)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        XCTAssertEqual(object?["version"] as? Int, 1, "legacy file is rewritten in the current format")
    }

    func testCorruptFileIsMovedAside() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: store.fileURL)
        XCTAssertEqual(try store.load(), [])
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(files.contains { $0.contains("corrupt") })
    }

    func testFutureVersionIsRejectedNotOverwritten() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"version": 99, "workspaces": []}"#.utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testInitials() {
        XCTAssertEqual(Workspace(name: "AppAlbania Clients", colorHex: "#fff").initials, "AC")
        XCTAssertEqual(Workspace(name: "dtis", colorHex: "#fff").initials, "DT")
        XCTAssertEqual(Workspace(name: "\u{200E}WhatsApp + Chrome", colorHex: "#fff").initials, "WC")
        XCTAssertEqual(Workspace.clean("\u{200E}WhatsApp "), "WhatsApp")
    }
}
