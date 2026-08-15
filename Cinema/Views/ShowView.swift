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
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.8)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                        .overlay(alignment: .bottomLeading) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(showName)
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
            }
            .padding(.bottom, Constants.outerPadding)
        }
        .navigationTitle("")
        .toolbarBackground(.hidden)
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
                Text("Episode \(episode.episodeNumber ?? 1)")
                    .font(.headline)
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
