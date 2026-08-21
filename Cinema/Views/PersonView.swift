/*
See the LICENSE.txt file for licensing information.

Abstract:
A person's page: portrait, biography, and filmography with library titles first.
*/

import SwiftUI
import SwiftData

/// The sheet a cast-row tap presents: the person's page inside its own
/// navigation stack, so filmography entries can push full movie and show pages.
struct PersonSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Namespace private var namespace

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
                .navigationDestination(for: TMDB.Show.self) { show in
                    ShowPageView(show: show)
                }
                // Owned titles push by stable identity (`NavigationNode`), never by model
                // object — a pushed page holding a live `Video` faults if the row is deleted
                // beneath it, which is NavigationNode's whole reason to exist.
                .navigationDestinationVideo(in: namespace)
        }
        // …so this sheet steps aside when playback starts and the app's
        // root presents the player.
        .dismissesForFullWindowPlayback()
        .appAppearance()
        .macSheetSize(width: 640, height: 680)
    }
}

/// One entry in a person's merged movie-and-TV filmography.
private enum PersonCredit: Identifiable {
    case movie(TMDB.FilmCredit)
    case show(TMDB.ShowCredit)

    var id: String {
        switch self {
        case .movie(let credit): "movie-\(credit.id)"
        case .show(let credit): "show-\(credit.id)"
        }
    }

    var title: String {
        switch self {
        case .movie(let credit): credit.title
        case .show(let credit): credit.name
        }
    }

    var year: Int? {
        switch self {
        case .movie(let credit): credit.year
        case .show(let credit): credit.year
        }
    }

    var character: String? {
        switch self {
        case .movie(let credit): credit.character
        case .show(let credit): credit.character
        }
    }

    var thumbnailURL: URL? {
        switch self {
        case .movie(let credit): credit.thumbnailURL
        case .show(let credit): credit.thumbnailURL
        }
    }

    var isShow: Bool {
        if case .show = self { true } else { false }
    }

    /// Release or first-air date, for newest-first ordering.
    var date: String {
        switch self {
        case .movie(let credit): credit.releaseDate ?? ""
        case .show(let credit): credit.firstAirDate ?? ""
        }
    }
}

/// The person's details and filmography — movies and TV shows together.
/// Titles already in the library sort first and carry a checkmark; the rest
/// follow, newest releases first.
private struct PersonPageView: View {
    let person: TMDB.CreditedPerson

    /// The matched library entries, for the ownership ordering and badges.
    @Query(filter: #Predicate<Video> { $0.tmdbID != nil })
    private var matchedVideos: [Video]

    @Query(filter: #Predicate<Video> { $0.tmdbShowID != nil })
    private var matchedEpisodes: [Video]

    @State private var details: TMDB.PersonDetails?
    @State private var movieCredits: [TMDB.FilmCredit] = []
    @State private var showCredits: [TMDB.ShowCredit] = []

    private func isOwned(_ credit: PersonCredit) -> Bool {
        switch credit {
        case .movie(let credit): matchedVideos.contains { $0.tmdbID == credit.id }
        case .show(let credit): matchedEpisodes.contains { $0.tmdbShowID == credit.id }
        }
    }

    /// Library titles first, then everything else by date, newest first.
    private var sortedFilmography: [PersonCredit] {
        let credits = movieCredits.map(PersonCredit.movie) + showCredits.map(PersonCredit.show)
        return credits.sorted { first, second in
            let firstOwned = isOwned(first)
            let secondOwned = isOwned(second)
            if firstOwned != secondOwned {
                return firstOwned
            }
            return first.date > second.date
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
                            // Owned titles open the library's own pages, ready
                            // to play; the rest open their TMDB pages.
                            switch credit {
                            case .movie(let movieCredit):
                                if let ownedVideo = matchedVideos.first(where: { $0.tmdbID == movieCredit.id }) {
                                    NavigationLink(value: NavigationNode.video(ownedVideo.id)) {
                                        FilmographyRow(credit: credit, isInLibrary: true)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    NavigationLink(value: movieCredit.asMovie) {
                                        FilmographyRow(credit: credit, isInLibrary: false)
                                    }
                                    .buttonStyle(.plain)
                                }

                            case .show(let showCredit):
                                if let showName = matchedEpisodes.first(where: { $0.tmdbShowID == showCredit.id })?.showName {
                                    NavigationLink(value: NavigationNode.show(showName)) {
                                        FilmographyRow(credit: credit, isInLibrary: true)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    NavigationLink(value: showCredit.asShow) {
                                        FilmographyRow(credit: credit, isInLibrary: false)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .padding(Constants.outerPadding)
        }
        .navigationTitle("")
        .task(id: person.personID) {
            async let personDetails = TMDB.person(forID: person.personID)
            async let movies = TMDB.filmography(forPersonID: person.personID)
            async let shows = TMDB.tvFilmography(forPersonID: person.personID)
            details = try? await personDetails
            movieCredits = (try? await movies) ?? []
            showCredits = (try? await shows) ?? []
        }
    }
}

/// One filmography entry: poster, title, year and role — with a checkmark
/// when the title is already in the library.
private struct FilmographyRow: View {
    let credit: PersonCredit
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
                    Image(systemName: credit.isShow ? "tv" : "film")
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
