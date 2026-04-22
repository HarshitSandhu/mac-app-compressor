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

private final class StreamingCommandState: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutBuffer = ""
    private var stderrData = Data()
    private var sawResult = false
    private var finalApp: ManagedApp?
    private var parseError: Error?

    func appendStdout(
        _ data: Data,
        progress: (@Sendable (_ title: String, _ detail: String) -> Void)?
    ) {
        lock.lock()
        stdoutBuffer += String(decoding: data, as: UTF8.self)
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
        let trailingStdout = stdoutBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailingStdout.isEmpty {
            handle(line: trailingStdout, progress: progress)
            stdoutBuffer = ""
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
        while let newlineRange = stdoutBuffer.range(of: "\n") {
            let line = String(stdoutBuffer[..<newlineRange.lowerBound])
            stdoutBuffer.removeSubrange(...newlineRange.lowerBound)
            if line.isEmpty {
                continue
            }
            handle(line: line, progress: progress)
        }
    }

    private func handle(
        line: String,
        progress: (@Sendable (_ title: String, _ detail: String) -> Void)?
    ) {
        do {
            let event = try RustBackendClient.decodeEvent(from: line)
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

final class RustBackendClient {
    private let fileManager: FileManager
    private let baseDirectoryURL: URL

    init(
        fileManager: FileManager = .default,
        baseDirectoryURL: URL = BackendPaths.baseDirectoryURL
    ) {
        self.fileManager = fileManager
        self.baseDirectoryURL = baseDirectoryURL
    }

    func listApps() throws -> [ManagedApp] {
        let response: BackendListResponse = try runJSONCommand(arguments: [
            "list",
            "--base-dir", baseDirectoryURL.path
        ])
        return response.apps
    }

    func compressionSummary(for appURL: URL) throws -> String {
        let response: BackendSummaryResponse = try runJSONCommand(arguments: [
            "summary",
            "--app-path", appURL.standardizedFileURL.path
        ])
        return response.formatted
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

        return try await Task.detached(priority: .userInitiated) { [executableURL] in
            try Self.runStreamingProcess(
                executableURL: executableURL,
                arguments: arguments,
                progress: progress
            )
        }.value
    }

    private static func runStreamingProcess(
        executableURL: URL,
        arguments: [String],
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

            try process.run()
            process.waitUntilExit()

            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            state.finish(progress: progress)

            let snapshot = state.snapshot()

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
