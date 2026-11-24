import Foundation
import AVFoundation
import UniformTypeIdentifiers
import CoreMedia

/// Reading audio out of video files (.mp4 / .mov / .m4v) so music videos can be analysed,
/// played through the show audio, and used as tracks.
enum MediaSupport {
    static let audioTypes: [UTType] = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]
    static let videoTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .video, .audiovisualContent]
    static let imageTypes: [UTType] = [.image, .png, .jpeg, .heic]

    static func isVideo(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return (t.conforms(to: .movie) || t.conforms(to: .video) || t.conforms(to: .audiovisualContent)) && !t.conforms(to: .audio)
    }

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .image) ?? false
    }

    // MARK: Cache of extracted audio

    private static var cacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("STRDMStage/VideoAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Stable cache path per video file + modification date.
    static func cachedAudioURL(for video: URL) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: video.path)
        let stamp = Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        var hasher = Hasher()
        hasher.combine(video.path)
        let key = String(UInt(bitPattern: hasher.finalize()), radix: 36)
        return cacheDir.appendingPathComponent("\(video.deletingPathExtension().lastPathComponent)-\(key)-\(stamp)-\(size).m4a")
    }

    /// The extracted audio if it's already on disk.
    static func readyAudio(for video: URL) -> URL? {
        let url = cachedAudioURL(for: video)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Extracts (once) the video's soundtrack to an .m4a that the audio engine can play.
    static func extractAudio(from video: URL) async throws -> URL {
        let out = cachedAudioURL(for: video)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let asset = AVURLAsset(url: video)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw MediaError.noAudio(video.lastPathComponent) }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw MediaError.cantExport(video.lastPathComponent)
        }
        let tmp = out.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".m4a")
        session.outputURL = tmp
        session.outputFileType = .m4a
        await session.export()
        guard session.status == .completed else {
            throw session.error ?? MediaError.cantExport(video.lastPathComponent)
        }
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: tmp, to: out)
        return out
    }

    /// Fire-and-forget extraction (used when video cues are added or a show opens).
    static func prepare(_ video: URL) {
        guard isVideo(video), readyAudio(for: video) == nil else { return }
        Task.detached(priority: .utility) { _ = try? await extractAudio(from: video) }
    }

    /// Checks a video can be played by AVFoundation (H.264 / HEVC / ProRes in .mov/.mp4/.m4v).
    static func canPlayVideo(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        let playable = (try? await asset.load(.isPlayable)) ?? false
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        return playable && !videoTracks.isEmpty
    }

    /// Decodes any audio or video file's sound to mono Float32 at `sampleRate` (for analysis).
    static func decodeMono(_ url: URL, sampleRate: Double) throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else { throw MediaError.noAudio(url.lastPathComponent) }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaError.cantExport(url.lastPathComponent) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MediaError.cantExport(url.lastPathComponent) }
        var samples: [Float] = []
        while let sb = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes { raw in
                if let base = raw.baseAddress { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base) }
            }
            samples.append(contentsOf: chunk)
        }
        if reader.status == .failed { throw reader.error ?? MediaError.cantExport(url.lastPathComponent) }
        return samples
    }

    enum MediaError: LocalizedError {
        case noAudio(String), cantExport(String), unsupported(String)
        var errorDescription: String? {
            switch self {
            case .noAudio(let n): return "“\(n)” has no audio track."
            case .cantExport(let n): return "Couldn't read the sound from “\(n)”."
            case .unsupported(let n): return "“\(n)” isn't a format macOS can play. Convert it to .mp4 (H.264/HEVC) or .mov (ProRes)."
            }
        }
    }
}
