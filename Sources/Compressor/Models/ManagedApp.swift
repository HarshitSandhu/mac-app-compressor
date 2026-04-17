import Foundation

struct ManagedApp: Codable, Identifiable, Equatable {
    let id: UUID
    let displayName: String
    let bundleIdentifier: String?
    let originalPath: String
    let archivePath: String
    let originalSizeBytes: Int64
    let archiveSizeBytes: Int64
    let createdAt: Date
    let lastRestoredAt: Date?
    let status: CompressionStatus

    func withStatus(_ status: CompressionStatus, lastRestoredAt: Date? = nil) -> ManagedApp {
        ManagedApp(
            id: id,
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            originalPath: originalPath,
            archivePath: archivePath,
            originalSizeBytes: originalSizeBytes,
            archiveSizeBytes: archiveSizeBytes,
            createdAt: createdAt,
            lastRestoredAt: lastRestoredAt ?? self.lastRestoredAt,
            status: status
        )
    }
}
