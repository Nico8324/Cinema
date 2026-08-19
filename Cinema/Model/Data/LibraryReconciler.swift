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
        // Per-video thumbnails, plus the shared show-backdrop artwork of every
        // show that still has episodes in the library.
        let referencedThumbnails = Set(videos.compactMap { video in
            video.thumbnailFilename.map { MediaStore.thumbnailURL(forFilename: $0).lastPathComponent }
        }).union(Set(videos.compactMap { video in
            video.tmdbShowID.map {
                MediaStore.thumbnailURL(forFilename: MediaStore.showArtworkFilename(forShowID: $0)).lastPathComponent
            }
        }))

        // Media files no library entry references: dead bytes — remove them.
        var removedOrphans = 0
        for url in files(in: MediaStore.videosDirectory) where !referencedMedia.contains(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
            removedOrphans += 1
        }

        // Thumbnails whose video is gone.
        for url in files(in: MediaStore.thumbnailsDirectory) where !referencedThumbnails.contains(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
            removedOrphans += 1
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

        if removedOrphans > 0 || removedEntries > 0 {
            logger.notice("Reconciled the library: removed \(removedOrphans) orphaned file(s) and \(removedEntries) dead entrie(s).")
        }
    }

    private static func files(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }
}
