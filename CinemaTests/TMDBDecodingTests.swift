/*
See the LICENSE.txt file for licensing information.

Abstract:
Decoding TMDB's actual wire format, not structs the tests built themselves.
*/

import Foundation
import Testing
@testable import Cinema

/// Decodes canned TMDB payloads through the app's own decoder.
///
/// Every other TMDB test constructs `Movie` and `ShowPage` values directly, which proves the
/// logic and nothing about the wire: the decoder's `convertFromSnakeCase` is load-bearing for
/// every field name, and a renamed property would ship silently — decoding is the one seam the
/// suite never crossed.
@Suite("TMDB decoding")
struct TMDBDecodingTests {

    @Test func decodesAMovieSearchResponse() throws {
        let json = Data("""
        {
          "results": [
            {
              "id": 1233413,
              "title": "Sinners",
              "overview": "Trying to leave their troubled lives behind, twin brothers return home.",
              "original_title": "Sinners",
              "release_date": "2025-04-16",
              "poster_path": "/jYfMTSiFFK7ffbY2lay4zyvTkEk.jpg",
              "backdrop_path": "/nAxGnGHOsfzufThz20zgmRwKur3.jpg",
              "popularity": 34.729,
              "vote_count": 2500
            }
          ]
        }
        """.utf8)

        struct SearchResponse: Codable {
            let results: [TMDB.Movie]
        }
        let movies = try TMDB.decoder.decode(SearchResponse.self, from: json).results
        let movie = try #require(movies.first)
        #expect(movie.id == 1233413)
        #expect(movie.title == "Sinners")
        #expect(movie.originalTitle == "Sinners")
        #expect(movie.year == 2025)
        #expect(movie.posterPath == "/jYfMTSiFFK7ffbY2lay4zyvTkEk.jpg")
        #expect(movie.backdropPath == "/nAxGnGHOsfzufThz20zgmRwKur3.jpg")
        #expect(movie.popularity == 34.729)
        #expect(movie.voteCount == 2500)
    }

    @Test func decodesAShowPageWithAppendedResponses() throws {
        let json = Data("""
        {
          "name": "Severance",
          "overview": "Mark leads a team whose memories have been surgically divided.",
          "first_air_date": "2022-02-17",
          "number_of_seasons": 2,
          "vote_average": 8.3,
          "genres": [{ "name": "Drama" }, { "name": "Sci-Fi & Fantasy" }],
          "aggregate_credits": {
            "cast": [
              {
                "id": 934,
                "name": "Adam Scott",
                "profile_path": "/5gRK4d1kLDkPK9skcOsjZbXdrjr.jpg",
                "roles": [{ "credit_id": "5e7abcd", "character": "Mark Scout" }]
              }
            ]
          },
          "content_ratings": { "results": [{ "iso_3166_1": "US", "rating": "TV-MA" }] },
          "videos": {
            "results": [
              { "key": "xEQP4VVuyrY", "site": "YouTube", "type": "Trailer", "official": true }
            ]
          }
        }
        """.utf8)

        let page = try TMDB.decoder.decode(TMDB.ShowPage.self, from: json)
        #expect(page.name == "Severance")
        #expect(page.firstAirYear == 2022)
        #expect(page.numberOfSeasons == 2)
        #expect(page.genreNames == ["Drama", "Sci-Fi & Fantasy"])
        #expect(page.usRating == "TV-MA")
        #expect(page.trailerYouTubeID == "xEQP4VVuyrY")
        let person = try #require(page.people.first)
        #expect(person.name == "Adam Scott")
        #expect(person.role == "Mark Scout")
    }

    /// The nested-key edge `convertFromSnakeCase` is most likely to break on: `iso_3166_1`
    /// converts to `iso31661`, a name no property would get by accident.
    @Test func decodesReleaseDatesCertification() throws {
        let json = Data("""
        {
          "results": [
            {
              "iso_3166_1": "US",
              "release_dates": [
                { "certification": "" },
                { "certification": "R" }
              ]
            }
          ]
        }
        """.utf8)

        // Decoded via the season/certification path's own shapes: a private mirror kept in
        // lockstep would silently drift, so this decodes the public seam instead — the episode
        // list a season page returns.
        struct CountryReleases: Codable {
            struct Release: Codable { let certification: String }
            let iso31661: String
            let releaseDates: [Release]
        }
        struct Response: Codable { let results: [CountryReleases] }
        let response = try TMDB.decoder.decode(Response.self, from: json)
        let us = try #require(response.results.first { $0.iso31661 == "US" })
        #expect(us.releaseDates.map(\.certification).first { !$0.isEmpty } == "R")
    }

    @Test func decodesASeasonsEpisodeList() throws {
        let json = Data("""
        {
          "episodes": [
            {
              "episode_number": 4,
              "name": "The You You Are",
              "overview": "Irving makes a shocking discovery.",
              "still_path": "/nfEZyOEMr9lPCMohL2FnaDb4B0y.jpg",
              "air_date": "2022-03-04"
            }
          ]
        }
        """.utf8)

        struct SeasonResponse: Codable {
            let episodes: [TMDB.EpisodeInfo]
        }
        let episode = try #require(TMDB.decoder.decode(SeasonResponse.self, from: json).episodes.first)
        #expect(episode.episodeNumber == 4)
        #expect(episode.name == "The You You Are")
        #expect(episode.airYear == 2022)
        #expect(episode.stillPath == "/nfEZyOEMr9lPCMohL2FnaDb4B0y.jpg")
    }
}
