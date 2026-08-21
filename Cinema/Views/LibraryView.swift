/*
See the LICENSE.txt file for licensing information.

Abstract:
A view that displays the list of videos the library contains in a grid.
*/

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// A view that displays the list of videos the library contains in a grid.
struct LibraryView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var context

    @Query(sort: \Video.name)
    private var allVideos: [Video]

    @Query(sort: \Genre.name)
    private var genres: [Genre]

    /// The series rows, for card titles: a show's card is named by its own row — the name a
    /// TMDB match maintains — not by whichever episode happens to sort first.
    @Query private var shows: [Show]

    @Namespace private var namespace

    @AppStorage(ArtworkStyle.storageKey) private var artworkStyle: ArtworkStyle = .wide

    /// Which slice of the library the grid shows: movies or shows.
    enum LibraryFilter: String, CaseIterable, Identifiable {
        case movies
        case shows

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .movies: String(localized: "Movies")
            case .shows: String(localized: "TV Shows")
            }
        }
    }

    /// Opens the grid on a particular slice. macOS picks the slice in the sidebar, the way the
    /// TV app does, rather than with the in-content segmented control.
    init(filter: LibraryFilter = .movies) {
        _filter = State(initialValue: filter)
    }

    @State private var navigationPath = [NavigationNode]()
    @State private var filter: LibraryFilter
    @State private var selectedGenre: Genre?
    @State private var isPickingFile = false
    @State private var isAddingYouTubeVideo = false
    @State private var importErrorMessage: String?
    @State private var importProgress = ImportProgress()

    // Adapt the number columns based on platform and size class.
    private var columns: [GridItem] {
        let gridItem = GridItem(.flexible(), spacing: Constants.cardSpacing)
        let base = horizontalSizeClass == .compact ? Constants.libraryColumnCountCompact : Constants.libraryColumnCount
        // Posters are narrower than backdrops, so the same grid fits more of them per row.
        return [GridItem](repeating: gridItem, count: base + artworkStyle.extraGridColumns)
    }

    /// One grid cell: a movie, or a whole show collapsed into a single card.
    private enum LibraryItem: Identifiable {
        case movie(Video)
        /// `name` is a raw grouping name (a spelling some filename used), which is what
        /// navigation keys on; `title` is what the card shows — the Show row's own name,
        /// which is the one a TMDB match is allowed to change.
        case show(name: String, title: String, episodes: [Video])

        var id: String {
            switch self {
            case .movie(let video): video.uuid.uuidString
            case .show(let name, _, _): "show-\(Show.key(for: name))"
            }
        }

        var sortKey: String {
            switch self {
            case .movie(let video): video.name
            case .show(_, let title, _): title
            }
        }
    }

    /// The grid's cards for the selected type — movies, or shows with a show's
    /// episodes grouped into one card — sorted alphabetically.
    ///
    /// Shows group by `Show.key`, not by the raw string: `Suits` and `suits.` are one series
    /// and must be one card, which is the entire reason the insensitive key exists. Grouping by
    /// the raw name put the split the model had already healed straight back on screen.
    private var libraryItems: [LibraryItem] {
        let videos = selectedGenre?.videos ?? allVideos
        let showsByKey = Dictionary(grouping: shows, by: \.sortKey)
        let items: [LibraryItem] = switch filter {
        case .movies:
            videos.filter { !$0.isEpisode }.map(LibraryItem.movie)
        case .shows:
            Dictionary(grouping: videos.filter(\.isEpisode)) { Show.key(for: $0.showName ?? "") }
                .map { key, episodes in
                    let name = episodes.first?.showName ?? ""
                    let title = showsByKey[key]?.first?.name ?? episodes.first?.name ?? name
                    return LibraryItem.show(name: name, title: title, episodes: episodes.sorted {
                        ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0) < ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0)
                    })
                }
        }
        return items.sorted { $0.sortKey.localizedStandardCompare($1.sortKey) == .orderedAscending }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if allVideos.isEmpty {
                    ContentUnavailableView(
                        "Your Library Is Empty",
                        systemImage: "film.stack",
                        description: Text("Videos you add to your library will appear here.")
                    )
                } else {
                    // Wrap the content in a vertically scrolling view.
                    ScrollView(showsIndicators: false) {
                        VStack {
                            // Wrap the content in a horizontally scrolling view.
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    Button("All") {
                                        selectedGenre = nil
                                    }
                                    .buttonStyle(PickerButtonStyle(isSelected: selectedGenre == nil))

                                    ForEach(genres) { genre in
                                        Button(genre.localizedName) {
                                            selectedGenre = genre
                                        }
                                        .buttonStyle(PickerButtonStyle(isSelected: selectedGenre == genre))
                                    }
                                }
                            }
                            .defaultScrollAnchor(.center)
                            .scrollClipDisabled()
                            .padding(.bottom)

                            if libraryItems.isEmpty {
                                // Only reachable when the toolbar filter (or a
                                // genre pill) leaves nothing to show.
                                ContentUnavailableView(
                                    filter == .shows ? String(localized: "No TV Shows") : String(localized: "No Movies"),
                                    systemImage: filter == .shows ? "tv" : "film",
                                    description: Text("Nothing in your library matches this filter.")
                                )
                                .padding(.top, Constants.outerPadding * 4)
                            }

                            LazyVGrid(columns: columns, spacing: Constants.cardSpacing) {
                                ForEach(libraryItems) { item in
                                    switch item {
                                    case .movie(let video):
                                        NavigationLink(value: NavigationNode.video(video.id)) {
                                            VideoCardView(video: video, style: .grid)
                                        }
                                        .transitionSource(id: video.id, namespace: namespace)
                                        .accessibilityLabel(video.name)
                                        .buttonStyle(.plain)

                                    case .show(let name, let title, let episodes):
                                        NavigationLink(value: NavigationNode.show(name)) {
                                            ShowCardView(name: title, episodes: episodes,
                                                     style: artworkStyle)
                                        }
                                        .accessibilityLabel(title)
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .navigationDestinationVideo(in: namespace)
                        .padding(Constants.outerPadding)
                    }
                    .scrollClipDisabled()
                }
            }
            // No title — the filter is the bar's content. Inline mode keeps the
            // grid from leaving a large-title gap under the toolbar.
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                // On macOS the sidebar already names the slice, so an in-content picker would
                // say the same thing twice.
                #if !os(macOS)
                ToolbarItem(placement: .principal) {
                    Picker("Category", selection: $filter) {
                        ForEach(LibraryFilter.allCases) { filter in
                            Text(filter.displayName).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                #endif
                ToolbarItem(placement: .primaryAction) {
                    // While an import runs, the add button becomes a progress ring.
                    // Both states live inside button chrome so they share the same
                    // circular toolbar treatment; the ring state just doesn't act.
                    if let fraction = importProgress.fraction {
                        Button {} label: {
                            ImportProgressRing(fraction: fraction)
                        }
                    } else {
                        Menu {
                            // tvOS has no document browser to pick local files from, so adding
                            // by link is the only route there.
                            #if !os(tvOS)
                            Button {
                                isPickingFile = true
                            } label: {
                                Label("Choose Files", systemImage: "folder")
                            }
                            #endif
                            Button {
                                isAddingYouTubeVideo = true
                            } label: {
                                Label("From YouTube Link", systemImage: "link")
                            }
                        } label: {
                            Label("Add Video", systemImage: "plus")
                        }
                    }
                }
            }
            #if !os(tvOS)
            .fileImporter(
                isPresented: $isPickingFile,
                allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie],
                allowsMultipleSelection: true,
                onCompletion: handlePickedFiles
            )
            #endif
            .sheet(isPresented: $isAddingYouTubeVideo) {
                AddYouTubeVideoView()
            }
            .alert(
                "Couldn’t Add Video",
                isPresented: .init(
                    get: { importErrorMessage != nil },
                    set: { isPresented in if !isPresented { importErrorMessage = nil } }
                ),
                presenting: importErrorMessage
            ) { _ in
                Button("OK") { }
            } message: { message in
                Text(message)
            }
        }
    }

    private func handlePickedFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importErrorMessage = error.localizedDescription

        case .success(let sourceURLs):
            importProgress.begin()
            Task {
                let importStart = ContinuousClock.now
                // The copy and duration probe run off the main actor; only the
                // model inserts and thumbnail bookkeeping happen back here.
                let progress = importProgress
                let outcome = await VideoImporter.importFiles(from: sourceURLs) { fraction in
                    Task { @MainActor in
                        progress.update(to: fraction)
                    }
                }
                let newVideos = VideoImporter.addVideos(for: outcome.imported, to: context)
                for video in newVideos {
                    VideoImporter.generateThumbnail(for: video, in: context)
                }
                // Picked files get the same automatic matching as scanned ones — the two routes
                // put identical entries in the library, so they should learn identical metadata.
                await MetadataAutoMatch.match(newVideos, in: context)
                // Small files copy in milliseconds; hold the full ring briefly so the
                // progress indicator reads as a state, not a glitch.
                let minimumRingTime: Duration = .milliseconds(750)
                let elapsed = ContinuousClock.now - importStart
                if elapsed < minimumRingTime {
                    try? await Task.sleep(for: minimumRingTime - elapsed)
                }
                importProgress.end()

                var messages = outcome.failures
                if !outcome.duplicateFilenames.isEmpty {
                    let names = outcome.duplicateFilenames.map { filename in
                        allVideos.first { $0.localFilename == filename }?.name ?? String(localized: "a video")
                    }
                    messages.append(String(localized: "Already in your library: \(names.formatted())"))
                }
                if !messages.isEmpty {
                    importErrorMessage = messages.joined(separator: "\n")
                }
            }
        }
    }
}

/// A grid card for a whole show: the first episode's art with an episode-count
/// badge, in the same visual language as the movie cards.
// Internal rather than private: Search collapses a show's episodes into this same card, and a
// second hand-rolled show card would drift from this one the first time either changes.
struct ShowCardView: View {
    let name: String
    let episodes: [Video]
    var style: ArtworkStyle = .wide

    var body: some View {
        VStack {
            ZStack(alignment: .topTrailing) {
                if let cover = episodes.first {
                    // The show's own backdrop once matched; episode art before.
                    ShowArtworkView(cover: cover, style: style)
                        .aspectRatio(style.aspectRatio, contentMode: .fit)
                        .cornerRadius(Constants.cornerRadius)
                }

                Text("\(episodes.count)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
                    .padding(6)
                    .accessibilityLabel(episodes.count == 1
                                        ? String(localized: "1 episode")
                                        : String(localized: "\(episodes.count) episodes"))
            }

            Text(name)
                .font(.body)
                .lineLimit(1)
        }
        #if os(iOS) || os(visionOS)
        .hoverEffect()
        #endif
    }
}

/// A determinate progress ring in the App Store download style — a faint circular
/// track with the tint-colored arc filling clockwise from 12 o'clock — replacing
/// the add button's icon while files copy in.
private struct ImportProgressRing: View {
    let fraction: Double

    private static let lineWidth: CGFloat = 2.25

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: Self.lineWidth)
            Circle()
                // Show a small starting arc immediately so the ring reads as
                // determinate progress from the first frame.
                .trim(from: 0, to: max(fraction, 0.03))
                .stroke(.tint, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 17, height: 17)
        .animation(.smooth(duration: 0.3), value: fraction)
        .accessibilityLabel("Importing videos")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

#Preview(traits: .previewData) {
    LibraryView()
}
