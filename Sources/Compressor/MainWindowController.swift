import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    let viewModel: CompressorViewModel
    private let window: NSWindow

    override init() {
        self.viewModel = CompressorViewModel()

        let contentView = CompressorDashboardView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: contentView)

        self.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.window.title = "Compressor"
        self.window.contentViewController = hostingController
        self.window.minSize = NSSize(width: 720, height: 460)
        self.window.isReleasedWhenClosed = false

        super.init()
        self.window.delegate = self
    }

    func showWindow() {
        viewModel.refresh()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func addApp() {
        showWindow()
        viewModel.selectAndArchive()
    }
}
