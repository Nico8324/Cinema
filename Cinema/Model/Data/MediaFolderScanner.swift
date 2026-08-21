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
        /// How many of the added videos TMDB identified confidently.
        var matched = 0
        /// Whether the folder itself couldn't be read (moved, renamed, or on a drive that's away).
        var folderUnreachable = false
    }

    /// Every MP4 under `folder`, recursively.
    ///
    /// Deliberately MP4 and nothing else. The library may only contain files that actually play,
    /// and MP4 is what the converter produces — so anything else in the folder is a *candidate for
    /// conversion*, not a library entry. Admitting a `.mkv` here would put a row on screen that
    /// can never play, and admitting a `.mov` would quietly split the library across two formats
    /// with different guarantees.
    ///
    /// The test is uniform-type conformance rather than a string comparison on the extension, so a
    /// file is judged by what it is rather than what it is called. That matters in both directions:
    /// an MKV on a Mac with VLC installed resolves to a real `public.movie` type and would sail
    /// through a `.movie` check, while on a Mac without it the same file has no video type at all —
    /// which is exactly how this filter came to look correct while being wrong.
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
                  type.conforms(to: .mpeg4Movie)
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

        // Everything that touches the disk happens here, off the main actor: walking the tree,
        // stat-ing each file, and hashing a megabyte of any that might be a duplicate. Left on
        // the main actor this froze the app for the length of the scan — and the scan runs at
        // launch, so the freeze was the first thing anyone saw.
        let selection = await Task.detached { () -> (new: [URL], alreadyPresent: Int) in
            var fresh: [URL] = []
            var alreadyPresent = 0
            // Content keys of the files accepted so far, so two identical copies inside the
            // folder itself don't both become library entries — matching against what was
            // previously imported catches only half the problem.
            var acceptedContent = Set<String>()

            for url in videoFiles(in: folder) {
                guard !known.contains(url.path(percentEncoded: false)) else {
                    alreadyPresent += 1
                    continue
                }
                // A file the person imported before choosing a media folder is in the library
                // twice over otherwise: once as the app's own copy, once as a reference to the
                // original. The paths differ, so only matching on content catches it.
                guard VideoImporter.existingLibraryFilename(matching: url) == nil else {
                    alreadyPresent += 1
                    continue
                }
                if let key = VideoImporter.contentKey(for: url), !acceptedContent.insert(key).inserted {
                    alreadyPresent += 1
                    continue
                }
                fresh.append(url)
            }
            return (fresh, alreadyPresent)
        }.value

        outcome.alreadyPresent = selection.alreadyPresent

        // Only a fallback: a year the filename states beats the year the scan happened.
        let scanYear = Calendar.current.component(.year, from: .now)
        var added: [Video] = []

        for url in selection.new {
            let path = url.path(percentEncoded: false)
            let parsed = FilenameMetadata.parse(url.deletingPathExtension().lastPathComponent)
            let episode = parsed.episode
            let video = Video(
                // Episodes take the show's name; the marker fields carry the rest.
                name: episode?.showName ?? parsed.title,
                synopsis: episode?.showName ?? parsed.title,
                externalPath: path,
                yearOfRelease: parsed.year ?? scanYear,
                duration: await ThumbnailGenerator.duration(for: url),
                showName: episode?.showName,
                seasonNumber: episode?.season,
                episodeNumber: episode?.episode
            )
            context.insert(video)
            // Attached as it arrives rather than reconciled later: an episode inserted without a
            // show is one that groups by string until something notices, and "something notices"
            // is the design this version replaced.
            if let showName = episode?.showName {
                video.show = Show.findOrCreate(named: showName, in: context)
            }
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

        // Match everything still unidentified, not merely what this scan added.
        //
        // Restricting this to new arrivals made it unreachable in the ordinary case: a library
        // built before matching existed, or one whose films were added while the network was
        // down, would never be revisited — and since scanning is additive, there'd be nothing
        // new to trigger it. Emptying the library and starting over shouldn't be the only way to
        // get metadata. Entries that genuinely can't be identified are re-tried on each scan,
        // which costs one search apiece and leaves them exactly as they were.
        let unmatched = (try? context.fetch(FetchDescriptor<Video>()))?
            .filter { $0.isEpisode ? $0.tmdbShowID == nil : $0.tmdbID == nil } ?? []
        if !unmatched.isEmpty {
            outcome.matched = await MetadataAutoMatch.match(unmatched, in: context)
        }

        return outcome
    }
}
#endif
