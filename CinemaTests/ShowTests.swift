/*
See the LICENSE.txt file for licensing information.

Abstract:
A television series as a row: one per name, however its episodes spell it.
*/

import Testing
import Foundation
import SwiftData
@testable import Cinema

@MainActor
@Suite("Shows")
struct ShowTests {
    /// Three spellings of one series used to be three shows, because the grouping key was the raw
    /// string a filename happened to contain.
    @Test func oneSeriesHoweverItsEpisodesSpellIt() throws {
        let context = try TestSupport.freshContext()
        let first = Show.findOrCreate(named: "Suits", in: context)
        let second = Show.findOrCreate(named: "suits", in: context)
        let third = Show.findOrCreate(named: "  Suits  ", in: context)

        #expect(first === second)
        #expect(first === third)
        #expect(try context.fetch(FetchDescriptor<Show>()).count == 1)
        // The first spelling wins the display name — it isn't lowercased to match on it.
        #expect(first?.name == "Suits")
    }

    /// A name of nothing but spaces is not a series.
    @Test func anEmptyNameMakesNoShow() throws {
        let context = try TestSupport.freshContext()
        #expect(Show.findOrCreate(named: "   ", in: context) == nil)
        #expect(try context.fetch(FetchDescriptor<Show>()).isEmpty)
    }

    /// The failure that motivated the model: deleting the last episode used to take the series with
    /// it, and its TMDB match and artwork went too. Now the row waits for the next episode.
    @Test func aShowOutlivesItsLastEpisode() throws {
        let context = try TestSupport.freshContext()
        let show = try #require(Show.findOrCreate(named: "Suits", in: context))
        show.tmdbShowID = 37680

        let episode = Video(name: "Suits", synopsis: "Suits", yearOfRelease: 2011,
                              showName: "Suits", seasonNumber: 1, episodeNumber: 1)
        context.insert(episode)
        episode.show = show
        try context.save()
        #expect(show.episodes?.count == 1)

        context.delete(episode)
        try context.save()

        let surviving = try context.fetch(FetchDescriptor<Show>())
        #expect(surviving.count == 1)
        #expect(surviving.first?.tmdbShowID == 37680)
    }

    /// Episodes read in the order the series runs, not the order they were added — and season 10
    /// comes after season 2 rather than between 1 and 3.
    @Test func episodesReadInBroadcastOrder() throws {
        let context = try TestSupport.freshContext()
        let show = try #require(Show.findOrCreate(named: "Suits", in: context))
        for (season, number) in [(2, 3), (10, 1), (1, 2), (1, 1)] {
            let episode = Video(name: "Suits", synopsis: "Suits", yearOfRelease: 2011,
                                showName: "Suits", seasonNumber: season, episodeNumber: number)
            context.insert(episode)
            episode.show = show
        }
        try context.save()

        let order = show.episodesInOrder.map { ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0) }
        #expect(order.map(\.0) == [1, 1, 2, 10])
        #expect(show.seasonNumbers == [1, 2, 10])
    }
}
