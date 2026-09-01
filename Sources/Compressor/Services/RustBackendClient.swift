import Foundation

struct BackendSummaryResponse: Decodable {
    let sizeBytes: Int64
    let formatted: String
}

struct BackendListResponse: Decodable {
    let apps: [ManagedApp]
}

private struct BackendEvent: Decodable {
    let event: String
    let title: String?
    let detail: String?
    let app: ManagedApp?
}

/// Buffers raw bytes rather than decoded text. A pipe read can end partway through
/// a multi-byte UTF-8 character - decoding each chunk on arrival turned those split
/// characters into `U+FFFD` permanently, corrupting non-ASCII app names.
final class StreamingCommandState: @unchecked Sendable {
    private static let newline = UInt8(ascii: "\n")

    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrData = Data()
    private var sawResult = false
    private var finalApp: ManagedApp?
    private var parseError: Error?

    func appendStdout(
        _ data: Data,
        progress: (@Sendable (_ title: String, _ detail: String) -> Void)?
    ) {
        lock.lock()
        stdoutBuffer.append(data)
        parseAvailableLines(progress: progress)
        lock.unlock()
    }

    func appendStderr(_ data: Data) {
        lock.lock()
        stderrData.append(data)
        lock.unlock()
    }

    func finish(progress: (@Sendable (_ title: String, _ detail: String) -> Void)?) {
        lock.lock()
        let trailing = stdoutBuffer
        stdoutBuffer.removeAll()
        if !trailing.isEmpty {
            handle(lineData: trailing, progress: progress)
        }
        lock.unlock()
    }

    func snapshot() -> (error: Error?, stderr: Data, sawResult: Bool, app: ManagedApp?) {
        lock.lock()
        let snapshot = (parseError, stderrData, sawResult, finalApp)
        lock.unlock()
        return snapshot
    }

    private func parseAvailableLines(
        progress: (@Sendable (_ title: String, _ detail: String) -> Void)?
    ) {
        while let newlineIndex = stdoutBuffer.firstIndex(of: Self.newline) {
            let lineData = Data(stdoutBuffer[stdoutBuffer.startIndex..<newlineIndex])
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newlineIndex)
            if lineData.isEmpty {
                continue
            }
            handle(lineData: lineData, progress: progress)
        }
    }

    private func handle(
        lineData: Data,
        progress: (@Sendable (_ title: String, _ detail: String) -> Void)?
    ) {
        let trimmed = String(decoding: lineData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        do {
            let event = try RustBackendClient.decodeEvent(from: trimmed)
            switch event.event {
            case "progress":
                if let title = event.title, let detail = event.detail {
                    progress?(title, detail)
                }
            case "result":
                sawResult = true
                finalApp = event.app
            default:
                break
            }
        } catch {
            parseError = error
        }
    }
}

struct BackendRemoveResponse: Decodable {
    let removed: Bool
}

/// Tracks the backend process for the operation in flight so it can be cancelled.
/// The backend makes itself a process-group leader, so signalling the group reaches
/// the long-running tool it spawned (hdiutil, ditto) as well as the backend itself.
private final class BackendProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    /// Returns false when cancellation arrived before the process started, so the
    /// caller can avoid launching work the user already backed out of.
    func adopt(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !cancelled else {
            return false
        }
        self.process = process
        return true
    }

    func release() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func beginOperation() {
        lock.lock()
        cancelled = false
        process = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let identifier = process?.processIdentifier
        lock.unlock()

        signal(identifier)
    }

    /// A cancel that lands between `adopt` and `run` has no pid to signal yet.
    /// Calling this once the process is running delivers it.
    func signalIfCancelled() {
        lock.lock()
        let shouldSignal = cancelled
        let identifier = process?.processIdentifier
        lock.unlock()

        guard shouldSignal else {
            return
        }
        signal(identifier)
    }

    private func signal(_ identifier: pid_t?) {
        guard let identifier, identifier > 0 else {
            return
        }
        // The backend makes itself a process-group leader, so this reaches the
        // hdiutil or ditto run it is currently waiting on.
        killpg(identifier, SIGINT)
    }

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

final class RustBackendClient {
    private let fileManager: FileManager
    private let baseDirectoryURL: URL
    private let processHandle = BackendProcessHandle()

    init(
        fileManager: FileManager = .default,
        baseDirectoryURL: URL = BackendPaths.baseDirectoryURL
    ) {
        self.fileManager = fileManager
        self.baseDirectoryURL = baseDirectoryURL
    }

    /// Signals the running archive or restore. Safe to call when nothing is running.
    func cancel() {
        processHandle.cancel()
    }

    func listApps() throws -> [ManagedApp] {
        let response: BackendListResponse = try runJSONCommand(arguments: [
            "list",
            "--base-dir", baseDirectoryURL.path
        ])
        return response.apps
    }

    /// Returns raw bytes rather than the backend's preformatted string so that every
    /// size in the UI runs through one formatter.
    func compressionSummary(for appURL: URL) throws -> Int64 {
        let response: BackendSummaryResponse = try runJSONCommand(arguments: [
            "summary",
            "--app-path", appURL.standardizedFileURL.path
        ])
        return response.sizeBytes
    }

    func remove(_ app: ManagedApp, deleteArchive: Bool) throws {
        var arguments = [
            "remove",
            "--base-dir", baseDirectoryURL.path,
            "--app-id", app.id.uuidString
        ]
        if deleteArchive {
            arguments.append("--delete-archive")
        }

        let _: BackendRemoveResponse = try runJSONCommand(arguments: arguments)
    }

    func archive(
        appURL: URL,
        progress: (@Sendable (_ title: String, _ detail: String) -> Void)? = nil
    ) async throws -> ManagedApp {
        guard let app = try await runStreamingCommand(
            arguments: [
                "archive",
                "--base-dir", baseDirectoryURL.path,
                "--app-path", appURL.standardizedFileURL.path
            ],
            progress: progress
        ) else {
            throw CompressorError.commandFailed(
                executable: try backendExecutableURL().path,
                status: 0,
                output: "Rust backend returned no archived app."
            )
        }

        return app
    }

    func restore(
        _ app: ManagedApp,
        progress: (@Sendable (_ title: String, _ detail: String) -> Void)? = nil
    ) async throws {
        _ = try await runStreamingCommand(
            arguments: [
                "restore",
                "--base-dir", baseDirectoryURL.path,
                "--app-id", app.id.uuidString
            ],
            progress: progress
        )
    }

    private func runJSONCommand<Response: Decodable>(arguments: [String]) throws -> Response {
        let executableURL = try backendExecutableURL()
        let result = try ProcessRunner.run(executableURL.path, arguments: arguments)
        return try Self.decodeJSON(Response.self, from: result.stdout)
    }

    private func runStreamingCommand(
        arguments: [String],
        progress: (@Sendable (_ title: String, _ detail: String) -> Void)?
    ) async throws -> ManagedApp? {
        let executableURL = try backendExecutableURL()
        let handle = processHandle
        handle.beginOperation()

        defer { handle.release() }

        return try await Task.detached(priority: .userInitiated) { [executableURL] in
            try Self.runStreamingProcess(
                executableURL: executableURL,
                arguments: arguments,
                handle: handle,
                progress: progress
            )
        }.value
    }

    private static func runStreamingProcess(
        executableURL: URL,
        arguments: [String],
        handle: BackendProcessHandle,
        progress: (@Sendable (_ title: String, _ detail: String) -> Void)?
    ) throws -> ManagedApp? {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let state = StreamingCommandState()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    return
                }
                state.appendStdout(data, progress: progress)
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    return
                }
                state.appendStderr(data)
            }

            guard handle.adopt(process) else {
                throw CompressorError.cancelled
            }

            try process.run()
            handle.signalIfCancelled()
            process.waitUntilExit()

            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            state.finish(progress: progress)

            let snapshot = state.snapshot()

            // Checked ahead of the parse error, because a cancelled run fails with
            // whatever the signalled tool reported and that is not worth showing.
            // A clean exit still counts as success: a cancel that arrives after the
            // backend has already finished its work did not actually stop anything.
            if handle.wasCancelled && process.terminationStatus != 0 {
                throw CompressorError.cancelled
            }

            if let error = snapshot.error {
                throw error
            }

            guard process.terminationStatus == 0 else {
                let output = String(data: snapshot.stderr, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw CompressorError.commandFailed(
                    executable: executableURL.path,
                    status: process.terminationStatus,
                    output: output
                )
            }

            guard snapshot.sawResult else {
                throw CompressorError.commandFailed(
                    executable: executableURL.path,
                    status: process.terminationStatus,
                    output: "Rust backend returned no result event."
                )
            }

            return snapshot.app
    }

    fileprivate static func decodeJSON<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: data)
    }

    fileprivate static func decodeEvent(from line: String) throws -> BackendEvent {
        try decodeJSON(BackendEvent.self, from: Data(line.utf8))
    }

    private func backendExecutableURL() throws -> URL {
        if let overriddenPath = ProcessInfo.processInfo.environment["COMPRESSOR_BACKEND_BIN"],
           fileManager.isExecutableFile(atPath: overriddenPath) {
            return URL(fileURLWithPath: overriddenPath)
        }

        if let executableURL = Bundle.main.executableURL {
            for ancestor in ancestors(of: executableURL.deletingLastPathComponent()) {
                if let pluginBuiltURL = pluginBuiltExecutableURL(under: ancestor) {
                    return pluginBuiltURL
                }

                let candidates = [
                    ancestor.appendingPathComponent("rust-backend/target/debug/compressor-backend"),
                    ancestor.appendingPathComponent("rust-backend/target/release/compressor-backend")
                ]

                for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        throw CompressorError.commandFailed(
            executable: "compressor-backend",
            status: 127,
            output: "Rust backend binary not found. Build it with `cargo build --manifest-path rust-backend/Cargo.toml` or set COMPRESSOR_BACKEND_BIN."
        )
    }

    private func pluginBuiltExecutableURL(under ancestor: URL) -> URL? {
        let pluginsDirectory = ancestor.appendingPathComponent(".build/plugins", isDirectory: true)
        guard fileManager.fileExists(atPath: pluginsDirectory.path),
              let enumerator = fileManager.enumerator(
                at: pluginsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        let preferredMarker = preferredPluginMarkerFileName
        let fallbackMarkers = [
            "compressor-backend-debug-path.txt",
            "compressor-backend-release-path.txt"
        ]

        var discovered: [String: URL] = [:]
        for case let fileURL as URL in enumerator {
            let markerName = fileURL.lastPathComponent
            guard markerName == preferredMarker || fallbackMarkers.contains(markerName),
                  let path = try? String(contentsOf: fileURL).trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty,
                  fileManager.isExecutableFile(atPath: path) else {
                continue
            }
            discovered[markerName] = URL(fileURLWithPath: path)
        }

        if let preferred = discovered[preferredMarker] {
            return preferred
        }

        for marker in fallbackMarkers {
            if let fallback = discovered[marker] {
                return fallback
            }
        }

        return nil
    }

    private var preferredPluginMarkerFileName: String {
        #if DEBUG
        return "compressor-backend-debug-path.txt"
        #else
        return "compressor-backend-release-path.txt"
        #endif
    }

    private func ancestors(of start: URL) -> [URL] {
        var current = start.standardizedFileURL
        var urls: [URL] = [current]

        while current.path != "/" {
            current.deleteLastPathComponent()
            urls.append(current)
        }

        return urls
    }
}
