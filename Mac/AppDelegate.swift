import Cocoa
import WebKit

/// Finestra principale di ARNOCUT per Mac e menu a tendina.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let controller = WebViewController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "ARNOCUT"
        NSWindow.allowsAutomaticWindowTabbing = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 640, height: 520)
        window.backgroundColor = NSColor(red: 0.051, green: 0.055, blue: 0.063, alpha: 1)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1180, height: 860))
        window.setFrameAutosaveName("ArnoVideoWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Prima di uscire la pagina salva il progetto.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller.saveBeforeQuit { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    // MARK: - Menu

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ command: String,
                     _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(WebViewController.menuCommand(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        item.representedObject = command
        item.target = controller
        menu.addItem(item)
        return item
    }

    private func top(_ main: NSMenu, _ title: String, _ fill: (NSMenu) -> Void) -> NSMenu {
        let item = NSMenuItem()
        let menu = NSMenu(title: title)
        fill(menu)
        item.submenu = menu
        main.addItem(item)
        return menu
    }

    private func key(_ scalar: Int) -> String { String(Character(UnicodeScalar(scalar)!)) }

    private func buildMenu() {
        let main = NSMenu()
        let left = key(NSLeftArrowFunctionKey), right = key(NSRightArrowFunctionKey)

        _ = top(main, "ARNOCUT") { m in
            m.addItem(withTitle: "Informazioni su ARNOCUT",
                      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
            m.addItem(.separator())
            m.addItem(withTitle: "Nascondi ARNOCUT", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
            m.addItem(.separator())
            m.addItem(withTitle: "Esci da ARNOCUT", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        }

        _ = top(main, "File") { m in
            add(m, "Nuovo progetto", "new", "n")
            add(m, "Progetti recenti", "recent", "r", [.command, .shift])
            m.addItem(.separator())
            add(m, "Aggiungi file multimediali…", "open", "o")
            m.addItem(.separator())
            add(m, "Esporta MP4…", "export", "e")
            m.addItem(.separator())
            m.addItem(withTitle: "Chiudi finestra", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        }

        _ = top(main, "Modifica") { m in
            add(m, "Annulla", "undo", "z")
            add(m, "Ripeti", "redo", "z", [.command, .shift])
            m.addItem(.separator())
            m.addItem(withTitle: "Taglia", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            m.addItem(withTitle: "Copia", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            m.addItem(withTitle: "Incolla", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            m.addItem(withTitle: "Seleziona tutto", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        }

        _ = top(main, "Riproduzione") { m in
            add(m, "Play / Pausa  (barra spaziatrice)", "play")
            m.addItem(.separator())
            add(m, "Indietro di 5 secondi", "rew", left)
            add(m, "Avanti di 5 secondi", "ffw", right)
            add(m, "Elemento precedente", "prevItem", left, [.command, .option])
            add(m, "Elemento successivo", "nextItem", right, [.command, .option])
            m.addItem(.separator())
            add(m, "Torna all'inizio", "start", left, [.command, .shift])
        }

        let winMenu = top(main, "Finestra") { m in
            m.addItem(withTitle: "Contrai", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
            m.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
            let full = m.addItem(withTitle: "Schermo intero", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            full.keyEquivalentModifierMask = [.command, .control]
        }
        NSApp.windowsMenu = winMenu

        NSApp.mainMenu = main
    }
}
