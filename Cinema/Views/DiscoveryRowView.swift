/*
See the LICENSE.txt file for licensing information.

Abstract:
A Watch Now row of movies from a TMDB list, with a detail sheet and trailer.
*/

import SwiftUI

/// A horizontally scrolling row of movies from the TMDB list chosen in Settings
/// (in theatres, coming soon, popular…), shown as portrait poster cards. Tapping
/// one opens a detail sheet with the movie's backdrop, overview, and trailer.
struct DiscoveryRow: View {
    let title: String
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
                            DiscoveryPosterCard(movie: movie)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(movie.title)
                    }
                }
                .padding(.leading, Constants.outerPadding)
            }
            .scrollClipDisabled()
        } header: {
            Text(title)
                .font(.title3.bold())
                .padding(.vertical, Constants.listTitleVerticalPadding)
                .padding(.leading, Constants.outerPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .sheet(item: $selectedMovie) { movie in
            DiscoveryMovieSheet(movie: movie)
        }
    }
}

/// A portrait poster card — discovery entries deliberately look different from
/// the landscape cards of owned videos.
private struct DiscoveryPosterCard: View {
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
        .frame(width: Constants.discoveryPosterWidth)
        .clipShape(.rect(cornerRadius: Constants.cornerRadius))
        #if os(iOS) || os(visionOS)
        .hoverEffect()
        #endif
    }
}

/// The discovery movie's details: backdrop, metadata, overview, and its trailer,
/// playing inline through the same player the library's trailers use.
private struct DiscoveryMovieSheet: View {
    @Environment(\.dismiss) private var dismiss

    let movie: TMDB.Movie

    var body: some View {
        NavigationStack {
            MoviePageView(movie: movie)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
                // Filmography taps (via a person's page) push more movie pages.
                .navigationDestination(for: TMDB.Movie.self) { pushed in
                    MoviePageView(movie: pushed)
                }
        }
        .preferredColorScheme(.dark)
    }
}

/// A TMDB movie's full page: backdrop, facts, genres, overview, trailer, and
/// cast. Works as a sheet's root or pushed from a person's filmography.
struct MoviePageView: View {
    let movie: TMDB.Movie

    @State private var trailerYouTubeID: String?
    @State private var moviePage: TMDB.MoviePage?

    var body: some View {
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

                    // The movie's key facts, filled in as the page loads.
                    HStack(alignment: .top, spacing: Constants.outerPadding * 2) {
                        if let year = movie.year {
                            FactView(label: String(localized: "Released"), value: String(year))
                        }
                        if let runtime = moviePage?.formattedRuntime {
                            FactView(label: String(localized: "Runtime"), value: runtime)
                        }
                        if let score = moviePage?.formattedScore {
                            FactView(label: String(localized: "Score"), value: score)
                        }
                    }

                    if let genreNames = moviePage?.genreNames, !genreNames.isEmpty {
                        GenreNamesView(names: genreNames)
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

                if let people = moviePage?.people, !people.isEmpty {
                    CastRow(people: people)
                        .padding(.top, Constants.verticalTextSpacing)
                }
            }
            .padding(.bottom, Constants.outerPadding)
        }
        .ignoresSafeArea(edges: .top)
        .toolbarBackground(.hidden)
        .task(id: movie.id) {
            async let trailer = TMDB.trailerYouTubeID(forMovieID: movie.id)
            async let page = TMDB.moviePage(forMovieID: movie.id)
            trailerYouTubeID = try? await trailer
            moviePage = try? await page
        }
    }
}

extension Constants {
    /// The width of a discovery-row portrait poster card.
    static var discoveryPosterWidth: Double {
        #if os(visionOS)
        180
        #else
        140
        #endif
    }
}
