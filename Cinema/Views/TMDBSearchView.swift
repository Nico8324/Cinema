/*
See the LICENSE.txt file for licensing information.

Abstract:
A sheet that matches a library entry against The Movie Database.
*/

import SwiftUI
import SwiftData

/// A sheet that matches a library entry against The Movie Database and applies
/// the chosen movie's metadata and artwork.
struct TMDBSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    let video: Video

    @State private var query: String
    @State private var results: [TMDB.Movie] = []
    @State private var isSearching = false
    @State private var isApplying = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    init(video: Video) {
        self.video = video
        // Prefill with the video's name, minus any trailing "(2026)"-style year —
        // titles derived from filenames often carry one, and it hurts search results.
        let name = video.name.replacing(/\s*\(\d{4}\)\s*$/, with: "")
        self._query = State(initialValue: name)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isSearching && results.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Search Failed",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(results) { movie in
                        Button {
                            apply(movie)
                        } label: {
                            MovieRow(movie: movie)
                        }
                        .disabled(isApplying)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Match Metadata")
            #if !os(macOS) && !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $query, prompt: Text("Movie title"))
            .interactiveDismissDisabled(isApplying)
            .overlay {
                if isApplying {
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                        ProgressView("Applying…")
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isApplying)
                }
            }
            .task {
                await search()
            }
            .onChange(of: query) {
                scheduleSearch()
            }
        }
        .macSheetSize()
    }

    /// Debounces typing so TMDB isn't queried on every keystroke.
    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await search()
        }
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            return
        }
        isSearching = true
        errorMessage = nil
        do {
            results = try await TMDB.searchMovies(matching: trimmed)
        } catch {
            errorMessage = error.localizedDescription
        }
        isSearching = false
    }

    private func apply(_ movie: TMDB.Movie) {
        isApplying = true
        Task {
            do {
                let match = try await TMDB.loadMatch(for: movie)
                TMDB.apply(match, to: video, in: context)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isApplying = false
            }
        }
    }
}

/// One search result: poster thumbnail, title, year, and a synopsis excerpt.
private struct MovieRow: View {
    let movie: TMDB.Movie

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: movie.thumbnailURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Color(white: 0.15)
                    Image(systemName: "film")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 53, height: 80)
            .clipShape(.rect(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(movie.title)
                    .font(.headline)
                if let year = movie.year {
                    Text(String(year))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !movie.overview.isEmpty {
                    Text(movie.overview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

#Preview(traits: .previewData) {
    @Previewable @Query(sort: \Video.name) var videos: [Video]
    return Group {
        if let video = videos.first {
            TMDBSearchView(video: video)
        }
    }
}
