/*
See the LICENSE.txt file for licensing information.

Abstract:
Giving files converted before the naming rules existed the names they would get today.
*/

#if os(macOS)
import Foundation
import SwiftData
import os

/// Renames and files converted videos the way the converter would name them now.
///
/// Conversions made before the naming rules existed kept their source's name — a release group's
/// hash and its technical tokens — and every episode sat at the top level beside the films. This
/// is the one-off that catches them up.
///
/// It moves **only** files this app produced or could have produced: MP4 and M4V. A source is never
/// touched, renamed or moved, because the source is the way back from a wrong judgement and it
/// should be exactly where its owner left it.
enum MediaFolderTidy {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Cinema",
                                       category: "Tidy")

    /// One file that would be renamed, moved, or both.
    struct Move: Identifiable, Sendable, Hashable {
        let from: URL
        let to: URL
        var id: URL { from }

        /// What the change reads as in a list: the new path relative to the media folder.
        func destination(relativeTo folder: URL) -> String {
            let base = folder.path(percentEncoded: false)
            let path = to.path(percentEncoded: false)
            return path.hasPrefix(base) ? String(path.dropFirst(base.count).drop { $0 == "/" }) : path
        }
    }

    /// What tidying the folder would do, without doing any of it.
    ///
    /// Separated from applying so the list can be read first. A bulk rename of someone's film
    /// library is the kind of thing that should be looked at before it happens, not explained
    /// afterwards.
    /// - Parameter years: the year the library holds for each file, keyed by resolved path. A
    ///   disc remux is usually named without one while the library has it from a TMDB match, and a
    ///   bare title is ambiguous across remakes — so the match wins where there is one.
    static func plannedMoves(in folder: URL, years: [String: Int] = [:]) -> [Move] {
        // Both sides resolved to the same form before anything is compared. A directory
        // enumeration hands back `/private/var/…` where the folder was given as `/var/…`, and the
        // two are the same place — so a file already sitting at its correct name looks different
        // from itself, and the tidy pass proposes moving it onto itself. `/tmp`, `/var` and any
        // media folder reached through a symlink all have this shape.
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        let files = OutputName.videoFiles(under: root, extensions: ["mp4", "m4v"])
            .map { $0.resolvingSymlinksInPath().standardizedFileURL }
        var claimed: Set<URL> = Set(files)
        var moves: [Move] = []

        for file in files.sorted(by: { $0.path < $1.path }) {
            let components = OutputName.relativeComponents(
                forConverting: file, year: years[file.path(percentEncoded: false)])
            let directory = components.dropLast().reduce(root) { $0.appending(path: $1) }
            let destination = directory
                .appending(path: components.last ?? file.deletingPathExtension().lastPathComponent)
                .appendingPathExtension(file.pathExtension)
                .standardizedFileURL

            guard destination != file else { continue }
            // Never onto something already there. Two sources that parse to one name is a real
            // possibility — a film and its extended cut, two rips of one episode — and the right
            // answer is to leave both alone and let a person look, not to pick a winner.
            guard !claimed.contains(destination) else {
                logger.notice("Leaving \(file.lastPathComponent, privacy: .public): \(destination.lastPathComponent, privacy: .public) is taken.")
                continue
            }
            claimed.insert(destination)
            moves.append(Move(from: file, to: destination))
        }
        return moves
    }

    /// Carries out the moves and points the library at where the files went.
    ///
    /// The two halves are one operation. A file moved without its record becomes a film that is in
    /// the library, has artwork and a resume position, and plays nothing — which is worse than
    /// either doing nothing or losing the row, because it looks like it works until it's opened.
    ///
    /// - Returns: the moves that succeeded, and the ones that didn't with the reason.
    @MainActor
    @discardableResult
    static func apply(_ moves: [Move], in context: ModelContext) -> (moved: [Move], failed: [(name: String, reason: String)]) {
        guard !moves.isEmpty else { return ([], []) }
        // Keyed on the resolved path, because the moves are resolved and a stored path need not
        // be. The same `/var` against `/private/var` mismatch that made a file look unlike itself
        // above would here leave the row pointing at a file that has moved — which is the failure
        // this whole function exists to avoid, arriving through the back door.
        let videos = (try? context.fetch(FetchDescriptor<Video>())) ?? []
        var byPath: [String: [Video]] = [:]
        for video in videos {
            guard let path = video.externalPath else { continue }
            byPath[resolved(path), default: []].append(video)
        }

        var moved: [Move] = []
        var failed: [(name: String, reason: String)] = []
        for move in moves {
            do {
                try FileManager.default.createDirectory(at: move.to.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: move.from, to: move.to)
            } catch {
                failed.append((move.from.lastPathComponent, error.localizedDescription))
                continue
            }
            // Only after the move has actually happened. Rewriting the record first and failing to
            // move would point the library at a file that isn't there.
            for video in byPath[resolved(move.from.path(percentEncoded: false))] ?? [] {
                video.externalPath = move.to.path(percentEncoded: false)
            }
            moved.append(move)
        }

        if !moved.isEmpty {
            try? context.save()
            logger.notice("Tidied \(moved.count, privacy: .public) file(s).")
        }
        return (moved, failed)
    }

    /// What the library *actually knows* about each file's year, keyed the way `plannedMoves`
    /// looks it up.
    ///
    /// **Only a matched film counts.** `yearOfRelease` is never empty: a scan that finds no year in
    /// the filename stores the current year, so every unmatched video in this library reads 2026 —
    /// including a YouTube trailer. Writing that into a filename would not be a guess a person
    /// could see and correct, it would be a fabricated fact stamped permanently onto their file.
    ///
    /// A TMDB match is the only evidence that the number came from the film rather than from the
    /// clock. Where there is no match, the filename's own year is used if it has one, and otherwise
    /// the name simply carries no year — which is honest and reversible.
    @MainActor
    static func knownYears(in context: ModelContext) -> [String: Int] {
        let videos = (try? context.fetch(FetchDescriptor<Video>())) ?? []
        return videos.reduce(into: [:]) { years, video in
            guard let path = video.externalPath,
                  video.tmdbID != nil,
                  video.yearOfRelease > 0 else { return }
            years[resolved(path)] = video.yearOfRelease
        }
    }

    private static func resolved(_ path: String) -> String {
        URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL
            .path(percentEncoded: false)
    }
}
#endif
