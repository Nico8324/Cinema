/*
See the LICENSE.txt file for licensing information.

Abstract:
Tests for the import pipeline and library reconciliation, against a scratch media root.
*/

import Foundation
import SwiftData
import Testing
@testable import Cinema

extension CinemaSuite {
    @Suite("Storage")
    @MainActor
    struct StorageTests {

        private func writeSourceFile(named name: String, size: Int, byte: UInt8 = 0xAB) throws -> URL {
            let url = FileManager.default.temporaryDirectory.appending(path: name)
            try Data(repeating: byte, count: size).write(to: url)
            return url
        }

        @Test("Importing copies the file and reports full progress")
        func importCopiesFile() async throws {
            let root = try TestSupport.useScratchMediaRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let source = try writeSourceFile(named: "movie-\(UUID().uuidString).mp4", size: 2_000_000)
            defer { try? FileManager.default.removeItem(at: source) }

            nonisolated(unsafe) var lastProgress = 0.0
            let outcome = await VideoImporter.importFiles(from: [source]) { fraction in
                lastProgress = fraction
            }

            #expect(outcome.imported.count == 1)
            #expect(outcome.failures.isEmpty)
            #expect(outcome.duplicateFilenames.isEmpty)
            #expect(lastProgress == 1)

            let stored = try #require(outcome.imported.first)
            let storedURL = MediaStore.videoURL(forFilename: stored.filename)
            let storedSize = try FileManager.default.attributesOfItem(atPath: storedURL.path)[.size] as? Int
            #expect(storedSize == 2_000_000)
            #expect(stored.filename.hasSuffix(".mp4"))
        }

        @Test("Re-importing identical content is skipped as a duplicate")
        func importSkipsDuplicates() async throws {
            let root = try TestSupport.useScratchMediaRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let source = try writeSourceFile(named: "movie-\(UUID().uuidString).mp4", size: 1_500_000)
            defer { try? FileManager.default.removeItem(at: source) }

            let first = await VideoImporter.importFiles(from: [source]) { _ in }
            let firstFilename = try #require(first.imported.first?.filename)

            let second = await VideoImporter.importFiles(from: [source]) { _ in }
            #expect(second.imported.isEmpty)
            #expect(second.duplicateFilenames == [firstFilename])

            // Same size but different content must NOT be treated as a duplicate.
            let sibling = try writeSourceFile(named: "movie-\(UUID().uuidString).mp4", size: 1_500_000, byte: 0xCD)
            defer { try? FileManager.default.removeItem(at: sibling) }
            let third = await VideoImporter.importFiles(from: [sibling]) { _ in }
            #expect(third.imported.count == 1)
            #expect(third.duplicateFilenames.isEmpty)
        }

        @Test("Reconciliation removes orphaned files and dead entries, keeps healthy ones")
        func reconciliationSweeps() async throws {
            let root = try TestSupport.useScratchMediaRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let context = try TestSupport.freshContext()

            try FileManager.default.createDirectory(at: MediaStore.videosDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: MediaStore.thumbnailsDirectory, withIntermediateDirectories: true)

            // A healthy entry: file on disk + library row.
            let healthyFilename = "healthy.mp4"
            try Data(repeating: 1, count: 10).write(to: MediaStore.videoURL(forFilename: healthyFilename))
            let healthy = Video(name: "Healthy", synopsis: "", localFilename: healthyFilename, yearOfRelease: 2026)
            context.insert(healthy)

            // A dead entry: library row whose file vanished.
            let dead = Video(name: "Dead", synopsis: "", localFilename: "gone.mp4", yearOfRelease: 2026)
            context.insert(dead)

            // A remote entry: no local file expected — must survive.
            let remote = Video(
                name: "Remote",
                synopsis: "",
                remoteURL: YouTubeSource.watchURL(forVideoID: "aqz-KE-bpKQ"),
                yearOfRelease: 2026
            )
            context.insert(remote)

            // Orphaned bytes: files no row references.
            try Data(repeating: 2, count: 10).write(to: MediaStore.videoURL(forFilename: "stray.mp4"))
            try Data(repeating: 3, count: 10).write(to: MediaStore.thumbnailURL(forFilename: "stray.mp4"))
            try context.save()

            LibraryReconciler.reconcile(in: context)

            let survivors = try context.fetch(FetchDescriptor<Video>())
            #expect(Set(survivors.map(\.name)) == ["Healthy", "Remote"])
            #expect(FileManager.default.fileExists(atPath: MediaStore.videoURL(forFilename: healthyFilename).path))
            #expect(!FileManager.default.fileExists(atPath: MediaStore.videoURL(forFilename: "stray.mp4").path))
            #expect(!FileManager.default.fileExists(atPath: MediaStore.thumbnailURL(forFilename: "stray.mp4").path))
        }
    }
}
