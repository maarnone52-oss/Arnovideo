import WebKit

/// La pagina dell'app viene da un file locale: senza questi permessi le immagini dei video
/// «sporcano» le tele (SecurityError) e la pagina non può farne miniature.
enum FileAccess {
    static func allow(_ config: WKWebViewConfiguration) {
        typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
        func call(_ obj: AnyObject, _ name: String) {
            let sel = NSSelectorFromString(name)
            if obj.responds(to: sel) {
                let f = unsafeBitCast(obj.method(for: sel), to: SetBool.self)
                f(obj, sel, true)
            }
        }
        call(config.preferences, "_setAllowFileAccessFromFileURLs:")
        call(config, "_setAllowUniversalAccessFromFileURLs:")
    }

    /// Ingrandimento della pagina (come ⌘− / ⌘+ in Safari): la pagina si ridispone, più spazio di lavoro.
    static func setZoom(_ webView: WKWebView, _ z: Double) {
        let sel = NSSelectorFromString("_setPageZoomFactor:")
        if webView.responds(to: sel) {
            typealias SetD = @convention(c) (AnyObject, Selector, Double) -> Void
            let f = unsafeBitCast(webView.method(for: sel), to: SetD.self)
            f(webView, sel, max(0.3, min(2, z)))
        } else if #available(macOS 11.0, *) {
            webView.pageZoom = CGFloat(max(0.3, min(2, z)))
        }
    }
}
