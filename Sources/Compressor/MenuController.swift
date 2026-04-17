import AppKit
import Foundation

@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private weak var windowController: MainWindowController?

    init(windowController: MainWindowController) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.windowController = windowController
        super.init()

        statusItem.button?.title = "Compressor"
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        windowController?.viewModel.refresh()
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let openItem = NSMenuItem(title: "Open Compressor", action: #selector(openCompressor), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let addItem = NSMenuItem(title: "Add App...", action: #selector(addApp), keyEquivalent: "")
        addItem.target = self
        addItem.isEnabled = !(windowController?.viewModel.isWorking ?? false)
        menu.addItem(addItem)

        menu.addItem(.separator())

        let title = NSMenuItem(title: "Archived Apps", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let apps = windowController?.viewModel.apps ?? []
        if apps.isEmpty {
            let emptyItem = NSMenuItem(title: "No archived apps", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for app in apps.prefix(8) {
                let item = NSMenuItem(title: "\(app.displayName) - \(app.status.rawValue)", action: #selector(openCompressor), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func openCompressor() {
        windowController?.showWindow()
    }

    @objc private func addApp() {
        windowController?.addApp()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
