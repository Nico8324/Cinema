/*
See the LICENSE.txt file for licensing information.

Abstract:
The order to convert a folder of films in, and why that order changes as it goes.
*/

#if os(macOS)
import Foundation
import Observation
import os

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// The films waiting to be converted, in the order they should be done.
///
/// Shortest first. A folder of features is a day's work whatever the order, but the order decides
/// how much of the library is watchable while the rest runs: a fourteen-minute rewrap sitting
/// behind a seven-hour encode is fourteen minutes of value withheld for seven hours. Nothing about
/// the total changes; everything about the wait does.
///
/// The order is re-derived after each finished job rather than fixed at the start, because each
/// job measures this Mac a little better — see `ConversionCalibration`. An estimate made before
/// anything has run is the least informed one that will ever be made.
@Observable
@MainActor
final class ConversionQueue {
    nonisolated static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Cinema",
                                           category: "Conversion")

    /// The planned conversions, shortest estimate first.
    private(set) var plans: [ConversionPlan] = []
    /// Files that couldn't be planned, and why — an unreadable file is worth saying out loud
    /// rather than quietly leaving out of the list.
    private(set) var failures: [(name: String, reason: String)] = []
    private(set) var progress: Progress?

    /// The conversion happening now, if any.
    private(set) var running: Running?
    /// What has finished this session, newest first — including what each one actually cost
    /// against what it was estimated at, which is the only honest way to read an estimate.
    private(set) var finished: [Finished] = []

    /// The process currently doing the work, so it can be stopped mid-flight.
    private var currentProcess: Process?
    private var work: Task<Void, Never>?

    /// Called when the queue runs dry, so the library can pick up what was just made. Without it a
    /// film converted while the app was running stays invisible until the next launch — the folder
    /// gained an MP4 and nothing asked the library to look.
    var onFinished: (@MainActor () -> Void)?

    var isConverting: Bool { work != nil }

    struct Running: Equatable {
        let plan: ConversionPlan
        var fraction: Double
        var started: Date
    }

    struct Finished: Identifiable, Equatable {
        let id: URL
        let name: String
        let elapsed: Double
        let estimated: Double
        let outputBytes: Int64
        let error: String?
        /// Whether the source went to the Trash afterwards, so the screen can say so. A file that
        /// left the folder without the person being told is the thing this exists to prevent.
        var originalTrashed = false
    }

    struct Progress: Equatable {
        var planned: Int
        var total: Int
        var current: String
    }

    /// Whether a source is moved to the Trash once its conversion has been verified.
    ///
    /// **The Trash, never a delete.** A conversion is one generation of loss and a judgement about
    /// bitrate; if either turns out wrong, the only way back is the file it came from. The Trash is
    /// what makes that recoverable by the person rather than by a backup.
    nonisolated static let trashesOriginalsKey = "trashesOriginalsAfterConverting"
    nonisolated static var trashesOriginals: Bool {
        UserDefaults.standard.bool(forKey: trashesOriginalsKey)
    }

    /// Extensions worth offering to convert. MP4 and M4V are already the destination.
    nonisolated private static let convertibleExtensions: Set<String> = [
        "mkv", "avi", "wmv", "mpg", "mpeg", "ts", "m2ts", "vob", "flv", "webm", "ogv", "divx", "mov"
    ]

    var totalEstimate: Double { plans.reduce(0) { $0 + $1.estimate.total } }

    /// What the whole queue would put on disk. Shown beside the hours because the setting that
    /// decides the route trades exactly these two quantities against each other, and a queue that
    /// displays only one of them reads as though the other were free.
    var totalOutputBytes: Int64 { plans.reduce(0) { $0 + $1.estimate.outputBytes } }

    /// Reads every convertible file in the folder and works out what each one would cost.
    ///
    /// Sequential on purpose. Planning decodes real frames to find the black bars, and running
    /// several of those at once against the same disk makes all of them slower without finishing
    /// any of them sooner.
    func plan(folder: URL) async {
        plans = []
        failures = []
        let candidates = Self.convertibleFiles(in: folder)
        progress = Progress(planned: 0, total: candidates.count, current: "")

        for (index, url) in candidates.enumerated() {
            guard !Task.isCancelled else { break }
            progress = Progress(planned: index, total: candidates.count,
                                current: url.deletingPathExtension().lastPathComponent)
            do {
                let plan = try await ConversionPlan.plan(for: url)
                plans.append(plan)
                sort()
            } catch is CancellationError {
                break
            } catch {
                failures.append((url.lastPathComponent, error.localizedDescription))
            }
        }
        progress = nil
    }

    /// Works through the queue until nothing is waiting, or something goes wrong.
    ///
    /// A loop rather than a call at the end of each job: one conversion at a time is a rule about
    /// the encoder, not merely about tidiness — two concurrent x265 encodes produce *different
    /// files*, because frame threads and lookahead are sized to the cores available and those
    /// decisions feed rate control.
    func start(preferredAudioLanguage: String? = nil) {
        guard work == nil else { return }
        work = Task { [weak self] in
            while let self, let next = await self.plans.first, !Task.isCancelled {
                await self.convert(next, preferredAudioLanguage: preferredAudioLanguage)
            }
            await self?.finishRunning()
        }
    }

    /// Stops after killing whatever is running. The half-written output goes with it — a partial
    /// file that looks like a conversion is worse than no file.
    func stop() {
        work?.cancel()
        currentProcess?.terminate()
        work = nil
        running = nil
    }

    private func finishRunning() {
        let didWork = !finished.isEmpty
        work = nil
        running = nil
        currentProcess = nil
        if didWork { onFinished?() }
    }

    private func convert(_ plan: ConversionPlan, preferredAudioLanguage: String?) async {
        running = Running(plan: plan, fraction: 0, started: .now)
        let started = ContinuousClock.now

        do {
            let outcome = try await ConversionRunner.run(
                plan,
                preferredAudioLanguage: preferredAudioLanguage,
                holding: { [weak self] process in self?.currentProcess = process },
                onProgress: { [weak self] fraction in self?.running?.fraction = fraction })

            let elapsed = (ContinuousClock.now - started).seconds
            let trashed = Self.trashOriginal(of: plan)
            finished.insert(Finished(id: plan.id, name: plan.source.url.lastPathComponent,
                                     elapsed: elapsed, estimated: plan.estimate.total,
                                     outputBytes: outcome.outputBytes, error: nil,
                                     originalTrashed: trashed), at: 0)
            recordCompletion(of: plan, encodeSeconds: outcome.encodeSeconds,
                             finishSeconds: outcome.finishSeconds, outputBytes: outcome.outputBytes)
        } catch is CancellationError {
            running = nil
            return
        } catch {
            // A failed job leaves the queue rather than blocking it, and says why.
            finished.insert(Finished(id: plan.id, name: plan.source.url.lastPathComponent,
                                     elapsed: (ContinuousClock.now - started).seconds,
                                     estimated: plan.estimate.total, outputBytes: 0,
                                     error: error.localizedDescription,
                                     originalTrashed: false), at: 0)
            plans.removeAll { $0.id == plan.id }
        }
        running = nil
    }

    /// Moves a converted source to the Trash, if that's been asked for.
    ///
    /// Only ever reached after `ConversionRunner.run` returned without throwing, which means the
    /// output rendered a real frame, parsed end to end under a stricter reader, carried the Dolby
    /// Vision an Apple device accepts and matched the source frame for frame. Anything less and the
    /// output has already been deleted and this line never runs — the original outlives every
    /// failure by construction.
    ///
    /// `trashItem`, never `removeItem`. The difference is whether a wrong judgement about bitrate
    /// is recoverable by the person who made it.
    private static func trashOriginal(of plan: ConversionPlan) -> Bool {
        guard trashesOriginals else { return false }
        do {
            try FileManager.default.trashItem(at: plan.source.url, resultingItemURL: nil)
            return true
        } catch {
            // Not fatal, and not silent either: the conversion succeeded and the file is good. A
            // source that couldn't be moved is a tidiness problem, not a data problem.
            logger.error("Couldn't trash \(plan.source.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Folds a finished conversion into the machine's measured rates and re-orders what's left.
    ///
    /// Called with what actually happened, not with what was predicted — the point is the
    /// difference between the two.
    func recordCompletion(of plan: ConversionPlan, encodeSeconds: Double,
                          finishSeconds: Double, outputBytes: Int64) {
        let pixels: Double = if let encode = plan.route.encode {
            Double(plan.source.frameCount) * Double(encode.width) * Double(encode.height)
        } else { 0 }

        ConversionCalibration.record(
            encodedPixels: pixels,
            encodeSeconds: encodeSeconds,
            outputBytes: outputBytes,
            finishSeconds: finishSeconds,
            isRewrap: !plan.route.isReencode
        )

        plans.removeAll { $0.id == plan.id }
        // Re-estimate everything still waiting against what this Mac has just shown it can do.
        plans = plans.map {
            ConversionPlan(source: $0.source, letterbox: $0.letterbox, route: $0.route,
                           estimate: ConversionEstimate(source: $0.source, route: $0.route),
                           notes: $0.notes)
        }
        sort()
    }

    /// Takes an already-planned set of films, ordering them the same way a scan would.
    func adopt(_ plans: [ConversionPlan]) {
        self.plans = plans
        sort()
    }

    func remove(_ plan: ConversionPlan) {
        plans.removeAll { $0.id == plan.id }
    }

    private func sort() {
        plans.sort { $0.estimate.total < $1.estimate.total }
    }

    /// The files in a folder that are worth converting.
    ///
    /// A source that already has an MP4 of the same name beside it is left alone: it has been
    /// converted, and offering to do it again is offering to spend five hours reproducing a file
    /// that's already there.
    nonisolated static func convertibleFiles(in folder: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []

        let converted = Set(contents
            .filter { ["mp4", "m4v"].contains($0.pathExtension.lowercased()) }
            .map { $0.deletingPathExtension().lastPathComponent })

        return contents
            .filter { convertibleExtensions.contains($0.pathExtension.lowercased()) }
            .filter { !converted.contains($0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
#endif
