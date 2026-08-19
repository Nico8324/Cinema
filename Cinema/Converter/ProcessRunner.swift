/*
See the LICENSE.txt file for licensing information.

Abstract:
Running a command-line tool and reading its progress as it goes.
*/

#if os(macOS)
import Foundation

extension URL {
    /// The file's size right now, for watching one grow. `nil` when it isn't there yet.
    nonisolated var currentFileSize: Int64? {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: path(percentEncoded: false))[.size] as? NSNumber
        else { return nil }
        return size.int64Value
    }
}

/// Running the converter's tools.
///
/// Three ways of reporting progress, because the tools differ: ffmpeg reports `out_time_us`
/// honestly, while `dovi_tool` and `MP4Box` say nothing at all and have to be measured by
/// watching the file they're writing grow.
///
/// The concurrency here is deliberate and load-bearing. Progress callbacks are typed
/// `@escaping @MainActor (Double) -> Void` because they fire from a pipe's readability handler
/// and from a detached task, both off the main actor — global-actor isolation is what makes them
/// safe to hand across that boundary, and inferring the type instead loses it.
extension Process {
    /// Runs a tool and returns everything it wrote to standard output.
    ///
    /// Output goes to temporary files rather than pipes, and the wait is a termination handler
    /// rather than `waitUntilExit()`. Both choices are deliberate, and both were arrived at by
    /// watching this deadlock:
    ///
    /// - A pipe holds 64 KB. Whichever end isn't being drained blocks the tool the moment it fills,
    ///   and a tool blocked writing never exits, so the wait never returns. It only happens on runs
    ///   whose output is large enough, which is the worst way for a bug to present.
    /// - `readDataToEndOfFile()` and `waitUntilExit()` both block the thread they're called on. On
    ///   Swift's cooperative pool, enough concurrent calls exhaust the pool, and then the very task
    ///   that would drain the pipe can't be scheduled. The deadlock survives fixing the first cause.
    ///
    /// Files have neither property: the kernel writes them without blocking, and nothing has to be
    /// scheduled for the tool to make progress.
    static func output(of tool: URL, arguments: [String]) async throws -> Data {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "cinema-run-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let outURL = scratch.appending(path: "out")
        let errURL = scratch.appending(path: "err")
        FileManager.default.createFile(atPath: outURL.path(percentEncoded: false), contents: nil)
        FileManager.default.createFile(atPath: errURL.path(percentEncoded: false), contents: nil)

        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardOutput = try FileHandle(forWritingTo: outURL)
        process.standardError = try FileHandle(forWritingTo: errURL)

        try await process.runToCompletion()

        let data = (try? Data(contentsOf: outURL)) ?? Data()
        guard process.terminationStatus == 0 else {
            let errorText = String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self)
            throw ConversionError.failed(errorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }

    /// Runs a tool and returns what it wrote to standard *error*.
    ///
    /// ffmpeg's analysis filters report through stderr — `cropdetect` prints its running answer
    /// there, not to standard output, which carries the video. A non-zero exit isn't an error here
    /// either: a run cut short after a fixed number of frames still measured what it was asked to,
    /// and its findings are in the text.
    static func diagnostics(of tool: URL, arguments: [String]) async throws -> String {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "cinema-diag-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let errURL = scratch.appending(path: "err")
        FileManager.default.createFile(atPath: errURL.path(percentEncoded: false), contents: nil)

        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: errURL)

        try await process.runToCompletion()
        return String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self)
    }

    /// Starts the process and suspends until it exits, without blocking a thread.
    ///
    /// `waitUntilExit()` parks the calling thread. On the cooperative pool that thread is a scarce
    /// resource shared with every other task, including the ones this process is waiting on.
    func runToCompletion() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            terminationHandler = { _ in continuation.resume() }
            do {
                try run()
            } catch {
                terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// Runs one tool with its output piped straight into another.
    ///
    /// Neither end can report progress here — the first tool's standard output is carrying the
    /// video, not a progress feed — so the file being written is measured as it grows instead. It
    /// ends up smaller than what went in, since the enhancement layer is dropped along the way, so
    /// this runs slightly ahead of the truth rather than behind.
    ///
    /// Standard error is captured for both, and returned so a caller can inspect it: `dovi_tool`
    /// reports a frame-count mismatch there while still exiting zero, and that warning must be
    /// treated as fatal rather than ignored.
    @discardableResult
    static func runPiped(
        _ first: URL,
        arguments firstArguments: [String],
        into second: URL,
        arguments secondArguments: [String],
        holding: @escaping @MainActor (Process) -> Void,
        expectedBytes: Int64?,
        watching output: URL,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws -> String {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "cinema-pipe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let upstreamErrors = scratch.appending(path: "upstream-err")
        let downstreamErrors = scratch.appending(path: "downstream-err")
        FileManager.default.createFile(atPath: upstreamErrors.path(percentEncoded: false), contents: nil)
        FileManager.default.createFile(atPath: downstreamErrors.path(percentEncoded: false), contents: nil)

        let upstream = Process()
        upstream.executableURL = first
        upstream.arguments = firstArguments

        let downstream = Process()
        downstream.executableURL = second
        downstream.arguments = secondArguments

        // The only pipe here is the one carrying the video between the two tools, which both ends
        // are actively reading and writing. Diagnostics go to files — see `output` for why a pipe
        // nobody drains is a deadlock waiting for a talkative enough run.
        let bridge = Pipe()
        upstream.standardOutput = bridge
        downstream.standardInput = bridge
        upstream.standardError = try FileHandle(forWritingTo: upstreamErrors)
        downstream.standardError = try FileHandle(forWritingTo: downstreamErrors)
        await holding(downstream)

        let monitor = sizeMonitor(of: output, expecting: expectedBytes, onProgress: onProgress)
        defer { monitor?.cancel() }

        async let upstreamDone: Void = upstream.runToCompletion()
        async let downstreamDone: Void = downstream.runToCompletion()
        _ = try await (upstreamDone, downstreamDone)

        // Terminated by hand rather than by finishing: SIGTERM shows up as an uncaught signal,
        // which is a cancellation rather than a crash.
        guard downstream.terminationReason == .exit else { throw CancellationError() }
        let diagnostics = String(decoding: (try? Data(contentsOf: downstreamErrors)) ?? Data(), as: UTF8.self)
        guard downstream.terminationStatus == 0 else {
            throw ConversionError.failed(lastLine(of: diagnostics))
        }
        return diagnostics
    }

    /// - Parameter rejectingErrorContaining: text in the tool's own diagnostics that makes this a
    ///   failure whatever it exited with. `dovi_tool` reports `mismatched lengths` — the picture and
    ///   its metadata coming out different lengths — and exits zero regardless. Tolerating that
    ///   yields a file where every frame carries an earlier frame's metadata, which passes every
    ///   other check in `Verification`.
    @discardableResult
    static func runWatchingOutput(
        _ tool: URL,
        arguments: [String],
        holding: @escaping @MainActor (Process) -> Void,
        expectedBytes: Int64?,
        watching output: URL,
        rejectingErrorContaining rejected: String? = nil,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws -> String {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "cinema-watch-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let errors = scratch.appending(path: "err")
        FileManager.default.createFile(atPath: errors.path(percentEncoded: false), contents: nil)

        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardError = try FileHandle(forWritingTo: errors)
        process.standardOutput = FileHandle.nullDevice
        await holding(process)

        let monitor = sizeMonitor(of: output, expecting: expectedBytes, onProgress: onProgress)
        defer { monitor?.cancel() }

        try await process.runToCompletion()

        guard process.terminationReason == .exit else { throw CancellationError() }
        let diagnostics = String(decoding: (try? Data(contentsOf: errors)) ?? Data(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ConversionError.failed(lastLine(of: diagnostics))
        }
        if let rejected, diagnostics.localizedCaseInsensitiveContains(rejected) {
            throw ConversionError.failed(lastLine(of: diagnostics))
        }
        return diagnostics
    }

    /// Runs ffmpeg, reporting how far through the file it has got.
    ///
    /// Progress comes from `-progress pipe:1`, which prints `out_time_us` as it goes — measuring
    /// the timeline rather than guessing from bytes, so it stays honest whether the streams are
    /// being copied or re-encoded.
    static func run(
        _ tool: URL,
        arguments: [String],
        duration: Double,
        holding: @escaping @MainActor (Process) -> Void,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "cinema-run-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let errors = scratch.appending(path: "err")
        FileManager.default.createFile(atPath: errors.path(percentEncoded: false), contents: nil)

        let process = Process()
        process.executableURL = tool
        process.arguments = arguments

        // The progress feed stays a pipe because it is read as it arrives, by a readability
        // handler rather than by a thread parked on the far end. Diagnostics go to a file.
        let out = Pipe()
        process.standardOutput = out
        process.standardError = try FileHandle(forWritingTo: errors)
        await holding(process)

        out.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            for line in text.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                guard duration > 0,
                      let microseconds = Double(line.dropFirst("out_time_us=".count)) else { continue }
                let fraction = min(microseconds / 1_000_000 / duration, 1)
                Task { @MainActor in onProgress(fraction) }
            }
        }

        try await process.runToCompletion()
        out.fileHandleForReading.readabilityHandler = nil

        guard process.terminationReason == .exit else { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            throw ConversionError.failed(lastLine(of: String(decoding: (try? Data(contentsOf: errors)) ?? Data(), as: UTF8.self)))
        }
    }

    /// Reports how far a file has been written by watching it grow.
    private static func sizeMonitor(
        of url: URL,
        expecting expected: Int64?,
        onProgress: @escaping @MainActor (Double) -> Void
    ) -> Task<Void, Never>? {
        guard let expected, expected > 0 else { return nil }
        return Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                let written = url.currentFileSize ?? 0
                // Never reports complete: the file reaching its expected size doesn't mean the
                // tool has finished with it.
                let fraction = min(Double(written) / Double(expected), 0.99)
                await MainActor.run { onProgress(fraction) }
            }
        }
    }

    private static func lastLine(of text: String) -> String {
        text.split(separator: "\n").last.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
#endif
