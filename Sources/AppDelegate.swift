import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var tabs = [BrowserWindowController]()
    private var burning = false
    let isSelfTest = CommandLine.arguments.contains("--selftest")

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        BrowserSession.shared.prepare {
            if self.isSelfTest {
                SelfTest.run()
            } else {
                let tab = self.openTab(inNewWindow: true)
                // `Palisade https://example.com` opens that address.
                if let url = CommandLine.arguments.dropFirst().lazy
                    .compactMap({ AddressParser.directURL($0) }).first {
                    tab.load(url)
                }
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !burning && !isSelfTest
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Tabs

    /// Opens a tab. With a `configuration` (a page opened a new window) WebKit
    /// loads the content itself; otherwise the start page is shown.
    @discardableResult
    func openTab(configuration: WKWebViewConfiguration? = nil,
                 from parent: BrowserWindowController? = nil,
                 inNewWindow: Bool = false) -> BrowserWindowController {
        let tab = BrowserWindowController(configuration: configuration)
        tabs.append(tab)
        guard let window = tab.window else { return tab }

        let host = parent?.window ?? tabs.first(where: { $0.window?.isKeyWindow == true })?.window
        if !inNewWindow, let host {
            host.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        } else {
            // Keep macOS from folding a deliberate new window into the tab group.
            window.tabbingMode = .disallowed
            window.makeKeyAndOrderFront(nil)
            window.tabbingMode = .preferred
        }
        if configuration == nil { tab.showStartPage() }
        return tab
    }

    func tabDidClose(_ tab: BrowserWindowController) {
        tabs.removeAll { $0 === tab }
    }

    @objc func newTab(_ sender: Any?) { openTab() }
    @objc func newWindow(_ sender: Any?) { openTab(inNewWindow: true) }

    // MARK: Burn

    @objc func burnSession(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Burn this session?"
        alert.informativeText = "Every tab closes, and all cookies, cached files, site data and "
            + "per-site exceptions are erased. This cannot be undone."
        alert.addButton(withTitle: "Burn")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performBurn()
    }

    func performBurn() {
        burning = true
        let old = tabs
        BrowserSession.shared.burn()
        openTab(inNewWindow: true)
        for tab in old { tab.close() }
        burning = false
    }

    // MARK: Menu

    private func buildMenu() {
        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            return item
        }
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            return holder
        }

        let windowMenu = menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "\t", .control),
            item("Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "\t", [.control, .shift]),
        ])

        let main = NSMenu()
        main.addItem(menu("Palisade", [
            item("About Palisade", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide Palisade", #selector(NSApplication.hide(_:)), "h"),
            item("Quit Palisade", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(menu("File", [
            item("New Tab", #selector(newTab(_:)), "t", target: self),
            item("New Window", #selector(newWindow(_:)), "n", target: self),
            item("Open Location…", #selector(BrowserWindowController.focusAddressBar(_:)), "l"),
            .separator(),
            item("Close Tab", #selector(NSWindow.performClose(_:)), "w"),
        ]))
        main.addItem(menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]))
        main.addItem(menu("View", [
            item("Reload", #selector(BrowserWindowController.reloadPage(_:)), "r"),
            .separator(),
            item("Zoom In", #selector(BrowserWindowController.zoomIn(_:)), "+"),
            item("Zoom Out", #selector(BrowserWindowController.zoomOut(_:)), "-"),
            item("Actual Size", #selector(BrowserWindowController.zoomReset(_:)), "0"),
        ]))
        main.addItem(menu("History", [
            item("Back", #selector(BrowserWindowController.navigateBack(_:)), "["),
            item("Forward", #selector(BrowserWindowController.navigateForward(_:)), "]"),
        ]))
        main.addItem(menu("Privacy", [
            item("Burn Session…", #selector(burnSession(_:)), "\u{8}", [.command, .shift], target: self),
        ]))
        main.addItem(windowMenu)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu.submenu
    }
}
