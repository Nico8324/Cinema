/*
See the LICENSE.txt file for licensing information.

Abstract:
The single source of truth for where the app keeps media files on disk.
*/

import Foundation
import OSLog

/// The single source of truth for where the app keeps media files on disk.
///
/// All paths are reconstructed against the current sandbox container on every access —
/// the container path isn't stable across reinstalls/updates, so nothing absolute is
/// ever stored or cached.
enum MediaStore {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Cinema", category: "MediaStore")

    /// The shared card/header artwork for a matched show (its TMDB backdrop),
    /// keyed by show ID — episodes keep their own stills.
    static func showArtworkFilename(forShowID showID: Int) -> String {
        "show-\(showID).jpg"
    }

    /// The container all media directories live under. Tests point this at a scratch
    /// directory so they never touch a real library.
    ///
    /// On the Mac this is an app-named folder rather than Application Support itself, for the
    /// same reason the SwiftData store moved: the app runs without a sandbox, so the bare
    /// directory is shared with every other unsandboxed app — and generic names like `Videos`
    /// are exactly the kind another app would also use. The orphan sweep in `LibraryReconciler`
    /// deletes files out of `Videos`, which must never happen in a folder that isn't ours.
    #if os(macOS)
    nonisolated(unsafe) static var rootDirectory: URL = .applicationSupportDirectory
        .appending(path: "Cinema", directoryHint: .isDirectory)
    #else
    nonisolated(unsafe) static var rootDirectory: URL = .applicationSupportDirectory
    #endif

    #if os(macOS)
    /// One-time move of the media directories out of the shared Application Support root.
    ///
    /// Runs before anything reads or sweeps the store: the reconciler judging rows against a
    /// still-empty new root would strand every imported file. Each entry moves only if it
    /// exists at the old location and nothing occupies the new one, so the move can't clobber
    /// and re-running is a no-op.
    static func migrateLegacySharedDirectoriesIfNeeded() {
        let legacyRoot = URL.applicationSupportDirectory
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        for name in ["Videos", "Thumbnails", "Posters", "profile.jpg"] {
            let source = legacyRoot.appending(path: name)
            let destination = rootDirectory.appending(path: name)
            guard fileManager.fileExists(atPath: source.path),
                  !fileManager.fileExists(atPath: destination.path) else { continue }
            do {
                try fileManager.moveItem(at: source, to: destination)
                logger.notice("Moved \(name, privacy: .public) into the app's own media root.")
            } catch {
                logger.error("Couldn't move \(name, privacy: .public) into the media root: \(error.localizedDescription)")
            }
        }
    }
    #endif

    /// The directory holding imported video files.
    static var videosDirectory: URL {
        rootDirectory.appending(path: "Videos", directoryHint: .isDirectory)
    }

    /// The directory holding generated poster thumbnails.
    static var thumbnailsDirectory: URL {
        rootDirectory.appending(path: "Thumbnails", directoryHint: .isDirectory)
    }

    /// The directory holding downloaded portrait posters.
    ///
    /// Separate from `thumbnailsDirectory` because the two are different pictures of the same
    /// film — a 16:9 backdrop and a 2:3 poster — and a person can switch between them at any
    /// time, so neither may overwrite the other.
    static var postersDirectory: URL {
        rootDirectory.appending(path: "Posters", directoryHint: .isDirectory)
    }

    /// The location of the stored poster for the video with the given identity.
    static func posterURL(forFilename filename: String) -> URL {
        postersDirectory
            .appending(path: filename, directoryHint: .notDirectory)
            .deletingPathExtension()
            .appendingPathExtension("jpg")
    }

    /// The file holding the profile photo, stored as a downscaled JPEG.
    static var profileImageURL: URL {
        rootDirectory.appending(path: "profile.jpg", directoryHint: .notDirectory)
    }

    /// The location of an imported video file with the given stored filename.
    static func videoURL(forFilename filename: String) -> URL {
        videosDirectory.appending(path: filename, directoryHint: .notDirectory)
    }

    /// The location of the generated thumbnail for the video file with the given stored filename.
    static func thumbnailURL(forFilename filename: String) -> URL {
        thumbnailsDirectory
            .appending(path: filename, directoryHint: .notDirectory)
            .deletingPathExtension()
            .appendingPathExtension("jpg")
    }

    /// Removes an imported video file and its thumbnail (if any) from disk, logging failures.
    static func removeMedia(forFilename filename: String) {
        remove(videoURL(forFilename: filename))
        remove(thumbnailURL(forFilename: filename))
        remove(posterURL(forFilename: filename))
    }

    private static func remove(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            logger.error("Couldn't remove \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
