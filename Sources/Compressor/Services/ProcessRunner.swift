import Foundation

struct CommandResult {
    let status: Int32
    let stdout: Data
    let stderr: Data

    var outputString: String {
        let output = String(data: stdout, encoding: .utf8) ?? ""
        let error = String(data: stderr, encoding: .utf8) ?? ""
        return [output, error]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

enum ProcessRunner {
    @discardableResult
    static func run(_ executable: String, arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let result = CommandResult(
            status: process.terminationStatus,
            stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
            stderr: stderr.fileHandleForReading.readDataToEndOfFile()
        )

        guard result.status == 0 else {
            throw CompressorError.commandFailed(
                executable: executable,
                status: result.status,
                output: result.outputString
            )
        }

        return result
    }
}
