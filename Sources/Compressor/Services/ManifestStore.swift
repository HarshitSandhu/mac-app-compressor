import Foundation

final class ManifestStore {
    let baseDirectoryURL: URL
    let manifestURL: URL
    let archiveDirectoryURL: URL

    init(baseDirectoryURL: URL = ManifestStore.defaultBaseDirectoryURL()) {
        self.baseDirectoryURL = baseDirectoryURL
        self.manifestURL = baseDirectoryURL.appendingPathComponent("manifest.json")
        self.archiveDirectoryURL = baseDirectoryURL.appendingPathComponent("Archives", isDirectory: true)
    }

    static func defaultBaseDirectoryURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Compressor", isDirectory: true)
    }

    func ensureDirectoriesExist() throws {
        try FileManager.default.createDirectory(
            at: archiveDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    func load() throws -> ArchiveManifest {
        try ensureDirectoriesExist()

        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return ArchiveManifest()
        }

        do {
            let data = try Data(contentsOf: manifestURL)
            return try JSONDecoder.compressor.decode(ArchiveManifest.self, from: data)
        } catch {
            throw CompressorError.manifestCorrupt(error.localizedDescription)
        }
    }

    func save(_ manifest: ArchiveManifest) throws {
        try ensureDirectoriesExist()
        let data = try JSONEncoder.compressor.encode(manifest)
        try data.write(to: manifestURL, options: [.atomic])
    }

    func upsert(_ app: ManagedApp) throws {
        var manifest = try load()
        manifest.upsert(app)
        try save(manifest)
    }

    func updateStatus(for id: UUID, status: CompressionStatus, restoredAt: Date? = nil) throws {
        var manifest = try load()
        manifest.updateStatus(for: id, status: status, restoredAt: restoredAt)
        try save(manifest)
    }
}

private extension JSONEncoder {
    static var compressor: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var compressor: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
