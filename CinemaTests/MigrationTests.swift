/*
See the LICENSE.txt file for licensing information.

Abstract:
Tests that the schema migration plan carries real V1 stores forward intact.
*/

import Foundation
import SwiftData
import Testing
@testable import Cinema

extension CinemaSuite {
    /// Builds a store with the shipped V1 schema, migrates it through the full plan,
    /// and asserts the library survives — the automated version of the manual
    /// simulator verification done when V2 was introduced.
    @Suite("Schema migration")
    @MainActor
    struct MigrationTests {

    @Test("V1 store migrates to the current schema intact")
    func migratesV1StoreForward() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "migration-test-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "store.sqlite")
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

        let localMarkerURL = URL(string: "file://5D3A1111-2222-3333-4444-555566667777.mp4")!
        let remoteURL = URL(string: "https://example.com/stream.m3u8")!

        // Build a V1 store the way v0.0.1 did.
        do {
            let v1Schema = Schema(versionedSchema: CinemaSchemaV1.self)
            let container = try ModelContainer(
                for: v1Schema,
                configurations: [ModelConfiguration(schema: v1Schema, url: storeURL)]
            )
            let context = container.mainContext

            let localVideo = CinemaSchemaV1.Video(id: 0, url: localMarkerURL, name: "Local Movie")
            localVideo.playbackPosition = 42
            localVideo.hasThumbnail = true
            let remoteVideo = CinemaSchemaV1.Video(id: 1, url: remoteURL, name: "Remote Movie")
            context.insert(localVideo)
            context.insert(remoteVideo)

            let genre = CinemaSchemaV1.Genre(id: 0, name: "Action")
            context.insert(genre)
            localVideo.genres = [genre]

            let person = CinemaSchemaV1.Person(id: 0, initial: "A", surname: "Body")
            context.insert(person)

            // One queue entry attached to a video, one orphaned by a past deletion.
            let attachedItem = CinemaSchemaV1.UpNextItem(videoID: 0)
            attachedItem.video = localVideo
            context.insert(attachedItem)
            context.insert(CinemaSchemaV1.UpNextItem(videoID: 99))

            try context.save()
        }

        // Reopen through the migration plan, exactly like the app does.
        let currentSchema = Schema(versionedSchema: CinemaSchemaV10.self)
        let migrated = try ModelContainer(
            for: currentSchema,
            migrationPlan: CinemaMigrationPlan.self,
            configurations: [ModelConfiguration(schema: currentSchema, url: storeURL)]
        )
        let context = migrated.mainContext

        let videos = try context.fetch(FetchDescriptor<Video>(sortBy: [SortDescriptor(\.name)]))
        #expect(videos.count == 2)

        let local = try #require(videos.first { $0.name == "Local Movie" })
        let remote = try #require(videos.first { $0.name == "Remote Movie" })

        // The file:// marker unpacked into an explicit filename; case preserved.
        #expect(local.localFilename == "5D3A1111-2222-3333-4444-555566667777.mp4")
        #expect(local.remoteURL == nil)
        #expect(local.playbackPosition == 42)
        #expect(local.hasThumbnail)
        #expect(local.genres.map(\.name) == ["Action"])

        // Genuinely remote entries keep their URL and gain no filename.
        #expect(remote.remoteURL == remoteURL)
        #expect(remote.localFilename == nil)

        // Fresh, distinct identities; dates backfilled; V3 fields default to nil.
        #expect(local.uuid != remote.uuid)
        #expect(local.dateAdded != .distantPast)
        #expect(local.tmdbID == nil)
        #expect(local.trailerYouTubeID == nil)
        #expect(local.showName == nil)
        #expect(local.seasonNumber == nil)
        #expect(local.episodeNumber == nil)

        // The orphaned queue entry was swept; the attached one survived.
        let queueItems = try context.fetch(FetchDescriptor<UpNextItem>())
        #expect(queueItems.count == 1)
        #expect(queueItems.first?.video?.name == "Local Movie")
    }
}

    /// V7 → V8 gains a `Show` model, and the reconciler derives the rows that never existed: one
    /// per distinct name, with every episode attached. It is also where a library holding two
    /// spellings of one series is healed, because both match on the same insensitive key.
    ///
    /// The backfill lives outside the migration because SwiftData skips a custom stage's
    /// `didMigrate` when the change is lightweight-eligible — measured, by writing it there first
    /// and watching four episodes migrate into zero shows.
    @Test func v7ToV8GivesEveryEpisodeAShowAndMergesSpellings() throws {
        let storeURL = URL.temporaryDirectory
            .appending(path: "shows-\(UUID().uuidString)")
            .appending(path: "store.sqlite")
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

        do {
            let schema = Schema(versionedSchema: CinemaSchemaV7.self)
            let container = try ModelContainer(
                for: schema, configurations: [ModelConfiguration(schema: schema, url: storeURL)])
            let context = container.mainContext
            for (name, season, number) in [("Suits", 1, 1), ("suits ", 1, 2), ("Severance", 1, 1)] {
                let video = Video(name: name, synopsis: name, yearOfRelease: 2011,
                                  showName: name, seasonNumber: season, episodeNumber: number)
                video.tmdbShowID = name.hasPrefix("S") && name.contains("uits") ? 37680 : nil
                context.insert(video)
            }
            // A film, which must come out of the migration with no show at all.
            context.insert(Video(name: "Sinners", synopsis: "Sinners", yearOfRelease: 2025))
            try context.save()
        }

        let schema = Schema(versionedSchema: CinemaSchemaV10.self)
        let migrated = try ModelContainer(
            for: schema, migrationPlan: CinemaMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: storeURL)])
        let context = migrated.mainContext

        // The migration itself is lightweight; the rows are derived by the reconciler, which is
        // what the app runs at launch. Asserted here rather than in a separate test because the
        // pair is the migration — a schema that gains a model nobody fills is not an upgrade.
        let attached = ShowReconciler.reconcile(in: context)
        #expect(attached.episodes == 3)
        #expect(attached.shows == 2)

        let shows = try context.fetch(FetchDescriptor<Show>(sortBy: [SortDescriptor(\.name)]))
        // "Suits" and "suits " are one series, not two.
        #expect(shows.map(\.name) == ["Severance", "Suits"])

        let suits = try #require(shows.first { $0.sortKey == "suits" })
        #expect(suits.episodes?.count == 2)
        #expect(suits.tmdbShowID == 37680)

        let videos = try context.fetch(FetchDescriptor<Video>())
        let film = try #require(videos.first { $0.name == "Sinners" })
        #expect(film.show == nil)
        // The grouping key is left exactly as the filename spelled it: rewriting it here would be
        // a migration silently regrouping someone's library.
        #expect(Set(videos.compactMap(\.showName)) == ["Suits", "suits ", "Severance"])
    }
}
