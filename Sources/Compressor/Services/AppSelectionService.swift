import AppKit
import Foundation
import UniformTypeIdentifiers

final class AppSelectionService {
    @MainActor
    func selectApp() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose an app to compress"
        panel.message = "Select a rarely used app from Applications."
        panel.prompt = "Choose App"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        guard panel.runModal() == .OK else {
            return nil
        }

        return panel.url
    }

    static func validateAppURL(_ appURL: URL) throws {
        let path = appURL.standardizedFileURL.path

        guard appURL.pathExtension.lowercased() == "app" else {
            throw CompressorError.invalidAppPath(path)
        }

        if path == "/System/Applications" || path.hasPrefix("/System/Applications/") {
            throw CompressorError.systemAppNotAllowed(path)
        }
    }

    static func requireExistingApp(at appURL: URL) throws {
        try validateAppURL(appURL)

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: appURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CompressorError.appMissing(appURL.path)
        }
    }
}
