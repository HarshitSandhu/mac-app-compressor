import Foundation

final class RestoreService {
    private let manifestStore: ManifestStore
    private let permissionService: PermissionService

    init(
        manifestStore: ManifestStore = ManifestStore(),
        permissionService: PermissionService = PermissionService()
    ) {
        self.manifestStore = manifestStore
        self.permissionService = permissionService
    }

    func restore(
        _ app: ManagedApp,
        progress: ((_ title: String, _ detail: String) -> Void)? = nil
    ) async throws {
        let archiveURL = URL(fileURLWithPath: app.archivePath)
        let destinationURL = URL(fileURLWithPath: app.originalPath)

        progress?("Checking \(app.displayName)", "Confirming the archive is available.")
        try ensureArchiveExists(for: app)

        if !canRestore(to: destinationURL) {
            throw CompressorError.destinationExists(destinationURL.path)
        }

        progress?("Preparing restore", "Updating Compressor's manifest.")
        try manifestStore.updateStatus(for: app.id, status: .restoring)

        progress?("Mounting archive", "Opening the compressed disk image.")
        let mountPoint = try attachArchive(at: archiveURL)
        do {
            progress?("Finding app", "Locating \(app.displayName) in the mounted archive.")
            let sourceURL = try appSourceURL(in: mountPoint, displayName: app.displayName)
            progress?("Restoring \(app.displayName)", "Copying the app back to its original location.")
            try permissionService.copyWithDitto(from: sourceURL, to: destinationURL)
            progress?("Cleaning up", "Detaching the mounted archive.")
            try detachArchive(at: mountPoint)
            try manifestStore.updateStatus(for: app.id, status: .restored, restoredAt: Date())
        } catch {
            try? detachArchive(at: mountPoint)
            try? manifestStore.updateStatus(for: app.id, status: .failed)
            throw error
        }
    }

    func canRestore(to originalPath: URL) -> Bool {
        !FileManager.default.fileExists(atPath: originalPath.path)
    }

    func ensureArchiveExists(for app: ManagedApp) throws {
        guard FileManager.default.fileExists(atPath: app.archivePath) else {
            throw CompressorError.archiveMissing(app.archivePath)
        }
    }

    private func attachArchive(at archiveURL: URL) throws -> URL {
        let result = try ProcessRunner.run(
            "/usr/bin/hdiutil",
            arguments: ["attach", "-nobrowse", "-readonly", "-plist", archiveURL.path]
        )

        guard let plist = try PropertyListSerialization.propertyList(
            from: result.stdout,
            options: [],
            format: nil
        ) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPath = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw CompressorError.mountPointNotFound(archiveURL.path)
        }

        return URL(fileURLWithPath: mountPath, isDirectory: true)
    }

    private func detachArchive(at mountPoint: URL) throws {
        try ProcessRunner.run("/usr/bin/hdiutil", arguments: ["detach", mountPoint.path])
    }

    private func appSourceURL(in mountPoint: URL, displayName: String) throws -> URL {
        let fileManager = FileManager.default
        let preferredURL = mountPoint.appendingPathComponent(displayName, isDirectory: true)

        if fileManager.fileExists(atPath: preferredURL.path) {
            return preferredURL
        }

        let directInfoPlist = mountPoint
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")

        if fileManager.fileExists(atPath: directInfoPlist.path) {
            return mountPoint
        }

        let contents = try fileManager.contentsOfDirectory(
            at: mountPoint,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        if let appURL = contents.first(where: { $0.pathExtension.lowercased() == "app" }) {
            return appURL
        }

        throw CompressorError.appNotFoundInMountedArchive(mountPoint.path)
    }
}
