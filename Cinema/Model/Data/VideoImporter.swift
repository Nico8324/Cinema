/*
See the LICENSE.txt file for licensing information.

Abstract:
Imports user-picked video files into the app's library.
*/

import Foundation
import SwiftData
import OSLog
import CryptoKit

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
        /// The release year stated in the filename, when it states one.
        let year: Int?
        /// The episode marker parsed from the filename, for TV content.
        let episode: EpisodeMarker?
    }

    /// A season/episode marker parsed from a filename like "Silo S02E04".
    struct EpisodeMarker: Sendable, Equatable {
        let showName: String
        let season: Int
        let episode: Int
    }

    /// Parses a "Show S01E02"-style title into its show and episode parts.
    /// Handles separators like dots, underscores, and dashes; returns `nil`
    /// for titles without a season/episode marker (movies).
    ///
    /// Character classes stand in for case-insensitivity, and a separator is
    /// required before the marker — Swift Regex's `\b` follows Unicode default
    /// word-boundary rules and misbehaves around dots and mixed case here.
    nonisolated static func episodeMarker(in title: String) -> EpisodeMarker? {
        let pattern = /^(?<show>.+?)[\s._-]+[Ss](?<season>\d{1,2})[\s._-]*[Ee](?<episode>\d{1,3})\b/
        guard let match = title.firstMatch(of: pattern),
              let season = Int(match.season),
              let episode = Int(match.episode) else {
            return nil
        }
        let show = match.show
            .replacing(/[._]/, with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -"))
        guard !show.isEmpty else { return nil }
        return EpisodeMarker(showName: show, season: season, episode: episode)
    }

    /// The outcome of an import run: the files that made it in, per-file failure
    /// messages, and the stored filenames of duplicates that were skipped.
    struct Outcome: Sendable {
        var imported: [ImportedFile] = []
        var failures: [String] = []
        var duplicateFilenames: [String] = []
    }

    /// Copies the picked files into the app's storage and probes their durations.
    /// Runs entirely off the main actor; UI stays responsive during multi-gigabyte copies.
    ///
    /// Files whose content already exists in the library are skipped and reported
    /// in the outcome instead of silently duplicating disk usage.
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
                if let existingFilename = existingLibraryFilename(matching: sourceURL) {
                    outcome.duplicateFilenames.append(existingFilename)
                    // Count the skipped bytes as done so overall progress stays honest.
                    copiedBytes += fileSize(of: sourceURL)
                    if totalBytes > 0 {
                        onProgress(min(Double(copiedBytes) / Double(totalBytes), 1))
                    }
                    continue
                }

                let filename = try copyIntoLibrary(from: sourceURL) { chunkBytes in
                    copiedBytes += chunkBytes
                    if totalBytes > 0 {
                        onProgress(min(Double(copiedBytes) / Double(totalBytes), 1))
                    }
                }
                let duration = await ThumbnailGenerator.duration(for: MediaStore.videoURL(forFilename: filename))
                // Read through `FilenameMetadata` rather than taking the name literally: a raw
                // `The.Invite.2026.2160p.WEB-DL.HEVC-GROUP` is both an unreadable library title
                // and a useless thing to search TMDB with.
                let parsed = FilenameMetadata.parse(sourceURL.deletingPathExtension().lastPathComponent)
                outcome.imported.append(ImportedFile(
                    filename: filename,
                    title: parsed.title,
                    duration: duration,
                    year: parsed.year,
                    episode: parsed.episode
                ))
            } catch {
                logger.error("Import failed for \(sourceURL.lastPathComponent): \(error.localizedDescription)")
                outcome.failures.append("\(sourceURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        onProgress(1)
        return outcome
    }

    /// The stored filename of a library file with the same content as the given file,
    /// or `nil` if the file is new. Compares by size first (cheap), then by a hash of
    /// the first megabyte — no metadata schema involved; the disk is the source of truth.
    ///
    /// Used by the picker to skip re-importing, and by the Mac's folder scan to avoid listing a
    /// film twice when the person already imported a copy of it.
    nonisolated static func existingLibraryFilename(matching sourceURL: URL) -> String? {
        let sourceSize = fileSize(of: sourceURL)
        guard sourceSize > 0 else { return nil }

        let fileManager = FileManager.default
        guard let existing = try? fileManager.contentsOfDirectory(
            at: MediaStore.videosDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return nil }

        let sameSizeCandidates = existing.filter { url in
            Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1) == sourceSize
        }
        guard !sameSizeCandidates.isEmpty else { return nil }

        guard let sourceHash = leadingHash(of: sourceURL) else { return nil }
        return sameSizeCandidates.first { leadingHash(of: $0) == sourceHash }?.lastPathComponent
    }

    /// A cheap content identity for a file: its size paired with a hash of its first megabyte.
    ///
    /// Two files sharing a key are the same film as far as the library is concerned. Exposed so
    /// callers can deduplicate a set of files against each other, not only against what's already
    /// been imported — the folder scan needs both.
    nonisolated static func contentKey(for url: URL) -> String? {
        let size = fileSize(of: url)
        guard size > 0, let hash = leadingHash(of: url) else { return nil }
        return "\(size)-" + hash.map { String(format: "%02x", $0) }.joined()
    }

    /// A SHA-256 digest of the file's first megabyte — combined with an exact size
    /// match, near-certain identity without reading multi-gigabyte files end to end.
    private nonisolated static func leadingHash(of url: URL) -> SHA256Digest? {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1024 * 1024) else { return nil }
        return SHA256.hash(data: data)
    }

    /// Creates and saves library entries for successfully imported files.
    /// Returns the inserted videos so callers can kick off thumbnail generation.
    @MainActor
    static func addVideos(for files: [ImportedFile], to context: ModelContext) -> [Video] {
        // Only a fallback: a year the filename actually states beats the year the import happened.
        let importYear = Calendar.current.component(.year, from: .now)
        let videos = files.map { file in
            // Episodes take the show's name; the marker fields carry the rest.
            let video = Video(
                name: file.episode?.showName ?? file.title,
                synopsis: file.episode?.showName ?? file.title,
                localFilename: file.filename,
                yearOfRelease: file.year ?? importYear,
                duration: file.duration,
                showName: file.episode?.showName,
                seasonNumber: file.episode?.season,
                episodeNumber: file.episode?.episode
            )
            context.insert(video)
            if let showName = file.episode?.showName {
                video.show = Show.findOrCreate(named: showName, in: context)
            }
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
        // Works for imported and referenced media alike — both resolve to a file on disk. The
        // file-URL test keeps YouTube entries out: there's no frame to extract from a stream URL,
        // and those get their poster from TMDB instead.
        guard let mediaURL = video.mediaURL, mediaURL.isFileURL,
              let filename = video.thumbnailFilename else { return }
        Task {
            guard await writeThumbnailFile(from: mediaURL, forFilename: filename) else {
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
        // `try`, not `try?`: a failed fetch can't prove the video is new, and swallowing it
        // would admit a duplicate row on exactly the launches something is already wrong.
        let existing = try context.fetch(FetchDescriptor<Video>())
        if let duplicate = existing.first(where: { $0.remoteURL == watchURL }) {
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

        if Thread.isMainThread {
            // The whole point of this pipeline is staying off the main thread —
            // if this fires, actor-inference semantics changed underneath us.
            logger.fault("Import copy is running on the MAIN thread — UI will freeze for the whole copy.")
        }

        let source = try FileHandle(forReadingFrom: sourceURL)
        defer { try? source.close() }

        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            let destination = try FileHandle(forWritingTo: destinationURL)
            defer { try? destination.close() }
            // Drain an autorelease pool every chunk: FileHandle returns autoreleased
            // data, and without this a multi-gigabyte movie accumulates entirely in
            // memory during the loop — enough to hit the platform memory limit and
            // get the app killed mid-import (seen on Vision Pro, limit 5GB).
            var reachedEnd = false
            while !reachedEnd {
                try autoreleasepool {
                    guard let chunk = try source.read(upToCount: copyChunkSize), !chunk.isEmpty else {
                        reachedEnd = true
                        return
                    }
                    try destination.write(contentsOf: chunk)
                    onChunk(Int64(chunk.count))
                }
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
