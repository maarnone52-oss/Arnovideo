import Cocoa
import WebKit
import AVFoundation

/// Mostra ARNOVIDEO (Web/index.html): sceglie video e foto con il pannello del Finder
/// e salva il video esportato con la finestra "Salva con nome".
final class WebViewController: NSViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView!
    private var partID: String?
    // file scelti col pannello del Finder: "nome|dimensione" -> percorso (ricordati anche dopo la chiusura)
    private var knownFiles: [String: String] = UserDefaults.standard.dictionary(forKey: "ArnoVideoFiles") as? [String: String] ?? [:]
    // file passati dalla pagina in questa sessione (es. trascinati nella finestra)
    private var uploaded: [String: URL] = [:]
    private var renderer: NativeRenderer?

    override func loadView() {
        let contentController = WKUserContentController()
        contentController.add(self, name: "save")
        contentController.add(self, name: "render")

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

        // La pagina viene da un file: senza questo, le immagini dei video «sporcano» le tele (SecurityError)
        // e la pagina non può farne miniature né leggerle.
        FileAccess.allow(config)

        webView = ArnoWebView(frame: NSRect(x: 0, y: 0, width: 1180, height: 860), configuration: config)
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
        panel.message = "Scegli video, foto o file audio"
        panel.allowedFileTypes = ["mp4", "m4v", "mov", "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "mp3", "m4a", "aac", "wav", "aif", "aiff", "caf"]
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] result in
            if result == .OK { self?.remember(panel.urls) }
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

    // MARK: - Esportazione fatta dal Mac (AVFoundation)

    private static func fileKey(_ url: URL) -> String? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        return url.lastPathComponent + "|" + String(size)
    }

    private func remember(_ urls: [URL]) {
        for url in urls { if let key = Self.fileKey(url) { knownFiles[key] = url.path } }
        if knownFiles.count > 2000 { knownFiles = [:] }
        UserDefaults.standard.set(knownFiles, forKey: "ArnoVideoFiles")
    }

    private func fileURL(for key: String) -> URL? {
        if let url = uploaded[key], FileManager.default.fileExists(atPath: url.path) { return url }
        if let path = knownFiles[key] {
            let url = URL(fileURLWithPath: path)
            if Self.fileKey(url) == key { return url }      // stesso file, non spostato né modificato
        }
        return nil
    }

    private func js(_ code: String) {
        DispatchQueue.main.async { self.webView.evaluateJavaScript(code, completionHandler: nil) }
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let s = String(data: data, encoding: .utf8) else { return "null" }
        return String(s.dropFirst().dropLast())
    }

    private func handleRender(_ body: [String: Any]) {
        switch body["cmd"] as? String {
        case "check":
            let keys = body["keys"] as? [String] ?? []
            let missing = keys.filter { fileURL(for: $0) == nil }
            js("arnoNative.reply(\(Self.json(body["id"] ?? 0)),\(Self.json(missing)))")

        case "upload":
            guard let key = body["key"] as? String,
                  let b64 = body["base64"] as? String, let data = Data(base64Encoded: b64),
                  let index = (body["index"] as? NSNumber)?.intValue,
                  let count = (body["count"] as? NSNumber)?.intValue else { return }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arnovideo-files", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = String(key.split(separator: "|").first ?? "file")
            let safe = String(abs(key.hashValue)) + "-" + name.replacingOccurrences(of: "/", with: "-")
            let url = dir.appendingPathComponent(safe)
            if index == 0 {
                try? FileManager.default.removeItem(at: url)
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.seekToEndOfFile(); handle.write(data); handle.closeFile()
            if index == count - 1 { uploaded[key] = url }

        case "render":
            let list = body["items"] as? [[String: Any]] ?? []
            var items: [RenderItem] = []
            for entry in list {
                guard let key = entry["key"] as? String, let url = fileURL(for: key) else {
                    return finishRender(false, "Manca un file: «\((entry["key"] as? String ?? "").split(separator: "|").first ?? "")».")
                }
                items.append(RenderItem(isPhoto: (entry["type"] as? String) == "img", url: url,
                                        duration: (entry["dur"] as? NSNumber)?.doubleValue ?? 3,
                                        start: (entry["tin"] as? NSNumber)?.doubleValue ?? 0,
                                        volume: (entry["vol"] as? NSNumber)?.doubleValue ?? 1,
                                        audioIn: (entry["ain"] as? NSNumber)?.doubleValue ?? 0,
                                        audioOut: (entry["aout"] as? NSNumber)?.doubleValue ?? 0))
            }
            let w = max(2, ((body["w"] as? NSNumber)?.intValue ?? 1920) / 2 * 2)
            let h = max(2, ((body["h"] as? NSNumber)?.intValue ?? 1080) / 2 * 2)
            var music: [MusicItem] = []
            for entry in body["music"] as? [[String: Any]] ?? [] {
                guard let key = entry["key"] as? String, let url = fileURL(for: key) else { continue }
                music.append(MusicItem(url: url, start: (entry["start"] as? NSNumber)?.doubleValue ?? 0,
                                       offset: (entry["tin"] as? NSNumber)?.doubleValue ?? 0,
                                       duration: (entry["dur"] as? NSNumber)?.doubleValue ?? 0,
                                       volume: (entry["vol"] as? NSNumber)?.doubleValue ?? 1))
            }
            let name = (body["name"] as? String) ?? "ArnoVideo.mp4"
            let renderer = NativeRenderer()
            self.renderer = renderer
            var lastSent = -1
            renderer.render(items: items, music: music, size: CGSize(width: w, height: h), fill: (body["fit"] as? String) == "cover",
                            progress: { [weak self] p in
                                let pct = Int(p * 100)
                                if pct != lastSent { lastSent = pct; self?.js("arnoNative.progress(\(p))") }
                            },
                            done: { [weak self] result in
                                DispatchQueue.main.async { self?.renderFinished(result, name: name, renderer: renderer) }
                            })

        case "thumbs":
            // miniature preparate dal Mac (AVFoundation): primo fotogramma + striscia
            let id = body["id"] ?? ""
            let times = (body["times"] as? [NSNumber])?.map { $0.doubleValue } ?? []
            guard let key = body["key"] as? String, let url = fileURL(for: key), !times.isEmpty else {
                js("arnoNative.reply(\(Self.json(id)),null)"); return
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let list = Self.makeThumbs(url: url, times: times, exact: (body["exact"] as? Bool) ?? false)
                self?.js("arnoNative.reply(\(Self.json(id)),\(Self.json(list)))")
            }

        case "peaks":
            // forma d'onda della traccia audio, calcolata dal Mac
            let id = body["id"] ?? ""
            let rate = (body["rate"] as? NSNumber)?.intValue ?? 100
            guard let key = body["key"] as? String, let url = fileURL(for: key) else {
                js("arnoNative.reply(\(Self.json(id)),undefined)"); return
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let res = AudioPeaks.compute(url: url, rate: rate)
                self?.js("arnoNative.reply(\(Self.json(id)),\(res.map { Self.json($0) } ?? "undefined"))")
            }

        case "vconv":
            // conversione di un video in MP4 H.264 + AAC (formato unico, compatibile con l'esportazione)
            let id = body["id"] ?? ""
            guard let key = body["key"] as? String, let url = fileURL(for: key) else {
                js("arnoNative.reply(\(Self.json(id)),{error:'file non trovato'})"); return
            }
            let name = (body["name"] as? String) ?? url.deletingPathExtension().lastPathComponent
            VideoConvert.toMP4(url: url, name: name, progress: { [weak self] p in
                self?.js("arnoNative.vprog(\(Self.json(id)),\(p))")
            }) { [weak self] out, err in
                guard let self = self else { return }
                if let out = out {
                    self.remember([out])
                    self.js("arnoNative.reply(\(Self.json(id)),{url:\(Self.json(out.absoluteString))})")
                } else {
                    self.js("arnoNative.reply(\(Self.json(id)),{error:\(Self.json(err ?? "conversione non riuscita"))})")
                }
            }

        case "aac":
            // conversione in AAC (.m4a): il file convertito torna alla pagina
            let id = body["id"] ?? ""
            guard let key = body["key"] as? String, let url = fileURL(for: key) else {
                js("arnoNative.reply(\(Self.json(id)),null)"); return
            }
            AudioConvert.toM4A(url: url) { [weak self] out in
                var b64: String? = nil
                if let out = out { b64 = (try? Data(contentsOf: out))?.base64EncodedString(); try? FileManager.default.removeItem(at: out) }
                self?.js("arnoNative.reply(\(Self.json(id)),\(b64.map { Self.json($0) } ?? "null"))")
            }

        case "cancel":
            renderer?.cancel()

        default: break
        }
    }

    private static func makeThumbs(url: URL, times: [Double], exact: Bool) -> [String] {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true          // video girati: miniatura dritta
        gen.maximumSize = CGSize(width: 320, height: 180)
        // per la timeline ingrandita serve il fotogramma esatto
        let tol = exact ? CMTime.zero : CMTime(value: 1, timescale: 10)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol
        return times.map { t in
            guard let cg = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) else { return "" }
            // dentro un riquadro 16:9 nero, intero (come nella pagina)
            let W = 320, H = 180
            guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return "" }
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
            let k = min(CGFloat(W) / iw, CGFloat(H) / ih)
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: (CGFloat(W) - iw * k) / 2, y: (CGFloat(H) - ih * k) / 2, width: iw * k, height: ih * k))
            guard let out = ctx.makeImage(),
                  let jpg = NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
            else { return "" }
            return "data:image/jpeg;base64," + jpg.base64EncodedString()
        }
    }

    private func finishRender(_ ok: Bool, _ message: String) {
        js("arnoNative.done(\(ok ? "true" : "false"),\(Self.json(message)))")
    }

    private func renderFinished(_ result: Result<URL, Error>, name: String, renderer: NativeRenderer) {
        self.renderer = nil
        switch result {
        case .failure(let error):
            renderer.cleanUp()
            finishRender(false, error.localizedDescription)
        case .success(let file):
            js("setStatus('Video pronto: scegli dove salvarlo.')")
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-")
            panel.allowedFileTypes = ["mp4"]
            panel.canCreateDirectories = true
            let save: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard response == .OK, let url = panel.url else {
                    renderer.cleanUp()
                    self?.finishRender(false, "Video non salvato.")
                    return
                }
                do {
                    try? FileManager.default.removeItem(at: url)
                    try FileManager.default.moveItem(at: file, to: url)
                    renderer.cleanUp()
                    let mb = ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) / 1_048_576
                    self?.finishRender(true, "Video salvato: \(url.lastPathComponent) (\(mb) MB) in «\(url.deletingLastPathComponent().lastPathComponent)».")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    renderer.cleanUp()
                    self?.finishRender(false, "Salvataggio non riuscito: " + error.localizedDescription)
                }
            }
            if let window = view.window { panel.beginSheetModal(for: window, completionHandler: save) }
            else { save(panel.runModal()) }
        }
    }

    // MARK: - Salvataggio del video esportato (arriva a pezzi da 4 MB)

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if message.name == "render", let body = message.body as? [String: Any] {
            handleRender(body)
            return
        }
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

/// WKWebView senza «Ricarica» (Reload) nel menu del tasto destro:
/// ricaricare la pagina interromperebbe esportazioni e riproduzione.
final class ArnoWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        for item in menu.items where item.identifier?.rawValue == "WKMenuItemIdentifierReload" {
            menu.removeItem(item)
        }
        // niente separatori rimasti in cima o in fondo
        while let first = menu.items.first, first.isSeparatorItem { menu.removeItem(first) }
        while let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
        super.willOpenMenu(menu, with: event)
    }
}
