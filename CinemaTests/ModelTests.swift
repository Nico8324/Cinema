/*
See the LICENSE.txt file for licensing information.

Abstract:
Tests for Video's derived properties, genre hygiene, and applying TMDB matches.
*/

import Foundation
import SwiftData
import Testing
@testable import Cinema

extension CinemaSuite {
    @Suite("Video model")
    @MainActor
    struct VideoModelTests {

        @Test("Playback progress and resume heuristics")
        func playbackHeuristics() {
            let video = Video(name: "Movie", synopsis: "", yearOfRelease: 2026, duration: 1_000)

            video.playbackPosition = 0
            #expect(video.playbackProgress == 0)
            #expect(!video.isPartiallyWatched)

            // An accidental tap isn't worth resuming.
            video.playbackPosition = 4
            #expect(!video.isPartiallyWatched)

            video.playbackPosition = 500
            #expect(video.playbackProgress == 0.5)
            #expect(video.isPartiallyWatched)

            // Essentially finished isn't worth resuming either.
            video.playbackPosition = 990
            #expect(!video.isPartiallyWatched)

            // Unknown duration never divides by zero.
            let unknownDuration = Video(name: "Clip", synopsis: "", yearOfRelease: 2026, duration: 0)
            unknownDuration.playbackPosition = 50
            #expect(unknownDuration.playbackProgress == 0)
        }

        @Test("Media and thumbnail references derive from the entry's source")
        func sourceDerivedReferences() {
            let local = Video(name: "Local", synopsis: "", localFilename: "abc.mp4", yearOfRelease: 2026)
            #expect(local.mediaURL == MediaStore.videoURL(forFilename: "abc.mp4"))
            #expect(local.thumbnailFilename == "abc.mp4")
            #expect(!local.isYouTubeVideo)

            let youtube = Video(
                name: "Tube",
                synopsis: "",
                remoteURL: YouTubeSource.watchURL(forVideoID: "aqz-KE-bpKQ"),
                yearOfRelease: 2026
            )
            #expect(youtube.isYouTubeVideo)
            #expect(youtube.mediaURL == youtube.remoteURL)
            #expect(youtube.thumbnailFilename == "youtube-aqz-KE-bpKQ.jpg")

            let empty = Video(name: "Empty", synopsis: "", yearOfRelease: 2026)
            #expect(empty.mediaURL == nil)
            #expect(empty.thumbnailFilename == nil)

            // Thumbnail URLs only exist once a thumbnail was actually generated.
            #expect(local.thumbnailURL == nil)
            local.hasThumbnail = true
            #expect(local.thumbnailURL == MediaStore.thumbnailURL(forFilename: "abc.mp4"))
        }

        @Test("Orphaned genres are swept, attached ones survive")
        func genreOrphanSweep() throws {
            let context = try TestSupport.freshContext()

            let video = Video(name: "Movie", synopsis: "", yearOfRelease: 2026)
            context.insert(video)
            let attached = Genre(name: "Action")
            let orphan = Genre(name: "Adventure")
            context.insert(attached)
            context.insert(orphan)
            video.genres = [attached]
            try context.save()

            Genre.deleteOrphaned(in: context)

            let remaining = try context.fetch(FetchDescriptor<Genre>())
            #expect(remaining.map(\.name) == ["Action"])
        }

        @Test("Applying a TMDB match fills metadata and reuses existing genres")
        func tmdbApply() throws {
            let context = try TestSupport.freshContext()

            let video = Video(name: "avengers doomsday (2026)", synopsis: "old", yearOfRelease: 2020)
            context.insert(video)
            let existingAction = Genre(name: "Action")
            context.insert(existingAction)
            video.genres = [existingAction]
            try context.save()

            let movie = TMDB.Movie(
                id: 986055,
                title: "Avengers: Doomsday",
                overview: "Heroes collide.",
                originalTitle: "Avengers: Doomsday",
                releaseDate: "2026-12-16",
                posterPath: "/poster.jpg",
                backdropPath: "/backdrop.jpg",
                popularity: nil,
                voteCount: nil
            )
            let match = TMDB.Match(
                movie: movie,
                genreNames: ["Action", "Science Fiction"],
                certification: "PG-13",
                backdropData: nil,
                posterData: nil,
                trailerYouTubeID: "trailer123"
            )

            TMDB.apply(match, to: video, in: context)

            #expect(video.name == "Avengers: Doomsday")
            #expect(video.synopsis == "Heroes collide.")
            #expect(video.yearOfRelease == 2026)
            #expect(video.contentRating == "PG-13")
            #expect(video.tmdbID == 986055)
            #expect(video.trailerYouTubeID == "trailer123")
            #expect(Set(video.genres.map(\.name)) == ["Action", "Science Fiction"])

            // "Action" was reused, not duplicated.
            let genres = try context.fetch(FetchDescriptor<Genre>())
            #expect(genres.filter { $0.name == "Action" }.count == 1)

            // Movie helpers derive year and image URLs.
            #expect(movie.year == 2026)
            #expect(movie.thumbnailURL?.absoluteString == "https://image.tmdb.org/t/p/w154/poster.jpg")
            #expect(movie.backdropURL?.absoluteString == "https://image.tmdb.org/t/p/w780/backdrop.jpg")
        }
    }
}
