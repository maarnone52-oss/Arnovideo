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
    func render(items: [RenderItem], size: CGSize, fill: Bool,
                progress: @escaping (Double) -> Void,
                done: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try self.build(items: items, size: size, fill: fill, progress: progress)
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

    private func build(items: [RenderItem], size: CGSize, fill: Bool,
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

            volumes.append((CMTimeRange(start: cursor, duration: range.duration), Float(max(0, min(1, item.volume)))))
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
        if anyAudio, volumes.contains(where: { $0.1 < 0.999 }) {
            let params = AVMutableAudioMixInputParameters(track: audioTrack)
            for (r, vol) in volumes { params.setVolumeRamp(fromStartVolume: vol, toEndVolume: vol, timeRange: r) }
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
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
