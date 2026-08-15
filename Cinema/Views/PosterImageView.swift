/*
See the LICENSE.txt file for licensing information.

Abstract:
A view that asynchronously loads and displays a video's poster thumbnail.
*/

import SwiftUI

/// A view that asynchronously loads and displays a video's poster thumbnail,
/// with a designed placeholder for videos that don't have one.
///
/// Thumbnails are decoded off the main actor and cached, so scrolling grids never
/// re-read JPEGs from disk on every body evaluation. The view fills whatever frame
/// its parent proposes, cropping the image to fit.
struct PosterImageView: View {
    let video: Video

    @State private var poster: Image?

    var body: some View {
        Color(white: 0.12)
            .overlay {
                if let poster {
                    poster
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholder
                }
            }
            .clipped()
            // Reload when thumbnail generation completes after import.
            .task(id: taskID) {
                poster = await PosterImageCache.image(for: video)
            }
    }

    /// Identifies the load task by video and thumbnail state, so a finished
    /// generation or a changed video triggers a reload.
    private var taskID: String {
        "\(video.uuid)-\(video.hasThumbnail)"
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.25), Color(white: 0.1)],
                startPoint: .top,
                endPoint: .bottom
            )
            Image(systemName: "film")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
}

/// Loads and caches decoded poster thumbnails, keyed by thumbnail filename.
@MainActor
enum PosterImageCache {
    private static let cache = NSCache<NSString, PlatformImage>()

    /// Drops the cached image for a thumbnail file whose contents changed on disk.
    static func invalidate(forFilename filename: String) {
        cache.removeObject(forKey: filename as NSString)
    }

    static func image(for video: Video) async -> Image? {
        guard let url = video.thumbnailURL else { return nil }
        let key = url.lastPathComponent as NSString
        if let cached = cache.object(forKey: key) {
            return Image(platformImage: cached)
        }
        guard let decoded = await decodeImage(at: url) else { return nil }
        cache.setObject(decoded, forKey: key)
        return Image(platformImage: decoded)
    }

    /// Reads and decodes the image off the main actor.
    private nonisolated static func decodeImage(at url: URL) async -> PlatformImage? {
        guard let data = try? Data(contentsOf: url), let image = PlatformImage(data: data) else {
            return nil
        }
        #if !os(macOS)
        // Force decoding now, off the main actor, instead of lazily at first render.
        return await image.byPreparingForDisplay() ?? image
        #else
        return image
        #endif
    }
}
