import Foundation

final class PermissionService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func canWriteParent(of url: URL) -> Bool {
        let parent = url.deletingLastPathComponent()
        return fileManager.isWritableFile(atPath: parent.path)
    }

    func needsAdministratorPrivileges(for url: URL) -> Bool {
        !canWriteParent(of: url)
    }

    func moveToTrash(_ url: URL) throws {
        if !needsAdministratorPrivileges(for: url) {
            do {
                _ = try fileManager.trashItem(at: url, resultingItemURL: nil)
                return
            } catch {
                try moveToTrashWithAdministratorPrivileges(url, fallbackReason: error.localizedDescription)
                return
            }
        }

        try moveToTrashWithAdministratorPrivileges(url)
    }

    private func moveToTrashWithAdministratorPrivileges(_ url: URL, fallbackReason: String? = nil) throws {
        let trashURL = uniqueTrashURL(for: url)
        let command = shellCommand(arguments: ["/bin/mv", url.path, trashURL.path])
        do {
            try runPrivilegedShellCommand(command)
        } catch {
            let reason = [fallbackReason, error.localizedDescription]
                .compactMap { $0 }
                .joined(separator: "\n")
            throw CompressorError.trashMoveFailed(reason)
        }
    }

    func copyWithDitto(from sourceURL: URL, to destinationURL: URL) throws {
        if needsAdministratorPrivileges(for: destinationURL) {
            let command = shellCommand(arguments: ["/usr/bin/ditto", sourceURL.path, destinationURL.path])
            try runPrivilegedShellCommand(command)
        } else {
            try ProcessRunner.run("/usr/bin/ditto", arguments: [sourceURL.path, destinationURL.path])
        }
    }

    func runPrivilegedShellCommand(_ command: String) throws {
        let script = "do shell script \(appleScriptString(command)) with administrator privileges"
        try ProcessRunner.run("/usr/bin/osascript", arguments: ["-e", script])
    }

    func shellCommand(arguments: [String]) -> String {
        arguments.map(shellQuote).joined(separator: " ")
    }

    func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func uniqueTrashURL(for url: URL) -> URL {
        let trashDirectory = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
        let baseName = url.lastPathComponent
        var candidate = trashDirectory.appendingPathComponent(baseName)

        if !fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        candidate = trashDirectory.appendingPathComponent("\(baseName)-\(stamp)")
        return candidate
    }

    private func appleScriptString(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
