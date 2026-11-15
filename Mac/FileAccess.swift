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
}
