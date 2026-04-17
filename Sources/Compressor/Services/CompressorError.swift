import Foundation

enum CompressorError: LocalizedError, Equatable {
    case invalidAppPath(String)
    case systemAppNotAllowed(String)
    case appMissing(String)
    case duplicateApp(String)
    case archiveMissing(String)
    case destinationExists(String)
    case commandFailed(executable: String, status: Int32, output: String)
    case mountPointNotFound(String)
    case appNotFoundInMountedArchive(String)
    case manifestCorrupt(String)
    case trashMoveFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidAppPath(let path):
            return "Select a valid macOS application: \(path)"
        case .systemAppNotAllowed(let path):
            return "System apps cannot be compressed: \(path)"
        case .appMissing(let path):
            return "The app no longer exists: \(path)"
        case .duplicateApp(let path):
            return "This app is already archived: \(path)"
        case .archiveMissing(let path):
            return "The archive is missing: \(path)"
        case .destinationExists(let path):
            return "An app already exists at the restore destination: \(path)"
        case .commandFailed(let executable, let status, let output):
            return "\(executable) failed with status \(status): \(output)"
        case .mountPointNotFound(let path):
            return "The archive mounted, but no mount point was reported: \(path)"
        case .appNotFoundInMountedArchive(let path):
            return "No app bundle was found in the mounted archive: \(path)"
        case .manifestCorrupt(let reason):
            return "The Compressor manifest could not be read: \(reason)"
        case .trashMoveFailed(let path):
            return "The app could not be moved to Trash: \(path)"
        }
    }
}
