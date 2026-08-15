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

    /// The directory holding imported video files.
    static var videosDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Videos", directoryHint: .isDirectory)
    }

    /// The directory holding generated poster thumbnails.
    static var thumbnailsDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Thumbnails", directoryHint: .isDirectory)
    }

    /// The file holding the profile photo, stored as a downscaled JPEG.
    static var profileImageURL: URL {
        URL.applicationSupportDirectory.appending(path: "profile.jpg", directoryHint: .notDirectory)
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
