/*
See the LICENSE.txt file for licensing information.

Abstract:
Finding out, before committing hours, whether copying a film's picture keeps its Dolby Vision
in a form an Apple device will actually render.
*/

#if os(macOS)
import Foundation

/// Tests the cheap route on a fragment before choosing it for the whole film.
///
/// Some Dolby Vision sources come out of a stream copy declaring compatibility 6 rather than 1 —
/// a file that opens, reports itself playable, decodes in ffmpeg, and shows a viewer a black
/// screen. Re-encoding the same picture with the *same* RPU produces compatibility 1 and renders.
///
/// Whatever property of the base-layer bitstream decides that is unknown: two implementations
/// diffed the RPU headers, the VUI and the static HDR metadata and found nothing. It isn't visible
/// in any metadata either of them could read — but it is perfectly visible in fifteen seconds of
/// output, so this converts an unanswerable question into a measurement.
enum DolbyVisionProbe {
    /// Seconds of film to try it on. From frame zero, because a slice cut from the middle carries a
    /// frame drift of its own that has nothing to do with what's being measured here.
    private static let sampleSeconds = 15

    /// Whether copying this film's picture yields Dolby Vision an Apple device will render.
    ///
    /// `true` when it can't be tested — a missing tool or a failed probe is not evidence of a
    /// problem, and the verification at the end of the real conversion is the backstop either way.
    static func copyKeepsApplePlayableSignalling(_ media: SourceMedia) async -> Bool {
        guard media.dolbyVision != nil,
              let ffmpeg = ConverterTools.ffmpeg,
              let doviTool = ConverterTools.doviTool,
              let mp4box = ConverterTools.mp4box,
              let rebuild = DolbyVisionRebuild(media: media) else { return true }

        let workspace = FileManager.default.temporaryDirectory
            .appending(path: "cinema-dvprobe-\(UUID().uuidString)", directoryHint: .isDirectory)
        guard (try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)) != nil
        else { return true }
        defer { try? FileManager.default.removeItem(at: workspace) }

        let slice = workspace.appending(path: "slice.mkv")
        let video = workspace.appending(path: "video.hevc")
        let muxed = workspace.appending(path: "probe.mp4")

        do {
            _ = try await Process.output(of: ffmpeg, arguments: [
                "-y", "-hide_banner", "-v", "error",
                "-i", media.url.path(percentEncoded: false),
                "-t", String(sampleSeconds), "-map", "0:\(media.videoStreamIndex)", "-c", "copy",
                slice.path(percentEncoded: false)
            ])

            let conversion = rebuild.convertArguments(from: slice)
            _ = try await Process.runPiped(
                ffmpeg, arguments: conversion.ffmpeg,
                into: doviTool, arguments: conversion.doviTool + [video.path(percentEncoded: false)],
                holding: { _ in }, expectedBytes: nil, watching: video) { _ in }

            _ = try await Process.output(of: mp4box, arguments: [
                "-quiet",
                "-add", "\(video.path(percentEncoded: false)):dvp=8.hdr10:fps=\(rebuild.frameRate)",
                "-new", muxed.path(percentEncoded: false)
            ])
        } catch {
            return true
        }

        guard let ffprobe = ConverterTools.ffprobe,
              let output = try? await Process.output(of: ffprobe, arguments: [
                  "-v", "error", "-select_streams", "v:0",
                  "-show_entries", "stream_side_data=dv_bl_signal_compatibility_id",
                  "-of", "csv=p=0", muxed.path(percentEncoded: false)
              ]) else { return true }

        let text = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        guard let compatibility = Int(text) else { return true }
        return compatibility == 1
    }
}
#endif
