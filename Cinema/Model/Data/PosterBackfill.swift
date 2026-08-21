/*
See the LICENSE.txt file for licensing information.

Abstract:
Fills in portrait posters for library entries matched before the app stored them.
*/

import Foundation
import SwiftData

/// Downloads the posters that matched library entries don't have yet.
///
/// Every video matched before posters existed has only its wide backdrop on disk, so switching the
/// library to posters would show a shelf of backdrops in portrait frames. This quietly fetches what
/// is missing, one title at a time, and leaves everything already stored alone — so it costs nothing
/// on later runs, and an interrupted pass simply resumes on the next one.
enum PosterBackfill {
    @MainActor
    static func run(in context: ModelContext) async {
        let videos = (try? context.fetch(FetchDescriptor<Video>())) ?? []

        for video in videos where !video.isEpisode {
            guard !Task.isCancelled else { return }
            guard let movieID = video.tmdbID,
                  let filename = video.thumbnailFilename else { continue }
            if hasStoredPoster(named: filename) {
                // Heal a stranded flag: `applyPoster` toggles `hasPoster` through false and
                // restores it a cycle later, so a termination between the two writes persists
                // `false` while the file sits on disk — and this loop would then skip the
                // title forever without ever showing its poster.
                if !video.hasPoster {
                    video.hasPoster = true
                    video.modelContext?.saveReportingErrors()
                }
                continue
            }
            guard let movie = try? await TMDB.movie(forID: movieID) else { continue }
            TMDB.applyPoster(try? await TMDB.fetchImage(at: movie.fullResolutionPosterURL), to: video)
        }

        // One poster per show, not per episode: every episode of a show shares it.
        let showIDs = Set(videos.compactMap(\.tmdbShowID))
        for showID in showIDs {
            guard !Task.isCancelled else { return }
            let filename = MediaStore.showArtworkFilename(forShowID: showID)
            guard !hasStoredPoster(named: filename) else { continue }
            guard let show = try? await TMDB.show(forID: showID) else { continue }
            TMDB.applyShowPoster(try? await TMDB.fetchImage(at: show.fullResolutionPosterURL), forShowID: showID)
        }
    }

    /// Whether the poster file itself is on disk — the flag alone can't be trusted here, since the
    /// file may have been swept while the entry survived.
    private static func hasStoredPoster(named filename: String) -> Bool {
        FileManager.default.fileExists(atPath: MediaStore.posterURL(forFilename: filename).path)
    }
}
