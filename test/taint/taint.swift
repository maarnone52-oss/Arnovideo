import Cocoa
import WebKit
class H: NSObject, WKScriptMessageHandler {
    var result: String? = nil
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) { result = m.body as? String }
}
func run(_ allow: Bool) -> String {
    let dir = URL(fileURLWithPath: CommandLine.arguments[1])
    let h = H(); let cc = WKUserContentController(); cc.add(h, name: "out")
    let config = WKWebViewConfiguration(); config.userContentController = cc
    if #available(macOS 10.12, *) { config.mediaTypesRequiringUserActionForPlayback = [] }
    if allow { FileAccess.allow(config) }
    let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    win.contentView = wv; win.orderFront(nil)
    wv.loadFileURL(dir.appendingPathComponent("test.html"), allowingReadAccessTo: dir)
    let end = Date().addingTimeInterval(30)
    while h.result == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    var r = h.result ?? "nessuna risposta"
    // ingrandimento della pagina: con 0.5 la larghezza utile raddoppia
    var w1 = 0.0, w2 = 0.0, got = false
    wv.evaluateJavaScript("innerWidth") { v, _ in w1 = (v as? Double) ?? Double((v as? Int) ?? 0); got = true }
    while !got { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    FileAccess.setZoom(wv, 0.5); got = false
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    wv.evaluateJavaScript("innerWidth") { v, _ in w2 = (v as? Double) ?? Double((v as? Int) ?? 0); got = true }
    while !got { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    r += " · larghezza pagina \(Int(w1)) → \(Int(w2)) con zoom 50%"
    return r
}
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
let without = run(false), with = run(true)
print("[TAINT] senza permesso: \(without)")
print("[TAINT] con permesso:   \(with)")
if !with.hasPrefix("OK") { print("PROVA FALLITA (taint)"); exit(1) }
if !with.contains("→ 800") { print("PROVA FALLITA (zoom)"); exit(1) }
print("PROVA RIUSCITA (taint)")
