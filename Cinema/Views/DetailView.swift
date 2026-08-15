/*
See the LICENSE.txt file for licensing information.

Abstract:
A view that presents the video content details.
*/

import SwiftUI
import SwiftData

/// A view that presents the video content details.
struct DetailView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(PlayerModel.self) private var player
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    // `Video` is an observable model class — a plain `let` still drives updates.
    let video: Video

    @State private var viewSize: CGSize = CGSize(width: 0, height: 0)
    @State private var isConfirmingDelete = false
    @State private var isEditing = false
    @State private var isMatchingMetadata = false

    /// The TMDB movie page (cast, runtime, score) for matched videos, fetched live.
    @State private var moviePage: TMDB.MoviePage?

    private var playButtonTitle: LocalizedStringKey {
        switch (video.isEpisode, video.isPartiallyWatched) {
        case (true, true): "Resume Episode"
        case (true, false): "Play Episode"
        case (false, true): "Resume Movie"
        case (false, false): "Play Movie"
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack {
                VStack(alignment: .leading, spacing: Constants.verticalTextSpacing) {
                    // Matched episodes lead with their own title, show name above.
                    if video.isEpisode, video.episodeTitle != nil {
                        Text(video.name)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }

                    Text(video.episodeTitle ?? video.name)
                        .font(isCompact ? .title : .largeTitle)
                        .bold()

                    Text(
                        ([video.episodeLabel, video.formattedYearOfRelease, video.contentRating, video.formattedDuration]
                            .compactMap { $0 })
                            .joined(separator: " | ")
                    )
                    .font(.headline)
                    .accessibilityLabel("""
                                        \(video.episodeLabel ?? "") Released \(video.formattedYearOfRelease), \
                                        rated \(video.contentRating), \(video.accessibleDuration)
                                        """)

                    GenreView(genres: video.genres)

                    Text(video.synopsis)
                        .multilineTextAlignment(.leading)
                        .font(isCompact ? .body : .headline)
                        .fontWeight(.semibold)

                    HStack {
                        // A button that plays the video in a full-window presentation.
                        Button {
                            /// Load the media item for full-window presentation.
                            player.loadVideo(video, presentation: .fullWindow)
                        } label: {
                            // Episodes get episode wording; the movie labels stay for movies.
                            Label(playButtonTitle, systemImage: "play.fill")
                        }
                        // A button that toggles whether the video is in the Up Next queue.
                        Button {
                            video.toggleUpNext(in: context)
                        } label: {
                            let isQueued = video.upNextItem != nil
                            Label(isQueued ? "In Up Next" : "Add to Up Next",
                                  systemImage: isQueued ? "checkmark" : "plus")
                        }

                        Spacer()

                    }
                    .buttonStyle(CustomButtonStyle())
                    // Make the buttons the same width.
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)

                }
                .padding(isCompact ? Constants.detailCompactPadding : Constants.detailPadding)
                .padding(.bottom, isCompact ? Constants.detailCompactPadding : 0)
                .padding(.trailing, isCompact ? 0 : Constants.detailTrailingPadding)
                .frame(height: viewSize.height, alignment: .bottom)
                .background(alignment: .bottom) { backgroundView }

                // The movie's trailer, when a TMDB match provided one. Plays inline,
                // in place, with system controls (including expand-to-full-screen).
                if let trailerYouTubeID = video.trailerYouTubeID {
                    VStack(alignment: .leading, spacing: Constants.verticalTextSpacing) {
                        Text("Trailer")
                            .font(.headline)

                        InlineTrailerView(youtubeID: trailerYouTubeID)
                            .frame(maxWidth: Constants.trailerHeight)
                    }
                    .padding(isCompact ? Constants.detailCompactPadding : Constants.detailPadding)
                    .padding(.bottom, isCompact ? Constants.detailCompactPadding : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Cast, crew, and movie facts from TMDB, for matched videos.
                if let moviePage {
                    if !moviePage.people.isEmpty {
                        CastRow(
                            people: moviePage.people,
                            horizontalPadding: isCompact ? Constants.detailCompactPadding : Constants.detailPadding
                        )
                        .padding(.bottom, isCompact ? Constants.detailCompactPadding : 0)
                    }
                    InformationSection(video: video, page: moviePage, isCompact: isCompact)
                }
            }
            #if os(iOS)
            .background(.black)
            #endif
        }
        .scrollClipDisabled()
        .padding(.top, isCompact ? -Constants.compactDetailSafeAreaHeight : -Constants.detailSafeAreaHeight)
        .onGeometryChange(for: CGSize.self) { proxy in
            return proxy.size
        } action: { size in
            let heightPadding = (isCompact ? Constants.compactDetailSafeAreaHeight : Constants.detailSafeAreaHeight)
            let widthPadding = Constants.extendSafeAreaTV
            viewSize = CGSize(width: size.width + widthPadding, height: size.height + heightPadding)
        }
        // Don't show a navigation title in iOS.
        .navigationTitle("")
        .toolbarBackground(.hidden)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Edit Video", systemImage: "pencil") {
                        isEditing = true
                    }
                    // Movie matching would attach the wrong metadata to a TV
                    // episode — TMDB's TV endpoints are a separate milestone.
                    if !video.isEpisode {
                        Button("Match Metadata", systemImage: "sparkles.rectangle.stack") {
                            isMatchingMetadata = true
                        }
                    }
                    Button("Delete Video", systemImage: "trash", role: .destructive) {
                        isConfirmingDelete = true
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                // A centered alert — the standard treatment for a destructive,
                // irreversible confirmation, with no popover anchoring quirks.
                .alert(
                    "Delete “\(video.name)”?",
                    isPresented: $isConfirmingDelete
                ) {
                    Button("Delete Video", role: .destructive) {
                        deleteVideo()
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This can’t be undone.")
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            EditVideoView(video: video)
        }
        .sheet(isPresented: $isMatchingMetadata) {
            TMDBSearchView(video: video)
        }
        .task(id: video.tmdbID) {
            guard let tmdbID = video.tmdbID else {
                moviePage = nil
                return
            }
            moviePage = try? await TMDB.moviePage(forMovieID: tmdbID)
        }
    }

    /// Dismisses first, then deletes the video (including the locally imported file and
    /// thumbnail backing it) on the next run-loop cycle — deleting a model this view still
    /// displays mid-dismissal risks faulting a deleted object during the transition.
    private func deleteVideo() {
        dismiss()
        Task {
            video.removeLocalFiles()
            context.delete(video)
            Genre.deleteOrphaned(in: context)
            context.saveReportingErrors()
        }
    }

    private var backgroundView: some View {
        Group {
            PosterImageView(video: video)
                .frame(width: viewSize.width, height: viewSize.height)
                .accessibilityHidden(true)

            // Add a subtle gradient to make the text stand out.
            #if os(iOS)
            GradientView(style: .black.opacity(0.6), direction: .horizontal, width: Constants.gradientSize, startPoint: .leading)
            GradientView(style: .black, height: Constants.gradientSize, startPoint: .bottom)
            #else
            GradientView(style: .black.opacity(0.4), direction: .horizontal, width: Constants.gradientSize, startPoint: .leading)
            GradientView(style: .black.opacity(0.5), height: Constants.gradientSize, startPoint: .bottom)
            #endif
        }
        .padding([.horizontal, .bottom], -Constants.extendSafeAreaTV)
    }
}

/// Movie facts — released, runtime, rating, score — in the TV-app's
/// label-over-value style.
private struct InformationSection: View {
    let video: Video
    let page: TMDB.MoviePage
    let isCompact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.verticalTextSpacing) {
            Text("Information")
                .font(.headline)

            HStack(alignment: .top, spacing: Constants.outerPadding * 2) {
                FactView(label: String(localized: "Released"), value: video.formattedYearOfRelease)

                if let runtime = page.formattedRuntime {
                    FactView(label: String(localized: "Runtime"), value: runtime)
                }

                FactView(label: String(localized: "Rated"), value: video.contentRating)

                if let score = page.formattedScore {
                    FactView(label: String(localized: "Score"), value: score)
                }
            }
        }
        .padding(isCompact ? Constants.detailCompactPadding : Constants.detailPadding)
        .padding(.bottom, isCompact ? Constants.detailCompactPadding : Constants.detailPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview(traits: .previewData) {
    @Previewable @Query(sort: \Video.name) var videos: [Video]
    return Group {
        if let video = videos.first {
            DetailView(video: video)
        }
    }
}
