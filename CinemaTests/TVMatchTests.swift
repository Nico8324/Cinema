/*
See the LICENSE.txt file for licensing information.

Abstract:
Tests for applying a TMDB show match to the library's episodes.
*/

import Foundation
import SwiftData
import Testing
@testable import Cinema

extension CinemaSuite {
    @Suite("TV show matching")
    @MainActor
    struct TVMatchTests {

        @Test("Applying a show match enriches every episode")
        func applyShowMatch() throws {
            let context = try TestSupport.freshContext()

            let episode1 = Video(
                name: "neuromancer", synopsis: "", yearOfRelease: 2020,
                showName: "neuromancer", seasonNumber: 1, episodeNumber: 1
            )
            let episode2 = Video(
                name: "neuromancer", synopsis: "", yearOfRelease: 2020,
                showName: "neuromancer", seasonNumber: 1, episodeNumber: 2
            )
            context.insert(episode1)
            context.insert(episode2)
            try context.save()

            let show = TMDB.Show(
                id: 129552,
                name: "Neuromancer",
                overview: "Case, a washed-up hacker, is hired for one last job.",
                firstAirDate: "2026-04-01",
                posterPath: nil,
                backdropPath: nil
            )
            let page = TMDB.ShowPage(
                name: "Neuromancer",
                overview: show.overview,
                firstAirDate: "2026-04-01",
                numberOfSeasons: 1,
                voteAverage: 8.1,
                genres: [.init(name: "Sci-Fi & Fantasy")],
                aggregateCredits: nil,
                contentRatings: .init(results: [.init(iso31661: "US", rating: "TV-MA")]),
                videos: .init(results: [.init(key: "trailer123", site: "YouTube", type: "Trailer", official: true)])
            )
            let match = TMDB.ShowMatch(
                show: show,
                page: page,
                episodes: [1: [
                    1: .init(episodeNumber: 1, name: "Chiba City Blues", overview: "Case hits bottom.", stillPath: nil, airDate: "2026-04-01"),
                    2: .init(episodeNumber: 2, name: "The Screaming Fist", overview: nil, stillPath: nil, airDate: "2026-04-08"),
                ]],
                stills: [:]
            )

            TMDB.apply(match, to: [episode1, episode2], in: context)

            for episode in [episode1, episode2] {
                #expect(episode.tmdbShowID == 129552)
                #expect(episode.name == "Neuromancer")
                // The grouping key must never change under an open, name-keyed page.
                #expect(episode.showName == "neuromancer")
                #expect(episode.contentRating == "TV-MA")
                #expect(episode.trailerYouTubeID == "trailer123")
                #expect(episode.genres.map(\.name) == ["Sci-Fi & Fantasy"])
                #expect(episode.yearOfRelease == 2026)
            }

            #expect(episode1.episodeTitle == "Chiba City Blues")
            #expect(episode1.synopsis == "Case hits bottom.")
            // Episode 2 has no overview of its own — the show's fills in.
            #expect(episode2.episodeTitle == "The Screaming Fist")
            #expect(episode2.synopsis == show.overview)

            // The show page derives its display helpers correctly.
            #expect(page.usRating == "TV-MA")
            #expect(page.trailerYouTubeID == "trailer123")
            #expect(page.formattedScore == "★ 8.1")
        }
    }
}
