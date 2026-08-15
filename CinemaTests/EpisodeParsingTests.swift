/*
See the LICENSE.txt file for licensing information.

Abstract:
Tests for parsing season/episode markers out of filenames.
*/

import Foundation
import Testing
@testable import Cinema

@Suite("Episode filename parsing")
struct EpisodeParsingTests {

    @Test("Recognizes common episode filename shapes", arguments: [
        ("Silo S02E04", "Silo", 2, 4),
        ("Neuromancer S01E01", "Neuromancer", 1, 1),
        ("The.Last.Stand.S01E10", "The Last Stand", 1, 10),
        ("Dark_Matter_s1e2", "Dark Matter", 1, 2),
        ("Lioness - S03E01", "Lioness", 3, 1),
        ("Show S1 E2", "Show", 1, 2),
        ("Foundation S02E110", "Foundation", 2, 110),
    ])
    func parsesEpisodes(title: String, show: String, season: Int, episode: Int) {
        let marker = VideoImporter.episodeMarker(in: title)
        #expect(marker == VideoImporter.EpisodeMarker(showName: show, season: season, episode: episode))
    }

    @Test("Leaves movie titles alone", arguments: [
        "Avengers Doomsday (2026)",
        "Ballerina (2025)",
        "Seven",
        "S.W.A.T. The Movie",
        "Summer E3 Recap",
    ])
    func ignoresMovies(title: String) {
        #expect(VideoImporter.episodeMarker(in: title) == nil)
    }

    @Test("Episode display metadata derives from the marker fields")
    func displayMetadata() {
        let episode = Video(
            name: "Silo",
            synopsis: "",
            yearOfRelease: 2026,
            showName: "Silo",
            seasonNumber: 2,
            episodeNumber: 4
        )
        #expect(episode.isEpisode)
        #expect(episode.episodeLabel == "S2, E4")
        #expect(episode.displayName == "Silo S2, E4")

        let movie = Video(name: "Ballerina", synopsis: "", yearOfRelease: 2025)
        #expect(!movie.isEpisode)
        #expect(movie.episodeLabel == nil)
        #expect(movie.displayName == "Ballerina")
    }
}
