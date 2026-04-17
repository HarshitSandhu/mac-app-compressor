import Foundation
@testable import Compressor

func makeManagedApp(
    id: UUID = UUID(uuidString: "A0D51CFB-502E-4111-93CA-8E865EF41367")!,
    displayName: String = "Foo.app",
    bundleIdentifier: String? = "com.example.foo",
    originalPath: String = "/Applications/Foo.app",
    archivePath: String = "/tmp/Foo.dmg",
    originalSizeBytes: Int64 = 1_000,
    archiveSizeBytes: Int64 = 500,
    createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    lastRestoredAt: Date? = nil,
    status: CompressionStatus
) -> ManagedApp {
    ManagedApp(
        id: id,
        displayName: displayName,
        bundleIdentifier: bundleIdentifier,
        originalPath: originalPath,
        archivePath: archivePath,
        originalSizeBytes: originalSizeBytes,
        archiveSizeBytes: archiveSizeBytes,
        createdAt: createdAt,
        lastRestoredAt: lastRestoredAt,
        status: status
    )
}
