import XCTest
@testable import Compressor

final class PathSafetyTests: XCTestCase {
    func testRejectsNonAppPath() {
        XCTAssertThrowsError(try AppSelectionService.validateAppURL(URL(fileURLWithPath: "/Applications/Foo.txt"))) { error in
            XCTAssertEqual(error as? CompressorError, .invalidAppPath("/Applications/Foo.txt"))
        }
    }

    func testRejectsSystemApplications() {
        let path = "/System/Applications/Calculator.app"
        XCTAssertThrowsError(try AppSelectionService.validateAppURL(URL(fileURLWithPath: path))) { error in
            XCTAssertEqual(error as? CompressorError, .systemAppNotAllowed(path))
        }
    }

    func testRestoreDestinationConflictDetection() {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let existingApp = tempDirectory.appendingPathComponent("Existing.app", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: existingApp, withIntermediateDirectories: true)
            let restoreService = RestoreService()
            XCTAssertFalse(restoreService.canRestore(to: existingApp))
        } catch {
            XCTFail("Unexpected setup error: \(error)")
        }

        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testShellQuotingKeepsArgumentsSeparate() {
        let service = PermissionService()
        let command = service.shellCommand(arguments: ["/bin/mv", "/Applications/O'Hare App.app", "/Users/me/.Trash/O'Hare App.app"])

        XCTAssertEqual(
            command,
            "'/bin/mv' '/Applications/O'\\''Hare App.app' '/Users/me/.Trash/O'\\''Hare App.app'"
        )
    }
}
