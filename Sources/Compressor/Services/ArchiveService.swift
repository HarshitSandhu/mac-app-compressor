import Foundation

final class ArchiveService {
    private let manifestStore: ManifestStore
    private let diskUsageService: DiskUsageService
    private let permissionService: PermissionService

    init(
        manifestStore: ManifestStore = ManifestStore(),
        diskUsageService: DiskUsageService = DiskUsageService(),
        permissionService: PermissionService = PermissionService()
    ) {
        self.manifestStore = manifestStore
        self.diskUsageService = diskUsageService
        self.permissionService = permissionService
    }

    func archive(
        appURL: URL,
        progress: ((_ title: String, _ detail: String) -> Void)? = nil
    ) async throws -> ManagedApp {
        let appURL = appURL.standardizedFileURL
        progress?("Validating \(appURL.lastPathComponent)", "Checking the selected application.")
        try AppSelectionService.requireExistingApp(at: appURL)

        let manifest = try manifestStore.load()
        if manifest.archivedApp(forOriginalPath: appURL.path) != nil {
            throw CompressorError.duplicateApp(appURL.path)
        }

        progress?("Measuring \(appURL.lastPathComponent)", "Calculating the original size.")
        let originalSize = try diskUsageService.sizeOfItem(at: appURL)
        let id = UUID()
        let destinationURL = try archivePath(for: appURL, id: id)
        let displayName = appURL.lastPathComponent
        let volumeName = appURL.deletingPathExtension().lastPathComponent

        progress?("Compressing \(displayName)", "Creating a compressed archive. Large apps can take a while.")
        try ProcessRunner.run(
            "/usr/bin/hdiutil",
            arguments: [
                "create",
                "-srcfolder", appURL.path,
                "-format", "ULFO",
                "-volname", volumeName,
                destinationURL.path
            ]
        )

        progress?("Verifying \(displayName)", "Checking that the archive can be read.")
        try verifyArchive(at: destinationURL)
        let archiveSize = try diskUsageService.sizeOfItem(at: destinationURL)

        let managedApp = ManagedApp(
            id: id,
            displayName: displayName,
            bundleIdentifier: bundleIdentifier(for: appURL),
            originalPath: appURL.path,
            archivePath: destinationURL.path,
            originalSizeBytes: originalSize,
            archiveSizeBytes: archiveSize,
            createdAt: Date(),
            lastRestoredAt: nil,
            status: .archived
        )

        progress?("Moving \(displayName) to Trash", "The archive is verified. Removing the original app.")
        try permissionService.moveToTrash(appURL)
        progress?("Updating archive list", "Saving Compressor's manifest.")
        try manifestStore.upsert(managedApp)

        return managedApp
    }

    func verifyArchive(at archiveURL: URL) throws {
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw CompressorError.archiveMissing(archiveURL.path)
        }

        try ProcessRunner.run("/usr/bin/hdiutil", arguments: ["verify", archiveURL.path])
    }

    func archivePath(for appURL: URL) throws -> URL {
        try archivePath(for: appURL, id: UUID())
    }

    func archivePath(for appURL: URL, id: UUID) throws -> URL {
        try AppSelectionService.validateAppURL(appURL)
        try manifestStore.ensureDirectoriesExist()

        let appName = appURL.deletingPathExtension().lastPathComponent
        let safeName = sanitizeArchiveBaseName(appName)
        return manifestStore.archiveDirectoryURL
            .appendingPathComponent("\(safeName)-\(id.uuidString).dmg")
    }

    func compressionSummary(for appURL: URL) throws -> String {
        let size = try diskUsageService.sizeOfItem(at: appURL)
        return diskUsageService.formattedBytes(size)
    }

    private func bundleIdentifier(for appURL: URL) -> String? {
        let infoURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")

        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any] else {
            return nil
        }

        return plist["CFBundleIdentifier"] as? String
    }

    private func sanitizeArchiveBaseName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: " ._-"))
        let scalars = name.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let sanitized = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "App" : sanitized
    }
}
