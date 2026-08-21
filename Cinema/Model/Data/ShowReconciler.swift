/*
See the LICENSE.txt file for licensing information.

Abstract:
Giving episodes the series they belong to, whenever one is found without it.
*/

import Foundation
import SwiftData
import os

/// Attaches episodes to their series.
///
/// This is where the V7 → V8 backfill actually happens. It began life inside the migration's
/// `didMigrate`, which never ran: SwiftData skips a custom stage's hook when the schema difference
/// is lightweight-eligible, and adding a model plus an optional relationship is exactly that. A
/// migration that silently does nothing is the worst possible home for the one step that decides
/// whether anybody's library has shows in it.
///
/// So it runs at launch instead, and is written to be run again — it looks for episodes that have
/// a show *name* and no show, which is true of a library that has just migrated, of one where an
/// episode was added by an older build, and of nothing else. On a library that is already correct
/// it fetches nothing and returns.
@MainActor
enum ShowReconciler {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Cinema",
                                       category: "Shows")

    /// Attaches every episode that has a show name but no show.
    ///
    /// - Returns: how many episodes were attached, and how many series were created for them.
    @discardableResult
    static func reconcile(in context: ModelContext) -> (episodes: Int, shows: Int) {
        let descriptor = FetchDescriptor<Video>(
            predicate: #Predicate { $0.showName != nil && $0.show == nil })
        guard let orphans = try? context.fetch(descriptor), !orphans.isEmpty else { return (0, 0) }

        let before = (try? context.fetchCount(FetchDescriptor<Show>())) ?? 0
        var attached = 0
        // Sorted, so a library with two spellings of one series produces the same show name every
        // time rather than one that depends on the order rows came back in.
        for episode in orphans.sorted(by: { ($0.showName ?? "") < ($1.showName ?? "") }) {
            guard let name = episode.showName,
                  let show = Show.findOrCreate(named: name, in: context) else { continue }
            episode.show = show
            // A series matched before it had a row of its own keeps that match, rather than
            // starting again from nothing.
            if show.tmdbShowID == nil { show.tmdbShowID = episode.tmdbShowID }
            attached += 1
        }
        let created = ((try? context.fetchCount(FetchDescriptor<Show>())) ?? 0) - before

        if attached > 0 {
            try? context.save()
            logger.notice("Attached \(attached, privacy: .public) episode(s) to \(created, privacy: .public) new series.")
        }
        return (attached, created)
    }
}
