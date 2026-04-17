import XCTest
@testable import Compressor

final class ArchiveManifestTests: XCTestCase {
    func testManifestRoundTrip() throws {
        let app = makeManagedApp(status: .archived)
        let manifest = ArchiveManifest(apps: [app])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ArchiveManifest.self, from: data)

        XCTAssertEqual(decoded, manifest)
    }

    func testArchivedDuplicateDetectionUsesNormalizedPath() {
        let originalURL = URL(fileURLWithPath: "/Applications/Foo.app")
        let app = makeManagedApp(originalPath: originalURL.path, status: .archived)
        let manifest = ArchiveManifest(apps: [app])

        XCTAssertEqual(
            manifest.archivedApp(forOriginalPath: "/Applications/./Foo.app")?.id,
            app.id
        )
    }

    func testRestoredAppIsNotActiveDuplicate() {
        let app = makeManagedApp(status: .restored)
        let manifest = ArchiveManifest(apps: [app])

        XCTAssertNil(manifest.archivedApp(forOriginalPath: app.originalPath))
    }
}
