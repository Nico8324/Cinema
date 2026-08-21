/*
See the LICENSE.txt file for licensing information.

Abstract:
A television series as a thing in its own right, rather than a string repeated on every episode.
*/

import Foundation
import SwiftData

/// A television series.
///
/// Shows used to exist only as a `showName` string copied onto every episode, grouped at query
/// time. That works until you ask it a question about the *show*: where its poster lives, what it
/// is called when its episodes disagree, what happens when the last episode is deleted. The
/// answers were, respectively, nowhere, whichever episode sorted first, and it silently ceased to
/// exist — along with its TMDB match and everything downloaded for it.
///
/// A show is now a row. Episodes point at it, so show-level facts have one home, a show outlives
/// its episodes, and two spellings of one name can no longer become two shows.
@Model
final class Show {
    #Index<Show>([\.sortKey])

    var id: UUID = UUID()

    /// What the show is called, for reading. Set from the episodes' parsed name to begin with and
    /// replaced by TMDB's own title once matched — the one place a rename is allowed to happen.
    var name: String = ""

    /// The identity two spellings share, and what a lookup matches on.
    ///
    /// Case and surrounding space are removed because they are the difference between `Suits`,
    /// `suits` and `Suits ` — three rows, three posters, three pages, one series. The grouping key
    /// has to be insensitive to the things a filename is careless about.
    var sortKey: String = ""

    var tmdbShowID: Int?
    var synopsis: String?
    var firstAiredYear: Int?
    /// Whether a portrait poster has been downloaded for the show, matching `Video.hasPoster`.
    var hasPoster: Bool = false
    var dateAdded: Date = Date.now

    /// The episodes, newest schema first. `nullify` rather than `cascade`: deleting a show should
    /// not delete the files' rows out from under the library, and deleting the last episode should
    /// leave the show — with its match and its artwork — waiting for the next one.
    @Relationship(deleteRule: .nullify, inverse: \Video.show)
    var episodes: [Video]? = []

    init(name: String, tmdbShowID: Int? = nil) {
        self.id = UUID()
        self.name = name
        self.sortKey = Show.key(for: name)
        self.tmdbShowID = tmdbShowID
        self.dateAdded = .now
        self.episodes = []
    }

    /// Which of two spellings is the better one to show a person.
    ///
    /// The spellings differ only in the things the key ignores — case and space — so the row's
    /// identity is settled and only its *label* is in question. A capital is evidence someone
    /// typed the name rather than a tool lowercasing it, so `Suits` beats `suits`; where that
    /// can't separate them, the alphabetically earlier one wins so the answer doesn't depend on
    /// which episode a fetch happened to return first. That dependence is the bug this model was
    /// built to remove, and it would have crept back in through the name.
    static func preferredName(between first: String, and second: String) -> String {
        let firstHasCapital = first != first.lowercased()
        let secondHasCapital = second != second.lowercased()
        if firstHasCapital != secondHasCapital { return firstHasCapital ? first : second }
        return first <= second ? first : second
    }

    /// The grouping key for a show name as a filename spelled it.
    static func key(for name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "  ", with: " ")
    }

    /// The show for a name, creating it the first time that name is seen.
    ///
    /// Find-or-create rather than create-and-deduplicate, because the alternative is two rows for
    /// one series the moment a second episode is scanned — which is exactly the bug the model
    /// exists to remove.
    @MainActor
    static func findOrCreate(named name: String, in context: ModelContext) -> Show? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = key(for: trimmed)

        var descriptor = FetchDescriptor<Show>(predicate: #Predicate { $0.sortKey == key })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            // A better spelling of a name already seen improves the label without touching the
            // identity — which is what makes the result independent of fetch order.
            existing.name = preferredName(between: existing.name, and: trimmed)
            return existing
        }

        let show = Show(name: trimmed)
        context.insert(show)
        return show
    }

    /// Episodes in the order the series runs, rather than the order they were added.
    var episodesInOrder: [Video] {
        (episodes ?? []).sorted {
            ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0) < ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0)
        }
    }

    var seasonNumbers: [Int] {
        Array(Set((episodes ?? []).compactMap(\.seasonNumber))).sorted()
    }
}
