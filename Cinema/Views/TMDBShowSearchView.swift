/*
See the LICENSE.txt file for licensing information.

Abstract:
A sheet that matches a library show against The Movie Database's TV catalog.
*/

import SwiftUI
import SwiftData

/// A sheet that matches a show against TMDB's TV catalog and applies the
/// result to every episode of the show in the library.
struct TMDBShowSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    let showName: String
    let episodes: [Video]

    @State private var query: String
    @State private var results: [TMDB.Show] = []
    @State private var isSearching = false
    @State private var isApplying = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    init(showName: String, episodes: [Video]) {
        self.showName = showName
        self.episodes = episodes
        self._query = State(initialValue: showName)
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
                    List(results) { show in
                        Button {
                            apply(show)
                        } label: {
                            ShowRow(show: show)
                        }
                        .disabled(isApplying)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Match Show")
            #if !os(macOS) && !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $query, prompt: Text("Show title"))
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
            results = try await TMDB.searchShows(matching: trimmed)
        } catch {
            errorMessage = error.localizedDescription
        }
        isSearching = false
    }

    private func apply(_ show: TMDB.Show) {
        isApplying = true
        let ownedSeasonEpisodes = Dictionary(grouping: episodes) { $0.seasonNumber ?? 1 }
            .mapValues { Set($0.map { $0.episodeNumber ?? 1 }) }
        Task {
            do {
                let match = try await TMDB.loadShowMatch(for: show, ownedSeasonEpisodes: ownedSeasonEpisodes)
                TMDB.apply(match, to: episodes, in: context, overridingUserEdits: true)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isApplying = false
            }
        }
    }
}

/// One search result: poster thumbnail, name, first-air year, and overview excerpt.
private struct ShowRow: View {
    let show: TMDB.Show

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: show.thumbnailURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Color(white: 0.15)
                    Image(systemName: "tv")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 53, height: 80)
            .clipShape(.rect(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(show.name)
                    .font(.headline)
                if let year = show.year {
                    Text(String(year))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !show.overview.isEmpty {
                    Text(show.overview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .contentShape(Rectangle())
    }
}
