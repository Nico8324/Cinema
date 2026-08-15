/*
See the LICENSE.txt file for licensing information.

Abstract:
A view that lets a person edit a video's metadata after it's been added to the library.
*/

import SwiftUI
import SwiftData

/// A view that lets a person edit a video's metadata after it's been added to the library.
struct EditVideoView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @Query(sort: \Genre.name) private var allGenres: [Genre]

    @Bindable var video: Video

    /// A fixed set of common genres to choose from, rather than free-text entry — keeps the
    /// Library's genre filter row from accumulating near-duplicate, inconsistently spelled genres.
    private static let genreChoices = [
        "Action", "Adventure", "Animation", "Comedy", "Documentary",
        "Drama", "Fantasy", "Horror", "Mystery", "Romance", "Sci-Fi", "Thriller"
    ]

    private static let contentRatings = ["NR", "G", "PG", "PG-13", "R", "TV-MA"]

    var body: some View {
        NavigationStack {
            List {
                Section("Title") {
                    TextField("Title", text: $video.name)
                }

                Section("Synopsis") {
                    TextField("Synopsis", text: $video.synopsis, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section("Details") {
                    TextField("Year", value: $video.yearOfRelease, format: .number.grouping(.never))
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif

                    Picker("Content Rating", selection: $video.contentRating) {
                        ForEach(Self.contentRatings, id: \.self) { rating in
                            Text(rating).tag(rating)
                        }
                    }
                }

                Section("Genres") {
                    ForEach(Self.genreChoices, id: \.self) { name in
                        Button {
                            toggleGenre(named: name)
                        } label: {
                            HStack {
                                Text(name)
                                Spacer()
                                if video.genres.contains(where: { $0.name == name }) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .navigationTitle("Edit Video")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        // Sweep genres the edit may have emptied, so the Library's
                        // filter row doesn't accumulate dead pills.
                        Genre.deleteOrphaned(in: context)
                        context.saveReportingErrors()
                        dismiss()
                    }
                }
            }
        }
    }

    private func toggleGenre(named name: String) {
        if let index = video.genres.firstIndex(where: { $0.name == name }) {
            video.genres.remove(at: index)
        } else if let existing = allGenres.first(where: { $0.name == name }) {
            video.genres.append(existing)
        } else {
            let genre = Genre(name: name)
            context.insert(genre)
            video.genres.append(genre)
        }
    }
}

#Preview(traits: .previewData) {
    @Previewable @Query(sort: \Video.name) var videos: [Video]
    return Group {
        if let video = videos.first {
            EditVideoView(video: video)
        }
    }
}
