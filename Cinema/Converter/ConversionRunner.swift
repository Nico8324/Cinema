/*
See the LICENSE.txt file for licensing information.

Abstract:
Running one conversion: the tools, in order, and the checks that decide whether to keep the result.
*/

#if os(macOS)
import CoreMedia
import Foundation

/// Converts one file, following its plan.
///
/// One conversion at a time, always — two concurrent x265 encodes produce *different files*, not
/// merely slower ones, because frame threads and lookahead are sized to the cores available and
/// those decisions feed rate control. `ConversionQueue` is what enforces that; this runs the job it
/// is given.
///
/// Nothing here ever touches the original. The output is written beside it under a new name, and a
/// conversion that fails any check deletes **its own output** and leaves everything else alone.
enum ConversionRunner {
    /// What a finished conversion turned out to cost, for the queue to calibrate itself with.
    struct Outcome: Sendable {
        let output: URL
        let encodeSeconds: Double
        let finishSeconds: Double
        let outputBytes: Int64
    }

    /// Runs one plan to completion.
    ///
    /// - Parameters:
    ///   - holding: called with each process as it starts, so the queue can stop one mid-flight.
    ///   - onProgress: 0...1 across the whole job, not per step.
    static func run(_ plan: ConversionPlan,
                    preferredAudioLanguage: String? = nil,
                    holding: @escaping @MainActor (Process) -> Void = { _ in },
                    onProgress: @escaping @MainActor (Double) -> Void = { _ in }) async throws -> Outcome {
        guard ConverterTools.isInstalled else {
            throw ConversionError.toolsMissing(installCommand: ConverterTools.installCommand)
        }
        // Profile 5's base layer is IPT-encoded, not BT.2020 PQ — which is precisely why it isn't
        // HDR10-compatible. `dovi_tool` rewrites the RPU; it cannot rewrite pixels. Converting it
        // would produce a file declaring `dvp=8.hdr10` over a base layer that is nothing of the
        // sort: right on a Dolby Vision display, badly wrong on every other, and silent about it.
        // Refused rather than guessed at. Nothing in this library is profile 5, and no one has
        // ever run this path.
        //
        // Apple's own store delivery settles what carrying it would take, measured from a purchased
        // film's unencrypted init segments: `frma dvh1`, `dvcC profile=5 compat=0` — no HDR10
        // fallback in the stream at all — shipped **alongside a separate H.264 rendition of the
        // same picture**. That second stream is what makes profile 5 safe there, and a local file
        // has no such companion, which is why the streaming spec's "Dolby Vision MUST be profile 5"
        // does not transfer here. If this path is ever built it also needs `-tag:v dvh1` rather
        // than `hvc1`: the tag follows the profile, and the pairs do not mix.
        if plan.source.dolbyVision?.profile == 5 {
            throw ConversionError.dolbyVisionProfile5
        }
        let source = plan.source.url
        let finalDestination = try unusedOutputURL(forConverting: source)
        // All work happens at a hidden in-progress name and only a fully verified file is
        // renamed into place — so a quit, crash or power loss mid-encode can never leave a
        // truncated file at a name the scanner would import or the queue would count as "already
        // converted". Hidden (dot-prefixed) because every enumeration in the converter and the
        // scanner skips hidden files: in-progress work is invisible to all of them by the same
        // rule that hides it from Finder.
        let destination = inProgressURL(for: finalDestination)
        try? FileManager.default.removeItem(at: destination)
        try checkSpace(for: plan, writingTo: destination)

        let sidecars = SidecarSubtitle.discover(for: source)

        // What the kept subtitle tracks actually contain, read before the mux because the answer
        // decides which one is written `forced` and which `hearing_impaired` — and those flags are
        // what a player uses to auto-enable a track and to name it. Only the kept tracks are read:
        // scanning all 33 of a disc remux's would spend a minute on tracks nobody will ever see.
        let spokenLanguage = TrackPlan.spokenLanguage(of: plan.source,
                                                      preferredLanguage: preferredAudioLanguage)
        let cueContent = await SubtitleScan.scan(
            TrackPlan.keptSubtitles(for: plan.source, spokenLanguage: spokenLanguage), of: plan.source)

        let start = ContinuousClock.now
        var encodeFinished: ContinuousClock.Instant?

        do {
            switch plan.route {
            case .rewrap, .reencode:
                try await runPlain(plan, sidecars: sidecars, from: source, to: destination,
                                   preferredAudioLanguage: preferredAudioLanguage,
                                   cueContent: cueContent,
                                   holding: holding, onProgress: onProgress)
                encodeFinished = .now

            case .rebuildDolbyVision(let encode):
                encodeFinished = try await runDolbyVision(
                    plan, encode: encode, sidecars: sidecars, from: source, to: destination,
                    preferredAudioLanguage: preferredAudioLanguage, cueContent: cueContent,
                    holding: holding, onProgress: onProgress)
            }

            // Everything that rewrites the finished file in place happens here, and **before**
            // verification, deliberately. The GPAC language/flag pass and the AVFoundation
            // accessibility pass both mutate a file that already exists, so a failure in either
            // damages the artefact rather than merely failing to produce one. Running them ahead
            // of `Verification.check` means the container parse, the render check and frame parity
            // all see the *final* bytes — and a mutation that breaks the file is caught and the
            // file deleted, instead of shipping a broken container that still plays.
            try await finishSubtitleTracks(of: plan, sidecars: sidecars,
                                           preferredAudioLanguage: preferredAudioLanguage,
                                           cueContent: cueContent, at: destination)

            try await Verification.check(
                destination,
                wasRebuiltAsDolbyVision: plan.route.isDolbyVision,
                expectedCroppedSize: plan.route.encode.flatMap { encode in
                    encode.isCropping ? (encode.width, encode.height) : nil
                },
                matchingFrameCountOf: plan.route.isReencode ? source : nil)
        } catch {
            // A file that failed its checks is worse than no file: it looks like a success and
            // would quietly replace something that worked.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        // The rename is the very last step, after the subtitle passes *and* verification — a
        // file at its final name is, by construction, a verified one. Re-derived rather than
        // reused in case something claimed the name during the hours this job ran.
        let output: URL
        do {
            let target = FileManager.default.fileExists(atPath: finalDestination.path(percentEncoded: false))
                ? try unusedOutputURL(forConverting: source)
                : finalDestination
            try FileManager.default.moveItem(at: destination, to: target)
            output = target
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        let end = ContinuousClock.now
        let encodeSeconds = (encodeFinished ?? end) - start
        return Outcome(
            output: output,
            encodeSeconds: plan.route.isReencode ? encodeSeconds.seconds : 0,
            finishSeconds: plan.route.isReencode ? (end - (encodeFinished ?? end)).seconds
                                                : (end - start).seconds,
            outputBytes: output.currentFileSize ?? 0)
    }

    /// Where a conversion is written while it runs: hidden, beside its final name.
    static func inProgressURL(for finalDestination: URL) -> URL {
        finalDestination.deletingLastPathComponent()
            .appending(path: "." + finalDestination.deletingPathExtension().lastPathComponent
                       + ".converting.mp4")
    }

    /// Sweeps in-progress files a previous run abandoned by quitting or crashing mid-encode.
    /// Only ever called while nothing is converting — a live in-progress file is being written.
    static func removeAbandonedInProgressFiles(under folder: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return }
        for case let url as URL in enumerator
        where url.lastPathComponent.hasPrefix(".") && url.lastPathComponent.hasSuffix(".converting.mp4") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - The two routes

    /// One ffmpeg command: copy or re-encode the picture, carry the tracks, write the MP4.
    private static func runPlain(_ plan: ConversionPlan, sidecars: [SidecarSubtitle],
                                 from source: URL, to destination: URL,
                                 preferredAudioLanguage: String?,
                                 cueContent: [Int: SubtitleContent],
                                 holding: @escaping @MainActor (Process) -> Void,
                                 onProgress: @escaping @MainActor (Double) -> Void) async throws {
        guard let ffmpeg = ConverterTools.ffmpeg else {
            throw ConversionError.toolsMissing(installCommand: ConverterTools.installCommand)
        }
        let media = plan.source

        var arguments = ["-y", "-i", source.path(percentEncoded: false)]
            + sidecars.flatMap { ["-i", $0.url.path(percentEncoded: false)] }
            + ["-map", "0:\(media.videoStreamIndex)"]

        if let encode = plan.route.encode {
            let range = media.dynamicRange
            // The grade's own mastering display and MaxCLL, carried across the re-encode. x265
            // drops both unless told, and a file that loses them tone maps differently from its
            // source on every display that reads them.
            let hdr = range.isHighDynamicRange
                ? await HDRMetadata.read(from: source, videoStream: media.videoStreamIndex)
                : HDRMetadata.empty
            if let top = encode.cropTop {
                arguments += ["-vf", "crop=\(encode.width):\(encode.height):0:\(top)"]
            }
            // See `DolbyVisionRebuild.encodeArguments`: one output frame per input frame. It
            // matters most where an RPU is involved, but a re-encode that quietly changes a film's
            // length is wrong on any route.
            arguments += ["-fps_mode:v", "passthrough", "-tag:v", "hvc1"]
                + PlaybackTarget.rateControlArguments(bitrate: encode.bitrate)
                + PlaybackTarget.encoderParameters(
                    bitrate: encode.bitrate, framesPerSecond: media.frameRate, dynamicRange: range,
                    masteringDisplay: hdr.masteringDisplay, contentLightLevel: hdr.contentLightLevel)
                + PlaybackTarget.pictureArguments(for: range)
                + range.bitstreamColourArguments
        } else {
            // Copied straight out of Matroska, HEVC lands as `hev1` — which AVFoundation opens,
            // enumerates and reads while reporting `isPlayable == false`. Retagging is a relabel,
            // not a re-encode: the samples are untouched.
            arguments += ["-c:v", "copy"]
            if media.videoCodec == "hevc" { arguments += ["-tag:v", "hvc1"] }
        }

        arguments += TrackPlan.trackArguments(for: media, sidecars: sidecars,
                                              preferredLanguage: preferredAudioLanguage,
                                              content: cueContent).arguments
        arguments += ["-progress", "pipe:1", "-nostats", "-loglevel", "error",
                      destination.path(percentEncoded: false)]

        try await Process.run(ffmpeg, arguments: arguments, duration: media.duration,
                              holding: holding, onProgress: onProgress)
    }

    /// The Dolby Vision route: RPU out, picture copied or rebuilt, RPU back in, GPAC mux.
    ///
    /// Returns the moment the picture was finished, so the queue can tell encoding time from
    /// muxing time and calibrate each against the right rate.
    private static func runDolbyVision(_ plan: ConversionPlan, encode: ConversionPlan.Encode?,
                                       sidecars: [SidecarSubtitle], from source: URL, to destination: URL,
                                       preferredAudioLanguage: String?,
                                       cueContent: [Int: SubtitleContent],
                                       holding: @escaping @MainActor (Process) -> Void,
                                       onProgress: @escaping @MainActor (Double) -> Void)
    async throws -> ContinuousClock.Instant {
        guard let ffmpeg = ConverterTools.ffmpeg,
              let doviTool = ConverterTools.doviTool,
              let mp4box = ConverterTools.mp4box,
              let rebuild = DolbyVisionRebuild(media: plan.source) else {
            throw ConversionError.toolsMissing(installCommand: ConverterTools.installCommand)
        }
        let media = plan.source

        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "cinema-convert-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let videoURL = scratch.appending(path: "video.hevc")
        let tracksURL = scratch.appending(path: "tracks.mp4")
        let pictureFinished: ContinuousClock.Instant

        if let encode {
            let rpuURL = scratch.appending(path: "rpu.bin")
            let encodedURL = scratch.appending(path: "encoded.hevc")
            let hdr = await HDRMetadata.read(from: source, videoStream: media.videoStreamIndex)

            // The RPU comes out first, the picture is rebuilt without it, and it goes back in
            // afterwards — every frame still where it was, so every RPU still lands on the frame it
            // describes.
            let extraction = rebuild.extractRPUArguments(from: source, crop: encode.isCropping)
            try await Process.runPiped(
                ffmpeg, arguments: extraction.ffmpeg,
                into: doviTool, arguments: extraction.doviTool + [rpuURL.path(percentEncoded: false)],
                holding: holding, expectedBytes: nil, watching: rpuURL) { _ in }
            await onProgress(0.05)

            try await Process.run(
                ffmpeg,
                arguments: rebuild.encodeArguments(
                    from: source, to: encodedURL, bitrate: encode.bitrate,
                    framesPerSecond: media.frameRate, hdr: hdr,
                    crop: encode.cropTop.map { (encode.width, encode.height, $0) }),
                duration: media.duration, holding: holding) { onProgress(0.05 + $0 * 0.65) }

            try await Process.runWatchingOutput(
                doviTool, arguments: rebuild.injectArguments(video: encodedURL, rpu: rpuURL, to: videoURL),
                holding: holding, expectedBytes: encodedURL.currentFileSize, watching: videoURL,
                rejectingErrorContaining: "mismatched lengths") { onProgress(0.70 + $0 * 0.10) }
            // The encoded stream has served its purpose the moment the RPU is safely inside the
            // injected one. Holding both alive is what makes this route need three times the
            // output's size on disk rather than twice — and running out near the end of a
            // multi-hour encode is the most expensive way there is to fail.
            try? FileManager.default.removeItem(at: encodedURL)
            pictureFinished = .now
        } else {
            // Nothing to re-encode: rewrite the RPU in place and keep the picture exactly as it is.
            let conversion = rebuild.convertArguments(from: source)
            try await Process.runPiped(
                ffmpeg, arguments: conversion.ffmpeg,
                into: doviTool, arguments: conversion.doviTool + [videoURL.path(percentEncoded: false)],
                holding: holding, expectedBytes: source.currentFileSize,
                watching: videoURL) { onProgress($0 * 0.80) }
            pictureFinished = .now
        }

        try await Process.run(
            ffmpeg,
            arguments: TrackPlan.trackOnlyArguments(for: media, from: source, to: tracksURL,
                                                    sidecars: sidecars,
                                                    preferredLanguage: preferredAudioLanguage),
            duration: media.duration, holding: holding) { onProgress(0.80 + $0 * 0.05) }

        try await Process.runWatchingOutput(
            mp4box, arguments: rebuild.muxArguments(video: videoURL, tracks: tracksURL, to: destination),
            holding: holding, expectedBytes: videoURL.currentFileSize,
            watching: destination) { onProgress(0.85 + $0 * 0.15) }

        return pictureFinished
    }

    // MARK: - Finishing touches

    /// Finishes the subtitle tracks in the muxed file: which start switched on, and how a player
    /// tells two of the same language apart.
    ///
    /// Both are needed because **GPAC decides for itself which track is enabled**, whatever ffmpeg
    /// wrote on the intermediate. Measured: a file whose ten subtitle tracks were all written
    /// `-disposition 0` came out of the mux with the first one enabled — so a viewer opening the
    /// film would find Cantonese subtitles switched on. Apple ships subtitles off unless a forced
    /// track matches the audio, and that's the rule this restores.
    ///
    /// The flag edits are free — GPAC rewrites the track header in place, measured at 0.03 s on a
    /// muxed file. Only the language tags rewrite the file, so they run solely when there is a
    /// same-language collision to resolve.
    private static func finishSubtitleTracks(of plan: ConversionPlan, sidecars: [SidecarSubtitle],
                                             preferredAudioLanguage: String?,
                                             cueContent: [Int: SubtitleContent],
                                             at destination: URL) async throws {
        guard let mp4box = ConverterTools.mp4box else { return }

        // Everything that becomes a subtitle track, in the order the mux writes them: the source's
        // own text tracks first, then any file found beside the film. Counting only the source's
        // would silently skip this entire pass the moment someone supplied a sidecar — and skipping
        // it means shipping GPAC's mangled languages and whichever track it decided to switch on.
        let spoken = TrackPlan.spokenLanguage(of: plan.source, preferredLanguage: preferredAudioLanguage)
        let kept = TrackPlan.keptSubtitles(for: plan.source, spokenLanguage: spoken)
            .map(LanguageTags.Subtitle.init) + sidecars.map(LanguageTags.Subtitle.init)
        guard !kept.isEmpty else { return }

        // Read back rather than predicted: a tag or a flag aimed at the wrong track silently
        // rewrites *that* track, and the result passes every check in `Verification`.
        let tracks = try await subtitleTracks(of: destination, using: mp4box)
        guard tracks.count == kept.count else {
            // The one thing not to do here is carry on and guess: if the finished file doesn't hold
            // the tracks this plan expects, every id below addresses the wrong one, and a language
            // written onto the wrong track is indistinguishable from a correct file afterwards.
            throw ConversionError.failed(String(localized: """
                The converted file has \(tracks.count) subtitle tracks where \(kept.count) were \
                expected, so their languages couldn’t be set safely.
                """))
        }

        // The one subtitle that starts on, if any: a forced track in the language the film opens
        // in, since that carries dialogue a viewer has no other way to follow.
        let defaultAudioLanguage = TrackPlan.selectAudio(from: plan.source)
            .audio.first(where: \.isDefault)?.track.language.map(TrackPlan.normalisedLanguage)
        let wanted = kept.firstIndex {
            $0.isForced && $0.language.map(TrackPlan.normalisedLanguage) == defaultAudioLanguage
        }

        let variantArguments = LanguageTags.arguments(forSubtitles: kept, trackIDs: tracks.map(\.id))
        var arguments = variantArguments

        // Every remaining language written again, explicitly, because **GPAC rewrites some of them
        // on import**: an intermediate carrying `ara bul zho ces` came out of `MP4Box -add` as
        // `fra fra zho zho` — Arabic and Bulgarian both claiming French, Czech claiming Chinese, in
        // a delivered film. It is the same defect as the documented `chi` → Norwegian, and moving to
        // terminological codes does not avoid it, because those are mangled too. `-lang` writes what
        // it is given, so the language a track ends up with is set here rather than trusted to
        // survive the mux.
        let alreadyTagged = Set(zip(variantArguments, variantArguments.dropFirst())
            .filter { $0.0 == "-lang" }
            .compactMap { $0.1.split(separator: "=").first.map(String.init) })

        for (offset, track) in tracks.enumerated() where !alreadyTagged.contains("\(track.id)") {
            guard let language = kept[offset].language.map(TrackPlan.normalisedLanguage) else { continue }
            arguments += ["-lang", "\(track.id)=\(language)"]
        }

        // Flags go in the *same* invocation as the languages, and the order matters only in that
        // both must be in one pass. Measured on a real feature: `-lang` on its own re-enables the
        // first subtitle track, and a follow-up `-disable` re-mangles the languages, because GPAC
        // re-applies its broken language mapping on every rewrite. One pass gets both right; two
        // passes always leave one of them wrong.
        for (offset, track) in tracks.enumerated() {
            if offset == wanted, !track.isEnabled {
                arguments += ["-enable", "\(track.id)"]
            } else if offset != wanted {
                arguments += ["-disable", "\(track.id)"]
            }
        }
        guard !arguments.isEmpty else { return }

        // Not `try?`. This pass rewrites the finished file, and on a feature-sized output that is
        // minutes of work rather than the instant it takes on a short one — measured by damaging a
        // 21 GB file with an interrupted run, which left a container GPAC could no longer open
        // while AVFoundation still played it happily. A failure here has to delete the output like
        // any other, because "still plays" is not the same as "well-formed", and the half-finished
        // version is the one that would be kept.
        _ = try await Process.output(of: mp4box,
                                     arguments: ["-quiet"] + arguments
                                     + [destination.path(percentEncoded: false)])

        try await markAccessibleSubtitles(kept: kept, tracks: tracks, cueContent: cueContent,
                                          source: plan.source, at: destination)
    }

    /// Marks the SDH tracks so an Apple player can tell them apart, and names them for the viewer.
    ///
    /// **Last, deliberately.** It regenerates the `moov`, so anything GPAC still has to write must
    /// already be written — and a forced track flagged by `MP4Box -kind` beforehand does survive
    /// this pass, which is the interaction that had to be checked rather than assumed.
    ///
    /// Failure here does not fail the conversion. Every other step in this file guards something
    /// the format requires; this one adds a label. A film that arrives with two identical "English"
    /// entries is worse than one that doesn't, and it is not worth destroying hours of encoding
    /// over — so the error is logged rather than thrown.
    private static func markAccessibleSubtitles(kept: [LanguageTags.Subtitle],
                                                tracks: [(id: Int, isEnabled: Bool)],
                                                cueContent: [Int: SubtitleContent],
                                                source: SourceMedia, at destination: URL) async throws {
        let byIndex = Dictionary(uniqueKeysWithValues: source.subtitles.map { ($0.index, $0) })
        let ids: [CMPersistentTrackID] = zip(kept, tracks).compactMap { subtitle, track in
            // A sidecar says what it is in its filename and was never scanned, so it is taken at
            // its word; a track from inside the source is decided by flag, title, then its cues.
            guard let index = subtitle.sourceIndex, let original = byIndex[index] else {
                return subtitle.isHearingImpaired ? CMPersistentTrackID(track.id) : nil
            }
            guard TrackPlan.isHearingImpaired(original, content: cueContent[index]) else { return nil }
            return CMPersistentTrackID(track.id)
        }
        guard !ids.isEmpty else { return }
        do {
            _ = try await AccessibilityMarking.mark(trackIDs: ids, in: destination)
        } catch {
            // Non-fatal by design, but never silent: a swallowed error here meant nobody could
            // tell a marked library from one where the pass had been failing for months.
            ConversionQueue.logger.error("Couldn't mark SDH subtitles in \(destination.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The subtitle tracks of a muxed file: their MP4 track IDs and whether each starts enabled.
    ///
    /// Read from `MP4Box -info`, which names each track (`# Track 3 Info - ID 3`), says what it
    /// holds (`Media Type: sbtl:tx3g`) and how it starts (`Track flags: Enabled In Movie`).
    static func subtitleTracks(of file: URL, using mp4box: URL) async throws -> [(id: Int, isEnabled: Bool)] {
        // GPAC writes `-info` to standard *error*. Read from standard output and the answer is an
        // empty string, which reads as "this file has no subtitle tracks" — so the whole pass
        // quietly does nothing and the file looks exactly like one that needed nothing done.
        let info = try await Process.diagnostics(of: mp4box, arguments: [
            "-info", file.path(percentEncoded: false)
        ])
        let tracks = subtitleTracks(inInfo: info)
        guard tracks.isEmpty else { return tracks }
        let output = try await Process.output(of: mp4box, arguments: [
            "-info", file.path(percentEncoded: false)
        ])
        return subtitleTracks(inInfo: String(decoding: output, as: UTF8.self))
    }

    static func subtitleTracks(inInfo info: String) -> [(id: Int, isEnabled: Bool)] {
        var tracks: [(id: Int, isEnabled: Bool)] = []
        var currentID: Int?
        var isSubtitle = false
        var isEnabled = false

        func flush() {
            if let id = currentID, isSubtitle { tracks.append((id, isEnabled)) }
            currentID = nil
            isSubtitle = false
            isEnabled = false
        }

        for line in info.split(separator: "\n", omittingEmptySubsequences: false) {
            if let match = line.firstMatch(of: /#\s*Track\s+\d+\s+Info\s+-\s+ID\s+(\d+)/) {
                flush()
                currentID = Int(match.output.1)
            } else if line.contains("Media Type: sbtl") {
                isSubtitle = true
            } else if line.contains("Track flags:"), line.contains("Enabled") {
                isEnabled = true
            }
        }
        flush()
        return tracks
    }

    /// Where to write the converted copy: beside the original, never over it.
    static func unusedOutputURL(forConverting source: URL) throws -> URL {
        // Named from what the filename means rather than from what it says: the release group's
        // hash and its technical tokens are noise everywhere except the tracker it came from. An
        // episode is also filed under its show and season, which is the part a flat folder can't do.
        let components = OutputName.relativeComponents(forConverting: source)
        let directory = components.dropLast().reduce(source.deletingLastPathComponent()) {
            $0.appending(path: $1)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = components.last ?? source.deletingPathExtension().lastPathComponent

        let first = directory.appending(path: "\(stem).mp4")
        guard FileManager.default.fileExists(atPath: first.path(percentEncoded: false)) else {
            return first
        }
        for suffix in 2...999 {
            let candidate = directory.appending(path: "\(stem) \(suffix).mp4")
            if !FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
        }
        // Practically unreachable — but the old fallback returned `first`, which exists, and
        // ffmpeg's `-y` would then overwrite a real file. Refusing is the only safe answer.
        throw ConversionError.failed(String(localized: "Couldn't find an unused name for \(stem).mp4."))
    }

    /// Refuses a conversion a disk can't hold, using the plan's own estimate of the output.
    ///
    /// Two volumes, not one: the output lands beside the source, but the Dolby Vision route's
    /// intermediates — the raw stream and the rebuilt one — are written to the system temporary
    /// directory, which lives on the boot volume. With the media folder on an external drive,
    /// checking only the destination answered a question nobody was asking.
    private static func checkSpace(for plan: ConversionPlan, writingTo destination: URL) throws {
        let output = plan.estimate.outputBytes
        try checkVolume(of: destination.deletingLastPathComponent(), holds: output)
        if plan.route.isDolbyVision {
            try checkVolume(of: FileManager.default.temporaryDirectory, holds: output * 2)
        }
    }

    private static func checkVolume(of directory: URL, holds needed: Int64) throws {
        guard let free = try? directory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage else { return }
        guard needed < free else {
            throw ConversionError.notEnoughSpace(needed: needed, free: free)
        }
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
#endif
