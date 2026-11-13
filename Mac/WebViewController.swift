import Cocoa
import WebKit

/// Mostra ARNOVIDEO (Web/index.html): sceglie video e foto con il pannello del Finder
/// e salva il video esportato con la finestra "Salva con nome".
final class WebViewController: NSViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView!
    private var partID: String?

    override func loadView() {
        let contentController = WKUserContentController()
        contentController.add(self, name: "save")

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        if #available(macOS 10.12, *) { config.mediaTypesRequiringUserActionForPlayback = [] }
        // Registrazione del video finale (MediaRecorder): sui macOS più vecchi va accesa a mano.
        let prefs = config.preferences
        let sel = NSSelectorFromString("_setMediaRecorderEnabled:")
        if prefs.responds(to: sel) {
            typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
            let f = unsafeBitCast(prefs.method(for: sel), to: SetBool.self)
            f(prefs, sel, true)
        }

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1180, height: 860), configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let index = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") else { return }
        webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
    }

    /// Voce di menu: esegue il comando nella pagina (vedi arnoMenu in index.html).
    @objc func menuCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else { return }
        webView.evaluateJavaScript("window.arnoMenu&&arnoMenu('\(command)')", completionHandler: nil)
    }

    func saveBeforeQuit(_ done: @escaping () -> Void) {
        var finished = false
        let finish = { if !finished { finished = true; done() } }
        webView.evaluateJavaScript("window.saveNow&&saveNow()") { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: finish)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: finish)
    }

    // MARK: - Scelta di video e foto (il pulsante "Aggiungi video e foto")

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Scegli uno o più video e foto"
        panel.allowedFileTypes = ["mp4", "m4v", "mov", "jpg", "jpeg", "png", "heic", "heif", "gif", "webp"]
        let finish: (NSApplication.ModalResponse) -> Void = { result in
            completionHandler(result == .OK ? panel.urls : nil)
        }
        if let window = view.window { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(panel.runModal()) }
    }

    // MARK: - Finestre di avviso, conferma e testo della pagina

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Annulla")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Annulla")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    // MARK: - Salvataggio del video esportato (arriva a pezzi da 4 MB)

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "save",
              let body = message.body as? [String: Any],
              let name = body["name"] as? String,
              let b64 = body["base64"] as? String,
              let data = Data(base64Encoded: b64) else { return }
        if let count = (body["count"] as? NSNumber)?.intValue,
           let index = (body["index"] as? NSNumber)?.intValue,
           let id = body["id"] as? String {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("arnovideo-" + id)
            if index == 0 {
                try? FileManager.default.removeItem(at: tmp)
                FileManager.default.createFile(atPath: tmp.path, contents: nil)
                partID = id
            }
            guard partID == id, let handle = try? FileHandle(forWritingTo: tmp) else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
            if index == count - 1 {
                partID = nil
                askWhereToSave(name: name) { url in
                    try? FileManager.default.removeItem(at: url)
                    try FileManager.default.moveItem(at: tmp, to: url)
                }
            }
            return
        }
        askWhereToSave(name: name) { url in try data.write(to: url, options: .atomic) }
    }

    private func askWhereToSave(name: String, write: @escaping (URL) throws -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-")
        panel.canCreateDirectories = true
        let save: (NSApplication.ModalResponse) -> Void = { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            do {
                try write(url)
                self?.webView.evaluateJavaScript("window.setStatus&&setStatus(\(Self.jsString("Video salvato in " + url.deletingLastPathComponent().lastPathComponent + ".")))", completionHandler: nil)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        if let window = view.window { panel.beginSheetModal(for: window, completionHandler: save) }
        else { save(panel.runModal()) }
    }

    private static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let arr = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    // MARK: - Link esterni nel browser, non dentro l'app

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
        if url.isFileURL || url.scheme == "blob" || url.scheme == "about" || url.scheme == "data" {
            // un file trascinato nella finestra non deve sostituire la pagina
            if url.isFileURL && url.lastPathComponent != "index.html" { return decisionHandler(.cancel) }
            decisionHandler(.allow)
        } else {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}
