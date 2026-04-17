import XCTest
@testable import Compressor

final class ArchiveServiceTests: XCTestCase {
    func testArchivePathUsesDmgExtensionAndArchivesDirectory() throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ManifestStore(baseDirectoryURL: baseDirectory)
        let service = ArchiveService(manifestStore: store)
        let appURL = URL(fileURLWithPath: "/Applications/My App.app")
        let id = UUID(uuidString: "A71F6C66-A026-430C-8C37-D5B6D4F562CC")!

        let archiveURL = try service.archivePath(for: appURL, id: id)

        XCTAssertEqual(archiveURL.deletingLastPathComponent(), store.archiveDirectoryURL)
        XCTAssertEqual(archiveURL.pathExtension, "dmg")
        XCTAssertTrue(archiveURL.lastPathComponent.contains("My App"))
        XCTAssertTrue(archiveURL.lastPathComponent.contains(id.uuidString))

        try? FileManager.default.removeItem(at: baseDirectory)
    }

    func testSavedSpaceCalculationNeverGoesNegative() {
        let service = DiskUsageService()

        XCTAssertEqual(service.savedBytes(original: 100, archive: 40), 60)
        XCTAssertEqual(service.savedBytes(original: 40, archive: 100), 0)
    }

    func testMissingArchiveThrows() {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("dmg")
            .path
        let app = makeManagedApp(archivePath: missingPath, status: .archived)
        let restoreService = RestoreService()

        XCTAssertThrowsError(try restoreService.ensureArchiveExists(for: app)) { error in
            XCTAssertEqual(error as? CompressorError, .archiveMissing(missingPath))
        }
    }

    func testMissingOriginalAppThrowsBeforeArchive() {
        let appURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("app")

        XCTAssertThrowsError(try AppSelectionService.requireExistingApp(at: appURL)) { error in
            XCTAssertEqual(error as? CompressorError, .appMissing(appURL.path))
        }
    }
}
