#if canImport(AVFoundation) && canImport(CoreVideo)
import AVFoundation
import VideoToolbox
import CoreVideo
import Foundation
import M2DCore

/// Transparent video export via AVFoundation.
/// HEVC with alpha (.mov) plays in Safari/iOS/macOS and imports into Final Cut,
/// Motion and most editors; ProRes 4444 is the lossless-quality interchange option.
public final class VideoExporter {
    public enum Codec: String, CaseIterable, Sendable {
        case hevcWithAlpha, proRes4444, h264
        public var displayName: String {
            switch self {
            case .hevcWithAlpha: return "HEVC with Alpha (.mov)"
            case .proRes4444: return "ProRes 4444 (.mov)"
            case .h264: return "H.264, opaque (.mp4)"
            }
        }
        public var fileType: AVFileType { self == .h264 ? .mp4 : .mov }
        public var fileExtension: String { self == .h264 ? "mp4" : "mov" }
        var avCodec: AVVideoCodecType {
            switch self {
            case .hevcWithAlpha: return .hevcWithAlpha
            case .proRes4444: return .proRes4444
            case .h264: return .h264
            }
        }
        public var supportsAlpha: Bool { self != .h264 }
    }

    public enum ExportError: Error { case cannotStart(String), writeFailed(String) }

    public static func export(_ renderer: FrameRenderer, codec: Codec, to url: URL,
                              progress: ((Double) -> Void)? = nil) async throws {
        let w = renderer.settings.width, h = renderer.settings.height
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: codec.fileType)
        var settings: [String: Any] = [AVVideoCodecKey: codec.avCodec, AVVideoWidthKey: w, AVVideoHeightKey: h]
        if codec == .hevcWithAlpha {
            settings[AVVideoCompressionPropertiesKey] = [kVTCompressionPropertyKey_TargetQualityForAlpha as String: 0.9,
                                                         AVVideoQualityKey: 0.9]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        guard writer.canAdd(input) else { throw ExportError.cannotStart("codec not supported on this device") }
        writer.add(input)
        guard writer.startWriting() else { throw ExportError.cannotStart(writer.error?.localizedDescription ?? "unknown") }
        writer.startSession(atSourceTime: .zero)

        let timescale = CMTimeScale(600)
        var i = 0
        while let frame = renderer.renderNext() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw ExportError.writeFailed("no pixel buffer pool") }
            var pbOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
            guard let pb = pbOut else { throw ExportError.writeFailed("could not allocate frame") }
            fill(pb, with: frame, premultiplied: codec.supportsAlpha)
            let t = CMTime(value: CMTimeValue(Double(i) / renderer.settings.frameRate * Double(timescale)), timescale: timescale)
            guard adaptor.append(pb, withPresentationTime: t) else {
                throw ExportError.writeFailed(writer.error?.localizedDescription ?? "append failed")
            }
            i += 1
            progress?(Double(i) / Double(renderer.frameCount))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw ExportError.writeFailed(writer.error?.localizedDescription ?? "unknown") }
    }

    static func fill(_ pb: CVPixelBuffer, with image: RGBAImage, premultiplied: Bool) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let src = premultiplied ? image.toPremultiplied() : image.toStraight()
        let dst = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<image.height {
            let row = dst + y * stride
            for x in 0..<image.width {
                let s = (y * image.width + x) * 4
                let a = src.pixels[s + 3]
                row[x * 4] = src.pixels[s + 2]
                row[x * 4 + 1] = src.pixels[s + 1]
                row[x * 4 + 2] = src.pixels[s]
                row[x * 4 + 3] = premultiplied ? a : 255
            }
        }
    }
}
#endif
