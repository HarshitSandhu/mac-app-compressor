import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    private var menuController: MenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainWindowController = MainWindowController()
        self.mainWindowController = mainWindowController
        self.menuController = MenuController(windowController: mainWindowController)
        mainWindowController.showWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
