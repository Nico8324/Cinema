/*
See the LICENSE.txt file for licensing information.

Abstract:
Versioned SwiftData schemas and the migration plan between them.
*/

import Foundation
import SwiftData
import CoreMedia

// MARK: - Current schema

/// The schema version the app currently uses.
///
/// The model classes themselves live in their own files (`Video`, `Genre`, `UpNextItem`);
/// this enum groups them under a version number so future schema changes migrate deliberately
/// through `CinemaMigrationPlan` instead of relying on lightweight-migration luck.
///
/// V4 adds `Video.showName`, `seasonNumber`, and `episodeNumber` for TV episodes.
enum CinemaSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Video.self, Genre.self, UpNextItem.self]
    }
}

// MARK: - Migration plan

enum CinemaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [CinemaSchemaV1.self, CinemaSchemaV2.self, CinemaSchemaV3.self, CinemaSchemaV4.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3, migrateV3toV4]
    }

    /// V1 → V2:
    /// - Removes the unused sample-catalog leftovers (`Person`, category IDs, hero/featured flags,
    ///   start time, asset image names).
    /// - Replaces the auto-incremented `Int` identity with a `UUID`.
    /// - Splits the overloaded `url` property (which smuggled a local filename through the URL's
    ///   host component) into an explicit `localFilename` and an optional `remoteURL`.
    /// - Adds `dateAdded`, backfilled for existing rows in `didMigrate`.
    /// - Deletes Up Next entries orphaned by earlier video deletions.
    static let migrateV1toV2 = MigrationStage.custom(
        fromVersion: CinemaSchemaV1.self,
        toVersion: CinemaSchemaV2.self,
        willMigrate: nil,
        didMigrate: { context in
            let videos = try context.fetch(FetchDescriptor<CinemaSchemaV2.Video>())
            for video in videos {
                // Give every migrated row a fresh identity. The lightweight backfill of the
                // inline default may stamp all rows with the same value, so assign explicitly.
                video.uuid = UUID()
                video.dateAdded = .now

                // Unpack the legacy "file://<filename>" marker into an explicit local filename.
                if let url = video.remoteURL, url.isFileURL {
                    video.localFilename = url.host()
                    video.remoteURL = nil
                }
            }

            // Remove queue entries whose video was deleted before the cascade rule existed.
            let upNextItems = try context.fetch(FetchDescriptor<CinemaSchemaV2.UpNextItem>())
            for item in upNextItems where item.video == nil {
                context.delete(item)
            }

            try context.save()
        }
    )

    /// V2 → V3: adds the optional `tmdbID` and `trailerYouTubeID` columns — additive only.
    static let migrateV2toV3 = MigrationStage.lightweight(
        fromVersion: CinemaSchemaV2.self,
        toVersion: CinemaSchemaV3.self
    )

    /// V3 → V4: adds the optional episode columns — additive only.
    static let migrateV3toV4 = MigrationStage.lightweight(
        fromVersion: CinemaSchemaV3.self,
        toVersion: CinemaSchemaV4.self
    )
}

// MARK: - Legacy schema V3

/// The V3 schema shape, kept only so existing stores can migrate.
/// Never reference these models outside the migration plan.
enum CinemaSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Video.self, Genre.self, UpNextItem.self]
    }

    @Model
    final class Video {
        @Relationship(inverse: \Genre.videos)
        var genres: [Genre]

        @Relationship(deleteRule: .cascade, inverse: \UpNextItem.video)
        var upNextItem: UpNextItem?

        var uuid: UUID = UUID()
        var localFilename: String?

        @Attribute(originalName: "url")
        var remoteURL: URL?

        var name: String
        var synopsis: String
        var yearOfRelease: Int
        var duration: Int
        var contentRating: String
        var dateAdded: Date = Date.distantPast
        var tmdbID: Int?
        var trailerYouTubeID: String?
        var hasThumbnail: Bool = false
        var playbackPosition: Double = 0
        var lastWatchedDate: Date?

        init(name: String) {
            self.genres = []
            self.name = name
            self.synopsis = ""
            self.yearOfRelease = 2023
            self.duration = 0
            self.contentRating = "NR"
        }
    }

    @Model
    final class Genre {
        @Relationship
        var videos: [Video]

        var name: String

        init(name: String) {
            self.videos = []
            self.name = name
        }
    }

    @Model
    final class UpNextItem {
        @Relationship(deleteRule: .nullify)
        var video: Video?

        var createdAt: Date

        init(createdAt: Date = .now) {
            self.createdAt = createdAt
        }
    }
}

// MARK: - Legacy schema V2

/// The V2 schema shape, kept only so existing stores can migrate.
/// Never reference these models outside the migration plan.
enum CinemaSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Video.self, Genre.self, UpNextItem.self]
    }

    @Model
    final class Video {
        @Relationship(inverse: \Genre.videos)
        var genres: [Genre]

        @Relationship(deleteRule: .cascade, inverse: \UpNextItem.video)
        var upNextItem: UpNextItem?

        var uuid: UUID = UUID()
        var localFilename: String?

        @Attribute(originalName: "url")
        var remoteURL: URL?

        var name: String
        var synopsis: String
        var yearOfRelease: Int
        var duration: Int
        var contentRating: String
        var dateAdded: Date = Date.distantPast
        var hasThumbnail: Bool = false
        var playbackPosition: Double = 0
        var lastWatchedDate: Date?

        init(name: String) {
            self.genres = []
            self.name = name
            self.synopsis = ""
            self.yearOfRelease = 2023
            self.duration = 0
            self.contentRating = "NR"
        }
    }

    @Model
    final class Genre {
        @Relationship
        var videos: [Video]

        var name: String

        init(name: String) {
            self.videos = []
            self.name = name
        }
    }

    @Model
    final class UpNextItem {
        @Relationship(deleteRule: .nullify)
        var video: Video?

        var createdAt: Date

        init(createdAt: Date = .now) {
            self.createdAt = createdAt
        }
    }
}

// MARK: - Legacy schema V1 (v0.0.1)

/// The schema shape the app shipped with, kept only so existing stores can migrate.
/// Never reference these models outside the migration plan.
enum CinemaSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Video.self, Person.self, Genre.self, UpNextItem.self]
    }

    @Model
    final class Video {
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
        var hasThumbnail: Bool = false
        var playbackPosition: Double = 0
        var lastWatchedDate: Date?

        init(id: Int, url: URL, name: String) {
            self.actors = []
            self.writers = []
            self.directors = []
            self.genres = []
            self.categoryIDs = []
            self.id = id
            self.url = url
            self.imageName = ""
            self.name = name
            self.synopsis = ""
            self.yearOfRelease = 2023
            self.duration = 0
            self.startTime = 0
            self.contentRating = "NR"
            self.isHero = false
            self.isFeatured = false
        }
    }

    @Model
    final class Person {
        @Relationship
        var appearsIn: [Video]

        @Relationship
        var wrote: [Video]

        @Relationship
        var directed: [Video]

        var id: Int
        var initial: String
        var surname: String

        init(id: Int, initial: String, surname: String) {
            self.appearsIn = []
            self.wrote = []
            self.directed = []
            self.id = id
            self.initial = initial
            self.surname = surname
        }
    }

    @Model
    final class Genre {
        @Relationship
        var videos: [Video]

        var id: Int
        var name: String

        init(id: Int, name: String) {
            self.videos = []
            self.id = id
            self.name = name
        }
    }

    @Model
    final class UpNextItem {
        @Attribute(.unique)
        private var videoID: Int

        @Relationship(deleteRule: .nullify)
        var video: Video?

        var createdAt: Date

        init(videoID: Int, createdAt: Date = .now) {
            self.videoID = videoID
            self.createdAt = createdAt
        }
    }
}
