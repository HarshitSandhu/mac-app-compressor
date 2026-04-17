import Foundation

final class DiskUsageService {
    func sizeOfItem(at url: URL) throws -> Int64 {
        if isDirectory(url) {
            return try directorySizeUsingDU(url)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.size] as? Int64 ?? 0
    }

    func savedBytes(original: Int64, archive: Int64) -> Int64 {
        max(0, original - archive)
    }

    func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func directorySizeUsingDU(_ url: URL) throws -> Int64 {
        let result = try ProcessRunner.run("/usr/bin/du", arguments: ["-sk", url.path])
        guard let output = String(data: result.stdout, encoding: .utf8),
              let kilobytes = Int64(output.split(separator: "\t").first ?? "") else {
            return 0
        }
        return kilobytes * 1024
    }
}
