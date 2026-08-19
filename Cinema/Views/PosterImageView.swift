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
    /// Which of the video's two pictures to show. Defaults to the wide backdrop, so the surfaces
    /// that are always wide — the hero, the detail header — don't have to say so.
    var style: ArtworkStyle = .wide

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
                poster = await PosterImageCache.image(for: video, style: style)
            }
    }

    /// Identifies the load task by video and thumbnail state, so a finished
    /// generation or a changed video triggers a reload.
    private var taskID: String {
        "\(video.uuid)-\(video.hasThumbnail)-\(video.hasPoster)-\(style.rawValue)"
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

/// A show's card and header artwork: the show's own TMDB backdrop when the
/// show is matched, falling back to the cover episode's thumbnail.
struct ShowArtworkView: View {
    /// The show's first episode — the fallback art and the match marker.
    let cover: Video
    var style: ArtworkStyle = .wide

    @State private var artwork: Image?

    var body: some View {
        Group {
            if let artwork {
                Color(white: 0.12)
                    .overlay {
                        artwork
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
            } else {
                PosterImageView(video: cover, style: style)
            }
        }
        .task(id: "\(cover.tmdbShowID ?? 0)-\(style.rawValue)") {
            guard let showID = cover.tmdbShowID else {
                artwork = nil
                return
            }
            let filename = MediaStore.showArtworkFilename(forShowID: showID)
            if style == .poster {
                // A show with no stored poster falls through to its backdrop rather than
                // showing nothing: a library is always part matched and part not.
                if let poster = await PosterImageCache.image(at: MediaStore.posterURL(forFilename: filename)) {
                    artwork = poster
                } else {
                    artwork = await PosterImageCache.image(forThumbnailFilename: filename)
                }
            } else {
                artwork = await PosterImageCache.image(forThumbnailFilename: filename)
            }
        }
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

    /// The video's artwork in the requested shape, falling back to the wide artwork when there's
    /// no poster — an unmatched video only ever has the frame the app took from the file itself,
    /// and showing it in the wrong shape beats showing a grey placeholder.
    static func image(for video: Video, style: ArtworkStyle = .wide) async -> Image? {
        if style == .poster, let posterURL = video.posterURL, let poster = await image(at: posterURL) {
            return poster
        }
        guard let url = video.thumbnailURL else { return nil }
        return await image(at: url)
    }

    /// A thumbnail-directory image by filename — show-level artwork lives
    /// there without belonging to any one video.
    static func image(forThumbnailFilename filename: String) async -> Image? {
        await image(at: MediaStore.thumbnailURL(forFilename: filename))
    }

    static func image(at url: URL) async -> Image? {
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
