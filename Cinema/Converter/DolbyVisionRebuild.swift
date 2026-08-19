/*
See the LICENSE.txt file for licensing information.

Abstract:
Carrying Dolby Vision across a conversion, which no single tool can do.
*/

#if os(macOS)
import Foundation

/// Rebuilding a Dolby Vision track into a profile Apple can decode.
///
/// Apple plays profiles 5 and 8.1. A Blu-ray rip is profile 7 — base layer, enhancement layer and
/// RPU — which no Apple device decodes, so an ordinary remux throws the Dolby Vision away and keeps
/// the HDR10 base. That's watchable, and the metadata is right there in the file.
///
/// Three tools, because none does all of it: ffmpeg demuxes but can't rewrite an RPU, `dovi_tool`
/// rewrites the RPU but can't mux, and ffmpeg's MP4 muxer can't write the `dvvC` box that marks the
/// track as Dolby Vision — only GPAC will. So the video goes out to a raw stream, through
/// `dovi_tool`, and back in through `MP4Box`, while the audio and subtitles take the ordinary route
/// and are added at the end.
///
/// The enhancement layer is discarded rather than carried: 8.1 is single-layer by definition,
/// nothing Apple owns would read the EL, and dropping it takes about a tenth off the file.
struct DolbyVisionRebuild: Sendable {
    let videoStream: Int
    let mode: Int
    let frameRate: String

    /// Which `dovi_tool` mode turns a profile into 8.1, or `nil` for one not worth touching.
    ///
    /// Mode 0 for an already-profile-8 file looks like a no-op and isn't: skip it and GPAC writes
    /// `compatibility_id=6` rather than 1, which tells every non-Dolby-Vision display the base
    /// layer is something it can't show correctly.
    static func mode(forProfile profile: Int) -> Int? {
        switch profile {
        case 7: 2   // dual-layer Blu-ray: convert and drop the enhancement layer
        case 5: 3   // IPT-graded base, unwatchable as HDR10 until converted
        case 8: 0   // already 8.x — rewrite untouched, purely to fix the signalling
        default: nil
        }
    }

    init?(media: SourceMedia) {
        guard let dolbyVision = media.dolbyVision,
              let mode = Self.mode(forProfile: dolbyVision.profile) else { return nil }
        self.videoStream = media.videoStreamIndex
        self.mode = mode
        // The source's real rate as a fraction. A raw HEVC stream carries no timing, so MP4Box
        // takes this on trust — a rounded 24 for 23.976 material drifts a frame every 42 seconds.
        self.frameRate = Self.rateFraction(media.frameRate)
    }

    /// Pulls the RPU out of the source, converting it to 8.1 on the way.
    ///
    /// Read from the original rather than a converted copy: a plain HEVC decoder ignores the
    /// enhancement layer, so the frames it produces are the base layer in order — exactly what the
    /// RPU is keyed to.
    ///
    /// - Parameter crop: whether the picture that follows this RPU back in is being cropped.
    ///   `--crop` zeroes the Level 5 offsets as it rewrites, so the metadata stops declaring bars
    ///   the encode has already cut away.
    func extractRPUArguments(from source: URL, crop: Bool) -> (ffmpeg: [String], doviTool: [String]) {
        (
            ffmpeg: [
                "-y", "-loglevel", "error",
                "-i", source.path(percentEncoded: false),
                "-map", "0:\(videoStream)", "-c:v", "copy",
                "-bsf:v", "hevc_mp4toannexb", "-f", "hevc", "-"
            ],
            doviTool: ["-m", "\(mode)"] + (crop ? ["--crop"] : []) + ["extract-rpu", "-", "-o"]
        )
    }

    /// Demuxes the video and rewrites its RPU in place, for a picture being kept as it is.
    func convertArguments(from source: URL) -> (ffmpeg: [String], doviTool: [String]) {
        (
            ffmpeg: [
                "-y", "-loglevel", "error",
                "-i", source.path(percentEncoded: false),
                "-map", "0:\(videoStream)", "-c:v", "copy",
                // MP4-style length prefixes become start codes, the only shape dovi_tool reads.
                "-bsf:v", "hevc_mp4toannexb", "-f", "hevc", "-"
            ],
            doviTool: ["-m", "\(mode)", "convert", "--discard", "-", "-o"]
        )
    }

    /// Re-encodes the base layer to a raw stream.
    ///
    /// The one place in this app a frame is ever resized, and deliberately so: the frame count and
    /// frame rate the RPU is keyed to are untouched, only the dead border goes — and it goes as a
    /// real crop of real pixels rather than a conformance window or a `clap` box, both of which
    /// AVFoundation gets wrong on playback.
    func encodeArguments(from source: URL, to destination: URL, bitrate: Int,
                         framesPerSecond: Double, hdr: HDRMetadata,
                         crop: (width: Int, height: Int, top: Int)?) -> [String] {
        ["-y", "-loglevel", "error",
         "-i", source.path(percentEncoded: false),
         "-map", "0:\(videoStream)", "-an", "-sn",
         // One output frame per input frame, and no invention. ffmpeg's default is to conform the
         // output to a constant rate, duplicating frames where the source's timestamps imply a gap
         // — measured doing exactly that: 481 frames in, 483 out. The RPU is keyed to frame order,
         // so two invented frames mean two frames wearing metadata written for their neighbours,
         // and nothing in the finished file would ever say so.
         "-fps_mode:v", "passthrough"]
        + (crop.map { ["-vf", "crop=\($0.width):\($0.height):0:\($0.top)"] } ?? [])
        + PlaybackTarget.rateControlArguments(bitrate: bitrate)
        + PlaybackTarget.encoderParameters(
            bitrate: bitrate, framesPerSecond: framesPerSecond, dynamicRange: .hdr10,
            masteringDisplay: hdr.masteringDisplay, contentLightLevel: hdr.contentLightLevel)
        + PlaybackTarget.pictureArguments(for: .hdr10)
        + DynamicRange.hdr10.bitstreamColourArguments
        + ["-progress", "pipe:1", "-nostats", "-f", "hevc", destination.path(percentEncoded: false)]
    }

    /// Threads the RPU back between the slices of the freshly encoded stream.
    ///
    /// Only lines up because the encode changed neither the number of frames nor their order.
    /// `inject-rpu` trims surplus metadata from the *end*, which is the right repair only if the
    /// missing frames were at the end — so any `mismatched lengths` is fatal, not a warning.
    func injectArguments(video: URL, rpu: URL, to destination: URL) -> [String] {
        ["inject-rpu",
         "-i", video.path(percentEncoded: false),
         "--rpu-in", rpu.path(percentEncoded: false),
         "-o", destination.path(percentEncoded: false)]
    }

    /// Puts the rewritten video and the ordinary tracks into one file.
    ///
    /// `dvp=8.hdr10` is profile 8 with the HDR10 compatibility ID — 8.1, written so a player that
    /// doesn't know Dolby Vision still sees a correct HDR10 picture. The frame rate has to be given
    /// because a raw stream carries no timing of its own.
    func muxArguments(video: URL, tracks: URL, to destination: URL) -> [String] {
        ["-quiet",
         "-add", "\(video.path(percentEncoded: false)):dvp=8.hdr10:fps=\(frameRate)",
         "-add", tracks.path(percentEncoded: false),
         "-new", destination.path(percentEncoded: false)]
    }

    /// The frame rate as MP4Box wants it: the exact fraction where there is one.
    static func rateFraction(_ rate: Double) -> String {
        let known: [(Double, String)] = [
            (24000.0 / 1001, "24000/1001"), (30000.0 / 1001, "30000/1001"),
            (60000.0 / 1001, "60000/1001"), (24, "24"), (25, "25"), (30, "30"),
            (50, "50"), (60, "60")
        ]
        if let match = known.first(where: { abs($0.0 - rate) < 0.001 }) { return match.1 }
        return String(format: "%.6f", rate)
    }
}
#endif
