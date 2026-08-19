/*
See the LICENSE.txt file for licensing information.

Abstract:
Recovering a real title and year from the name a video file happens to arrive with.
*/

import Foundation

/// What can be read from a video's filename before anything is looked up.
///
/// Filenames are the only metadata a local library starts with, and they're written for
/// filesystems rather than for people: `Spider-Man__Across_the_Spider-Verse_06DB4225`,
/// `The.Invite.2026.2160p.WEB-DL.DDP5.1.Atmos.DV.HEVC-GROUP`. Taken literally they become
/// unreadable library titles and, worse, useless search terms — so the guessing happens here,
/// once, rather than in each place that needs it.
///
/// Everything here is a heuristic over conventions, not a parser of a format. It is deliberately
/// conservative: a title that keeps a stray word is recoverable by matching it against TMDB, while
/// one that has had a real word stripped may never match anything.
struct FilenameMetadata: Equatable, Sendable {
    /// The title, cleaned up as far as the conventions allow.
    let title: String
    /// The release year, when the filename states one.
    let year: Int?
    /// The season and episode, for television.
    let episode: VideoImporter.EpisodeMarker?

    /// Tokens that mark the end of a title and the start of the technical description.
    ///
    /// Ordered longest-first within each group so `WEB-DL` is recognised before `WEB`. Matching is
    /// case-insensitive and anchored to token boundaries, so a film called *Heat* survives a rule
    /// that strips `HEVC`.
    private static let technicalTokens: [String] = [
        // Resolution and scan
        "2160p", "1440p", "1080p", "1080i", "720p", "576p", "480p", "4k", "uhd",
        // Source
        "web-dl", "webrip", "web", "bluray", "blu-ray", "bdrip", "brrip", "bdremux", "remux",
        "hdtv", "dvdrip", "hdrip", "camrip", "telesync",
        // Video codec
        "x265", "x264", "h265", "h264", "h.265", "h.264", "hevc", "avc", "av1", "xvid", "divx",
        "10bit", "8bit",
        // Dynamic range
        "hdr10+", "hdr10", "hdr", "dovi", "dv", "sdr", "hlg",
        // Audio
        "atmos", "truehd", "dts-hd", "dtshd", "dts-x", "dtsx", "dts", "ddp5.1", "ddp", "eac3",
        "ac3", "aac", "flac", "opus", "mp3", "5.1", "7.1", "2.0",
        // Distribution noise
        "proper", "repack", "extended", "unrated", "remastered", "imax", "multi", "dual-audio"
    ]

    /// Reads what it can from a filename, without its extension.
    static func parse(_ filename: String) -> FilenameMetadata {
        var working = filename

        // Separators first, so every later rule sees words rather than runs of punctuation.
        // Dashes are left alone — they belong inside `Spider-Man` and `WEB-DL` alike.
        working = working.replacingOccurrences(of: "_", with: " ")
        working = working.replacingOccurrences(of: ".", with: " ")

        // Episodes are recognised after separators are normalised, not before: the marker pattern
        // ends on a word boundary, and an underscore is a word character — so `Suits_S1E1_6E3020AD`
        // reads as an episode only once those underscores are spaces.
        let episode = VideoImporter.episodeMarker(in: working)

        let year = extractYear(from: working)

        // Everything from the first technical token onwards is description, not title.
        working = truncateAtTechnicalToken(working)
        // The year, and anything after it, is likewise not part of the title.
        working = truncateAtYear(working)
        if let episode {
            working = truncateAtEpisodeMarker(working)
            // A show's own title is what the marker was attached to.
            return FilenameMetadata(
                title: tidy(working).isEmpty ? episode.showName : tidy(working),
                year: year,
                episode: episode
            )
        }

        working = stripTrailingHash(working)
        working = stripReleaseGroup(working)

        // Never hand back nothing: a messy row is findable, a blank one isn't. Falls back through
        // progressively less processing, ending at the raw name.
        let title = [tidy(working), tidy(filename), filename].first { !$0.isEmpty } ?? filename
        return FilenameMetadata(title: title, year: year, episode: nil)
    }

    /// The first plausible release year in the name, and where it sits.
    ///
    /// Bounded to 1888 — the year of the oldest surviving film — through next year, so a
    /// resolution like `2160` can't be mistaken for one. Digits either side disqualify a match,
    /// which is what stops a serial number like `60A32926` or `1920x1080` from reading as a year.
    /// The boundaries are checked by hand because Swift Regex has no lookbehind.
    private static func yearMatch(in text: String) -> (value: Int, range: Range<String.Index>)? {
        let nextYear = Calendar.current.component(.year, from: .now) + 1
        for match in text.matches(of: /(18|19|20)[0-9]{2}/) {
            let precedingIsDigit = match.range.lowerBound > text.startIndex
                && text[text.index(before: match.range.lowerBound)].isNumber
            let followingIsDigit = match.range.upperBound < text.endIndex
                && text[match.range.upperBound].isNumber
            guard !precedingIsDigit, !followingIsDigit,
                  let value = Int(text[match.range]),
                  (1888...nextYear).contains(value) else { continue }
            return (value, match.range)
        }
        return nil
    }

    private static func extractYear(from text: String) -> Int? {
        yearMatch(in: text)?.value
    }

    private static func truncateAtYear(_ text: String) -> String {
        guard let match = yearMatch(in: text) else { return text }
        let head = String(text[text.startIndex..<match.range.lowerBound])
        // Only a boundary when something precedes it — a film titled `1917` must keep its name.
        return tidy(head).isEmpty ? text : head
    }

    private static func truncateAtTechnicalToken(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        var kept: [Substring] = []
        for word in words {
            let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}-"))
                .lowercased()
            if technicalTokens.contains(bare) { break }
            kept.append(word)
        }
        // Everything stripped means the name was nothing but description; keep the original.
        return kept.isEmpty ? text : kept.joined(separator: " ")
    }

    private static func truncateAtEpisodeMarker(_ text: String) -> String {
        let pattern = /[\s._-]*[Ss][0-9]{1,2}[\s._-]*[Ee][0-9]{1,3}/
        guard let match = text.firstMatch(of: pattern) else { return text }
        return String(text[text.startIndex..<match.range.lowerBound])
    }

    /// Removes a trailing content hash, the kind a download tool appends to keep names unique —
    /// `Ballerina 60A32926`. Requires at least six hex digits and at least one letter among them,
    /// so a year or a sequel number is never mistaken for one.
    private static func stripTrailingHash(_ text: String) -> String {
        let pattern = /\s+(?<hash>[0-9A-Fa-f]{6,})$/
        guard let match = text.firstMatch(of: pattern) else { return text }
        let hash = String(match.hash)
        guard hash.contains(where: { $0.isLetter }) else { return text }
        return String(text[text.startIndex..<match.range.lowerBound])
    }

    /// Removes a trailing `-GROUP` tag, which scene releases append after everything else.
    ///
    /// Only an all-capitals tag counts. Requiring capitals is what separates `-RARBG` from the
    /// `-Verse` of *Spider-Man: Across the Spider-Verse*, which an earlier rule keyed on "is there
    /// a space earlier in the name" happily ate. A lowercase group survives instead of a real
    /// word being destroyed — the safer direction, since a stray token still matches in search.
    private static func stripReleaseGroup(_ text: String) -> String {
        guard let match = text.firstMatch(of: /-(?<group>[A-Z0-9]{2,})$/) else { return text }
        let group = String(match.group)
        guard group.contains(where: { $0.isLetter }) else { return text }
        return String(text[text.startIndex..<match.range.lowerBound])
    }

    /// Collapses runs of whitespace and trims the punctuation a strip can leave behind.
    private static func tidy(_ text: String) -> String {
        text
            .replacing(/\s+/, with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -_.([{}])"))
    }
}
