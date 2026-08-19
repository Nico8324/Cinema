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
        let currentSchema = Schema(versionedSchema: CinemaSchemaV7.self)
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
}
