/*
See the LICENSE.txt file for licensing information.

Abstract:
A Watch Now row of TV shows from a TMDB list, with a detail sheet and trailer.
*/

import SwiftUI
import SwiftData

/// A horizontally scrolling row of TV shows from the TMDB list chosen in
/// Settings (airing today, popular…), shown as portrait poster cards. Tapping
/// one opens a detail sheet — the library's own show page when the show is owned.
struct TVDiscoveryRow: View {
    let title: String
    let shows: [TMDB.Show]

    @Query(filter: #Predicate<Video> { $0.tmdbShowID != nil })
    private var matchedEpisodes: [Video]

    @State private var selectedShow: TMDB.Show?

    var body: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Constants.cardSpacing) {
                    ForEach(shows) { show in
                        Button {
                            selectedShow = show
                        } label: {
                            DiscoveryShowPosterCard(show: show)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(show.name)
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
        .sheet(item: $selectedShow) { show in
            // A discovery show the user already owns opens as their library's
            // show page, episodes ready to play — not as a read-only TMDB page.
            if let owned = matchedEpisodes.first(where: { $0.tmdbShowID == show.id }),
               let showName = owned.showName {
                OwnedShowSheet(showName: showName)
            } else {
                DiscoveryShowSheet(show: show)
            }
        }
    }
}

/// The library's show page presented as a sheet, with episode playback support.
private struct OwnedShowSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Namespace private var namespace

    let showName: String

    var body: some View {
        NavigationStack {
            ShowView(showName: showName)
                // Episode rows push the library's episode pages.
                .navigationDestinationVideo(in: namespace)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
        }
        // Steps aside when playback starts; the app's root presents the player.
        .dismissesForFullWindowPlayback()
        .appAppearance()
    }
}

/// A portrait poster card — discovery entries deliberately look different from
/// the landscape cards of owned videos.
private struct DiscoveryShowPosterCard: View {
    let show: TMDB.Show

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(ArtworkStyle.storageKey) private var artworkStyle: ArtworkStyle = .wide

    /// Matches the library's own cards when they're posters too, so the rows line up; keeps its
    /// own smaller size in wide mode, where being visibly different is the point.
    private var posterWidth: Double {
        artworkStyle == .poster
            ? artworkStyle.cardWidth(isCompact: horizontalSizeClass == .compact)
            : Constants.discoveryPosterWidth
    }

    var body: some View {
        AsyncImage(url: show.posterCardURL) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            ZStack {
                Color(white: 0.12)
                Image(systemName: "tv")
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .frame(width: posterWidth)
        .clipShape(.rect(cornerRadius: Constants.cornerRadius))
        #if os(iOS) || os(visionOS)
        .hoverEffect()
        #endif
    }
}

/// The discovery show's details: backdrop, metadata, overview, and its trailer,
/// playing inline through the same player the library's trailers use.
private struct DiscoveryShowSheet: View {
    @Environment(\.dismiss) private var dismiss

    let show: TMDB.Show

    var body: some View {
        NavigationStack {
            ShowPageView(show: show)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
                // Filmography taps (via a person's page) push more movie pages;
                // owned movies push the library's own page.
                .navigationDestination(for: TMDB.Movie.self) { pushed in
                    MoviePageView(movie: pushed)
                }
                .navigationDestination(for: Video.self) { video in
                    DetailView(video: video)
                }
        }
        // Steps aside when playback starts; the app's root presents the player.
        .dismissesForFullWindowPlayback()
        .appAppearance()
    }
}

/// A TMDB show's full page: backdrop, facts, genres, overview, trailer, and
/// cast — the TV counterpart of `MoviePageView`.
struct ShowPageView: View {
    let show: TMDB.Show

    @State private var showPage: TMDB.ShowPage?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Constants.verticalTextSpacing) {
                AsyncImage(url: show.backdropURL) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Color(white: 0.12)
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipped()

                VStack(alignment: .leading, spacing: Constants.verticalTextSpacing) {
                    Text(show.name)
                        .font(.title2.bold())

                    // The show's key facts, filled in as the page loads.
                    HStack(alignment: .top, spacing: Constants.outerPadding * 2) {
                        if let year = show.year {
                            FactView(label: String(localized: "First Aired"), value: String(year))
                        }
                        if let seasonCount = showPage?.numberOfSeasons {
                            FactView(label: String(localized: "Seasons"), value: String(seasonCount))
                        }
                        if let rating = showPage?.usRating, !rating.isEmpty {
                            FactView(label: String(localized: "Rated"), value: rating)
                        }
                        if let score = showPage?.formattedScore {
                            FactView(label: String(localized: "Score"), value: score)
                        }
                    }

                    if let genreNames = showPage?.genreNames, !genreNames.isEmpty {
                        GenreNamesView(names: genreNames)
                    }

                    if !show.overview.isEmpty {
                        Text(show.overview)
                            .font(.body)
                    }

                    if let trailerYouTubeID = showPage?.trailerYouTubeID {
                        Text("Trailer")
                            .font(.headline)
                            .padding(.top, Constants.verticalTextSpacing)

                        InlineTrailerView(youtubeID: trailerYouTubeID)
                            .frame(maxWidth: Constants.trailerHeight)
                    }
                }
                .padding(.horizontal, Constants.outerPadding)

                if let people = showPage?.people, !people.isEmpty {
                    CastRow(people: people)
                        .padding(.top, Constants.verticalTextSpacing)
                }
            }
            .padding(.bottom, Constants.outerPadding)
        }
        .ignoresSafeArea(edges: .top)
        .toolbarBackground(.hidden)
        .task(id: show.id) {
            showPage = try? await TMDB.showPage(forShowID: show.id)
        }
    }
}
