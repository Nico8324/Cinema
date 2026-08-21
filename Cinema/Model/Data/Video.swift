/*
See the LICENSE.txt file for licensing information.

Abstract:
A model class that defines the properties of a video.
*/

import Foundation
import SwiftData
import SwiftUI

/// A model class that defines the properties of a video.
@Model
final class Video: Identifiable {
    @Relationship(inverse: \Genre.videos)
    var genres: [Genre]

    /// Deleting a video also deletes its Up Next queue entry.
    @Relationship(deleteRule: .cascade, inverse: \UpNextItem.video)
    var upNextItem: UpNextItem?

    /// A stable, globally unique identity for the video, independent of the store's internals.
    /// Declared with an inline default so SwiftData's migration can backfill existing rows —
    /// a default only in `init` isn't visible to the migration (learned the hard way with `playbackPosition`).
    var uuid: UUID = UUID()

    /// The filename of the imported media file inside the app's Videos directory.
    /// Only the filename is stored, never an absolute path — the app's sandbox container path
    /// isn't stable across reinstalls/updates, so `mediaURL` reconstructs the full path fresh
    /// against the current container every time it's read.
    var localFilename: String?

    /// A remote streaming URL, for videos not backed by a local file. Unused by the current
    /// import flow, but kept explicit (rather than overloading one URL property with two
    /// meanings) for a future remote-source feature.
    @Attribute(originalName: "url")
    var remoteURL: URL?

    /// The absolute path of a file the library references where it already sits on disk, rather
    /// than copying into its own storage — how the Mac's scanned media folder works.
    ///
    /// Unlike `localFilename`, this *is* an absolute path, because the file isn't the app's to
    /// move: it belongs to the person's own folder structure, outside any container the app
    /// controls. Nothing here is ever deleted on the app's behalf.
    var externalPath: String?

    var name: String
    var synopsis: String
    var yearOfRelease: Int
    /// The video's duration in whole seconds.
    var duration: Int
    var contentRating: String
    /// When the video was added to the library — drives the "Recently Added" ordering.
    var dateAdded: Date = Date.distantPast
    /// The TMDB movie this entry was matched to, if any — enables metadata refreshes.
    var tmdbID: Int?
    /// The YouTube video ID of the movie's official trailer, from TMDB.
    var trailerYouTubeID: String?
    /// For TV episodes: the show this episode belongs to. `nil` means a movie.
    ///
    /// The name as the *filename* spelled it, which is what groups an episode on import before
    /// anything has been matched. `show` is where the series itself lives — its title, its poster,
    /// its TMDB match — and a match is allowed to rename that without touching this, because this
    /// is a grouping key and renaming a key regroups the library.
    var showName: String?
    /// The series this episode belongs to. `nil` for a movie, and for an episode scanned before
    /// V8 that hasn't been attached yet.
    var show: Show?
    /// For TV episodes: the season number parsed from the filename ("S01").
    var seasonNumber: Int?
    /// For TV episodes: the episode number parsed from the filename ("E02").
    var episodeNumber: Int?
    /// The TMDB show this episode's show was matched to, if any.
    var tmdbShowID: Int?
    /// The episode's own title from TMDB, like "The Engineer".
    var episodeTitle: String?
    /// Whether a portrait poster has been downloaded for this video.
    ///
    /// Separate from `hasThumbnail`: that one is a frame taken from the film, this one is the
    /// studio's own artwork, and a video can have either, both or neither.
    var hasPoster: Bool = false
    /// Whether a poster thumbnail has been generated from the video file itself (see `ThumbnailGenerator`).
    /// Generation happens asynchronously after import, so this starts `false` and flips once the file lands on disk.
    var hasThumbnail: Bool = false
    /// How far into the video playback last stopped, in seconds. Drives the "Continue Watching" resume behavior.
    var playbackPosition: Double = 0
    /// When playback of this video was last updated — sorts the "Continue Watching" row by recency.
    var lastWatchedDate: Date?

    init(
        name: String,
        synopsis: String,
        genres: [Genre] = [],
        localFilename: String? = nil,
        remoteURL: URL? = nil,
        externalPath: String? = nil,
        yearOfRelease: Int,
        duration: Int = 0,
        contentRating: String = "NR",
        dateAdded: Date = .now,
        showName: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        hasThumbnail: Bool = false,
        playbackPosition: Double = 0,
        lastWatchedDate: Date? = nil
    ) {
        self.genres = genres
        self.uuid = UUID()
        self.localFilename = localFilename
        self.remoteURL = remoteURL
        self.externalPath = externalPath
        self.name = name
        self.synopsis = synopsis
        self.yearOfRelease = yearOfRelease
        self.duration = duration
        self.contentRating = contentRating
        self.dateAdded = dateAdded
        self.showName = showName
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.tmdbShowID = nil
        self.episodeTitle = nil
        self.hasThumbnail = hasThumbnail
        self.playbackPosition = playbackPosition
        self.lastWatchedDate = lastWatchedDate
    }
}

extension Video {
    var id: UUID { uuid }

    /// Whether this entry is a TV episode rather than a movie.
    var isEpisode: Bool {
        showName != nil
    }

    /// The episode marker like "S1, E2", in the TV-app style. `nil` for movies.
    var episodeLabel: String? {
        guard isEpisode, let seasonNumber, let episodeNumber else { return nil }
        return String(localized: "S\(seasonNumber), E\(episodeNumber)")
    }

    /// The user-facing title: a movie's name, or "Show S1, E2" for episodes.
    var displayName: String {
        if let episodeLabel {
            return "\(name) \(episodeLabel)"
        }
        return name
    }

    /// The duration formatted for display, like "1h 32m" or "8m 24s".
    var formattedDuration: String {
        let allowed: Set<Duration.UnitsFormatStyle.Unit> = duration >= 3600 ? [.hours, .minutes] : [.minutes, .seconds]
        return Duration.seconds(duration).formatted(.units(allowed: allowed, width: .narrow))
    }

    /// The duration spelled out for VoiceOver, like "1 hour, 32 minutes".
    var accessibleDuration: String {
        let allowed: Set<Duration.UnitsFormatStyle.Unit> = duration >= 3600 ? [.hours, .minutes] : [.minutes, .seconds]
        return Duration.seconds(duration).formatted(.units(allowed: allowed, width: .wide))
    }

    var formattedYearOfRelease: String {
        yearOfRelease.formatted(.number.grouping(.never))
    }

    /// A URL that resolves to the video's playable media — the imported local file if there is
    /// one, otherwise the remote URL. `nil` when the video has no media at all.
    var mediaURL: URL? {
        if let externalPath {
            return URL(filePath: externalPath)
        }
        if let localFilename {
            return MediaStore.videoURL(forFilename: localFilename)
        }
        return remoteURL
    }

    /// Whether the media lives in the person's own folder rather than the app's storage.
    ///
    /// Referenced media is off-limits for deletion and for the reconciler's stranded-file sweep:
    /// an unreachable path means an unplugged drive or a moved folder, not a stale entry.
    var isExternallyReferenced: Bool {
        externalPath != nil
    }

    /// Whether this entry is a YouTube video rather than an imported file.
    var isYouTubeVideo: Bool {
        guard localFilename == nil, let remoteURL else { return false }
        return YouTubeSource.isYouTubeURL(remoteURL)
    }

    /// The filename that keys this video's generated thumbnail on disk.
    ///
    /// Imported files use their stored filename and YouTube entries their video ID. Referenced
    /// files are keyed by the entry's own UUID: their real filenames can collide across folders,
    /// and the thumbnail belongs to the app's storage even though the media doesn't.
    var thumbnailFilename: String? {
        if let localFilename { return localFilename }
        if externalPath != nil { return "external-\(uuid.uuidString).jpg" }
        if let remoteURL, let id = YouTubeSource.videoID(from: remoteURL) {
            return "youtube-\(id).jpg"
        }
        return nil
    }

    /// The downloaded portrait poster's location, for videos that have one.
    ///
    /// Episodes don't get their own: a poster is the show's, and every episode of a show shares it,
    /// the same way they share the show's backdrop.
    var posterURL: URL? {
        if let tmdbShowID {
            return MediaStore.posterURL(forFilename: MediaStore.showArtworkFilename(forShowID: tmdbShowID))
        }
        guard hasPoster, let thumbnailFilename else { return nil }
        return MediaStore.posterURL(forFilename: thumbnailFilename)
    }

    /// The generated poster thumbnail's file location, for videos that have one.
    var thumbnailURL: URL? {
        guard hasThumbnail, let thumbnailFilename else { return nil }
        return MediaStore.thumbnailURL(forFilename: thumbnailFilename)
    }

    /// How much of the video has been watched, from 0 (not started) to 1 (finished).
    var playbackProgress: Double {
        guard duration > 0 else { return 0 }
        return min(max(playbackPosition / Double(duration), 0), 1)
    }

    /// Whether the video has meaningful, unfinished playback progress worth offering to resume.
    /// Excludes videos just barely started (accidental taps) and videos essentially finished.
    var isPartiallyWatched: Bool {
        playbackPosition > 5 && playbackProgress < 0.95
    }

    /// Removes this video's files from disk: the imported media file and its thumbnail
    /// for local videos, or just the generated thumbnail for remote (YouTube) entries.
    ///
    /// Referenced media is deliberately untouched — `externalPath` never reaches `MediaStore`.
    /// Removing an entry that points into the person's own folder must delete the library's
    /// record of it and the thumbnail the app generated, never the film itself.
    func removeLocalFiles() {
        // Tested first and explicitly: the safety used to rest on referenced entries happening to
        // have no `localFilename`, which would quietly stop being true the moment one gained a
        // cached local copy. Say what's meant instead of relying on a coincidence.
        if isExternallyReferenced {
            if let thumbnailFilename {
                MediaStore.removeMedia(forFilename: thumbnailFilename)
            }
        } else if let localFilename {
            MediaStore.removeMedia(forFilename: localFilename)
        } else if let thumbnailFilename {
            // A YouTube entry: only the generated thumbnail exists to remove.
            MediaStore.removeMedia(forFilename: thumbnailFilename)
        }
    }

    func toggleUpNext(in context: ModelContext) {
        if let upNextItem {
            context.delete(upNextItem)
            self.upNextItem = nil
        } else {
            let item = UpNextItem(video: self)
            context.insert(item)
            self.upNextItem = item
        }
    }
}
