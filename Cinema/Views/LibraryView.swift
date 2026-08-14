/*
See the LICENSE.txt file for this sample’s licensing information.

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
    @State private var importErrorMessage: String?

    // Adapt the number columns based on platform and size class.
    private var columns: [GridItem] {
        let gridItem = GridItem(.flexible(), spacing: Constants.cardSpacing)
        let count = horizontalSizeClass == .compact ? Constants.libraryColumnCountCompact : Constants.libraryColumnCount
        return [GridItem](repeating: gridItem, count: count)
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

                                    ForEach(genres.sorted { $0.localizedName < $1.localizedName }) { genre in
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

                            // Filter videos using the genre a person selects.
                            let videos = selectedGenre?.videos.sorted(by: { $0.id < $1.id }) ?? allVideos.sorted { $0.localizedName < $1.localizedName }
                            LazyVGrid(columns: columns, spacing: Constants.cardSpacing) {
                                ForEach(videos) { video in
                                    NavigationLink(value: NavigationNode.video(video.id)) {
                                        VideoCardView(video: video, style: .grid)
                                    }
                                    .transitionSource(id: video.id, namespace: namespace)
                                    .accessibilityLabel(video.localizedName)
                                    .buttonStyle(buttonStyle)
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPickingFile = true
                    } label: {
                        Label("Add Video", systemImage: "plus")
                    }
                }
            }
            .fileImporter(
                isPresented: $isPickingFile,
                allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie],
                allowsMultipleSelection: true,
                onCompletion: handlePickedFiles
            )
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

    var buttonStyle: some PrimitiveButtonStyle {
        #if os(tvOS)
        .card
        #else
        .plain
        #endif
    }

    private func handlePickedFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importErrorMessage = error.localizedDescription

        case .success(let sourceURLs):
            Task {
                await importVideos(from: sourceURLs)
            }
        }
    }

    private func importVideos(from sourceURLs: [URL]) async {
        var nextID = (allVideos.map(\.id).max() ?? -1) + 1
        var failures: [String] = []

        for sourceURL in sourceURLs {
            do {
                let filename = try importFile(from: sourceURL)
                let name = sourceURL.deletingPathExtension().lastPathComponent
                let videoURL = URL.applicationSupportDirectory
                    .appending(path: "Videos", directoryHint: .isDirectory)
                    .appending(path: filename, directoryHint: .notDirectory)
                let duration = await ThumbnailGenerator.duration(for: videoURL)

                let video = Video(
                    id: nextID,
                    name: name,
                    synopsis: name,
                    // Store just a filename marker, not an absolute path — see Video.resolvedURL.
                    url: URL(string: "file://\(filename)")!,
                    imageName: "",
                    yearOfRelease: Calendar.current.component(.year, from: Date()),
                    duration: duration,
                    isFeatured: true
                )
                context.insert(video)
                nextID += 1

                generateThumbnail(for: video, filename: filename)
            } catch {
                failures.append("\(sourceURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        try? context.save()

        if !failures.isEmpty {
            importErrorMessage = failures.joined(separator: "\n")
        }
    }

    /// Extracts a representative poster frame from the imported video and saves it, updating the video once ready.
    private func generateThumbnail(for video: Video, filename: String) {
        Task {
            let videoURL = URL.applicationSupportDirectory
                .appending(path: "Videos", directoryHint: .isDirectory)
                .appending(path: filename, directoryHint: .notDirectory)

            guard let thumbnailData = await ThumbnailGenerator.generateThumbnailData(for: videoURL) else { return }

            let thumbnailsDirectory = URL.applicationSupportDirectory.appending(path: "Thumbnails", directoryHint: .isDirectory)
            do {
                try FileManager.default.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
                let thumbnailURL = thumbnailsDirectory
                    .appending(path: filename, directoryHint: .notDirectory)
                    .deletingPathExtension()
                    .appendingPathExtension("jpg")
                try thumbnailData.write(to: thumbnailURL)

                video.hasThumbnail = true
                try context.save()
            } catch {
                // The video still works without a thumbnail — just leave the fallback poster in place.
            }
        }
    }

    /// Copies a security-scoped, user-picked file into the app's own storage so it remains accessible after this session ends.
    /// Returns the stored filename (not an absolute path — the sandbox container path isn't stable across reinstalls).
    private func importFile(from sourceURL: URL) throws -> String {
        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let videosDirectory = URL.applicationSupportDirectory.appending(path: "Videos", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: videosDirectory, withIntermediateDirectories: true)

        let filename = UUID().uuidString + "." + sourceURL.pathExtension
        let destinationURL = videosDirectory.appending(path: filename, directoryHint: .notDirectory)

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return filename
    }
}

#Preview(traits: .previewData) {
    LibraryView()
}
