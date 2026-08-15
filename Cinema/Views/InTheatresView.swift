/*
See the LICENSE.txt file for licensing information.

Abstract:
A Watch Now row of movies currently in theatres, with a detail sheet and trailer.
*/

import SwiftUI

/// A horizontally scrolling row of movies currently in theatres (from TMDB),
/// shown as portrait poster cards. Tapping one opens a detail sheet with the
/// movie's backdrop, overview, and trailer.
struct InTheatresRow: View {
    let movies: [TMDB.Movie]

    @State private var selectedMovie: TMDB.Movie?

    var body: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Constants.cardSpacing) {
                    ForEach(movies) { movie in
                        Button {
                            selectedMovie = movie
                        } label: {
                            TheatrePosterCard(movie: movie)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(movie.title)
                    }
                }
                .padding(.leading, Constants.outerPadding)
            }
            .scrollClipDisabled()
        } header: {
            Text("In Theatres")
                .font(.title3.bold())
                .padding(.vertical, Constants.listTitleVerticalPadding)
                .padding(.leading, Constants.outerPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .sheet(item: $selectedMovie) { movie in
            TheatreMovieSheet(movie: movie)
        }
    }
}

/// A portrait poster card — theatre entries are discovery content, so they look
/// deliberately different from the landscape cards of owned videos.
private struct TheatrePosterCard: View {
    let movie: TMDB.Movie

    var body: some View {
        AsyncImage(url: movie.posterCardURL) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            ZStack {
                Color(white: 0.12)
                Image(systemName: "film")
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .frame(width: Constants.theatrePosterWidth)
        .clipShape(.rect(cornerRadius: Constants.cornerRadius))
        #if os(iOS) || os(visionOS)
        .hoverEffect()
        #endif
    }
}

/// The theatre movie's details: backdrop, metadata, overview, and its trailer,
/// playing inline through the same player the library's trailers use.
private struct TheatreMovieSheet: View {
    @Environment(\.dismiss) private var dismiss

    let movie: TMDB.Movie

    @State private var trailerYouTubeID: String?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Constants.verticalTextSpacing) {
                    AsyncImage(url: movie.backdropURL) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        Color(white: 0.12)
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipped()

                    VStack(alignment: .leading, spacing: Constants.verticalTextSpacing) {
                        Text(movie.title)
                            .font(.title2.bold())

                        if let year = movie.year {
                            Text(String(year))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        if !movie.overview.isEmpty {
                            Text(movie.overview)
                                .font(.body)
                        }

                        if let trailerYouTubeID {
                            Text("Trailer")
                                .font(.headline)
                                .padding(.top, Constants.verticalTextSpacing)

                            InlineTrailerView(youtubeID: trailerYouTubeID)
                                .frame(maxWidth: Constants.trailerHeight)
                        }
                    }
                    .padding(.horizontal, Constants.outerPadding)
                    .padding(.bottom, Constants.outerPadding)
                }
            }
            .ignoresSafeArea(edges: .top)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                trailerYouTubeID = try? await TMDB.trailerYouTubeID(forMovieID: movie.id)
            }
        }
        .preferredColorScheme(.dark)
    }
}

extension Constants {
    /// The width of an In Theatres portrait poster card.
    static var theatrePosterWidth: Double {
        #if os(visionOS)
        180
        #else
        140
        #endif
    }
}
