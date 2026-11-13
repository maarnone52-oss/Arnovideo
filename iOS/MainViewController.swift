import UIKit
import WebKit

/// Mostra ARNOVIDEO (Web/index.html) e salva il video esportato con il pannello Condividi
/// (da lì: «Salva video» nella galleria, oppure File, AirDrop, WhatsApp…).
final class MainViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView!
    private let panelColor = UIColor(red: 0.051, green: 0.055, blue: 0.063, alpha: 1)
    private var partID: String?

    override func loadView() {
        let contentController = WKUserContentController()
        contentController.add(self, name: "save")

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = panelColor
        webView.scrollView.backgroundColor = panelColor
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let index = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") else { return }
        webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // Durante l'esportazione lo schermo non si spegne da solo.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    // MARK: - Salvataggio del video esportato (arriva a pezzi da 4 MB)

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "save",
              let body = message.body as? [String: Any],
              let name = body["name"] as? String,
              let b64 = body["base64"] as? String,
              let data = Data(base64Encoded: b64) else { return }
        let safeName = name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
        if let count = (body["count"] as? NSNumber)?.intValue,
           let index = (body["index"] as? NSNumber)?.intValue,
           let id = body["id"] as? String {
            if index == 0 {
                try? FileManager.default.removeItem(at: url)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                partID = id
            }
            guard partID == id, let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
            if index == count - 1 {
                partID = nil
                presentShare(url)
            }
            return
        }
        do { try data.write(to: url, options: .atomic) } catch { return }
        presentShare(url)
    }

    private func presentShare(_ url: URL) {
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        present(sheet, animated: true)
    }

    // MARK: - Finestre di conferma della pagina (es. «Svuota», nome del progetto)

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Annulla", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .destructive) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText; $0.clearButtonMode = .whileEditing }
        alert.addAction(UIAlertAction(title: "Annulla", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
        present(alert, animated: true)
    }

    // MARK: - Link esterni nel browser, non dentro l'app

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
        if url.isFileURL || url.scheme == "blob" || url.scheme == "about" || url.scheme == "data" {
            decisionHandler(.allow)
        } else {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    // Se il sistema chiude il motore della pagina (poca memoria), la ricarica.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}
