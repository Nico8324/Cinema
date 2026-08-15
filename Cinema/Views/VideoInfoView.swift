/*
See the LICENSE.txt file for licensing information.

Abstract:
A view that displays information about a video including its title, description, and genre.
*/
import SwiftUI
import SwiftData

/// A view that displays information about a video including its title, description, and genre.
struct InfoView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    let video: Video

    var body: some View {
        VStack(alignment: .leading) {
            Text("\(video.formattedYearOfRelease) | \(video.contentRating) | \(video.formattedDuration)",
                 comment: "Release Year | Rating | Duration")
                #if os(tvOS)
                .font(.caption)
                #else
                .font(isCompact ? .caption : .headline)
                #endif
                .foregroundStyle(.secondary)

            Text(video.displayName)
                .font(isCompact ? .body : .title3)

            Text(video.synopsis)
                .font(isCompact ? .caption : .body)
                .lineLimit(2, reservesSpace: true)

            // Cards have a fixed width and genre lists come from real metadata —
            // show only as many pills as actually fit.
            ViewThatFits(in: .horizontal) {
                GenreView(genres: video.genres)
                GenreView(genres: Array(video.genres.prefix(2)))
                GenreView(genres: Array(video.genres.prefix(1)))
                Color.clear.frame(height: 1)
            }
        }
        .padding(Constants.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A view that displays a list of genres for a video.
struct GenreView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    let genres: [Genre]

    var body: some View {
        HStack(spacing: Constants.genreSpacing) {
            ForEach(genres) {
                Text($0.localizedName)
                    .fixedSize()
                    .font(isCompact ? .caption2 : .caption)
                    .padding(.horizontal, Constants.genreHorizontalPadding)
                    .padding(.vertical, Constants.genreVerticalPadding)
                    .background(Capsule().stroke())
            }
        }
    }
}

/// A view that displays a the video poster image with its title..
struct PosterCard: View {
    let video: Video
    let title: String
    /// Fraction watched (0...1). When provided, overlays a "Continue Watching"-style progress bar on the poster.
    var progress: Double? = nil

    var body: some View {
        VStack {
            ZStack(alignment: .bottom) {
                PosterImageView(video: video)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .cornerRadius(Constants.cornerRadius)

                if let progress {
                    WatchProgressBar(progress: progress)
                        .padding(6)
                }
            }

            Text(title)
            #if os(visionOS)
                .font(.title3)
            #else
                .font(.body)
            #endif
                .lineLimit(1)
        }
    }
}

/// A thin capsule progress indicator, matching the "Continue Watching" convention used across Apple's own apps.
private struct WatchProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.35))
                Capsule().fill(.white).frame(width: proxy.size.width * progress)
            }
        }
        .frame(height: 4)
    }
}

#Preview(traits: .previewData) {
    @Previewable @Query(sort: \Video.name) var videos: [Video]
    return Group {
        if let video = videos.first {
            InfoView(video: video)
                .frame(width: Constants.videoCardWidth)
        }
    }
}
