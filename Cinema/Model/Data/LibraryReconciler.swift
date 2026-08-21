/*
See the LICENSE.txt file for licensing information.

Abstract:
Reconciles the media files on disk with the video library at startup.
*/

import Foundation
import SwiftData
import OSLog

/// Reconciles the media files on disk with the video library.
///
/// Crashes and interrupted imports can strand state on either side: media files
/// with no library entry (wasted disk that nothing can see), or entries whose
/// backing file is gone (rows that can never play). Run once at startup — never
/// concurrently with an import, whose freshly copied files haven't been saved
/// to the store yet.
enum LibraryReconciler {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Cinema", category: "Reconcile")

    @MainActor
    static func reconcile(in context: ModelContext) {
        guard let videos = try? context.fetch(FetchDescriptor<Video>()) else { return }

        let fileManager = FileManager.default
        let referencedMedia = Set(videos.compactMap(\.localFilename))
        // The show artwork worth keeping is decided by Show rows as well as episodes: a show
        // deliberately outlives its last episode with its match intact, and sweeping
        // `show-<id>.jpg` the launch after that deletion would take the artwork the row is
        // keeping the match *for*.
        let matchedShowIDs = Set(videos.compactMap(\.tmdbShowID))
            .union(((try? context.fetch(FetchDescriptor<Show>())) ?? []).compactMap(\.tmdbShowID))
        // Per-video thumbnails, plus the shared show-backdrop artwork.
        let referencedThumbnails = Set(videos.compactMap { video in
            video.thumbnailFilename.map { MediaStore.thumbnailURL(forFilename: $0).lastPathComponent }
        }).union(Set(matchedShowIDs.map {
            MediaStore.thumbnailURL(forFilename: MediaStore.showArtworkFilename(forShowID: $0)).lastPathComponent
        }))

        // Media files no library entry references: dead bytes — remove them.
        var removedOrphans = 0
        var failedRemovals = 0
        func remove(_ url: URL) {
            do {
                try fileManager.removeItem(at: url)
                removedOrphans += 1
            } catch {
                // Counted and named: a sweep that silently fails on the same file every launch
                // looks identical to one that never needed to run.
                failedRemovals += 1
                logger.error("Couldn't remove orphaned \(url.lastPathComponent, privacy: .public): \(error.localizedDescription)")
            }
        }
        for url in files(in: MediaStore.videosDirectory) where !referencedMedia.contains(url.lastPathComponent) {
            remove(url)
        }

        // Thumbnails whose video is gone.
        for url in files(in: MediaStore.thumbnailsDirectory) where !referencedThumbnails.contains(url.lastPathComponent) {
            remove(url)
        }

        // Posters are keyed by the same filenames, so the same set decides which are still live.
        for url in files(in: MediaStore.postersDirectory) where !referencedThumbnails.contains(url.lastPathComponent) {
            remove(url)
        }

        // Entries whose imported file vanished can never play again — remove them
        // (their thumbnails too, via removeLocalFiles).
        //
        // Only entries the app imported are eligible, which the `localFilename` test enforces.
        // Remote entries have no local file, and referenced entries must survive an unreachable
        // path: an unplugged drive or a renamed folder is a temporary condition, not a reason to
        // silently drop rows describing films the person still owns.
        var removedEntries = 0
        for video in videos {
            guard !video.isExternallyReferenced,
                  let localFilename = video.localFilename,
                  !fileManager.fileExists(atPath: MediaStore.videoURL(forFilename: localFilename).path) else {
                continue
            }
            video.removeLocalFiles()
            context.delete(video)
            removedEntries += 1
        }
        if removedEntries > 0 {
            Genre.deleteOrphaned(in: context)
            context.saveReportingErrors()
        }

        if removedOrphans > 0 || removedEntries > 0 || failedRemovals > 0 {
            logger.notice("Reconciled the library: removed \(removedOrphans) orphaned file(s) and \(removedEntries) dead entrie(s); \(failedRemovals) removal(s) failed.")
        }
    }

    private static func files(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }
}
