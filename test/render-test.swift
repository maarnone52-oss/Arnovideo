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
        RenderItem(isPhoto: false, url: media.appendingPathComponent("colori.mp4"), duration: 2, start: 2, volume: 0.25),   // tagliato: blu poi giallo, volume 25%
        RenderItem(isPhoto: true, url: media.appendingPathComponent("blu.jpg"), duration: 1.5),
        RenderItem(isPhoto: false, url: media.appendingPathComponent("verde-verticale.mp4"), duration: 0, audioIn: 0.5, audioOut: 0.3),   // audio tagliato: muto 3.5–4.0 e 5.2–5.5
        RenderItem(isPhoto: false, url: media.appendingPathComponent("giallo-ruotato-muto.mp4"), duration: 0),
    ]
    let renderer = NativeRenderer()
    let sem = DispatchSemaphore(value: 0)
    var result: Result<URL, Error>!
    var steps = 0
    let t0 = Date()
    renderer.render(items: items, music: [MusicItem(url: media.appendingPathComponent("musica.m4a"), start: 2.0, offset: 0, duration: 1.5, volume: 1)], size: size, fill: fill, progress: { _ in steps += 1 }, done: { result = $0; sem.signal() })
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
        // livello audio: clip 1 (volume 25%) contro clip 3 (volume pieno)
        let l1 = level(dest, from: 0.3, to: 1.7), l3 = level(dest, from: 4.1, to: 5.1)
        let db = 20 * log10(max(l1, 1e-9) / max(l3, 1e-9))
        print(String(format: "[%@] audio clip 1: %.4f · clip 3: %.4f · differenza %.1f dB (attesa circa -12)", name, l1, l3, db))
        if abs(db + 12) > 2.5 { ok = false }
        let mh = level(dest, from: 3.6, to: 3.95), mt = level(dest, from: 5.25, to: 5.45)
        print(String(format: "[%@] audio tagliato in testa: %.4f · in coda: %.4f (attesi quasi 0)", name, mh, mt))
        if mh > l3 * 0.1 || mt > l3 * 0.1 { ok = false }
        let lm = level(dest, from: 2.2, to: 3.3)          // durante la foto c'è solo la musica
        print(String(format: "[%@] musica sopra la foto: %.4f (attesa sopra 0.02)", name, lm))
        if lm < 0.02 { ok = false }
        return ok
    }
}

func level(_ url: URL, from: Double, to: Double) -> Double {
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return 0 }
    reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600), end: CMTime(seconds: to, preferredTimescale: 600))
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
    reader.add(out); reader.startReading()
    var sum = 0.0, n = 0
    while let sb = out.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
        var len = 0; var ptr: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
        if let p = ptr { p.withMemoryRebound(to: Float.self, capacity: len / 4) { f in for i in 0..<(len / 4) { sum += Double(f[i] * f[i]) }; n += len / 4 } }
    }
    return n > 0 ? (sum / Double(n)).squareRoot() : 0
}

// forma d'onda
if let pk = AudioPeaks.compute(url: media.appendingPathComponent("colori.mp4")), let d = Data(base64Encoded: pk) {
    let avg = d.reduce(0) { $0 + Int($1) } / max(1, d.count)
    print("[forma d'onda] colori.mp4: \(d.count) valori (attesi circa 500), media \(avg)")
    if d.count < 480 || d.count > 520 || avg < 10 { print("PROVA FALLITA (forma d'onda)"); exit(1) }
} else { print("PROVA FALLITA: forma d'onda non calcolata"); exit(1) }
print("[forma d'onda] senza audio: «\(AudioPeaks.compute(url: media.appendingPathComponent("giallo-ruotato-muto.mp4")) ?? "nil")» (atteso vuoto)")

// conversione MP3 → AAC
do {
    let sem = DispatchSemaphore(value: 0); var res: URL? = nil
    AudioConvert.toM4A(url: media.appendingPathComponent("brano.mp3")) { res = $0; sem.signal() }
    sem.wait()
    if let r = res {
        let asset = AVURLAsset(url: r), d = asset.duration.seconds
        let codec = asset.tracks(withMediaType: .audio).first.flatMap { ($0.formatDescriptions.first).map { CMFormatDescriptionGetMediaSubType($0 as! CMFormatDescription) } } ?? 0
        let lv = level(r, from: 0.5, to: 2.5)
        print(String(format: "[AAC] brano.mp3 → m4a: %.2f s, codifica %@, livello %.3f", d, codec == kAudioFormatMPEG4AAC ? "AAC" : "altra", lv))
        if abs(d - 3) > 0.15 || codec != kAudioFormatMPEG4AAC || lv < 0.05 { print("PROVA FALLITA (AAC)"); exit(1) }
    } else { print("PROVA FALLITA: conversione AAC non riuscita"); exit(1) }
}

let a = run(fill: false, size: CGSize(width: 1280, height: 720), name: "orizzontale-intero")
let b = run(fill: true, size: CGSize(width: 720, height: 1280), name: "verticale-riempito")
print(a && b ? "PROVA RIUSCITA" : "PROVA FALLITA")
exit(a && b ? 0 : 1)
