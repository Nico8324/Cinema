/*
See the LICENSE.txt file for licensing information.

Abstract:
TMDB's TV endpoints: show search, show pages, and applying a match to episodes.
*/

import Foundation
import SwiftData

extension TMDB {
    /// A TV show as returned by the search endpoint.
    struct Show: Codable, Identifiable, Sendable, Hashable {
        let id: Int
        let name: String
        let overview: String
        let firstAirDate: String?
        let posterPath: String?
        let backdropPath: String?

        var year: Int? {
            firstAirDate.flatMap { Int($0.prefix(4)) }
        }

        /// A small poster image for search-result rows.
        var thumbnailURL: URL? {
            posterPath.map { URL(string: "https://image.tmdb.org/t/p/w154\($0)")! }
        }

        /// A mid-size portrait poster for browsing cards.
        var posterCardURL: URL? {
            posterPath.map { URL(string: "https://image.tmdb.org/t/p/w342\($0)")! }
        }

        /// The landscape backdrop, sized for the app's 16:9 poster cards.
        var backdropURL: URL? {
            backdropPath.map { URL(string: "https://image.tmdb.org/t/p/w780\($0)")! }
        }
    }

    /// The TMDB TV lists the Watch Now shows row can display, chosen in Settings.
    enum ShowList: String, CaseIterable, Identifiable, Sendable {
        case airingToday
        case onTheAir
        case popular
        case topRated
        case trending

        /// The Settings key holding the user's choice.
        static let storageKey = "watchNowTVDiscoveryList"

        var id: String { rawValue }

        /// The user-facing name — the Settings option and the Watch Now row title.
        /// Show-flavored so the row reads apart from the movies row above it.
        var displayName: String {
            switch self {
            case .airingToday: String(localized: "Airing Today")
            case .onTheAir: String(localized: "On the Air")
            case .popular: String(localized: "Popular Shows")
            case .topRated: String(localized: "Top Rated Shows")
            case .trending: String(localized: "Trending Shows")
            }
        }

        fileprivate var path: String {
            switch self {
            case .airingToday: "/tv/airing_today"
            case .onTheAir: "/tv/on_the_air"
            case .popular: "/tv/popular"
            case .topRated: "/tv/top_rated"
            case .trending: "/trending/tv/week"
            }
        }
    }

    /// The shows in one of TMDB's curated TV lists, localized for the user.
    static func shows(from list: ShowList) async throws -> [Show] {
        let url = endpoint(list.path, query: [
            URLQueryItem(name: "language", value: Locale.preferredLanguages.first ?? "en-US")
        ])
        let (data, _) = try await URLSession.shared.data(from: url)
        struct ListResponse: Codable {
            let results: [Show]
        }
        // Cards are pure poster art — entries without a poster have nothing to show.
        return try decoder.decode(ListResponse.self, from: data).results.filter { $0.posterPath != nil }
    }

    /// A show's page: extended details plus aggregate credits, ratings, and
    /// videos, fetched as one request via `append_to_response`.
    struct ShowPage: Codable, Sendable {
        struct AggregateCredits: Codable, Sendable {
            struct Cast: Codable, Sendable {
                struct Role: Codable, Sendable {
                    let creditId: String
                    let character: String?
                }
                let id: Int
                let name: String
                let roles: [Role]?
                let profilePath: String?
            }
            let cast: [Cast]
        }

        struct ContentRatings: Codable, Sendable {
            struct Rating: Codable, Sendable {
                let iso31661: String
                let rating: String
            }
            let results: [Rating]
        }

        struct Videos: Codable, Sendable {
            struct Clip: Codable, Sendable {
                let key: String
                let site: String
                let type: String
                let official: Bool
            }
            let results: [Clip]
        }

        struct GenreItem: Codable, Sendable {
            let name: String
        }

        let name: String?
        let overview: String?
        let firstAirDate: String?
        let numberOfSeasons: Int?
        let voteAverage: Double?
        let genres: [GenreItem]?
        let aggregateCredits: AggregateCredits?
        let contentRatings: ContentRatings?
        let videos: Videos?

        var firstAirYear: Int? {
            firstAirDate.flatMap { Int($0.prefix(4)) }
        }

        var genreNames: [String] {
            genres?.map(\.name) ?? []
        }

        /// The show's main cast, capped, as displayable people.
        var people: [CreditedPerson] {
            guard let cast = aggregateCredits?.cast else { return [] }
            return cast.prefix(15).map { member in
                CreditedPerson(
                    id: member.roles?.first?.creditId ?? "person-\(member.id)",
                    personID: member.id,
                    name: member.name,
                    role: member.roles?.first?.character ?? "",
                    profileURL: member.profilePath.map { URL(string: "https://image.tmdb.org/t/p/w185\($0)")! }
                )
            }
        }

        /// The US certification, like "TV-MA".
        var usRating: String? {
            contentRatings?.results.first { $0.iso31661 == "US" }?.rating
        }

        /// The show's best YouTube trailer: official trailers, then any, then teasers.
        var trailerYouTubeID: String? {
            let clips = (videos?.results ?? []).filter { $0.site == "YouTube" }
            let best = clips.first { $0.type == "Trailer" && $0.official }
                ?? clips.first { $0.type == "Trailer" }
                ?? clips.first { $0.type == "Teaser" }
            return best?.key
        }

        var formattedScore: String? {
            guard let voteAverage, voteAverage > 0 else { return nil }
            return String(format: "★ %.1f", voteAverage)
        }
    }

    /// One TV show in a person's filmography.
    struct ShowCredit: Codable, Identifiable, Sendable {
        let id: Int
        let name: String
        let character: String?
        let firstAirDate: String?
        let posterPath: String?
        let backdropPath: String?
        let overview: String?

        var year: Int? {
            firstAirDate.flatMap { Int($0.prefix(4)) }
        }

        var thumbnailURL: URL? {
            posterPath.map { URL(string: "https://image.tmdb.org/t/p/w154\($0)")! }
        }

        /// The credit as a displayable show, for the shared show page.
        var asShow: Show {
            Show(
                id: id,
                name: name,
                overview: overview ?? "",
                firstAirDate: firstAirDate,
                posterPath: posterPath,
                backdropPath: backdropPath
            )
        }
    }

    /// The person's TV acting credits, deduplicated by show.
    static func tvFilmography(forPersonID personID: Int) async throws -> [ShowCredit] {
        struct CreditsResponse: Codable {
            let cast: [ShowCredit]
        }
        let url = endpoint("/person/\(personID)/tv_credits", query: [
            URLQueryItem(name: "language", value: Locale.preferredLanguages.first ?? "en-US")
        ])
        let (data, _) = try await URLSession.shared.data(from: url)
        let credits = try decoder.decode(CreditsResponse.self, from: data).cast
        var seen = Set<Int>()
        return credits.filter { seen.insert($0.id).inserted }
    }

    /// One episode's metadata from a season page.
    struct EpisodeInfo: Codable, Sendable {
        let episodeNumber: Int
        let name: String?
        let overview: String?
        let stillPath: String?
        let airDate: String?

        var airYear: Int? {
            airDate.flatMap { Int($0.prefix(4)) }
        }

        var stillURL: URL? {
            stillPath.map { URL(string: "https://image.tmdb.org/t/p/w780\($0)")! }
        }
    }

    /// Everything gathered to apply a show match to the library's episodes.
    struct ShowMatch: Sendable {
        let show: Show
        let page: ShowPage
        /// Episode metadata keyed by season, then by episode number.
        let episodes: [Int: [Int: EpisodeInfo]]
        /// Episode still images keyed by season/episode, downloaded up front.
        let stills: [SeasonEpisodeKey: Data]
    }

    struct SeasonEpisodeKey: Hashable, Sendable {
        let season: Int
        let episode: Int
    }

    /// Searches TMDB for TV shows matching the query.
    static func searchShows(matching query: String) async throws -> [Show] {
        let url = endpoint("/search/tv", query: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "language", value: Locale.preferredLanguages.first ?? "en-US")
        ])
        let (data, _) = try await URLSession.shared.data(from: url)
        struct SearchResponse: Codable {
            let results: [Show]
        }
        return try decoder.decode(SearchResponse.self, from: data).results
    }

    /// The extended page for one show: details, credits, ratings, and videos in one call.
    static func showPage(forShowID showID: Int) async throws -> ShowPage {
        let url = endpoint("/tv/\(showID)", query: [
            URLQueryItem(name: "language", value: Locale.preferredLanguages.first ?? "en-US"),
            URLQueryItem(name: "append_to_response", value: "aggregate_credits,content_ratings,videos")
        ])
        let (data, _) = try await URLSession.shared.data(from: url)
        return try decoder.decode(ShowPage.self, from: data)
    }

    /// The episodes of one season.
    static func seasonEpisodes(showID: Int, season: Int) async throws -> [EpisodeInfo] {
        let url = endpoint("/tv/\(showID)/season/\(season)", query: [
            URLQueryItem(name: "language", value: Locale.preferredLanguages.first ?? "en-US")
        ])
        let (data, _) = try await URLSession.shared.data(from: url)
        struct SeasonResponse: Codable {
            let episodes: [EpisodeInfo]
        }
        return try decoder.decode(SeasonResponse.self, from: data).episodes
    }

    /// Gathers everything needed to apply a show to the library's episodes:
    /// the show page, per-season episode metadata, and episode stills for the
    /// seasons and episodes actually owned.
    static func loadShowMatch(for show: Show, ownedSeasonEpisodes: [Int: Set<Int>]) async throws -> ShowMatch {
        let page = try await showPage(forShowID: show.id)

        var episodes: [Int: [Int: EpisodeInfo]] = [:]
        var stills: [SeasonEpisodeKey: Data] = [:]

        for (season, ownedNumbers) in ownedSeasonEpisodes {
            guard let seasonEpisodes = try? await seasonEpisodes(showID: show.id, season: season) else { continue }
            var bySeason: [Int: EpisodeInfo] = [:]
            for info in seasonEpisodes {
                bySeason[info.episodeNumber] = info
                if ownedNumbers.contains(info.episodeNumber),
                   let stillURL = info.stillURL,
                   let (data, _) = try? await URLSession.shared.data(from: stillURL) {
                    stills[SeasonEpisodeKey(season: season, episode: info.episodeNumber)] = data
                }
            }
            episodes[season] = bySeason
        }

        return ShowMatch(show: show, page: page, episodes: episodes, stills: stills)
    }

    /// Applies a show match to all of the show's episodes in the library:
    /// official show name, genres, rating, show trailer, and per-episode
    /// titles, overviews, air years, and still artwork.
    @MainActor
    static func apply(_ match: ShowMatch, to episodes: [Video], in context: ModelContext) {
        let genreNames = match.page.genreNames

        for video in episodes {
            video.tmdbShowID = match.show.id
            // `name` is the display title; `showName` stays untouched — it's the
            // stable grouping key open pages and navigation are keyed by.
            video.name = match.show.name
            video.trailerYouTubeID = match.page.trailerYouTubeID
            if let rating = match.page.usRating, !rating.isEmpty {
                video.contentRating = rating
            }
            if !genreNames.isEmpty {
                applyGenres(named: genreNames, to: video, in: context)
            }

            let season = video.seasonNumber ?? 1
            let episodeNumber = video.episodeNumber ?? 1
            if let info = match.episodes[season]?[episodeNumber] {
                video.episodeTitle = info.name
                video.synopsis = info.overview?.isEmpty == false
                    ? info.overview!
                    : match.show.overview
                video.yearOfRelease = info.airYear ?? match.page.firstAirYear ?? video.yearOfRelease
                applyArtwork(match.stills[SeasonEpisodeKey(season: season, episode: episodeNumber)], to: video)
            } else {
                video.synopsis = match.show.overview
                video.yearOfRelease = match.page.firstAirYear ?? video.yearOfRelease
            }
        }

        Genre.deleteOrphaned(in: context)
        context.saveReportingErrors()
    }
}
