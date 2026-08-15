/*
See the LICENSE.txt file for licensing information.

Abstract:
A person's page: portrait, biography, and filmography with library titles first.
*/

import SwiftUI
import SwiftData

/// The sheet a cast-row tap presents: the person's page inside its own
/// navigation stack, so filmography entries can push full movie pages.
struct PersonSheet: View {
    @Environment(\.dismiss) private var dismiss

    let person: TMDB.CreditedPerson

    var body: some View {
        NavigationStack {
            PersonPageView(person: person)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
                .navigationDestination(for: TMDB.Movie.self) { movie in
                    MoviePageView(movie: movie)
                }
        }
        .preferredColorScheme(.dark)
    }
}

/// The person's details and filmography. Movies already in the library sort
/// first and carry a checkmark; the rest follow, newest releases first.
private struct PersonPageView: View {
    let person: TMDB.CreditedPerson

    /// The matched library entries, for the ownership ordering and badges.
    @Query(filter: #Predicate<Video> { $0.tmdbID != nil })
    private var matchedVideos: [Video]

    @State private var details: TMDB.PersonDetails?
    @State private var filmography: [TMDB.FilmCredit] = []

    private var libraryTMDBIDs: Set<Int> {
        Set(matchedVideos.compactMap(\.tmdbID))
    }

    /// Library titles first, then everything else by release date, newest first.
    private var sortedFilmography: [TMDB.FilmCredit] {
        let owned = libraryTMDBIDs
        return filmography.sorted { first, second in
            let firstOwned = owned.contains(first.id)
            let secondOwned = owned.contains(second.id)
            if firstOwned != secondOwned {
                return firstOwned
            }
            return (first.releaseDate ?? "") > (second.releaseDate ?? "")
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Constants.verticalTextSpacing) {
                HStack(spacing: Constants.outerPadding) {
                    AsyncImage(url: details?.portraitURL ?? person.profileURL) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        ZStack {
                            Color(white: 0.15)
                            Image(systemName: "person.fill")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 96, height: 96)
                    .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 4) {
                        Text(person.name)
                            .font(.title2.bold())
                        if !person.role.isEmpty {
                            Text(person.role)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let biography = details?.biography, !biography.isEmpty {
                    Text(biography)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                }

                if !sortedFilmography.isEmpty {
                    Text("Filmography")
                        .font(.headline)
                        .padding(.top, Constants.verticalTextSpacing)

                    LazyVStack(spacing: Constants.cardSpacing) {
                        ForEach(sortedFilmography) { credit in
                            NavigationLink(value: credit.asMovie) {
                                FilmographyRow(credit: credit, isInLibrary: libraryTMDBIDs.contains(credit.id))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(Constants.outerPadding)
        }
        .navigationTitle("")
        .task(id: person.personID) {
            async let personDetails = TMDB.person(forID: person.personID)
            async let credits = TMDB.filmography(forPersonID: person.personID)
            details = try? await personDetails
            filmography = (try? await credits) ?? []
        }
    }
}

/// One filmography entry: poster, title, year and role — with a checkmark
/// when the movie is already in the library.
private struct FilmographyRow: View {
    let credit: TMDB.FilmCredit
    let isInLibrary: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: credit.thumbnailURL) { image in
                image
                    .resizable()
                    .scaledToFill()
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
                Text(credit.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let year = credit.year {
                    Text(String(year))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let character = credit.character, !character.isEmpty {
                    Text(character)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if isInLibrary {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("In your library")
            }
        }
        .contentShape(Rectangle())
    }
}
