/*
See the LICENSE.txt file for licensing information.

Abstract:
A TV show's page: its episodes grouped by season.
*/

import SwiftUI
import SwiftData

/// A TV show's page: poster header and episodes grouped by season.
struct ShowView: View {
    let showName: String

    @Query private var episodes: [Video]

    @State private var isMatchingShow = false

    /// The TMDB show page (overview, cast, score) for matched shows, fetched live.
    @State private var showPage: TMDB.ShowPage?

    init(showName: String) {
        self.showName = showName
        self._episodes = Query(
            filter: #Predicate<Video> { $0.showName == showName },
            sort: [SortDescriptor(\Video.seasonNumber), SortDescriptor(\Video.episodeNumber)]
        )
    }

    /// Season numbers in order; episodes without a parsed season fall under 1.
    private var seasons: [(number: Int, episodes: [Video])] {
        Dictionary(grouping: episodes) { $0.seasonNumber ?? 1 }
            .sorted { $0.key < $1.key }
            .map { (number: $0.key, episodes: $0.value) }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Constants.verticalTextSpacing) {
                if let cover = episodes.first {
                    PosterImageView(video: cover)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay(alignment: .bottomLeading) {
                            // Background-colored scrim: black in dark mode,
                            // white in light — the title stays legible in both.
                            LinearGradient(
                                colors: [.clear, Color(.systemBackground).opacity(0.8)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                        .overlay(alignment: .bottomLeading) {
                            VStack(alignment: .leading, spacing: 2) {
                                // The official title once matched; the grouping key before.
                                Text(episodes.first?.name ?? showName)
                                    .font(.title.bold())
                                Text(episodes.count == 1
                                     ? String(localized: "1 episode")
                                     : String(localized: "\(episodes.count) episodes"))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(Constants.outerPadding)
                        }
                        .accessibilityHidden(true)
                }

                // The show's facts, genres, and overview, once matched with TMDB.
                if let showPage {
                    VStack(alignment: .leading, spacing: Constants.verticalTextSpacing) {
                        HStack(alignment: .top, spacing: Constants.outerPadding * 2) {
                            if let year = showPage.firstAirYear {
                                FactView(label: String(localized: "First Aired"), value: String(year))
                            }
                            if let seasonCount = showPage.numberOfSeasons {
                                FactView(label: String(localized: "Seasons"), value: String(seasonCount))
                            }
                            if let rating = showPage.usRating, !rating.isEmpty {
                                FactView(label: String(localized: "Rated"), value: rating)
                            }
                            if let score = showPage.formattedScore {
                                FactView(label: String(localized: "Score"), value: score)
                            }
                        }

                        if !showPage.genreNames.isEmpty {
                            GenreNamesView(names: showPage.genreNames)
                        }

                        if let overview = showPage.overview, !overview.isEmpty {
                            Text(overview)
                                .font(.body)
                        }

                        if let trailerYouTubeID = episodes.first?.trailerYouTubeID {
                            Text("Trailer")
                                .font(.headline)
                                .padding(.top, Constants.verticalTextSpacing)

                            InlineTrailerView(youtubeID: trailerYouTubeID)
                                .frame(maxWidth: Constants.trailerHeight)
                        }
                    }
                    .padding(.horizontal, Constants.outerPadding)
                }

                ForEach(seasons, id: \.number) { season in
                    VStack(alignment: .leading, spacing: Constants.cardSpacing) {
                        Text("Season \(season.number)")
                            .font(.headline)

                        ForEach(season.episodes) { episode in
                            NavigationLink(value: NavigationNode.video(episode.id)) {
                                EpisodeRow(episode: episode)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Constants.outerPadding)
                    .padding(.top, Constants.verticalTextSpacing)
                }

                if let people = showPage?.people, !people.isEmpty {
                    CastRow(people: people)
                        .padding(.top, Constants.verticalTextSpacing)
                }
            }
            .padding(.bottom, Constants.outerPadding)
        }
        .navigationTitle("")
        .toolbarBackground(.hidden)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Match Show", systemImage: "sparkles.tv") {
                        isMatchingShow = true
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $isMatchingShow) {
            TMDBShowSearchView(showName: showName, episodes: episodes)
        }
        .task(id: episodes.first?.tmdbShowID) {
            guard let showID = episodes.first?.tmdbShowID else {
                showPage = nil
                return
            }
            showPage = try? await TMDB.showPage(forShowID: showID)
        }
    }
}

/// One episode: thumbnail with watch progress, number, and duration.
private struct EpisodeRow: View {
    let episode: Video

    var body: some View {
        HStack(spacing: 12) {
            PosterImageView(video: episode)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(width: 120)
                .overlay(alignment: .bottom) {
                    if episode.isPartiallyWatched {
                        ProgressView(value: episode.playbackProgress)
                            .tint(.white)
                            .padding(.horizontal, 6)
                            .padding(.bottom, 4)
                    }
                }
                .clipShape(.rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                // "3. The Engineer" once matched; plain numbering before.
                if let title = episode.episodeTitle, !title.isEmpty {
                    Text("\(episode.episodeNumber ?? 1). \(title)")
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                } else {
                    Text("Episode \(episode.episodeNumber ?? 1)")
                        .font(.headline)
                }
                if episode.duration > 0 {
                    Text(episode.formattedDuration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

#Preview(traits: .previewData) {
    NavigationStack {
        ShowView(showName: "Neuromancer")
    }
}
