/*
See the LICENSE.txt file for licensing information.

Abstract:
Tests for the rule that decides when a TMDB match is safe to apply unasked.
*/

import Foundation
import Testing
@testable import Cinema

@Suite("Automatic matching")
struct AutoMatchTests {

    /// A stand-in for a search result, so the rule is tested without touching the network.
    private struct Candidate {
        let title: String
        var originalTitle: String? = nil
        let year: Int?
        var popularity: Double? = nil
        var voteCount: Int? = nil
    }

    private func choose(_ candidates: [Candidate], title: String, year: Int? = nil) -> String? {
        MetadataAutoMatch.confidentChoice(
            from: candidates,
            title: title,
            year: year,
            titlesOf: { [$0.title, $0.originalTitle].compactMap { $0 } },
            yearOf: \.year,
            popularityOf: \.popularity,
            voteCountOf: \.voteCount
        )?.title
    }

    private func choose(_ candidates: [(String, Int?)], title: String, year: Int? = nil) -> String? {
        choose(candidates.map { Candidate(title: $0.0, year: $0.1) }, title: title, year: year)
    }

    @Test("Matches a film under its original title when the search returned a translation")
    func matchesOriginalTitle() {
        // A French search returns L'Invitation for The Invite; the filename says the latter.
        #expect(choose([
            Candidate(title: "L\'Invitation", originalTitle: "The Invite", year: 2026,
                      popularity: 100.7, voteCount: 268),
            Candidate(title: "The Invite", originalTitle: "The Invite", year: 2022,
                      popularity: 3.5, voteCount: 0),
        ], title: "The Invite") == "L\'Invitation")
    }

    @Test("Accepts a single exact title match")
    func acceptsUnambiguous() {
        #expect(choose([("Ballerina", 2025)], title: "Ballerina") == "Ballerina")
    }

    @Test("Ignores case, punctuation and accents")
    func normalizesSpelling() {
        // The filename lost the colon and the accent; they carry no meaning for identity.
        #expect(choose([("Spider-Man: Across the Spider-Verse", 2023)],
                       title: "Spider-Man Across the Spider-Verse") == "Spider-Man: Across the Spider-Verse")
        #expect(choose([("Amélie", 2001)], title: "amelie") == "Amélie")
    }

    @Test("Refuses when namesakes are close in popularity")
    func refusesAmbiguity() {
        // Two comparably known films of the same name: picking either unasked is a coin toss.
        #expect(choose([
            Candidate(title: "Dune", year: 1984, popularity: 20, voteCount: 4000),
            Candidate(title: "Dune", year: 2021, popularity: 25, voteCount: 11000),
        ], title: "Dune") == nil)
    }

    @Test("Takes the obvious one when it dominates its namesakes")
    func acceptsDominantNamesake() {
        // The real shape of a TMDB search: many exact-title matches, one of them the film anyone
        // means. Numbers here are the measured ones for Ballerina — the narrowest real margin.
        #expect(choose([
            Candidate(title: "Ballerina", year: 2016, popularity: 7.59, voteCount: 2014),
            Candidate(title: "Ballerina", year: 2025, popularity: 17.34, voteCount: 2890),
            Candidate(title: "Ballerina", year: 2023, popularity: 5.33, voteCount: 726),
        ], title: "Ballerina") == "Ballerina")
    }

    @Test("Popularity alone isn't enough — votes must agree")
    func requiresBothSignals() {
        // A film spikes in popularity on release week. Without the vote-count check, a sequel
        // would take its predecessor's place in the library on the strength of a week's buzz.
        #expect(choose([
            Candidate(title: "The Thing", year: 1982, popularity: 30, voteCount: 8000),
            Candidate(title: "The Thing", year: 2026, popularity: 200, voteCount: 12),
        ], title: "The Thing") == nil)
    }

    @Test("A stated year overrules popularity")
    func yearWinsOverPopularity() {
        // Asking for the 1984 Dune must not return the famous one.
        #expect(choose([
            Candidate(title: "Dune", year: 1984, popularity: 20, voteCount: 4000),
            Candidate(title: "Dune", year: 2021, popularity: 500, voteCount: 11000),
        ], title: "Dune", year: 1984) == "Dune")
    }

    @Test("A year resolves what the title alone cannot")
    func yearBreaksTies() {
        #expect(choose([
            Candidate(title: "Dune", year: 1984, popularity: 20, voteCount: 4000),
            Candidate(title: "Dune", year: 2021, popularity: 25, voteCount: 11000),
        ], title: "Dune", year: 2021) == "Dune")
    }

    @Test("Tolerates a year off by one, rejects further")
    func yearTolerance() {
        // A December release is routinely filed under the following year.
        #expect(choose([("The Invite", 2026)], title: "The Invite", year: 2025) == "The Invite")
        #expect(choose([("The Invite", 2026)], title: "The Invite", year: 2023) == nil)
    }

    @Test("Refuses a near miss rather than guessing")
    func refusesPartialTitles() {
        // Substring matches are how a sequel gets another film's metadata.
        #expect(choose([("Ballerina Overdrive", 2024)], title: "Ballerina") == nil)
        #expect(choose([("Dune: Part Two", 2024)], title: "Dune") == nil)
    }

    @Test("Refuses when nothing matches, or there's nothing to match on")
    func refusesEmpty() {
        #expect(choose([("Something Else", 2020)], title: "Ballerina") == nil)
        #expect(choose([Candidate](), title: "Ballerina") == nil)
        #expect(choose([("Ballerina", 2025)], title: "   ") == nil)
    }

    @Test("A candidate with no year can't satisfy a year requirement")
    func requiresYearWhenAsked() {
        // Unknown is not the same as matching; accepting it would defeat the tie-break.
        #expect(choose([("Dune", nil)], title: "Dune", year: 2021) == nil)
    }
}
