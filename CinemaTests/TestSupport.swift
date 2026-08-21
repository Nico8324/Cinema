/*
See the LICENSE.txt file for licensing information.

Abstract:
Shared infrastructure for tests that touch SwiftData or the media store.
*/

import Foundation
import SwiftData
import Testing
@testable import Cinema

/// The serialized root for every suite that touches SwiftData or `MediaStore`.
///
/// SwiftData tolerates neither concurrent container churn across parallel test
/// workers nor repeated schema registration races — suites nested here run one
/// at a time, against one shared in-memory container.
@Suite(.serialized)
@MainActor
struct CinemaSuite {}

@MainActor
enum TestSupport {
    /// The single in-memory container shared by all tests in this process,
    /// built from the same versioned schema the app uses.
    static let container: ModelContainer = {
        let schema = Schema(versionedSchema: CinemaSchemaV8.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Couldn't create the shared test container: \(error)")
        }
    }()

    /// The shared main context, emptied of all model objects.
    /// Deletes object-by-object — batch deletes trip over the Video↔Genre
    /// many-to-many inverse.
    static func freshContext() throws -> ModelContext {
        let context = container.mainContext
        for item in try context.fetch(FetchDescriptor<UpNextItem>()) { context.delete(item) }
        for video in try context.fetch(FetchDescriptor<Video>()) { context.delete(video) }
        for genre in try context.fetch(FetchDescriptor<Genre>()) { context.delete(genre) }
        for show in try context.fetch(FetchDescriptor<Show>()) { context.delete(show) }
        try context.save()
        return context
    }

    /// Points `MediaStore` at a fresh scratch directory and returns it —
    /// tests must never touch a real library.
    static func useScratchMediaRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "cinema-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        MediaStore.rootDirectory = root
        return root
    }
}
