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

    @Namespace private var namespace

    @State private var navigationPath = [NavigationNode]()
    @State private var searchText = ""

    private var results: [Video] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return videos.filter { video in
            video.name.localizedCaseInsensitiveContains(query)
                || video.genres.contains { $0.localizedName.localizedCaseInsensitiveContains(query) }
        }
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
                            ForEach(results) { video in
                                NavigationLink(value: NavigationNode.video(video.id)) {
                                    VideoCardView(video: video, style: .grid)
                                }
                                .transitionSource(id: video.id, namespace: namespace)
                                .accessibilityLabel(video.name)
                                .buttonStyle(.plain)
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
