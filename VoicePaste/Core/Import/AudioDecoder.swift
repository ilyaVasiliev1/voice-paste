import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

/// Formats explicitly required by `US-007`/`UI-006` (`.m4a/.wav/.mp3/.mp4/.mov/.ogg`).
nonisolated public enum SupportedImportFormat: String, CaseIterable, Sendable {
    case m4a
    case wav
    case mp3
    case mp4
    case mov
    case m4v
    case ogg

    public static func isSupported(pathExtension: String) -> Bool {
        allCases.contains { $0.rawValue == pathExtension.lowercased() }
    }
}

nonisolated public enum AudioDecodeError: Error, Equatable, Sendable {
    case unsupportedFormat
    case noAudioTrack
    case decodeFailed(String)
}

/// Decodes an already security-scoped-accessible media file into 16 kHz mono
/// Float32 samples using only system CoreAudio/AVFoundation (`DEP-008`,
/// spike closed 2026-07-19 — no third-party OGG/Opus library).
///
/// Reads and converts in bounded chunks so multi-hour files stay within a
/// fixed memory footprint and report progress (`EC-013`, `AT-025`); the whole
/// decode loop is a plain `async` function so callers cancel it the normal
/// `Task.cancel()` way.
nonisolated public struct AudioDecoder: Sendable {
    /// Number of source seconds decoded per chunk.
    private let chunkDurationSeconds: Double

    public init(chunkDurationSeconds: Double = 60) {
        self.chunkDurationSeconds = chunkDurationSeconds
    }

    public func decode(url: URL, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> [Float] {
        guard SupportedImportFormat.isSupported(pathExtension: url.pathExtension) else {
            throw AudioDecodeError.unsupportedFormat
        }
        if Self.isVideo(url) {
            return try await decodeVideoAudioTrack(url: url, onProgress: onProgress)
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioDecodeError.decodeFailed(error.localizedDescription)
        }

        let sourceFormat = file.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioDecodeError.decodeFailed("Unsupported source format for resampling.")
        }

        let totalFrames = file.length
        guard totalFrames > 0, sourceFormat.sampleRate > 0 else {
            throw AudioDecodeError.decodeFailed("Empty or unreadable audio track.")
        }

        var result: [Float] = []
        result.reserveCapacity(Int(Double(totalFrames) * 16_000.0 / sourceFormat.sampleRate) + 1)

        let chunkFrameCount = max(1, AVAudioFrameCount(sourceFormat.sampleRate * chunkDurationSeconds))
        var framesRead: AVAudioFramePosition = 0

        while framesRead < totalFrames {
            try Task.checkCancellation()

            let framesRemaining = AVAudioFrameCount(totalFrames - framesRead)
            let framesToRead = min(chunkFrameCount, framesRemaining)
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: framesToRead) else {
                throw AudioDecodeError.decodeFailed("Buffer allocation failed.")
            }
            do {
                try file.read(into: inputBuffer, frameCount: framesToRead)
            } catch {
                throw AudioDecodeError.decodeFailed(error.localizedDescription)
            }
            guard inputBuffer.frameLength > 0 else { break }
            framesRead += AVAudioFramePosition(inputBuffer.frameLength)

            let outCapacity = AVAudioFrameCount(
                Double(inputBuffer.frameLength) * 16_000.0 / sourceFormat.sampleRate
            ) + 1_024
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
                throw AudioDecodeError.decodeFailed("Buffer allocation failed.")
            }

            nonisolated(unsafe) var consumed = false
            nonisolated(unsafe) let bufferToConsume = inputBuffer
            var conversionError: NSError?
            converter.convert(to: outBuffer, error: &conversionError) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return bufferToConsume
            }
            if let conversionError {
                throw AudioDecodeError.decodeFailed(conversionError.localizedDescription)
            }
            if let channelData = outBuffer.floatChannelData {
                let frameCount = Int(outBuffer.frameLength)
                result.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameCount))
            }

            onProgress?(Double(framesRead) / Double(totalFrames))
        }

        return result
    }

    /// `AVAudioFile` is ideal for standalone audio, but does not reliably
    /// expose an embedded track from every MP4/MOV container. Video imports
    /// therefore use `AVAssetReader` directly and request just one 16 kHz
    /// mono PCM audio stream: no video frames are decoded or retained.
    private func decodeVideoAudioTrack(
        url: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw AudioDecodeError.noAudioTrack
        }
        let assetDuration = try await asset.load(.duration)
        let duration = assetDuration.seconds
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioDecodeError.decodeFailed(error.localizedDescription)
        }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AudioDecodeError.decodeFailed("The video audio track cannot be read.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioDecodeError.decodeFailed(reader.error?.localizedDescription ?? "Could not start audio extraction.")
        }

        var result: [Float] = []
        while reader.status == .reading {
            try Task.checkCancellation()
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sampleBuffer) }

            if duration.isFinite, duration > 0 {
                let current = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                onProgress?(min(max(current / duration, 0), 1))
            }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var byteCount = 0
            var rawPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &byteCount,
                dataPointerOut: &rawPointer
            )
            guard status == noErr, let rawPointer, byteCount >= MemoryLayout<Float>.size else { continue }
            let sampleCount = byteCount / MemoryLayout<Float>.size
            rawPointer.withMemoryRebound(to: Float.self, capacity: sampleCount) { pointer in
                result.append(contentsOf: UnsafeBufferPointer(start: pointer, count: sampleCount))
            }
        }
        if reader.status == .failed {
            throw AudioDecodeError.decodeFailed(reader.error?.localizedDescription ?? "Could not extract video audio.")
        }
        guard !result.isEmpty else {
            throw AudioDecodeError.decodeFailed("The video audio track is empty.")
        }
        onProgress?(1)
        return result
    }

    /// Best-effort duration read for the "имя и длительность" preview in
    /// `UI-006`, before the user confirms the import.
    public func probeDuration(url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else {
            return nil
        }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private static func isVideo(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "m4v": true
        default: false
        }
    }
}
