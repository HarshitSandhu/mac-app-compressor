import AppKit
import Foundation

@MainActor
final class CompressorViewModel: ObservableObject {
    @Published private(set) var apps: [ManagedApp] = []
    @Published private(set) var isWorking = false
    @Published private(set) var progressTitle = "Ready"
    @Published private(set) var progressDetail = "Choose an app to archive, or restore one from the list."
    @Published private(set) var lastMessage: String?
    @Published private(set) var errorMessage: String?

    private let manifestStore: ManifestStore
    private let appSelectionService: AppSelectionService
    private let archiveService: ArchiveService
    private let restoreService: RestoreService
    private let diskUsageService: DiskUsageService

    init(
        manifestStore: ManifestStore = ManifestStore(),
        appSelectionService: AppSelectionService = AppSelectionService(),
        diskUsageService: DiskUsageService = DiskUsageService()
    ) {
        self.manifestStore = manifestStore
        self.appSelectionService = appSelectionService
        self.diskUsageService = diskUsageService
        self.archiveService = ArchiveService(
            manifestStore: manifestStore,
            diskUsageService: diskUsageService
        )
        self.restoreService = RestoreService(manifestStore: manifestStore)
        refresh()
    }

    var totalRecoverableBytes: Int64 {
        apps.reduce(Int64(0)) { total, app in
            guard app.status == .archived else {
                return total
            }
            return total + diskUsageService.savedBytes(
                original: app.originalSizeBytes,
                archive: app.archiveSizeBytes
            )
        }
    }

    func refresh() {
        do {
            apps = try manifestStore.load().apps.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            apps = []
        }
    }

    func selectAndArchive() {
        guard !isWorking else {
            return
        }

        guard let appURL = appSelectionService.selectApp() else {
            return
        }

        Task {
            await archive(appURL: appURL)
        }
    }

    func restore(_ app: ManagedApp) {
        guard !isWorking else {
            return
        }

        guard confirmRestore(app) else {
            return
        }

        isWorking = true
        lastMessage = nil
        errorMessage = nil
        setProgress("Restoring \(app.displayName)", "Preparing archive.")

        Task {
            do {
                try await restoreService.restore(app) { [weak self] title, detail in
                    Task { @MainActor in
                        self?.setProgress(title, detail)
                    }
                }
                refresh()
                lastMessage = "\(app.displayName) restored to \(app.originalPath)."
                setProgress("Restore complete", "The archive was left in place.")
            } catch {
                errorMessage = error.localizedDescription
                setProgress("Restore failed", error.localizedDescription)
            }
            isWorking = false
        }
    }

    func openArchiveFolder() {
        do {
            try manifestStore.ensureDirectoriesExist()
            NSWorkspace.shared.open(manifestStore.archiveDirectoryURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openTrash() {
        NSWorkspace.shared.open(
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
        )
    }

    func formattedBytes(_ bytes: Int64) -> String {
        diskUsageService.formattedBytes(bytes)
    }

    func savedBytes(for app: ManagedApp) -> Int64 {
        diskUsageService.savedBytes(
            original: app.originalSizeBytes,
            archive: app.archiveSizeBytes
        )
    }

    func archiveExists(for app: ManagedApp) -> Bool {
        FileManager.default.fileExists(atPath: app.archivePath)
    }

    func canRestore(_ app: ManagedApp) -> Bool {
        app.status == .archived
            && archiveExists(for: app)
            && !FileManager.default.fileExists(atPath: app.originalPath)
            && !isWorking
    }

    private func archive(appURL: URL) async {
        isWorking = true
        lastMessage = nil
        errorMessage = nil
        setProgress("Checking \(appURL.lastPathComponent)", "Validating the selected app.")

        do {
            try AppSelectionService.requireExistingApp(at: appURL)
            setProgress("Measuring \(appURL.lastPathComponent)", "Calculating the current app size.")
            let originalSize = try archiveService.compressionSummary(for: appURL)

            guard confirmArchive(appURL: appURL, originalSize: originalSize) else {
                setProgress("Ready", "Compression cancelled.")
                isWorking = false
                return
            }

            let app = try await archiveService.archive(appURL: appURL) { [weak self] title, detail in
                Task { @MainActor in
                    self?.setProgress(title, detail)
                }
            }

            refresh()
            lastMessage = "\(app.displayName) archived. Empty Trash to reclaim the remaining disk space."
            setProgress(
                "Compression complete",
                "Original: \(formattedBytes(app.originalSizeBytes))  Archive: \(formattedBytes(app.archiveSizeBytes))"
            )
        } catch {
            errorMessage = error.localizedDescription
            setProgress("Compression failed", error.localizedDescription)
        }

        isWorking = false
    }

    private func confirmArchive(appURL: URL, originalSize: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Compress \(appURL.lastPathComponent)?"
        alert.informativeText = """
        Original size: \(originalSize)
        Archive location: \(manifestStore.archiveDirectoryURL.path)

        After verification, \(appURL.lastPathComponent) will be moved to Trash.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Compress")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmRestore(_ app: ManagedApp) -> Bool {
        let destination = URL(fileURLWithPath: app.originalPath)

        if FileManager.default.fileExists(atPath: destination.path) {
            errorMessage = CompressorError.destinationExists(destination.path).localizedDescription
            return false
        }

        let alert = NSAlert()
        alert.messageText = "Restore \(app.displayName)?"
        alert.informativeText = "The app will be restored to \(destination.path)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func setProgress(_ title: String, _ detail: String) {
        progressTitle = title
        progressDetail = detail
    }
}
