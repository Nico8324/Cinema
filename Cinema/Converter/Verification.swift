/*
See the LICENSE.txt file for licensing information.

Abstract:
Checking that what came out is a file the library can actually play — and, for a rebuilt Dolby
Vision file, that what it claims about itself is true.
*/

#if os(macOS)
import AVFoundation
import Foundation

/// Checks a finished conversion before it is called done.
///
/// Not a formality. A conversion can finish, exit zero, and produce a file AVFoundation opens,
/// enumerates and reads — and still refuses to play, which is exactly what an HEVC track tagged
/// `hev1` rather than `hvc1` does. ffmpeg has no opinion on that; only the framework doing the
/// playing does. So the framework is asked, here.
///
/// Everything checked here establishes that a file is **well-formed**. None of it establishes that
/// it is a *faithful* rendering of the film — which is why a failure deletes the output and why an
/// original is never deleted on the strength of these passing.
enum Verification {
    /// - Parameters:
    ///   - wasRebuiltAsDolbyVision: whether this file went through the Dolby Vision route. Passed
    ///     in rather than guessed from the file: a plain HDR10 file and a Dolby Vision file that
    ///     lost its RPU partway through look identical to AVFoundation, so asking the file itself
    ///     isn't a question this check could answer honestly.
    ///   - expectedCroppedSize: the picture size the encode was told to produce, when this job
    ///     removed letterbox bars. `nil` for everything else.
    ///   - matchingFrameCountOf: the source, when the picture was re-encoded. A re-encode must
    ///     return exactly as many frames as it was given: `inject-rpu` warns when the metadata is
    ///     longer than the picture but not when the picture is longer than the metadata, and that
    ///     direction leaves frames wearing no metadata at all, at the end of the film where nothing
    ///     samples. Spec point 11 as a check rather than a hope.
    static func check(_ url: URL, wasRebuiltAsDolbyVision: Bool,
                      expectedCroppedSize: (width: Int, height: Int)? = nil,
                      matchingFrameCountOf source: URL? = nil) async throws {
        let asset = AVURLAsset(url: url)
        let (playable, duration) = try await asset.load(.isPlayable, .duration)
        let video = try await asset.loadTracks(withMediaType: .video)

        guard playable, !video.isEmpty, duration.seconds > 0 else {
            throw ConversionError.unplayableResult
        }
        guard (try? AVAssetReader(asset: asset)) != nil else {
            throw ConversionError.unplayableResult
        }

        try await checkContainerIsWellFormed(url)
        try await checkItRenders(asset)

        if wasRebuiltAsDolbyVision {
            try await checkDolbyVisionRPU(url, durationInSeconds: duration.seconds)
            try await checkDolbyVisionProfile(url)
            try await checkDolbyVisionCompatibility(url)
        }
        if let expectedCroppedSize {
            try await checkCroppedSize(video, expected: expectedCroppedSize)
        }
        if let source {
            try await checkFrameParity(source: source, output: url)
        }
    }

    /// Confirms the re-encode returned exactly as many frames as it was given.
    ///
    /// Costs a pass over each file's index — minutes on a feature, at the end of a job measured in
    /// hours, to close the one failure that every other check here would pass.
    private static func checkFrameParity(source: URL, output: URL) async throws {
        guard let sourceFrames = try? await frameCount(of: source),
              let outputFrames = try? await frameCount(of: output),
              sourceFrames > 0, outputFrames > 0 else { return }
        guard sourceFrames == outputFrames else {
            throw ConversionError.frameCountChanged(source: sourceFrames, output: outputFrames)
        }
    }

    static func frameCount(of url: URL) async throws -> Int {
        guard let ffprobe = ConverterTools.ffprobe else { return 0 }
        let output = try await Process.output(of: ffprobe, arguments: [
            "-v", "error", "-select_streams", "v:0", "-count_packets",
            "-show_entries", "stream=nb_read_packets", "-of", "csv=p=0",
            url.path(percentEncoded: false)
        ])
        let text = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        return Int(text) ?? 0
    }

    /// Confirms the file actually produces a picture.
    ///
    /// The check that was missing when a converted film reached someone's library and played
    /// nothing at all. Everything else here — `isPlayable`, a constructed reader, tracks, duration,
    /// even ffmpeg decoding the same file happily — was true of that file. What was false is the
    /// only thing a viewer cares about: a player asked it for a frame and got none, because its
    /// Dolby Vision signalling was a variant Apple's decoder won't render.
    ///
    /// So this asks the way a player asks: attach an `AVPlayerItemVideoOutput`, seek into the film,
    /// play, and wait for a real pixel buffer. A few seconds at the end of a job measured in hours.
    private static func checkItRenders(_ asset: AVURLAsset) async throws {
        let duration = try await asset.load(.duration).seconds
        let item = AVPlayerItem(asset: asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.volume = 0
        defer { player.pause() }

        // Well past any leader: black opening frames are the one place a decoder can produce
        // nothing for honest reasons.
        await player.seek(to: CMTime(seconds: min(30, duration / 4), preferredTimescale: 600))
        player.play()

        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(250))
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: time),
               output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil {
                return
            }
            if let error = item.error {
                throw ConversionError.doesNotRender(error.localizedDescription)
            }
        }
        throw ConversionError.doesNotRender("")
    }

    /// Confirms a stricter parser can read the file to the end.
    ///
    /// This exists because **playable and well-formed are different properties, and neither implies
    /// the other**. A file truncated mid-`mdat` reports `isPlayable == true`, constructs a reader,
    /// returns every track, seeks, decodes frames and gives the right duration — while GPAC cannot
    /// parse it to the end. Everything else in this file asks AVFoundation, so nothing else here
    /// would notice.
    ///
    /// And the damage has to be read out of the tool's *prose*: `MP4Box -info` **exits zero** on a
    /// file it could not finish parsing, printing `Incomplete box` and `aborting parsing` to
    /// standard error. An exit status gate catches none of it — the third tool in this pipeline to
    /// report failure only in words, after `inject-rpu`'s `mismatched lengths` and `-info` writing
    /// to stderr in the first place.
    private static func checkContainerIsWellFormed(_ url: URL) async throws {
        guard let mp4box = ConverterTools.mp4box else { return }
        guard let info = try? await Process.diagnostics(of: mp4box, arguments: [
            "-info", url.path(percentEncoded: false)
        ]) else { return }

        let damage = ["Incomplete box", "Incomplete file", "Incomplete MDAT",
                      "Invalid IsoMedia", "aborting parsing", "Unknown top-level box"]
        if let found = damage.first(where: { info.localizedCaseInsensitiveContains($0) }) {
            throw ConversionError.malformedContainer(found)
        }
    }

    /// Confirms the bars this job asked ffmpeg to crop actually left the file, rather than trusting
    /// that an argument ffmpeg accepted was one it obeyed.
    ///
    /// Checked against `naturalSize` rather than the coded picture size: HEVC's internal, CTU-padded
    /// picture can be larger than what a player shows, and `naturalSize` is the frame the library
    /// itself would draw.
    private static func checkCroppedSize(_ video: [AVAssetTrack],
                                         expected: (width: Int, height: Int)) async throws {
        guard let track = video.first else { throw ConversionError.unplayableResult }
        let size = try await track.load(.naturalSize)
        let actualWidth = Int(size.width.rounded())
        let actualHeight = Int(size.height.rounded())

        guard actualWidth == expected.width, abs(actualHeight - expected.height) <= 2 else {
            throw ConversionError.letterboxCropLost(
                expected: CGSize(width: expected.width, height: expected.height),
                actual: CGSize(width: actualWidth, height: actualHeight))
        }
    }

    /// Spot-checks that the RPU actually reached the frames, rather than trusting that three tools
    /// exiting zero means it did.
    ///
    /// Read at the start and again near the end, as two separate probes: asked together, one pass
    /// over the combined frames would accept a rebuild whose RPUs die partway through on the
    /// strength of its opening seconds — which is the exact failure the near-end sample exists to
    /// catch.
    private static func checkDolbyVisionRPU(_ url: URL, durationInSeconds: Double) async throws {
        guard let ffprobe = ConverterTools.ffprobe else { return }
        let nearEnd = max(0, durationInSeconds - 10)

        for interval in ["%+2", "\(nearEnd)%+2"] {
            let output = try? await Process.output(of: ffprobe, arguments: [
                "-v", "error", "-select_streams", "v:0",
                "-show_frames", "-show_entries", "frame=side_data_list",
                "-read_intervals", interval, "-print_format", "json",
                url.path(percentEncoded: false)
            ])
            guard let output, hasDolbyVisionRPU(in: output) else {
                throw ConversionError.dolbyVisionLost
            }
        }
    }

    /// Confirms the file declares the one compatibility an Apple device will render.
    ///
    /// Profile 8 alone isn't enough: 8.1 means "the base layer is plain HDR10", and that is the
    /// variant Apple decodes. A file declaring 8 with compatibility 6 opens, reports itself
    /// playable, decodes in ffmpeg, and shows a viewer **a black screen** — measured on a real
    /// film that reached a real library.
    ///
    /// Which property of the base-layer bitstream makes GPAC write 6 rather than 1 is unknown, and
    /// deliberately so: two implementations dumped and diffed the RPU headers, the VUI, and the
    /// static HDR metadata and found no difference, while the same RPU muxed over a re-encoded
    /// picture comes out as 1. So this detects rather than diagnoses — one field, no theory, and it
    /// catches any future source carrying whatever the property is.
    private static func checkDolbyVisionCompatibility(_ url: URL) async throws {
        guard let ffprobe = ConverterTools.ffprobe else { return }
        guard let output = try? await Process.output(of: ffprobe, arguments: [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream_side_data=dv_bl_signal_compatibility_id",
            "-of", "csv=p=0", url.path(percentEncoded: false)
        ]) else { return }

        let text = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        // No opinion when the field can't be read — a check that can't see shouldn't condemn.
        guard let compatibility = Int(text) else { return }
        guard compatibility == 1 else {
            throw ConversionError.dolbyVisionNotApplePlayable(compatibility: compatibility)
        }
    }

    /// Confirms the file really is profile 8.1 rather than something wearing its box.
    ///
    /// `dvvC` is written from what MP4Box is told: `dvp=8.hdr10` will stamp "profile 8,
    /// HDR10-compatible" onto a stream whose RPUs are still profile 7 — and the result reports
    /// profile 8 to ffprobe, plays, and carries an RPU on every frame while its dynamic metadata is
    /// the wrong kind entirely. Nothing else checked here would notice.
    ///
    /// The RPU itself is the only thing that knows. Read from a two-second head slice, since the
    /// profile can't change mid-file — about a twentieth of a second on a 21 GB output.
    /// `header.vdr_rpu_profile` is deliberately *not* read: it reports `1` on a genuine 8.1 and on
    /// the impostor alike, so a check built on it passes everything and proves nothing.
    private static func checkDolbyVisionProfile(_ url: URL) async throws {
        guard let ffmpeg = ConverterTools.ffmpeg, let doviTool = ConverterTools.doviTool else { return }

        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "cinema-profile-\(UUID().uuidString)", directoryHint: .isDirectory)
        guard (try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)) != nil
        else { return }
        defer { try? FileManager.default.removeItem(at: scratch) }

        let sample = scratch.appending(path: "head.hevc")
        let rpu = scratch.appending(path: "head.rpu")

        _ = try? await Process.output(of: ffmpeg, arguments: [
            "-y", "-loglevel", "error", "-t", "2",
            "-i", url.path(percentEncoded: false),
            "-map", "0:v:0", "-c:v", "copy",
            "-bsf:v", "hevc_mp4toannexb", "-f", "hevc",
            sample.path(percentEncoded: false)
        ])
        _ = try? await Process.output(of: doviTool, arguments: [
            "extract-rpu", sample.path(percentEncoded: false), "-o", rpu.path(percentEncoded: false)
        ])
        guard let info = try? await Process.output(of: doviTool, arguments: [
            "info", "-i", rpu.path(percentEncoded: false), "-f", "0"
        ]) else { return }

        // Output that can't be parsed at all is "no opinion" and passes: a tool changing its
        // output format must not start deleting good files.
        guard let profile = dolbyVisionProfile(in: info) else { return }
        guard profile == 8 else { throw ConversionError.dolbyVisionLost }
    }

    /// The `dovi_profile` from `dovi_tool info`'s JSON, or `nil` when it can't be read as JSON.
    static func dolbyVisionProfile(in output: Data) -> Int? {
        guard let start = output.firstIndex(of: UInt8(ascii: "{")),
              let object = try? JSONSerialization.jsonObject(with: output[start...]) as? [String: Any]
        else { return nil }
        // An enhancement layer is a profile-7 tell in its own right, whatever the profile says.
        if object["el_type"] != nil { return 7 }
        return object["dovi_profile"] as? Int
    }

    /// Whether any sampled frame carries an RPU. Matched by substring — what ffmpeg prints is
    /// "Dolby Vision RPU Data", and matching the stable part of that is one fewer place a point
    /// release could quietly break this check.
    static func hasDolbyVisionRPU(in json: Data) -> Bool {
        struct FrameSideData: Decodable {
            struct Frame: Decodable {
                struct SideData: Decodable { let sideDataType: String? }
                let sideDataList: [SideData]?
            }
            let frames: [Frame]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let decoded = try? decoder.decode(FrameSideData.self, from: json) else { return false }
        return decoded.frames.contains { frame in
            frame.sideDataList?.contains { ($0.sideDataType ?? "").contains("Dolby Vision RPU") } == true
        }
    }
}
#endif
