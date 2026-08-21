/*
See the LICENSE.txt file for licensing information.

Abstract:
Converting what lands in the media folder without being asked, and clearing up after it.
*/

#if os(macOS)
import Foundation
import Observation
import os

/// Watches the media folder and converts what the rest of the library can't open.
///
/// The queue window already does this on request. What this adds is that nobody has to ask: a disc
/// remux dropped into the folder is planned, converted, verified and — if that's been enabled —
/// its source moved to the Trash, while the app is doing something else entirely.
///
/// Off by default, deliberately. A conversion is hours of the machine's time and a judgement about
/// bitrate made without anybody watching, and the queue window exists so those judgements can be
/// read before they're taken. Turning this on is saying the judgements are trusted; it shouldn't be
/// the state someone discovers they were in.
@Observable
@MainActor
final class AutomaticConversion {
    nonisolated static let enabledKey = "convertsAutomatically"
    nonisolated static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Cinema",
                                       category: "AutoConvert")

    /// The queue doing the work, so a window opened later shows the same jobs rather than a second
    /// set. Two queues converting the same folder would plan the same files twice and race for the
    /// same output paths.
    let queue = ConversionQueue()

    private var watcher: FolderWatcher?
    private var work: Task<Void, Never>?
    /// What has already been planned this session, so a folder that changes while a four-hour
    /// encode runs doesn't restart it.
    private var considered: Set<URL> = []

    /// Begins watching, and converts anything already waiting.
    ///
    /// - Parameter onLibraryChanged: run when the queue empties, so whatever was just made can be
    ///   taken into the library. A conversion that finishes into a folder nobody re-reads is a film
    ///   that exists and can't be watched until the app is relaunched.
    func start(folder: URL, onLibraryChanged: (@MainActor () -> Void)? = nil) {
        guard Self.isEnabled, watcher == nil else { return }
        queue.onFinished = onLibraryChanged
        watcher = FolderWatcher(folder: folder) { [weak self] in
            self?.considerFolder(folder)
        }
        considerFolder(folder)
    }

    func stop() {
        watcher = nil
        work?.cancel()
        work = nil
        queue.stop()
    }

    /// Plans whatever is new and hands it to the queue.
    ///
    /// Re-entrant on purpose: the watcher fires while a conversion is running, and every firing
    /// asks the same question — is there anything here that isn't already accounted for? A file
    /// still being copied into the folder is the interesting case, and it's handled by planning
    /// failing on a partial file rather than by trying to guess when a copy has finished. It gets
    /// picked up on the next change, which a copy in progress produces plenty of.
    private func considerFolder(_ folder: URL) {
        guard Self.isEnabled, work == nil else { return }
        let waiting = ConversionQueue.convertibleFiles(in: folder)
            .filter { !considered.contains($0) }
        guard !waiting.isEmpty else { return }

        work = Task { [weak self] in
            guard let self else { return }
            var plans: [ConversionPlan] = []
            for url in waiting {
                guard !Task.isCancelled else { break }
                do {
                    plans.append(try await ConversionPlan.plan(for: url))
                    considered.insert(url)
                } catch {
                    // A file that can't be read yet — most often one still being copied in — is
                    // left out of `considered` so the next change reconsiders it.
                    Self.logger.notice("Not yet convertible: \(url.lastPathComponent, privacy: .public)")
                }
            }
            guard !plans.isEmpty, !Task.isCancelled else { work = nil; return }

            Self.logger.notice("Converting \(plans.count, privacy: .public) file(s) automatically.")
            queue.adopt(queue.plans + plans)
            queue.start()
            work = nil
        }
    }
}

/// Tells you when a folder's contents change.
///
/// A directory's file descriptor reports writes to the directory itself — a file appearing,
/// disappearing or being renamed — which is exactly the event worth reacting to and nothing else.
/// Notifications are coalesced by a short delay, because copying a file in produces a great many
/// of them and each one would otherwise start a scan.
private final class FolderWatcher {
    private let descriptor: CInt
    private let source: DispatchSourceFileSystemObject
    private var debounce: DispatchWorkItem?

    init?(folder: URL, onChange: @escaping @MainActor () -> Void) {
        descriptor = open(folder.path(percentEncoded: false), O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete],
            queue: .global(qos: .utility))

        source.setEventHandler { [weak self] in
            guard let self else { return }
            debounce?.cancel()
            let item = DispatchWorkItem { Task { @MainActor in onChange() } }
            debounce = item
            // Two seconds of quiet before believing the folder has settled. A 60 GB copy over a
            // network share writes for minutes; reacting to the first write would plan a file that
            // is a few megabytes long and conclude it has no video stream.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: item)
        }
        let descriptor = descriptor
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit {
        debounce?.cancel()
        source.cancel()
    }
}
#endif
