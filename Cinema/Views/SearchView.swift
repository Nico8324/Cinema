/*
See the LICENSE.txt file for licensing information.

Abstract:
A view that searches the library by title and genre.
*/

import SwiftUI
import SwiftData

/// A view that searches the library by title and genre.
struct SearchView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Query(sort: \Video.name)
    private var videos: [Video]

    @Query private var shows: [Show]

    @Namespace private var namespace

    @State private var navigationPath = [NavigationNode]()
    @State private var searchText = ""

    /// One search result: a movie card, or a whole show collapsed into one card.
    ///
    /// Shows collapse here for the same reason they do in the Library: a matched ten-episode
    /// season used to render as ten near-identical cards all named the show's title, none of
    /// which led to the show's page.
    private enum SearchResult: Identifiable {
        case movie(Video)
        case show(name: String, title: String, episodes: [Video])

        var id: String {
            switch self {
            case .movie(let video): video.uuid.uuidString
            case .show(let name, _, _): "show-\(Show.key(for: name))"
            }
        }
    }

    private var results: [SearchResult] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let matches = videos.filter { video in
            video.name.localizedCaseInsensitiveContains(query)
                // An episode is findable by its own title too — "The Engineer" is a real name
                // the show page displays, and a search that can't find it is lying by omission.
                || video.episodeTitle?.localizedCaseInsensitiveContains(query) == true
                || video.showName?.localizedCaseInsensitiveContains(query) == true
                || video.genres.contains { $0.localizedName.localizedCaseInsensitiveContains(query) }
        }
        let showsByKey = Dictionary(grouping: shows, by: \.sortKey)
        let movies: [SearchResult] = matches.filter { !$0.isEpisode }.map(SearchResult.movie)
        let grouped: [SearchResult] = Dictionary(grouping: matches.filter(\.isEpisode)) {
            Show.key(for: $0.showName ?? "")
        }.map { key, episodes in
            let name = episodes.first?.showName ?? ""
            let title = showsByKey[key]?.first?.name ?? episodes.first?.name ?? name
            return SearchResult.show(name: name, title: title, episodes: episodes.sorted {
                ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0) < ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0)
            })
        }
        return movies + grouped
    }

    // Adapt the number of columns based on platform and size class.
    private var columns: [GridItem] {
        let gridItem = GridItem(.flexible(), spacing: Constants.cardSpacing)
        let count = horizontalSizeClass == .compact ? Constants.libraryColumnCountCompact : Constants.libraryColumnCount
        return [GridItem](repeating: gridItem, count: count)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if videos.isEmpty {
                    ContentUnavailableView(
                        "Your Library Is Empty",
                        systemImage: "film.stack",
                        description: Text("Add videos to your library to search them.")
                    )
                } else if searchText.isEmpty {
                    ContentUnavailableView(
                        "Search Your Library",
                        systemImage: "magnifyingglass",
                        description: Text("Find videos by title or genre.")
                    )
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVGrid(columns: columns, spacing: Constants.cardSpacing) {
                            ForEach(results) { result in
                                switch result {
                                case .movie(let video):
                                    NavigationLink(value: NavigationNode.video(video.id)) {
                                        VideoCardView(video: video, style: .grid)
                                    }
                                    .transitionSource(id: video.id, namespace: namespace)
                                    .accessibilityLabel(video.name)
                                    .buttonStyle(.plain)

                                case .show(let name, let title, let episodes):
                                    NavigationLink(value: NavigationNode.show(name)) {
                                        ShowCardView(name: title, episodes: episodes)
                                    }
                                    .accessibilityLabel(title)
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(Constants.outerPadding)
                    }
                    .scrollClipDisabled()
                }
            }
            .navigationTitle("Search")
            .navigationDestinationVideo(in: namespace)
        }
        .searchable(text: $searchText, prompt: Text("Titles and genres"))
    }
}

#Preview(traits: .previewData) {
    SearchView()
}
