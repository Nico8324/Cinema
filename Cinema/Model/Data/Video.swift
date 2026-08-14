/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A model class that defines the properties of a video.
*/

import Foundation
import SwiftData
import CoreMedia
import SwiftUI

/// A model class that defines the properties of a video.
@Model
final class Video: Identifiable {
    @Relationship(inverse: \Person.appearsIn)
    var actors: [Person]
    
    @Relationship(inverse: \Person.wrote)
    var writers: [Person]
    
    @Relationship(inverse: \Person.directed)
    var directors: [Person]
    
    @Relationship(inverse: \Genre.videos)
    var genres: [Genre]
    
    @Relationship(inverse: \UpNextItem.video)
    var upNextItem: UpNextItem?
    
    private var categoryIDs: [Int]
    
    @Transient
    var categories: [Category] {
        get {
            categoryIDs.compactMap { Category(rawValue: $0) }
        }
        set {
            categoryIDs = newValue.map(\.rawValue)
        }
    }
    
    var id: Int
    var url: URL
    var imageName: String
    var name: String
    var synopsis: String
    var yearOfRelease: Int
    var duration: Int
    var startTime: CMTimeValue
    var contentRating: String
    var isHero: Bool
    var isFeatured: Bool
    /// Whether a poster thumbnail has been generated from the video file itself (see `ThumbnailGenerator`).
    /// Generation happens asynchronously after import, so this starts `false` and flips once the file lands on disk.
    /// Declared with an inline default so SwiftData's lightweight migration can backfill existing rows —
    /// a default only in `init` isn't visible to the migration (learned this the hard way with `playbackPosition`).
    var hasThumbnail: Bool = false
    /// How far into the video playback last stopped, in seconds. Drives the "Continue Watching" resume behavior.
    var playbackPosition: Double = 0
    /// When playback of this video was last updated — sorts the "Continue Watching" row by recency.
    var lastWatchedDate: Date?

    init(
        id: Int,
        name: String,
        synopsis: String,
        actors: [Person] = [],
        writers: [Person] = [],
        directors: [Person] = [],
        genres: [Genre] = [],
        categoryIDs: [Int] = [],
        url: URL,
        imageName: String,
        yearOfRelease: Int = 2023,
        duration: Int = 0,
        startTime: CMTimeValue = 0,
        contentRating: String = "NR",
        isHero: Bool = false,
        isFeatured: Bool = false,
        hasThumbnail: Bool = false,
        playbackPosition: Double = 0,
        lastWatchedDate: Date? = nil
    ) {
        self.actors = actors
        self.writers = writers
        self.directors = directors
        self.genres = genres
        self.categoryIDs = categoryIDs
        self.id = id
        self.url = url
        self.imageName = imageName
        self.name = name
        self.synopsis = synopsis
        self.yearOfRelease = yearOfRelease
        self.duration = duration
        self.startTime = startTime
        self.contentRating = contentRating
        self.isHero = isHero
        self.isFeatured = isFeatured
        self.hasThumbnail = hasThumbnail
        self.playbackPosition = playbackPosition
        self.lastWatchedDate = lastWatchedDate
    }
}

extension Video {
    var formattedDuration: String {
        Duration.seconds(duration)
            .formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2)))
    }
    
    var formattedYearOfRelease: String {
        yearOfRelease
            .formatted(.number.grouping(.never))
    }
    
    var landscapeImageName: String {
        "\(imageName)_landscape"
    }

    var portraitImageName: String {
        "\(imageName)_portrait"
    }

    /// The generated poster thumbnail's file location, for locally imported videos that have one.
    var thumbnailURL: URL? {
        guard hasThumbnail, url.isFileURL, let filename = url.host(), !filename.isEmpty else {
            return nil
        }
        return URL.applicationSupportDirectory
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
            .appending(path: filename, directoryHint: .notDirectory)
            .deletingPathExtension()
            .appendingPathExtension("jpg")
    }

    /// The generated thumbnail's raw data, if one exists on disk for this video.
    private var thumbnailData: Data? {
        guard let thumbnailURL else { return nil }
        return try? Data(contentsOf: thumbnailURL)
    }

    /// A landscape poster image — the generated video thumbnail if one exists, otherwise the named asset.
    var landscapeImage: Image {
        if let thumbnailData, let platformImage = PlatformImage(data: thumbnailData) {
            return Image(platformImage: platformImage)
        }
        return Image(landscapeImageName)
    }

    /// A portrait poster image — the generated video thumbnail if one exists, otherwise the named asset.
    var portraitImage: Image {
        if let thumbnailData, let platformImage = PlatformImage(data: thumbnailData) {
            return Image(platformImage: platformImage)
        }
        return Image(portraitImageName)
    }
    
    var localizedName: String {
        String(localized: LocalizedStringResource(stringLiteral: self.name))
    }
    
    var localizedSynopsis: String {
        String(localized: LocalizedStringResource(stringLiteral: self.synopsis))
    }
    
    var localizedContentRating: String {
        String(localized: LocalizedStringResource(stringLiteral: self.contentRating))
    }
    
    /// A url that resolves to specific local or remote media.
    ///
    /// Locally imported videos store only a filename marker (`file://<filename>`), not an absolute
    /// path — the app's sandbox container path isn't stable across reinstalls/updates, so the real
    /// path is reconstructed fresh against the current container every time this is read.
    var resolvedURL: URL {
        guard url.isFileURL, let filename = url.host(), !filename.isEmpty else {
            return url
        }
        return URL.applicationSupportDirectory
            .appending(path: "Videos", directoryHint: .isDirectory)
            .appending(path: filename, directoryHint: .notDirectory)
    }
    
    /// A Boolean value that indicates whether the video is hosted in a remote location.
    var hasRemoteMedia: Bool {
        !url.isFileURL
    }
    
    var imageData: Data {
        thumbnailData ?? PlatformImage(named: landscapeImageName)?.imageData ?? Data()
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

    /// Removes the locally imported video file and its generated thumbnail (if any) from disk.
    /// Safe to call for remote-media videos, which have neither.
    func removeLocalFiles() {
        guard !hasRemoteMedia else { return }
        try? FileManager.default.removeItem(at: resolvedURL)
        if let thumbnailURL {
            try? FileManager.default.removeItem(at: thumbnailURL)
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
