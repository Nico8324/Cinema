/*
See the LICENSE.txt file for licensing information.

Abstract:
Helpers for treating YouTube videos as library entries.
*/

import Foundation
import YouTubeKit

/// Helpers for treating YouTube videos as library entries.
///
/// A YouTube video is stored as a `Video` whose `remoteURL` is its canonical watch URL.
/// YouTube's direct stream URLs expire after a few hours, so they're never persisted —
/// a fresh one is resolved from the watch URL every time playback starts.
enum YouTubeSource {
    /// The extracted video ID, if the URL points to a YouTube video.
    /// Handles watch, share (youtu.be), shorts, live, and embed URL shapes.
    static func videoID(from url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        let pathParts = url.pathComponents.dropFirst() // Drops the leading "/".

        if host == "youtu.be" {
            return pathParts.first
        }

        guard host == "youtube.com" || host.hasSuffix(".youtube.com") else {
            return nil
        }

        switch pathParts.first {
        case "watch":
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "v" })?.value
        case "shorts", "embed", "live", "v":
            return pathParts.dropFirst().first
        default:
            return nil
        }
    }

    /// The canonical watch URL stored in the library for a video ID.
    static func watchURL(forVideoID id: String) -> URL {
        URL(string: "https://www.youtube.com/watch?v=\(id)")!
    }

    /// Whether the given URL is a YouTube video this app knows how to resolve.
    static func isYouTubeURL(_ url: URL) -> Bool {
        videoID(from: url) != nil
    }

    /// Resolves a freshly playable stream URL for a YouTube video ID.
    ///
    /// Only local extraction is used — YouTubeKit's remote fallback routes traffic
    /// through a third-party server, which this app deliberately avoids.
    static func streamURL(forVideoID id: String) async throws -> URL? {
        let streams = try await YouTube(videoID: id).streams
        let stream = streams
            .filterVideoAndAudio()
            .filter { $0.isNativelyPlayable }
            .highestResolutionStream()
        logger.debug("Resolved YouTube stream for \(id): \(stream?.url.absoluteString ?? "none")")
        return stream?.url
    }

    /// Fetches display metadata (title, description) for a YouTube video ID,
    /// or `nil` when YouTube doesn't provide any.
    static func metadata(forVideoID id: String) async throws -> YouTubeMetadata? {
        try await YouTube(videoID: id).metadata
    }
}
