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

    @Namespace private var namespace

    @State private var navigationPath = [NavigationNode]()
    @State private var selectedGenre: Genre?
    @State private var isPickingFile = false
    @State private var isAddingYouTubeVideo = false
    @State private var importErrorMessage: String?
    @State private var importProgress = ImportProgress()

    // Adapt the number columns based on platform and size class.
    private var columns: [GridItem] {
        let gridItem = GridItem(.flexible(), spacing: Constants.cardSpacing)
        let count = horizontalSizeClass == .compact ? Constants.libraryColumnCountCompact : Constants.libraryColumnCount
        return [GridItem](repeating: gridItem, count: count)
    }

    /// The videos to display, filtered by the selected genre, alphabetically.
    private var displayedVideos: [Video] {
        selectedGenre?.videos.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } ?? allVideos
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

                            LazyVGrid(columns: columns, spacing: Constants.cardSpacing) {
                                ForEach(displayedVideos) { video in
                                    NavigationLink(value: NavigationNode.video(video.id)) {
                                        VideoCardView(video: video, style: .grid)
                                    }
                                    .transitionSource(id: video.id, namespace: namespace)
                                    .accessibilityLabel(video.name)
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .navigationDestinationVideo(in: namespace)
                        .padding(Constants.outerPadding)
                    }
                    .scrollClipDisabled()
                }
            }
            .toolbar {
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
                            Button {
                                isPickingFile = true
                            } label: {
                                Label("Choose Files", systemImage: "folder")
                            }
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
            .fileImporter(
                isPresented: $isPickingFile,
                allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie],
                allowsMultipleSelection: true,
                onCompletion: handlePickedFiles
            )
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
                // Small files copy in milliseconds; hold the full ring briefly so the
                // progress indicator reads as a state, not a glitch.
                let minimumRingTime: Duration = .milliseconds(750)
                let elapsed = ContinuousClock.now - importStart
                if elapsed < minimumRingTime {
                    try? await Task.sleep(for: minimumRingTime - elapsed)
                }
                importProgress.end()
                if !outcome.failures.isEmpty {
                    importErrorMessage = outcome.failures.joined(separator: "\n")
                }
            }
        }
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
