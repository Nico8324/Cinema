/*
See the LICENSE.txt file for licensing information.

Abstract:
Matching newly added videos against TMDB on their own, when the evidence is strong enough.
*/

import Foundation
import SwiftData
import OSLog

/// Fills in metadata for freshly added videos without being asked, when — and only when — the
/// filename identifies a title beyond reasonable doubt.
///
/// The bar is deliberately high. A wrong match is worse than no match: it replaces the title,
/// synopsis, year, certification, genres and artwork with another film's, and every one of those
/// looks authoritative afterwards. An unmatched video still says exactly what its file said, and
/// the "Match Metadata" sheet is one click away. So anything ambiguous is left alone rather than
/// guessed at, and the guessing is left to the person who can actually recognise the film.
enum MetadataAutoMatch {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Cinema", category: "AutoMatch")

    /// How far a candidate's release year may sit from the filename's before it stops counting as
    /// the same film. One year, because a film released in December is routinely listed under the
    /// following year by whoever named the file.
    private static let yearTolerance = 1

    /// Matches every video that hasn't been matched already, returning how many were filled in.
    ///
    /// Movies are matched one by one; episodes are matched once per show, since every episode of a
    /// show shares one TMDB identity and searching per episode would ask the same question
    /// repeatedly and risk answering it inconsistently.
    @MainActor
    @discardableResult
    static func match(_ videos: [Video], in context: ModelContext) async -> Int {
        var matched = 0

        let movies = videos.filter { !$0.isEpisode && $0.tmdbID == nil }
        for video in movies where !Task.isCancelled {
            if await matchMovie(video, in: context) { matched += 1 }
        }

        // One lookup per show name, applied to all of its episodes at once.
        let episodes = videos.filter { $0.isEpisode && $0.tmdbShowID == nil }
        let shows = Dictionary(grouping: episodes) { $0.showName ?? "" }
        for (showName, episodes) in shows where !Task.isCancelled && !showName.isEmpty {
            if await matchShow(named: showName, episodes: episodes, in: context) {
                matched += episodes.count
            }
        }

        return matched
    }

    // MARK: - Movies

    @MainActor
    private static func matchMovie(_ video: Video, in context: ModelContext) async -> Bool {
        let title = video.name
        // The stored year is only evidence when it came from the filename. A video that fell back
        // to the year it was added would otherwise reject every correct match for an older film.
        let year = video.yearOfRelease == Calendar.current.component(.year, from: .now) ? nil : video.yearOfRelease

        guard let results = try? await TMDB.searchMovies(matching: title), !results.isEmpty else {
            return false
        }
        guard let choice = confidentChoice(
            from: results, title: title, year: year,
            titlesOf: { [$0.title, $0.originalTitle].compactMap { $0 } }, yearOf: \.year,
            popularityOf: \.popularity, voteCountOf: \.voteCount
        ) else {
            logger.debug("No confident match for \(title, privacy: .public) — leaving it for manual matching.")
            return false
        }
        guard let match = try? await TMDB.loadMatch(for: choice) else { return false }
        TMDB.apply(match, to: video, in: context)
        logger.info("Matched \(title, privacy: .public) to TMDB \(choice.id).")
        return true
    }

    // MARK: - Shows

    @MainActor
    private static func matchShow(named showName: String, episodes: [Video], in context: ModelContext) async -> Bool {
        guard let results = try? await TMDB.searchShows(matching: showName), !results.isEmpty else {
            return false
        }
        // A show's first-aired year is rarely in an episode filename, so the name alone decides —
        // which is exactly why the name has to be unambiguous among the results.
        guard let choice = confidentChoice(
            from: results, title: showName, year: nil,
            titlesOf: { [$0.name, $0.originalName].compactMap { $0 } }, yearOf: \.year,
            popularityOf: \.popularity, voteCountOf: \.voteCount
        ) else {
            logger.debug("No confident match for show \(showName, privacy: .public).")
            return false
        }

        // The show match needs to know which episodes are actually owned, so it fetches only those.
        let owned = Dictionary(grouping: episodes) { $0.seasonNumber ?? 0 }
            .mapValues { Set($0.compactMap(\.episodeNumber)) }
        guard let match = try? await TMDB.loadShowMatch(for: choice, ownedSeasonEpisodes: owned) else {
            return false
        }
        TMDB.apply(match, to: episodes, in: context)
        logger.info("Matched show \(showName, privacy: .public) to TMDB \(choice.id).")
        return true
    }

    // MARK: - The confidence rule

    /// How far ahead of its nearest namesake a title must be before it's taken as the obvious one.
    ///
    /// Measured against real results rather than chosen: every film in a typical library shares
    /// its exact title with several others on TMDB — *Ballerina* has fourteen — so requiring a
    /// unique title matches nothing at all. What does separate them is attention. The correct
    /// answer led its nearest namesake by 2.3× (Ballerina), 7.6× (War Machine), 19.6×
    /// (Supergirl) and 28.7× (The Invite). Two is therefore the floor that admits the closest
    /// real case, and the number to raise if a wrong match ever gets through.
    private static let popularityDominance = 2.0

    /// The one candidate that is unambiguously this title, or `nil` when the evidence doesn't
    /// single one out.
    ///
    /// Title equality is the filter; attention is the tie-break. Refuses when nothing matches the
    /// title exactly, when a stated year rules the leader out, or when two namesakes are close
    /// enough in popularity that choosing between them is a coin toss — which is what a remake or
    /// a re-release looks like from here.
    static func confidentChoice<Candidate>(
        from candidates: [Candidate],
        title: String,
        year: Int?,
        titlesOf: (Candidate) -> [String],
        yearOf: (Candidate) -> Int?,
        popularityOf: (Candidate) -> Double? = { _ in nil },
        voteCountOf: (Candidate) -> Int? = { _ in nil }
    ) -> Candidate? {
        let wanted = normalized(title)
        guard !wanted.isEmpty else { return nil }

        // Any of a candidate's names counts. A film is equally itself under its original title
        // and its translation, and a filename may have been written from either.
        var exact = candidates.filter { candidate in
            titlesOf(candidate).contains { normalized($0) == wanted }
        }
        guard !exact.isEmpty else { return nil }

        // A year the filename actually stated is the strongest evidence there is; when it's
        // present it decides, and popularity never overrules it.
        if let year {
            exact = exact.filter { candidate in
                guard let candidateYear = yearOf(candidate) else { return false }
                return abs(candidateYear - year) <= yearTolerance
            }
        }

        guard exact.count > 1 else { return exact.first }

        // Several namesakes: take the one the world is actually watching, but only if it's clearly
        // ahead on both signals. Votes as well as popularity, because popularity spikes on release
        // and would otherwise hand a new film its predecessor's library entry.
        let ranked = exact.sorted { (popularityOf($0) ?? 0) > (popularityOf($1) ?? 0) }
        guard let leader = ranked.first, let runnerUp = ranked.dropFirst().first else { return nil }

        let leadPopularity = popularityOf(leader) ?? 0
        let runnerUpPopularity = popularityOf(runnerUp) ?? 0
        guard leadPopularity > 0,
              runnerUpPopularity <= 0 || leadPopularity / runnerUpPopularity >= popularityDominance,
              (voteCountOf(leader) ?? 0) > (voteCountOf(runnerUp) ?? 0)
        else { return nil }

        return leader
    }

    /// Reduces a title to what two spellings of the same film have in common: case, punctuation
    /// and spacing all vary between a filename and a database, and none of them carry meaning.
    static func normalized(_ title: String) -> String {
        title
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacing(/[^a-z0-9 ]/, with: " ")
            .replacing(/\s+/, with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
