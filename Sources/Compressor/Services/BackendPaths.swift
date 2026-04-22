import Foundation

enum BackendPaths {
    static var baseDirectoryURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Compressor", isDirectory: true)
    }

    static var archiveDirectoryURL: URL {
        baseDirectoryURL.appendingPathComponent("Archives", isDirectory: true)
    }
}
