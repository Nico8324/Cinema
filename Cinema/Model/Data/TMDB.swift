/*
See the LICENSE.txt file for licensing information.

Abstract:
A minimal client for The Movie Database (TMDB) and the logic to apply a match to a video.
*/

import Foundation
import SwiftData

/// A minimal client for The Movie Database — https://developer.themoviedb.org
///
/// Used to match library entries against real movies and pull their metadata
/// (title, synopsis, year, certification, genres) and landscape backdrop art.
enum TMDB {
    /// A movie as returned by the search endpoint.
    struct Movie: Codable, Identifiable, Sendable, Hashable {
        let id: Int
        let title: String
        let overview: String
        /// The title in the film's own language, which is what filenames are almost always named
        /// after. `title` is localized to whatever language the search asked for — a French
        /// search returns *L'Invitation* for *The Invite* — so matching on `title` alone fails
        /// for every film whose title was translated.
        let originalTitle: String?
        let releaseDate: String?
        let posterPath: String?
        let backdropPath: String?
        /// TMDB's own measure of how much attention a title is getting, and how many people have
        /// rated it. Optional because only search and list endpoints return them.
        ///
        /// These are what separate a blockbuster from the fourteen other films sharing its exact
        /// title — the automatic matcher can't work without them, because exact-title uniqueness
        /// turns out to be vanishingly rare in a database this size.
        let popularity: Double?
        let voteCount: Int?

        /// The release year, parsed from the "yyyy-MM-dd" release date.
        var year: Int? {
            releaseDate.flatMap { Int($0.prefix(4)) }
        }

        /// A small poster image for search-result rows.
        var thumbnailURL: URL? {
            posterPath.map { URL(string: "https://image.tmdb.org/t/p/w154\($0)")! }
        }

        /// A mid-size portrait poster for browsing cards.
        var posterCardURL: URL? {
            posterPath.map { URL(string: "https://image.tmdb.org/t/p/w342\($0)")! }
        }

        /// The poster at the size TMDB holds it, for artwork the app stores.
        ///
        /// Posters are shown at up to a full grid cell and on Retina displays, and this is the
        /// picture the app keeps rather than re-fetches, so it takes the largest there is.
        var fullResolutionPosterURL: URL? {
            posterPath.map { URL(string: "https://image.tmdb.org/t/p/original\($0)")! }
        }

        /// The landscape backdrop, sized for the app's 16:9 poster cards.
        var backdropURL: URL? {
            backdropPath.map { URL(string: "https://image.tmdb.org/t/p/w780\($0)")! }
        }

        /// The backdrop at the size TMDB holds it, for artwork the app keeps and shows full-bleed.
        ///
        /// The card size is far too small for a hero: a Mac window 1220 points wide shows the
        /// artwork across roughly 1980 physical pixels on a 2× display, and a Vision Pro or a 4K
        /// TV asks for more again — so `w780` arrives already needing to be stretched two and a
        /// half times. This is downloaded once per film and stored, rather than on every scroll,
        /// which is what makes the larger file worth it here and not on the browsing rows.
        var fullResolutionBackdropURL: URL? {
            backdropPath.map { URL(string: "https://image.tmdb.org/t/p/original\($0)")! }
        }
    }

    private struct SearchResponse: Codable {
        let results: [Movie]
    }

    private struct MovieDetails: Codable {
        struct Genre: Codable {
            let name: String
        }
        let genres: [Genre]
    }

    private struct ReleaseDatesResponse: Codable {
        struct CountryReleases: Codable {
            struct Release: Codable {
                let certification: String
            }
            let iso31661: String
            let releaseDates: [Release]
        }
        let results: [CountryReleases]
    }

    /// One credited person, cast or crew, ready for display.
    struct CreditedPerson: Identifiable, Sendable, Hashable {
        /// TMDB's credit ID — unique per credit, unlike the person ID.
        let id: String
        /// TMDB's person ID, for loading the person's page and filmography.
        let personID: Int
        let name: String
        /// The character played, or the crew job.
        let role: String
        let profileURL: URL?
    }

    /// A person's page: portrait and biography.
    struct PersonDetails: Codable, Sendable {
        let name: String
        let biography: String?
        let profilePath: String?

        var portraitURL: URL? {
            profilePath.map { URL(string: "https://image.tmdb.org/t/p/w342\($0)")! }
        }
    }

    /// One movie in a person's filmography.
    struct FilmCredit: Codable, Identifiable, Sendable {
        let id: Int
        let title: String
        let character: String?
        let releaseDate: String?
        let posterPath: String?
        let backdropPath: String?
        let overview: String?

        var year: Int? {
            releaseDate.flatMap { Int($0.prefix(4)) }
        }

        var thumbnailURL: URL? {
            posterPath.map { URL(string: "https://image.tmdb.org/t/p/w154\($0)")! }
        }

        /// The credit as a displayable movie, for the shared movie page.
        var asMovie: Movie {
            Movie(
                id: id,
                title: title,
                overview: overview ?? "",
                originalTitle: nil,
                releaseDate: releaseDate,
                posterPath: posterPath,
                backdropPath: backdropPath,
                // A filmography credit carries no ranking signals, and doesn't need them: it's
                // already an identified title, not a candidate to choose between.
                popularity: nil,
                voteCount: nil
            )
        }
    }

    /// The person's page details, localized for the user.
    static func person(forID personID: Int) async throws -> PersonDetails {
        let url = endpoint("/person/\(personID)", query: [
            URLQueryItem(name: "language", value: Locale.preferredLanguages.first ?? "en-US")
        ])
        let (data, _) = try await URLSession.shared.data(from: url)
        return try decoder.decode(PersonDetails.self, from: data)
    }

    /// The person's acting filmography, deduplicated by movie.
    static func filmography(forPersonID personID: Int) async throws -> [FilmCredit] {
        struct CreditsResponse: Codable {
            let cast: [FilmCredit]
        }
        let url = endpoint("/person/\(personID)/movie_credits", query: [
            URLQueryItem(name: "language", value: Locale.preferredLanguages.first ?? "en-US")
        ])
        let (data, _) = try await URLSession.shared.data(from: url)
        let credits = try decoder.decode(CreditsResponse.self, from: data).cast
        var seen = Set<Int>()
        return credits.filter { seen.insert($0.id).inserted }
    }

    /// The full movie page for a matched video: extended details plus credits,
    /// fetched as one request via `append_to_response`.
    struct MoviePage: Codable, Sendable {
        struct Credits: Codable, Sendable {
            struct Cast: Codable, Sendable {
                let id: Int
                let creditId: String
                let name: String
                let character: String?
                let profilePath: String?
            }
            struct Crew: Codable, Sendable {
                let id: Int
                let creditId: String
                let name: String
                let job: String?
                let profilePath: String?
            }
            let cast: [Cast]
            let crew: [Crew]
        }

        struct GenreItem: Codable, Sendable {
            let name: String
        }

        let runtime: Int?
        let voteAverage: Double?
        let genres: [GenreItem]?
        let credits: Credits?

        /// The genre names, ready for pill rendering.
        var genreNames: [String] {
            genres?.map(\.name) ?? []
        }

        /// Cast first (capped), then the key creative crew — the TV-app ordering.
        var people: [CreditedPerson] {
            guard let credits else { return [] }
            let cast = credits.cast.prefix(15).map { member in
                CreditedPerson(
                    id: member.creditId,
                    personID: member.id,
                    name: member.name,
                    role: member.character ?? "",
                    profileURL: profileURL(for: member.profilePath)
                )
            }
            let keyJobs = ["Director", "Screenplay", "Writer"]
            let crew = credits.crew
                .filter { keyJobs.contains($0.job ?? "") }
                .map { member in
                    CreditedPerson(
                        id: member.creditId,
                        personID: member.id,
                        name: member.name,
                        role: member.job ?? "",
                        profileURL: profileURL(for: member.profilePath)
                    )
                }
            return Array(cast) + crew
        }

        private func profileURL(for path: String?) -> URL? {
            path.map { URL(string: "https://image.tmdb.org/t/p/w185\($0)")! }
        }
    }

    /// The extended page for one movie: runtime, score, and credits in one call.
    static func moviePage(forMovieID movieID: Int) async throws -> MoviePage {
        let url = endpoint("/movie/\(movieID)", query: [
            URLQueryItem(name: "language", value: Locale.preferredLanguages.first ?? "en-US"),
            URLQueryItem(name: "append_to_response", value: "credits")
        ])
        let (data, _) = try await URLSession.shared.data(from: url)
        return try decoder.decode(MoviePage.self, from: data)
    }

    private struct VideosResponse: Codable {
        struct Clip: Codable {
            let key: String
            let site: String
            let type: String
            let official: Bool
        }
        let results: [Clip]
    }

    /// The metadata gathered for one matched movie, ready to apply to a `Video`.
    struct Match: Sendable {
        let movie: Movie
        let genreNames: [String]
        let certification: String?
        let backdropData: Data?
        /// The portrait poster, for people who browse their library by poster.
        let posterData: Data?
        let trailerYouTubeID: String?
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    static func endpoint(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(string: "https://api.themoviedb.org/3\(path)")!
        components.queryItems = [URLQueryItem(name: "api_key", value: Secrets.tmdbAPIKey)] + query
        return components.url!
    }

    /// The TMDB movie lists the Watch Now discovery row can show, chosen in Settings.
    enum MovieList: String, CaseIterable, Identifiable, Sendable {
        case nowPlaying
        case upcoming
        case popular
        case topRated
        case trending

        /// The Settings key holding the user's choice.
        static let storageKey = "watchNowDiscoveryList"

        var id: String { rawValue }

        /// The user-facing name — the Settings option and the Watch Now row title.
        var displayName: String {
            switch self {
            case .nowPlaying: String(localized: "In Theatres")
            case .upcoming: String(localized: "Coming Soon")
            case .popular: String(localized: "Popular")
            case .topRated: String(localized: "Top Rated")
            case .trending: String(localized: "Trending This Week")
            }
        }

        fileprivate var path: String {
            switch self {
            case .nowPlaying: "/movie/now_playing"
            case .upcoming: "/movie/upcoming"
            case .popular: "/movie/popular"
            case .topRated: "/movie/top_rated"
            case .trending: "/trending/movie/week"
            }
        }

        /// Theatrical schedules differ by country; taste-based lists don't.
        fileprivate var usesRegion: Bool {
            switch self {
            case .nowPlaying, .upcoming: true
            case .popular, .topRated, .trending: false
            }
        }
    }

    /// The movies in one of TMDB's curated lists, localized for the user.
    static func movies(from list: MovieList) async throws -> [Movie] {
        var query = [URLQueryItem(name: "language", value: Locale.preferredLanguages.first ?? "en-US")]
        if list.usesRegion {
            query.append(URLQueryItem(name: "region", value: Locale.current.region?.identifier ?? "US"))
        }
        let (data, _) = try await URLSession.shared.data(from: endpoint(list.path, query: query))
        // Cards are pure poster art — entries without a poster have nothing to show.
        return try decoder.decode(SearchResponse.self, from: data).results.filter { $0.posterPath != nil }
    }

    /// Searches TMDB for movies matching the query.
    static func searchMovies(matching query: String) async throws -> [Movie] {
        let url = endpoint("/search/movie", query: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "language", value: Locale.preferredLanguages.first ?? "en-US")
        ])
        let (data, _) = try await URLSession.shared.data(from: url)
        return try decoder.decode(SearchResponse.self, from: data).results
    }

    /// One movie fetched by ID — for refreshing an already-matched entry.
    static func movie(forID movieID: Int) async throws -> Movie {
        let url = endpoint("/movie/\(movieID)", query: [
            URLQueryItem(name: "language", value: Locale.preferredLanguages.first ?? "en-US")
        ])
        let (data, _) = try await URLSession.shared.data(from: url)
        return try decoder.decode(Movie.self, from: data)
    }

    /// Gathers everything needed to apply a movie to a library entry:
    /// genre names, the US certification, and the backdrop image bytes.
    static func loadMatch(for movie: Movie) async throws -> Match {
        async let details = fetchDetails(movieID: movie.id)
        async let certification = fetchCertification(movieID: movie.id)
        async let backdropData = fetchBackdrop(for: movie)
        async let posterData = fetchImage(at: movie.fullResolutionPosterURL)
        async let trailerID = trailerYouTubeID(forMovieID: movie.id)
        return Match(
            movie: movie,
            genreNames: (try await details).genres.map(\.name),
            certification: try? await certification,
            backdropData: try? await backdropData,
            posterData: try? await posterData,
            trailerYouTubeID: try? await trailerID
        )
    }

    /// The YouTube ID of the movie's best trailer: official trailers first,
    /// then any trailer, then a teaser.
    static func trailerYouTubeID(forMovieID movieID: Int) async throws -> String? {
        // Trailers are most reliably listed under en-US.
        let url = endpoint("/movie/\(movieID)/videos", query: [
            URLQueryItem(name: "language", value: "en-US")
        ])
        let (data, _) = try await URLSession.shared.data(from: url)
        let clips = try decoder.decode(VideosResponse.self, from: data).results.filter { $0.site == "YouTube" }
        let best = clips.first { $0.type == "Trailer" && $0.official }
            ?? clips.first { $0.type == "Trailer" }
            ?? clips.first { $0.type == "Teaser" }
        return best?.key
    }

    private static func fetchDetails(movieID: Int) async throws -> MovieDetails {
        // Localized like every other detail endpoint, so applied movie genres
        // match the language TV genres arrive in.
        let url = endpoint("/movie/\(movieID)", query: [
            URLQueryItem(name: "language", value: Locale.preferredLanguages.first ?? "en-US")
        ])
        let (data, _) = try await URLSession.shared.data(from: url)
        return try decoder.decode(MovieDetails.self, from: data)
    }

    /// The US certification (like "PG-13"), matching the app's rating vocabulary.
    private static func fetchCertification(movieID: Int) async throws -> String? {
        let (data, _) = try await URLSession.shared.data(from: endpoint("/movie/\(movieID)/release_dates"))
        let response = try decoder.decode(ReleaseDatesResponse.self, from: data)
        return response.results
            .first { $0.iso31661 == "US" }?
            .releaseDates
            .map(\.certification)
            .first { !$0.isEmpty }
    }

    private static func fetchBackdrop(for movie: Movie) async throws -> Data? {
        try await fetchImage(at: movie.fullResolutionBackdropURL)
    }

    /// Downloads an artwork image, treating "there is no such image" as an empty result rather
    /// than a failure — plenty of titles have a poster but no backdrop, or the reverse.
    static func fetchImage(at url: URL?) async throws -> Data? {
        guard let url else { return nil }
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }

    /// Applies a TMDB match to a video: title, synopsis, year, certification,
    /// genres (found-or-created), and the backdrop as the poster thumbnail.
    @MainActor
    static func apply(_ match: Match, to video: Video, in context: ModelContext) {
        video.name = match.movie.title
        video.tmdbID = match.movie.id
        video.trailerYouTubeID = match.trailerYouTubeID
        if !match.movie.overview.isEmpty {
            video.synopsis = match.movie.overview
        }
        if let year = match.movie.year {
            video.yearOfRelease = year
        }
        if let certification = match.certification, !certification.isEmpty {
            video.contentRating = certification
        }

        applyGenres(named: match.genreNames, to: video, in: context)
        applyArtwork(match.backdropData, to: video)
        applyPoster(match.posterData, to: video)

        Genre.deleteOrphaned(in: context)
        context.saveReportingErrors()
    }

    @MainActor
    static func applyGenres(named names: [String], to video: Video, in context: ModelContext) {
        guard !names.isEmpty else { return }
        let existingGenres = (try? context.fetch(FetchDescriptor<Genre>())) ?? []
        video.genres = names.map { name in
            if let existing = existingGenres.first(where: { $0.name == name }) {
                return existing
            }
            let genre = Genre(name: name)
            context.insert(genre)
            return genre
        }
    }

    /// Stores the film's portrait poster alongside its wide artwork, so switching between the two
    /// in Settings is instant and offline rather than a re-download.
    @MainActor
    static func applyPoster(_ data: Data?, to video: Video) {
        guard let data, let filename = video.thumbnailFilename else { return }
        let url = MediaStore.posterURL(forFilename: filename)
        do {
            try FileManager.default.createDirectory(at: MediaStore.postersDirectory, withIntermediateDirectories: true)
            try data.write(to: url)
            PosterImageCache.invalidate(forFilename: url.lastPathComponent)
            // Same two-step as `applyArtwork`: both writes inside one SwiftUI transaction would
            // cancel out, and no view would reload the changed file.
            video.hasPoster = false
            Task { @MainActor in
                video.hasPoster = true
                video.modelContext?.saveReportingErrors()
            }
        } catch {
            logger.error("Couldn't save the TMDB poster for \(video.name): \(error.localizedDescription)")
        }
    }

    /// Replaces the generated thumbnail with TMDB artwork (a movie backdrop or an
    /// episode still), invalidating caches so every surface picks up the new art.
    @MainActor
    static func applyArtwork(_ data: Data?, to video: Video) {
        guard let data, let filename = video.thumbnailFilename else { return }
        do {
            try FileManager.default.createDirectory(at: MediaStore.thumbnailsDirectory, withIntermediateDirectories: true)
            try data.write(to: MediaStore.thumbnailURL(forFilename: filename))
            PosterImageCache.invalidate(forFilename: MediaStore.thumbnailURL(forFilename: filename).lastPathComponent)
            // Toggle hasThumbnail through false, restoring it on the next run-loop
            // cycle — both writes in one SwiftUI transaction would cancel out and
            // no view would reload the changed file.
            video.hasThumbnail = false
            Task { @MainActor in
                video.hasThumbnail = true
                video.modelContext?.saveReportingErrors()
            }
        } catch {
            logger.error("Couldn't save TMDB backdrop for \(video.name): \(error.localizedDescription)")
        }
    }
}
