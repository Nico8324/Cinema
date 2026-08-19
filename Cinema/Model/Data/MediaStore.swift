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

    /// The container all media directories live under. The app always uses
    /// Application Support; tests point this at a scratch directory so they
    /// never touch a real library.
    nonisolated(unsafe) static var rootDirectory: URL = .applicationSupportDirectory

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
