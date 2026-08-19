/*
See the LICENSE.txt file for licensing information.

Abstract:
Builds the Mac's library from a folder of media the person already keeps on disk.
*/

#if os(macOS)
import Foundation
import OSLog
import SwiftData
import UniformTypeIdentifiers

/// Builds the library from a folder the person already keeps their films in.
///
/// This is the Mac's alternative to picking files one at a time, and it differs from importing in
/// the way that matters: the files are **referenced where they sit**, never copied. A media folder
/// is routinely larger than the disk has room to duplicate, and it's a place the person curates
/// themselves — so the app reads from it and otherwise leaves it alone. Nothing here writes to,
/// moves, or deletes anything inside the folder.
///
/// Scanning is additive. A file that disappears leaves its library entry behind, because the
/// overwhelmingly likely cause is an unplugged drive or a folder that moved, not a film the person
/// wanted forgotten.
enum MediaFolderScanner {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Cinema", category: "FolderScan")

    /// The `UserDefaults` key holding the scanned folder's path.
    static let folderPathKey = "mediaFolderPath"

    /// The folder currently being scanned, if the person has chosen one.
    @MainActor
    static var folderURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: folderPathKey), !path.isEmpty else { return nil }
        return URL(filePath: path)
    }

    /// What a scan did.
    struct Outcome: Sendable {
        /// Files added to the library this run.
        var added = 0
        /// Files the library already had, by path or by content — the usual result of a rescan.
        var alreadyPresent = 0
        /// Whether the folder itself couldn't be read (moved, renamed, or on a drive that's away).
        var folderUnreachable = false
    }

    /// Every video file under `folder`, recursively.
    ///
    /// Matching is by uniform type rather than a list of extensions, so anything the system knows
    /// to be a movie counts, and a stray `.txt` never does.
    nonisolated static func videoFiles(in folder: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentTypeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var found: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let type = values.contentType,
                  type.conforms(to: .movie) || type.conforms(to: .video)
            else { continue }
            found.append(url)
        }
        // Stable order so a scan's additions read predictably rather than in filesystem order.
        return found.sorted { $0.path < $1.path }
    }

    /// Adds every video under `folder` that the library doesn't already reference.
    ///
    /// Existing entries are matched by path, so rescanning after adding a few films picks up only
    /// the new ones. Titles, season/episode markers and durations are derived exactly as they are
    /// for picked files, so scanned and imported content behaves identically downstream.
    @MainActor
    static func scan(folder: URL, into context: ModelContext) async -> Outcome {
        var outcome = Outcome()

        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else {
            logger.error("Media folder isn't reachable: \(folder.path(percentEncoded: false))")
            outcome.folderUnreachable = true
            return outcome
        }

        let known = Set((try? context.fetch(FetchDescriptor<Video>()))?.compactMap(\.externalPath) ?? [])
        // Walking a large folder tree is slow enough to keep off the main actor.
        let files = await Task.detached { videoFiles(in: folder) }.value

        let year = Calendar.current.component(.year, from: .now)
        var added: [Video] = []

        for url in files {
            let path = url.path(percentEncoded: false)
            guard !known.contains(path) else {
                outcome.alreadyPresent += 1
                continue
            }

            // A file the person imported before choosing a media folder is in the library twice
            // over otherwise: once as the app's own copy, once as a reference to the original.
            // The paths differ, so only matching on content catches it. The check is cheap when
            // nothing was ever imported — it compares sizes before it hashes anything.
            guard VideoImporter.existingLibraryFilename(matching: url) == nil else {
                outcome.alreadyPresent += 1
                continue
            }

            let title = url.deletingPathExtension().lastPathComponent
            let episode = VideoImporter.episodeMarker(in: title)
            let video = Video(
                // Episodes take the show's name; the marker fields carry the rest.
                name: episode?.showName ?? title,
                synopsis: episode?.showName ?? title,
                externalPath: path,
                yearOfRelease: year,
                duration: await ThumbnailGenerator.duration(for: url),
                showName: episode?.showName,
                seasonNumber: episode?.season,
                episodeNumber: episode?.episode
            )
            context.insert(video)
            added.append(video)
            outcome.added += 1
        }

        if !added.isEmpty {
            context.saveReportingErrors()
            // Posters come from the files themselves, written into the app's own storage.
            for video in added {
                VideoImporter.generateThumbnail(for: video, in: context)
            }
            logger.info("Added \(outcome.added) video(s) from \(folder.lastPathComponent).")
        }

        return outcome
    }
}
#endif
