import AVFoundation
import ImageIO
import CoreGraphics

/// Un elemento della timeline da mettere nel video finale.
struct RenderItem {
    let isPhoto: Bool
    let url: URL
    var duration: Double = 0  // foto: durata; video: durata del pezzo tagliato (0 = tutto il video)
    var start: Double = 0     // video: punto d'inizio nel file (taglio in testa)
    var volume: Double = 1    // volume della clip, da 0 a 1
    var audioIn: Double = 0   // audio muto per i primi secondi della clip (taglio audio in testa)
    var audioOut: Double = 0  // audio muto per gli ultimi secondi della clip (taglio audio in coda)
}

/// Un pezzo della traccia musicale.
struct MusicItem {
    let url: URL
    var start: Double = 0     // secondo della timeline in cui parte
    var offset: Double = 0    // punto d'inizio nel file
    var duration: Double = 0  // durata (già limitata alla fine del video)
    var volume: Double = 1
}

enum RenderError: LocalizedError {
    case message(String)
    case cancelled
    var errorDescription: String? {
        switch self {
        case .message(let s): return s
        case .cancelled: return "Esportazione annullata."
        }
    }
}

/// Crea il video finale direttamente sul Mac con AVFoundation:
/// molto più veloce della registrazione in tempo reale e senza perdita di sincronia.
/// I video vengono messi in fila così come sono; le foto diventano brevi clip fisse;
/// tutto viene adattato al formato scelto (intero con bande nere, oppure riempito e ritagliato).
final class NativeRenderer {
    private var session: AVAssetExportSession?
    private var cancelled = false
    private let workDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("arnovideo-render-\(UUID().uuidString)")

    func cancel() {
        cancelled = true
        session?.cancelExport()
    }

    /// progress: da 0 a 1. done arriva su un thread in background.
    func render(items: [RenderItem], music: [MusicItem] = [], size: CGSize, fill: Bool,
                progress: @escaping (Double) -> Void,
                done: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try self.build(items: items, music: music, size: size, fill: fill, progress: progress)
                done(.success(url))
            } catch {
                done(.failure(self.cancelled ? RenderError.cancelled : error))
            }
        }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - Composizione

    private func build(items: [RenderItem], music: [MusicItem], size: CGSize, fill: Bool,
                       progress: @escaping (Double) -> Void) throws -> URL {
        guard !items.isEmpty else { throw RenderError.message("La timeline è vuota.") }
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw RenderError.message("Il Mac non riesce a preparare il video.") }

        var instructions: [AVMutableVideoCompositionInstruction] = []
        var cursor = CMTime.zero
        var anyAudio = false
        var volumes: [(CMTimeRange, Float)] = []   // volume di ogni clip, per tutto il suo tratto

        for (index, item) in items.enumerated() {
            if cancelled { throw RenderError.cancelled }
            progress(0.15 * Double(index) / Double(items.count))

            let asset: AVURLAsset
            if item.isPhoto {
                let clip = workDir.appendingPathComponent("foto-\(index).mp4")
                try makePhotoClip(from: item.url, duration: max(0.5, item.duration), size: size, fill: fill, to: clip)
                asset = AVURLAsset(url: clip)
            } else {
                asset = AVURLAsset(url: item.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            }
            guard let source = asset.tracks(withMediaType: .video).first else {
                throw RenderError.message("Nel file «\(item.url.lastPathComponent)» non trovo il video.")
            }
            var range = source.timeRange
            if !item.isPhoto, item.start > 0 || item.duration > 0 {
                // taglio in testa e in coda
                let s = range.start + CMTime(seconds: max(0, item.start), preferredTimescale: 600)
                let d = item.duration > 0 ? CMTime(seconds: item.duration, preferredTimescale: 600) : range.end - s
                range = CMTimeRange(start: s, duration: d).intersection(source.timeRange)
            }
            guard range.duration.seconds > 0 else { continue }
            try videoTrack.insertTimeRange(range, of: source, at: cursor)

            // audio: quello del video, oppure silenzio
            if let sourceAudio = asset.tracks(withMediaType: .audio).first {
                let audioRange = sourceAudio.timeRange.intersection(range)
                if audioRange.duration.seconds > 0 {
                    let at = cursor + (audioRange.start - range.start)
                    alignAudio(audioTrack, to: at)
                    try audioTrack.insertTimeRange(audioRange, of: sourceAudio, at: at)
                    anyAudio = true
                }
            }

            do {   // volume della clip, muto nelle parti tagliate dell'audio
                let total = range.duration.seconds, vol = Float(max(0, min(1, item.volume)))
                let ain = max(0, min(item.audioIn, total)), aout = max(0, min(item.audioOut, total - ain))
                func seg(_ a: Double, _ b: Double, _ v: Float) {
                    if b - a > 0.0005 { volumes.append((CMTimeRange(start: cursor + CMTime(seconds: a, preferredTimescale: 600), duration: CMTime(seconds: b - a, preferredTimescale: 600)), v)) }
                }
                if ain == 0 && aout == 0 { volumes.append((CMTimeRange(start: cursor, duration: range.duration), vol)) }
                else { seg(0, ain, 0); seg(ain, total - aout, vol); seg(total - aout, total, 0) }
            }
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: range.duration)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layer.setTransform(item.isPhoto ? .identity : fitTransform(source, size: size, fill: fill), at: cursor)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)

            cursor = cursor + range.duration
        }
        guard !instructions.isEmpty else { throw RenderError.message("Nessun elemento utilizzabile nella timeline.") }
        if anyAudio { alignAudio(audioTrack, to: cursor) } else { composition.removeTrack(audioTrack) }

        // traccia musicale: una seconda traccia audio, ogni pezzo dal suo punto di partenza
        var musicVolumes: [(CMTimeRange, Float)] = []
        var musicTrack: AVMutableCompositionTrack?
        for m in music {
            let total = cursor.seconds
            guard m.start < total - 0.01 else { continue }
            let asset = AVURLAsset(url: m.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let src = asset.tracks(withMediaType: .audio).first else { continue }
            if musicTrack == nil {
                musicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            }
            guard let mt = musicTrack else { break }
            let s = src.timeRange.start + CMTime(seconds: max(0, m.offset), preferredTimescale: 600)
            var d = CMTime(seconds: min(m.duration > 0 ? m.duration : src.timeRange.duration.seconds, total - m.start), preferredTimescale: 600)
            if s + d > src.timeRange.end { d = src.timeRange.end - s }
            guard d.seconds > 0.01 else { continue }
            let at = CMTime(seconds: m.start, preferredTimescale: 600)
            alignAudio(mt, to: at)
            try mt.insertTimeRange(CMTimeRange(start: s, duration: d), of: src, at: at)
            musicVolumes.append((CMTimeRange(start: at, duration: d), Float(max(0, min(1, m.volume)))))
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = size
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions

        // esportazione MP4 (H.264 + AAC)
        let out = workDir.appendingPathComponent("ArnoVideo.mp4")
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw RenderError.message("Il Mac non riesce a esportare il video.")
        }
        export.outputURL = out
        export.outputFileType = .mp4
        export.videoComposition = videoComposition
        export.shouldOptimizeForNetworkUse = true
        var mixParams: [AVMutableAudioMixInputParameters] = []
        if anyAudio, volumes.contains(where: { $0.1 < 0.999 }) {
            let params = AVMutableAudioMixInputParameters(track: audioTrack)
            for (r, vol) in volumes { params.setVolumeRamp(fromStartVolume: vol, toEndVolume: vol, timeRange: r) }
            mixParams.append(params)
        }
        if let mt = musicTrack, musicVolumes.contains(where: { $0.1 < 0.999 }) {
            let params = AVMutableAudioMixInputParameters(track: mt)
            for (r, vol) in musicVolumes { params.setVolumeRamp(fromStartVolume: vol, toEndVolume: vol, timeRange: r) }
            mixParams.append(params)
        }
        if !mixParams.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = mixParams
            export.audioMix = mix
        }
        session = export

        let finished = DispatchSemaphore(value: 0)
        export.exportAsynchronously { finished.signal() }
        while finished.wait(timeout: .now() + 0.25) == .timedOut {
            progress(0.15 + 0.85 * Double(export.progress))
        }
        session = nil
        if cancelled || export.status == .cancelled { throw RenderError.cancelled }
        guard export.status == .completed else {
            throw RenderError.message("Esportazione non riuscita: " + (export.error?.localizedDescription ?? "errore sconosciuto"))
        }
        progress(1)
        return out
    }

    /// Riempie di silenzio la traccia audio fino al punto indicato.
    private func alignAudio(_ track: AVMutableCompositionTrack, to time: CMTime) {
        let end = track.timeRange.end
        let start = end.isValid ? end : .zero
        if time > start {
            track.insertEmptyTimeRange(CMTimeRange(start: start, end: time))
        }
    }

    /// Ruota (video girati), scala e centra il video nel formato finale.
    private func fitTransform(_ track: AVAssetTrack, size: CGSize, fill: Bool) -> CGAffineTransform {
        let pt = track.preferredTransform
        let rect = CGRect(origin: .zero, size: track.naturalSize).applying(pt)
        let w = abs(rect.width), h = abs(rect.height)
        guard w > 0, h > 0 else { return pt }
        let s = fill ? max(size.width / w, size.height / h) : min(size.width / w, size.height / h)
        return pt
            .concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: (size.width - w * s) / 2, y: (size.height - h * s) / 2))
    }

    // MARK: - Foto → clip fissa

    private func makePhotoClip(from url: URL, duration: Double, size: CGSize, fill: Bool, to out: URL) throws {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,      // rispetta l'orientamento della foto
            kCGImageSourceThumbnailMaxPixelSize: Int(max(size.width, size.height) * 2),
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw RenderError.message("Non riesco a leggere la foto «\(url.lastPathComponent)».") }

        let w = Int(size.width), h = Int(size.height)
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                      kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32ARGB, attrs as CFDictionary, &buffer)
        guard let pixels = buffer else { throw RenderError.message("Memoria insufficiente per la foto.") }

        CVPixelBufferLockBaseAddress(pixels, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: w, height: h, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            let k = fill ? max(size.width / iw, size.height / ih) : min(size.width / iw, size.height / ih)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: (size.width - iw * k) / 2, y: (size.height - ih * k) / 2,
                                       width: iw * k, height: ih * k))
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])

        try? FileManager.default.removeItem(at: out)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else {
            throw RenderError.message("Non riesco a preparare la foto: " + (writer.error?.localizedDescription ?? ""))
        }
        writer.startSession(atSourceTime: .zero)
        // la stessa immagine all'inizio e alla fine: il video resta fermo per tutta la durata
        let last = max(duration - 1.0 / 30.0, 1.0 / 30.0)
        for t in [0.0, last] {
            while !input.isReadyForMoreMediaData { usleep(2000) }
            adaptor.append(pixels, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw RenderError.message("Non riesco a preparare la foto: " + (writer.error?.localizedDescription ?? ""))
        }
    }
}

// MARK: - Forma d'onda per la timeline

enum AudioPeaks {
    /// Picchi dell'audio (0-255) ogni 1/rate di secondo, in base64. "" se il file non ha audio, nil se non leggibile.
    static func compute(url: URL, rate: Int = 100) -> String? {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else { return "" }
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let sampleRate = 8000.0                       // basta per i picchi, e legge molto più in fretta
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1])
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        guard reader.startReading() else { return nil }
        let per = Int(sampleRate) / rate
        var peaks: [UInt8] = []
        peaks.reserveCapacity(Int(asset.duration.seconds * Double(rate)) + 10)
        var count = 0, maxv: Int32 = 0
        while let sb = out.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            var len = 0
            var ptr: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr) == kCMBlockBufferNoErr,
                  let p = ptr else { continue }
            p.withMemoryRebound(to: Int16.self, capacity: len / 2) { s in
                for i in 0..<(len / 2) {
                    let v = abs(Int32(s[i]))
                    if v > maxv { maxv = v }
                    count += 1
                    if count == per {
                        peaks.append(UInt8(min(255, Int(maxv) * 255 / 32767)))
                        count = 0; maxv = 0
                    }
                }
            }
        }
        if count > 0 { peaks.append(UInt8(min(255, Int(maxv) * 255 / 32767))) }
        if reader.status == .failed { return nil }
        return Data(peaks).base64EncodedString()
    }
}

/// Conversione di un file audio (MP3, WAV, AIFF…) in AAC .m4a con AVFoundation.
enum AudioConvert {
    static func toM4A(url: URL, done: @escaping (URL?) -> Void) {
        let asset = AVURLAsset(url: url)
        guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { done(nil); return }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("arnovideo-aac-\(UUID().uuidString).m4a")
        ex.outputURL = out
        ex.outputFileType = .m4a
        ex.exportAsynchronously {
            done(ex.status == .completed ? out : nil)
        }
    }
}

/// Conversione di un video in MP4 (H.264 fino a 1920×1080, audio AAC): un formato unico che il Mac esporta sempre.
enum VideoConvert {
    static func toMP4(url: URL, name: String, progress: @escaping (Double) -> Void, done: @escaping (URL?, String?) -> Void) {
        let asset = AVURLAsset(url: url)
        let preset = AVAssetExportPreset1920x1080
        guard let ex = AVAssetExportSession(asset: asset, presetName: preset) else { done(nil, "il Mac non sa convertire questo video"); return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArnoVideo/convertiti", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "-")
        var out = dir.appendingPathComponent(safe + ".mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: out.path) { out = dir.appendingPathComponent("\(safe)-\(n).mp4"); n += 1 }
        ex.outputURL = out
        ex.outputFileType = .mp4
        ex.shouldOptimizeForNetworkUse = true
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { progress(Double(ex.progress)) }
        timer.resume()
        ex.exportAsynchronously {
            DispatchQueue.main.async {
                timer.cancel()
                if ex.status == .completed { done(out, nil) }
                else { done(nil, ex.error?.localizedDescription ?? "conversione non riuscita") }
            }
        }
    }
}
