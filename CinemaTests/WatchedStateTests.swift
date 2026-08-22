/*
See the LICENSE.txt file for licensing information.

Abstract:
What the library knows about what you have already seen.
*/

import Testing
import Foundation
import SwiftData
@testable import Cinema

@MainActor
@Suite("Watched state")
struct WatchedStateTests {
    private func film(_ name: String, position: Double = 0, duration: Int = 6000) -> Video {
        let video = Video(name: name, synopsis: name, yearOfRelease: 2025, duration: duration)
        video.playbackPosition = position
        return video
    }

    private func episode(_ show: String, season: Int, number: Int) -> Video {
        Video(name: show, synopsis: show, yearOfRelease: 2011, duration: 3000,
              showName: show, seasonNumber: season, episodeNumber: number)
    }

    /// Finishing something used to clear its position and nothing else, which left it looking
    /// exactly like a film never opened. The date is the only record that it happened.
    @Test func finishingAFilmRecordsItRatherThanForgettingIt() {
        let video = film("Sinners", position: 5900)
        video.markWatched()
        #expect(video.isWatched)
        #expect(video.playbackPosition == 0)
        #expect(!video.isPartiallyWatched)
    }

    /// The annoyance this feature exists to end: being offered to resume something you finished.
    /// A stale position on a watched film must not put it back in Continue Watching.
    @Test func aWatchedFilmIsNeverOfferedToResume() {
        let video = film("Sinners", position: 1200)
        #expect(video.isPartiallyWatched)
        video.watchedAt = .now
        #expect(!video.isPartiallyWatched)
    }

    /// Marking unwatched puts it back exactly as if it had never been opened — not watched, and
    /// not half-finished either.
    @Test func markingUnwatchedRestoresAFreshFilm() {
        let video = film("Sinners", position: 4000)
        video.markWatched()
        video.markUnwatched()
        #expect(!video.isWatched)
        #expect(!video.isPartiallyWatched)
        #expect(video.playbackPosition == 0)
    }

    /// The next episode is the first *unwatched* one, not the one after the last watched. Those
    /// differ when someone skips ahead, and the difference strands the episodes in between.
    @Test func theNextEpisodeIsTheFirstUnwatchedOne() throws {
        let context = try TestSupport.freshContext()
        let show = try #require(Show.findOrCreate(named: "Suits", in: context))
        var episodes: [Video] = []
        for number in 1...5 {
            let video = episode("Suits", season: 1, number: number)
            context.insert(video)
            video.show = show
            episodes.append(video)
        }
        try context.save()

        // Watched 1, 2 and — having skipped ahead — 4.
        episodes[0].markWatched()
        episodes[1].markWatched()
        episodes[3].markWatched()

        #expect(show.nextEpisode?.episodeNumber == 3)
    }

    /// A series nobody has started isn't "up next", and one that is finished has no next.
    @Test func onlyAStartedUnfinishedSeriesOffersAnything() throws {
        let context = try TestSupport.freshContext()
        let show = try #require(Show.findOrCreate(named: "Suits", in: context))
        let first = episode("Suits", season: 1, number: 1)
        let second = episode("Suits", season: 1, number: 2)
        for video in [first, second] { context.insert(video); video.show = show }
        try context.save()

        #expect(!show.isInProgress)          // untouched
        first.markWatched()
        #expect(show.isInProgress)           // started, one left
        #expect(show.nextEpisode?.episodeNumber == 2)
        second.markWatched()
        #expect(!show.isInProgress)          // finished
        #expect(show.nextEpisode == nil)
    }

    /// A film has no next episode, and rolling from one film into an unrelated one is what a
    /// channel does rather than a library. The offer is for series only.
    @Test func afilmQueuesNothing() throws {
        let context = try TestSupport.freshContext()
        let movie = film("Sinners")
        context.insert(movie)
        try context.save()
        #expect(!movie.isEpisode)
        #expect(movie.show?.nextEpisode == nil)
    }

    /// The last episode of a finished series queues nothing, rather than looping to the first.
    @Test func theEndOfASeriesQueuesNothing() throws {
        let context = try TestSupport.freshContext()
        let show = try #require(Show.findOrCreate(named: "Suits", in: context))
        let only = episode("Suits", season: 1, number: 1)
        context.insert(only)
        only.show = show
        try context.save()

        only.markWatched()
        #expect(show.nextEpisode == nil)
    }

    /// Season order, not episode number: season 2 episode 1 follows season 1 episode 10.
    @Test func theNextEpisodeCrossesIntoTheFollowingSeason() throws {
        let context = try TestSupport.freshContext()
        let show = try #require(Show.findOrCreate(named: "Suits", in: context))
        let finale = episode("Suits", season: 1, number: 10)
        let opener = episode("Suits", season: 2, number: 1)
        for video in [opener, finale] { context.insert(video); video.show = show }
        try context.save()

        finale.markWatched()
        #expect(show.nextEpisode?.seasonNumber == 2)
        #expect(show.nextEpisode?.episodeNumber == 1)
    }
}
