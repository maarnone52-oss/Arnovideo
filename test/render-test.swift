// Prova dell'esportazione fatta dal Mac (NativeRender.swift), eseguita su GitHub.
// Crea un video da: rosso (orizzontale, con audio) + foto blu + verde (verticale, con audio)
// + giallo (ruotato di 90°, senza audio) e controlla durata, tracce e colori dei fotogrammi.
import AVFoundation
import AppKit

let media = URL(fileURLWithPath: CommandLine.arguments[1])
let outDir = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func run(fill: Bool, size: CGSize, name: String) -> Bool {
    let items = [
        RenderItem(isPhoto: false, url: media.appendingPathComponent("colori.mp4"), duration: 2, start: 2),   // tagliato: blu poi giallo
        RenderItem(isPhoto: true, url: media.appendingPathComponent("blu.jpg"), duration: 1.5),
        RenderItem(isPhoto: false, url: media.appendingPathComponent("verde-verticale.mp4"), duration: 0),
        RenderItem(isPhoto: false, url: media.appendingPathComponent("giallo-ruotato-muto.mp4"), duration: 0),
    ]
    let renderer = NativeRenderer()
    let sem = DispatchSemaphore(value: 0)
    var result: Result<URL, Error>!
    var steps = 0
    let t0 = Date()
    renderer.render(items: items, size: size, fill: fill, progress: { _ in steps += 1 }, done: { result = $0; sem.signal() })
    sem.wait()
    switch result! {
    case .failure(let e):
        print("[\(name)] ERRORE: \(e.localizedDescription)")
        return false
    case .success(let url):
        let dest = outDir.appendingPathComponent(name + ".mp4")
        try? FileManager.default.removeItem(at: dest)
        try! FileManager.default.copyItem(at: url, to: dest)
        renderer.cleanUp()
        let asset = AVURLAsset(url: dest)
        let v = asset.tracks(withMediaType: .video).first!
        let a = asset.tracks(withMediaType: .audio)
        let size = v.naturalSize.applying(v.preferredTransform)
        print(String(format: "[%@] durata %.2f s (attesa 7.00) · video %dx%d · tracce audio %d · %.1f s · avanzamento %d", name,
                     asset.duration.seconds, Int(abs(size.width)), Int(abs(size.height)), a.count, Date().timeIntervalSince(t0), steps))
        if let fmt = v.formatDescriptions.first {
            let sub = CMFormatDescriptionGetMediaSubType(fmt as! CMFormatDescription)
            print("[\(name)] codec video: \(String(format: "%c%c%c%c", (sub >> 24) & 255, (sub >> 16) & 255, (sub >> 8) & 255, sub & 255))")
        }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        var ok = abs(asset.duration.seconds - 7.0) < 0.15 && a.count == 1
        for (t, expect) in [(0.5, "blu (taglio)"), (1.5, "giallo (taglio)"), (2.75, "blu foto"), (4.5, "verde"), (6.2, "giallo")] {
            guard let cg = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) else {
                print("[\(name)] t=\(t): nessun fotogramma"); ok = false; continue
            }
            let rep = NSBitmapImageRep(cgImage: cg)
            func px(_ x: Int, _ y: Int) -> String {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return "?" }
                return String(format: "%.0f,%.0f,%.0f", c.redComponent * 255, c.greenComponent * 255, c.blueComponent * 255)
            }
            let center = px(cg.width / 2, cg.height / 2), edge = px(3, cg.height / 2)
            print("[\(name)] t=\(t) atteso \(expect): centro \(center) · bordo sinistro \(edge)")
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: outDir.appendingPathComponent("\(name)-\(t).png"))
            }
        }
        return ok
    }
}

let a = run(fill: false, size: CGSize(width: 1280, height: 720), name: "orizzontale-intero")
let b = run(fill: true, size: CGSize(width: 720, height: 1280), name: "verticale-riempito")
print(a && b ? "PROVA RIUSCITA" : "PROVA FALLITA")
exit(a && b ? 0 : 1)
