import AppKit

/// The application's main menu, built in AppKit so its key equivalents work
/// regardless of which window (terminal, control panel, settings) is key.
@MainActor
enum JuggleMenu {
    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Juggle",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…",
                                       action: #selector(AppDelegate.showCommandCentre(_:)),
                                       keyEquivalent: ",")
        settings.target = target
        appMenu.addItem(.separator())
        let hide = appMenu.addItem(withTitle: "Hide Juggle", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp
        let quit = appMenu.addItem(withTitle: "Quit Juggle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp

        // File menu
        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        let open = fileMenu.addItem(withTitle: "Open Repo…", action: #selector(AppDelegate.openRepo(_:)), keyEquivalent: "o")
        open.target = target
        let newTerminal = fileMenu.addItem(withTitle: "New Terminal", action: #selector(AppDelegate.newTerminal(_:)), keyEquivalent: "n")
        newTerminal.target = target
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // Edit menu (standard responder-chain items for the terminal)
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Window menu
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        let panel = windowMenu.addItem(withTitle: "Control Panel", action: #selector(AppDelegate.toggleControlPopover(_:)), keyEquivalent: "0")
        panel.target = target
        let switcher = windowMenu.addItem(withTitle: "Jump to Terminal…", action: #selector(AppDelegate.toggleSwitcher), keyEquivalent: "j")
        switcher.target = target
        let panelWindow = windowMenu.addItem(withTitle: "Control Panel as Window", action: #selector(AppDelegate.detachControlPanel(_:)), keyEquivalent: "")
        panelWindow.target = target
        let tile = windowMenu.addItem(withTitle: "Tile Grid", action: #selector(AppDelegate.tileGrid(_:)), keyEquivalent: "g")
        tile.keyEquivalentModifierMask = [.command, .option]
        tile.target = target

        let layoutItem = windowMenu.addItem(withTitle: "Grid", action: nil, keyEquivalent: "")
        let layoutMenu = NSMenu()
        layoutItem.submenu = layoutMenu
        for (columns, rows) in [(1, 1), (2, 1), (2, 2), (3, 2), (3, 3), (4, 2), (4, 3), (4, 4)] {
            let item = layoutMenu.addItem(withTitle: "\(columns) × \(rows)", action: #selector(AppDelegate.chooseGrid(_:)), keyEquivalent: "")
            item.representedObject = "\(columns)x\(rows)"
            item.target = target
        }

        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        NSApp.windowsMenu = windowMenu

        return main
    }
}
