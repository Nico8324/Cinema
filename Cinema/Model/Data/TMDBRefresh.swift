/*
See the LICENSE.txt file for licensing information.

Abstract:
A library-wide refresh of TMDB metadata for everything already matched.
*/

import Foundation
import SwiftData

extension TMDB {
    /// The result of a library-wide metadata refresh.
    struct RefreshOutcome: Sendable {
        var updated = 0
        var failed = 0
    }

    /// Re-downloads and re-applies TMDB metadata for every matched movie and
    /// show in the library — titles, synopses, ratings, genres, trailers, and
    /// artwork in one pass. Unmatched entries are left alone. Failures
    /// (offline, an entry removed from TMDB) skip that title and keep going.
    @MainActor
    static func refreshLibraryMetadata(
        in context: ModelContext,
        onProgress: (_ completed: Int, _ total: Int) -> Void = { _, _ in }
    ) async -> RefreshOutcome {
        let videos = (try? context.fetch(FetchDescriptor<Video>())) ?? []
        let movies = videos.filter { $0.tmdbID != nil && !$0.isEpisode }
        let showGroups = Dictionary(grouping: videos.filter { $0.isEpisode && $0.tmdbShowID != nil }) {
            $0.tmdbShowID ?? -1
        }

        var outcome = RefreshOutcome()
        var completed = 0
        let total = movies.count + showGroups.count
        onProgress(completed, total)

        for video in movies {
            guard let movieID = video.tmdbID else { continue }
            do {
                let movie = try await movie(forID: movieID)
                let match = try await loadMatch(for: movie)
                apply(match, to: video, in: context)
                outcome.updated += 1
            } catch {
                outcome.failed += 1
            }
            completed += 1
            onProgress(completed, total)
        }

        for (showID, episodes) in showGroups {
            do {
                let show = try await show(forID: showID)
                var ownedSeasonEpisodes: [Int: Set<Int>] = [:]
                for episode in episodes {
                    ownedSeasonEpisodes[episode.seasonNumber ?? 1, default: []].insert(episode.episodeNumber ?? 1)
                }
                let match = try await loadShowMatch(for: show, ownedSeasonEpisodes: ownedSeasonEpisodes)
                apply(match, to: episodes, in: context)
                outcome.updated += 1
            } catch {
                outcome.failed += 1
            }
            completed += 1
            onProgress(completed, total)
        }

        return outcome
    }
}
