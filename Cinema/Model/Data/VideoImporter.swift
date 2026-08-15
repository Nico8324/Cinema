/*
See the LICENSE.txt file for licensing information.

Abstract:
Imports user-picked video files into the app's library.
*/

import Foundation
import SwiftData
import OSLog

/// Observable state for an in-flight import, driving the Library's toolbar progress ring.
@MainActor @Observable
final class ImportProgress {
    /// The overall fraction of bytes copied (0...1), or `nil` when no import is running.
    private(set) var fraction: Double?

    func begin() {
        fraction = 0
    }

    /// Progress only ever moves forward — chunk reports can arrive slightly out of order.
    func update(to newFraction: Double) {
        guard fraction != nil else { return }
        fraction = min(max(fraction ?? 0, newFraction), 1)
    }

    func end() {
        fraction = nil
    }
}

/// Imports user-picked video files into the app's library.
///
/// The heavy work — copying multi-gigabyte files, probing durations, generating thumbnails —
/// runs off the main actor and communicates only Sendable value types. Model objects are
/// created and mutated exclusively on the main actor.
enum VideoImporter {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Cinema", category: "Import")

    /// The result of copying one picked file into the app's storage.
    struct ImportedFile: Sendable {
        /// The stored filename inside the Videos directory (a UUID plus the original extension).
        let filename: String
        /// A display title derived from the original filename.
        let title: String
        /// The video's duration in whole seconds, or 0 if it couldn't be determined.
        let duration: Int
    }

    /// The outcome of an import run: the files that made it in, and per-file failure messages.
    struct Outcome: Sendable {
        var imported: [ImportedFile] = []
        var failures: [String] = []
    }

    /// Copies the picked files into the app's storage and probes their durations.
    /// Runs entirely off the main actor; UI stays responsive during multi-gigabyte copies.
    ///
    /// `onProgress` receives the overall fraction of bytes copied (0...1) across all
    /// files, from a background context — hop to the main actor before touching UI state.
    nonisolated static func importFiles(
        from sourceURLs: [URL],
        onProgress: @escaping @Sendable (Double) -> Void
    ) async -> Outcome {
        var outcome = Outcome()

        let totalBytes = sourceURLs.reduce(Int64(0)) { $0 + fileSize(of: $1) }
        var copiedBytes: Int64 = 0

        for sourceURL in sourceURLs {
            do {
                let filename = try copyIntoLibrary(from: sourceURL) { chunkBytes in
                    copiedBytes += chunkBytes
                    if totalBytes > 0 {
                        onProgress(min(Double(copiedBytes) / Double(totalBytes), 1))
                    }
                }
                let duration = await ThumbnailGenerator.duration(for: MediaStore.videoURL(forFilename: filename))
                outcome.imported.append(ImportedFile(
                    filename: filename,
                    title: sourceURL.deletingPathExtension().lastPathComponent,
                    duration: duration
                ))
            } catch {
                logger.error("Import failed for \(sourceURL.lastPathComponent): \(error.localizedDescription)")
                outcome.failures.append("\(sourceURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        onProgress(1)
        return outcome
    }

    /// Creates and saves library entries for successfully imported files.
    /// Returns the inserted videos so callers can kick off thumbnail generation.
    @MainActor
    static func addVideos(for files: [ImportedFile], to context: ModelContext) -> [Video] {
        let year = Calendar.current.component(.year, from: .now)
        let videos = files.map { file in
            let video = Video(
                name: file.title,
                synopsis: file.title,
                localFilename: file.filename,
                yearOfRelease: year,
                duration: file.duration
            )
            context.insert(video)
            return video
        }
        context.saveReportingErrors()
        return videos
    }

    /// Extracts a representative poster frame from the imported video and saves it,
    /// updating the video once the thumbnail is on disk. Generation runs off the main
    /// actor; only the model update happens on it.
    @MainActor
    static func generateThumbnail(for video: Video, in context: ModelContext) {
        guard let filename = video.localFilename else { return }
        Task {
            guard await writeThumbnailFile(from: MediaStore.videoURL(forFilename: filename), forFilename: filename) else {
                // The video still works without a thumbnail — the poster placeholder stays in place.
                return
            }
            video.hasThumbnail = true
            context.saveReportingErrors()
        }
    }

    /// What went wrong when adding a video from a URL.
    enum ImportError: LocalizedError {
        case notAYouTubeURL
        case alreadyInLibrary(String)

        var errorDescription: String? {
            switch self {
            case .notAYouTubeURL:
                String(localized: "This link doesn’t look like a YouTube video.")
            case .alreadyInLibrary(let name):
                String(localized: "“\(name)” is already in your library.")
            }
        }
    }

    /// Creates a library entry for a YouTube video from its watch/share URL.
    ///
    /// Only the canonical watch URL is stored — YouTube stream URLs expire, so a fresh
    /// one is resolved at playback time. Duration and a poster thumbnail are filled in
    /// asynchronously from a resolved stream after the entry appears.
    @MainActor
    static func addYouTubeVideo(from url: URL, to context: ModelContext) async throws -> Video {
        guard let videoID = YouTubeSource.videoID(from: url) else {
            throw ImportError.notAYouTubeURL
        }
        let watchURL = YouTubeSource.watchURL(forVideoID: videoID)

        // The library is small; an in-memory duplicate check keeps URL comparison simple.
        let existing = try? context.fetch(FetchDescriptor<Video>())
        if let duplicate = existing?.first(where: { $0.remoteURL == watchURL }) {
            throw ImportError.alreadyInLibrary(duplicate.name)
        }

        let metadata = try await YouTubeSource.metadata(forVideoID: videoID)

        let title = metadata?.title ?? ""
        let video = Video(
            name: title.isEmpty ? String(localized: "YouTube Video") : title,
            synopsis: metadata?.description ?? "",
            remoteURL: watchURL,
            yearOfRelease: Calendar.current.component(.year, from: .now)
        )
        context.insert(video)
        context.saveReportingErrors()

        enrichYouTubeVideo(video, videoID: videoID, in: context)
        return video
    }

    /// Fills in duration and a poster thumbnail from a freshly resolved stream.
    @MainActor
    private static func enrichYouTubeVideo(_ video: Video, videoID: String, in context: ModelContext) {
        guard let thumbnailFilename = video.thumbnailFilename else { return }
        Task {
            guard let streamURL = try? await YouTubeSource.streamURL(forVideoID: videoID) else { return }

            let duration = await ThumbnailGenerator.duration(for: streamURL)
            if duration > 0 {
                video.duration = duration
            }

            if await writeThumbnailFile(from: streamURL, forFilename: thumbnailFilename) {
                video.hasThumbnail = true
            }
            context.saveReportingErrors()
        }
    }

    /// Generates the thumbnail JPEG from the given media URL and writes it under the
    /// given thumbnail filename, off the main actor.
    private nonisolated static func writeThumbnailFile(from mediaURL: URL, forFilename filename: String) async -> Bool {
        guard let thumbnailData = await ThumbnailGenerator.generateThumbnailData(for: mediaURL) else { return false }

        do {
            try FileManager.default.createDirectory(at: MediaStore.thumbnailsDirectory, withIntermediateDirectories: true)
            try thumbnailData.write(to: MediaStore.thumbnailURL(forFilename: filename))
            return true
        } catch {
            logger.error("Couldn't write thumbnail for \(filename): \(error.localizedDescription)")
            return false
        }
    }

    /// The chunk size for manual file copies. Large enough to keep copies fast,
    /// small enough for smooth progress reporting.
    private static let copyChunkSize = 8 * 1024 * 1024

    /// Copies a security-scoped, user-picked file into the app's own storage so it remains
    /// accessible after this session ends. Returns the stored filename (not an absolute path —
    /// the sandbox container path isn't stable across reinstalls).
    ///
    /// The copy is chunked by hand rather than using `FileManager.copyItem`, which offers
    /// no progress reporting; `onChunk` receives each chunk's byte count as it lands.
    private nonisolated static func copyIntoLibrary(
        from sourceURL: URL,
        onChunk: (Int64) -> Void
    ) throws -> String {
        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        try FileManager.default.createDirectory(at: MediaStore.videosDirectory, withIntermediateDirectories: true)

        let filename = UUID().uuidString + "." + sourceURL.pathExtension
        let destinationURL = MediaStore.videoURL(forFilename: filename)

        let source = try FileHandle(forReadingFrom: sourceURL)
        defer { try? source.close() }

        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            let destination = try FileHandle(forWritingTo: destinationURL)
            defer { try? destination.close() }
            while let chunk = try source.read(upToCount: copyChunkSize), !chunk.isEmpty {
                try destination.write(contentsOf: chunk)
                onChunk(Int64(chunk.count))
            }
        } catch {
            // Never leave a partial file behind — it would be an orphan with no library entry.
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }

        return filename
    }

    /// The size of a picked file in bytes, or 0 if it can't be determined.
    private nonisolated static func fileSize(of url: URL) -> Int64 {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
