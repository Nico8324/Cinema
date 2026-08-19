/*
See the LICENSE.txt file for licensing information.

Abstract:
Tests for recovering a title and year from the name a video file arrives with.
*/

import Foundation
import Testing
@testable import Cinema

@Suite("Filename metadata")
struct FilenameMetadataTests {

    @Test("Recovers titles from real library filenames", arguments: [
        // Download tools append a content hash to keep names unique.
        ("Ballerina_60A32926", "Ballerina", Int?.none),
        ("The_Invite_047601C8", "The Invite", Int?.none),
        ("Spider-Man__Across_the_Spider-Verse_06DB4225", "Spider-Man Across the Spider-Verse", Int?.none),
        ("War_Machine_957529DE", "War Machine", Int?.none),
        // A year in the name is a year, not part of the title.
        ("Avengers Doomsday (2026)", "Avengers Doomsday", Int?.some(2026)),
        ("The.Invite.2026.2160p.WEB-DL.DDP5.1.Atmos.DV.HEVC-GROUP", "The Invite", Int?.some(2026)),
        ("Sinners.2025.1080p.BluRay.x265-RARBG", "Sinners", Int?.some(2025)),
        // Nothing to strip.
        ("Serenity", "Serenity", Int?.none),
    ])
    func parsesMovies(filename: String, expectedTitle: String, expectedYear: Int?) {
        let parsed = FilenameMetadata.parse(filename)
        #expect(parsed.title == expectedTitle)
        #expect(parsed.year == expectedYear)
        #expect(parsed.episode == nil)
    }

    @Test("A title that is itself a year survives", arguments: ["1917", "2012", "1984"])
    func keepsNumericTitles(filename: String) {
        // Truncating at the year would leave nothing at all, so the name stands as the title.
        #expect(FilenameMetadata.parse(filename).title == filename)
    }

    @Test("Resolutions and serial numbers are not years")
    func rejectsFalseYears() {
        // 2160 is a resolution, and the digits inside a hash are not a release year.
        #expect(FilenameMetadata.parse("Film.2160p.WEB").year == nil)
        #expect(FilenameMetadata.parse("Ballerina_60A32926").year == nil)
        // A run of digits with more than four figures isn't one either.
        #expect(FilenameMetadata.parse("Clip 20261231").year == nil)
    }

    @Test("Episodes keep their show name and marker")
    func parsesEpisodes() {
        let parsed = FilenameMetadata.parse("Suits_S1E1_6E3020AD")
        #expect(parsed.title == "Suits")
        #expect(parsed.episode == VideoImporter.EpisodeMarker(showName: "Suits", season: 1, episode: 1))
    }

    @Test("A hyphenated title is not mistaken for a release group")
    func keepsHyphenatedTitles() {
        // `-Verse` looks exactly like `-RARBG` to a naive rule; only a preceding space makes a
        // release group distinguishable.
        #expect(FilenameMetadata.parse("Spider-Man").title == "Spider-Man")
        #expect(FilenameMetadata.parse("X-Men").title == "X-Men")
    }

    @Test("An unreadable name still yields something")
    func neverReturnsEmpty() {
        // Better a messy row than a blank one — an empty title would be unfindable in the library.
        #expect(!FilenameMetadata.parse("2160p.WEB-DL.HEVC").title.isEmpty)
        #expect(!FilenameMetadata.parse("...").title.isEmpty)
    }
}
