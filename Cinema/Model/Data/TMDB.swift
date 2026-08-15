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
    struct Movie: Codable, Identifiable, Sendable {
        let id: Int
        let title: String
        let overview: String
        let releaseDate: String?
        let posterPath: String?
        let backdropPath: String?

        /// The release year, parsed from the "yyyy-MM-dd" release date.
        var year: Int? {
            releaseDate.flatMap { Int($0.prefix(4)) }
        }

        /// A small poster image for search-result rows.
        var thumbnailURL: URL? {
            posterPath.map { URL(string: "https://image.tmdb.org/t/p/w154\($0)")! }
        }

        /// The landscape backdrop, sized for the app's 16:9 poster cards.
        var backdropURL: URL? {
            backdropPath.map { URL(string: "https://image.tmdb.org/t/p/w780\($0)")! }
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
        let trailerYouTubeID: String?
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private static func endpoint(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(string: "https://api.themoviedb.org/3\(path)")!
        components.queryItems = [URLQueryItem(name: "api_key", value: Secrets.tmdbAPIKey)] + query
        return components.url!
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

    /// Gathers everything needed to apply a movie to a library entry:
    /// genre names, the US certification, and the backdrop image bytes.
    static func loadMatch(for movie: Movie) async throws -> Match {
        async let details = fetchDetails(movieID: movie.id)
        async let certification = fetchCertification(movieID: movie.id)
        async let backdropData = fetchBackdrop(for: movie)
        async let trailerID = fetchTrailerYouTubeID(movieID: movie.id)
        return Match(
            movie: movie,
            genreNames: (try await details).genres.map(\.name),
            certification: try? await certification,
            backdropData: try? await backdropData,
            trailerYouTubeID: try? await trailerID
        )
    }

    /// The YouTube ID of the movie's best trailer: official trailers first,
    /// then any trailer, then a teaser.
    private static func fetchTrailerYouTubeID(movieID: Int) async throws -> String? {
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
        let (data, _) = try await URLSession.shared.data(from: endpoint("/movie/\(movieID)"))
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
        guard let url = movie.backdropURL else { return nil }
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
        applyBackdrop(match.backdropData, to: video)

        Genre.deleteOrphaned(in: context)
        context.saveReportingErrors()
    }

    @MainActor
    private static func applyGenres(named names: [String], to video: Video, in context: ModelContext) {
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

    /// Replaces the generated thumbnail with the TMDB backdrop, invalidating caches
    /// so every surface picks up the new art.
    @MainActor
    private static func applyBackdrop(_ data: Data?, to video: Video) {
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
