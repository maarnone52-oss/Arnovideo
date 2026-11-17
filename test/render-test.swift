// Prova dell'esportazione fatta dal Mac (NativeRender.swift), eseguita su GitHub.
// Crea un video da: rosso (orizzontale, con audio) + foto blu + verde (verticale, con audio)
// + giallo (ruotato di 90°, senza audio) e controlla durata, tracce e colori dei fotogrammi.
import AVFoundation
import AppKit

let media = URL(fileURLWithPath: CommandLine.arguments[1])
let outDir = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

var musicFile = "musica.m4a"
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
    renderer.render(items: items, music: [MusicItem(url: media.appendingPathComponent(musicFile), start: 2.0, offset: 0, duration: 1.5, volume: 1)], size: size, fill: fill, progress: { _ in steps += 1 }, done: { result = $0; sem.signal() })
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

// conversione video → MP4 (dal video ruotato e senza audio, e da quello verticale con audio)
for f in ["giallo-ruotato-muto.mp4", "verde-verticale.mp4"] {
    let sem = DispatchSemaphore(value: 0); var res: URL? = nil; var err: String? = nil
    DispatchQueue.global().async {
        VideoConvert.toMP4(url: media.appendingPathComponent(f), name: "prova-" + f, size: "640x480", progress: { _ in }) { u, e in res = u; err = e; sem.signal() }
    }
    while sem.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    if let r = res {
        let asset = AVURLAsset(url: r), d = asset.duration.seconds
        let v = asset.tracks(withMediaType: .video).first
        let sub = v.flatMap { ($0.formatDescriptions.first).map { CMFormatDescriptionGetMediaSubType($0 as! CMFormatDescription) } } ?? 0
        let ns = v.map { $0.naturalSize.applying($0.preferredTransform) } ?? .zero
        print(String(format: "[MP4] %@ → %.2f s, video %@ %dx%d, tracce audio %d", f, d, sub == kCMVideoCodecType_H264 ? "H.264" : "altro", Int(abs(ns.width)), Int(abs(ns.height)), asset.tracks(withMediaType: .audio).count))
        if max(abs(ns.width), abs(ns.height)) > 641 { print("PROVA FALLITA (risoluzione)"); exit(1) }
        if sub != kCMVideoCodecType_H264 || d < 0.5 { print("PROVA FALLITA (MP4)"); exit(1) }
        try? FileManager.default.removeItem(at: r)
    } else { print("PROVA FALLITA: conversione MP4 non riuscita: \(err ?? "")"); exit(1) }
}

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

// volume oltre il 100% e dissolvenze (rosso.mp4 ha un tono continuo)
func audioRun(_ item: RenderItem, _ name: String) -> URL? {
    let r = NativeRenderer(); let sem = DispatchSemaphore(value: 0); var res: Result<URL, Error>!
    r.render(items: [item], music: [], size: CGSize(width: 640, height: 360), fill: false, progress: { _ in }, done: { res = $0; sem.signal() })
    sem.wait()
    guard case .success(let u) = res! else { return nil }
    let dest = outDir.appendingPathComponent(name + ".mp4"); try? FileManager.default.removeItem(at: dest); try? FileManager.default.copyItem(at: u, to: dest); r.cleanUp(); return dest
}
let rosso = media.appendingPathComponent("rosso.mp4")
if let u1 = audioRun(RenderItem(isPhoto: false, url: rosso, duration: 0, volume: 1), "vol100"),
   let u2 = audioRun(RenderItem(isPhoto: false, url: rosso, duration: 0, volume: 2), "vol200"),
   let u3 = audioRun(RenderItem(isPhoto: false, url: rosso, duration: 0, volume: 1, fadeIn: 0.6, fadeOut: 0.6), "dissolvenze") {
    let d = AVURLAsset(url: u1).duration.seconds
    let l1 = level(u1, from: 0.8, to: d - 0.8), l2 = level(u2, from: 0.8, to: d - 0.8)
    let fi = level(u3, from: 0.05, to: 0.25), mid = level(u3, from: 0.75, to: d - 0.75), fo = level(u3, from: d - 0.25, to: d - 0.05)
    print(String(format: "[VOL] 100%%: %.4f · 200%%: %.4f (rapporto %.2f, atteso circa 2)", l1, l2, l2 / max(l1, 1e-6)))
    print(String(format: "[FADE] inizio %.4f · centro %.4f · fine %.4f (attesi bassi all'inizio e alla fine)", fi, mid, fo))
    if fi > mid * 0.4 || fo > mid * 0.4 { print("PROVA FALLITA (dissolvenze)"); exit(1) }
} else { print("PROVA FALLITA (volume/dissolvenze)"); exit(1) }

// dissolvenze video tra le clip: rosso (2 s) → foto blu (2 s, sovrapposta 1 s) → verde (2 s, sovrapposto 0,5 s) = 4,5 s
do {
    let items = [
        RenderItem(isPhoto: false, url: rosso, duration: 0),
        RenderItem(isPhoto: true, url: media.appendingPathComponent("blu.jpg"), duration: 2, crossfade: 1.0),
        RenderItem(isPhoto: false, url: media.appendingPathComponent("verde-verticale.mp4"), duration: 0, crossfade: 0.5),
    ]
    let r = NativeRenderer(); let sem = DispatchSemaphore(value: 0); var res: Result<URL, Error>!
    r.render(items: items, music: [], size: CGSize(width: 640, height: 360), fill: true, progress: { _ in }, done: { res = $0; sem.signal() })
    sem.wait()
    guard case .success(let u) = res! else { print("PROVA FALLITA (dissolvenze video): \(res!)"); exit(1) }
    let dest = outDir.appendingPathComponent("dissolvenze-video.mp4"); try? FileManager.default.removeItem(at: dest); try! FileManager.default.copyItem(at: u, to: dest); r.cleanUp()
    let asset = AVURLAsset(url: dest)
    print(String(format: "[XF] durata %.2f s (attesa 4.50) · tracce video %d · tracce audio %d", asset.duration.seconds, asset.tracks(withMediaType: .video).count, asset.tracks(withMediaType: .audio).count))
    var ok = abs(asset.duration.seconds - 4.5) < 0.15
    let gen = AVAssetImageGenerator(asset: asset); gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
    func rgb(_ t: Double) -> (Double, Double, Double) {
        guard let cg = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil),
              let c = NSBitmapImageRep(cgImage: cg).colorAt(x: cg.width / 2, y: cg.height / 2)?.usingColorSpace(.deviceRGB) else { return (-1, -1, -1) }
        return (c.redComponent * 255, c.greenComponent * 255, c.blueComponent * 255)
    }
    for (t, what) in [(0.5, "rosso"), (1.5, "rosso+blu"), (2.2, "blu"), (2.75, "blu+verde"), (4.0, "verde")] {
        let (r0, g0, b0) = rgb(t)
        print(String(format: "[XF] t=%.2f atteso %@: %.0f,%.0f,%.0f", t, what, r0, g0, b0))
        switch what {
        case "rosso": if !(r0 > 150 && b0 < 80) { ok = false }
        case "rosso+blu": if !(r0 > 50 && b0 > 50) { ok = false }
        case "blu": if !(b0 > 150 && r0 < 80) { ok = false }
        case "blu+verde": if !(b0 > 40 && g0 > 40) { ok = false }
        default: if !(g0 > 100 && r0 < 80 && b0 < 80) { ok = false }
        }
    }
    let full = level(dest, from: 0.2, to: 0.8), tail = level(dest, from: 1.85, to: 1.98)
    print(String(format: "[XF] audio del rosso: pieno %.4f · fine della dissolvenza %.4f (atteso molto più basso)", full, tail))
    if tail > full * 0.35 { ok = false }
    if !ok { print("PROVA FALLITA (dissolvenze video)"); exit(1) }
}

let a = run(fill: false, size: CGSize(width: 1280, height: 720), name: "orizzontale-intero")
let b = run(fill: true, size: CGSize(width: 720, height: 1280), name: "verticale-riempito")
musicFile = "brano.mp3"
let c = run(fill: false, size: CGSize(width: 1280, height: 720), name: "con-mp3")
print("[MP3] esportazione con musica MP3: \(c ? "riuscita" : "NON riuscita")")
print(a && b ? "PROVA RIUSCITA" : "PROVA FALLITA")
exit(a && b ? 0 : 1)
