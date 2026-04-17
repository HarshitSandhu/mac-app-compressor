import Foundation

struct ArchiveManifest: Codable, Equatable {
    var apps: [ManagedApp]

    init(apps: [ManagedApp] = []) {
        self.apps = apps
    }

    func app(withID id: UUID) -> ManagedApp? {
        apps.first { $0.id == id }
    }

    func archivedApp(forOriginalPath path: String) -> ManagedApp? {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        return apps.first { app in
            URL(fileURLWithPath: app.originalPath).standardizedFileURL.path == normalizedPath
                && app.status == .archived
        }
    }

    mutating func upsert(_ app: ManagedApp) {
        if let index = apps.firstIndex(where: { $0.id == app.id }) {
            apps[index] = app
        } else {
            apps.append(app)
        }
    }

    mutating func updateStatus(for id: UUID, status: CompressionStatus, restoredAt: Date? = nil) {
        guard let index = apps.firstIndex(where: { $0.id == id }) else {
            return
        }
        apps[index] = apps[index].withStatus(status, lastRestoredAt: restoredAt)
    }
}
