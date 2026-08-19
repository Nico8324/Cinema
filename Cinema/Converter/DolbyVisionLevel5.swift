/*
See the LICENSE.txt file for licensing information.

Abstract:
Reading the letterbox the studio declared, rather than inferring it from pixels.
*/

#if os(macOS)
import Foundation

/// The active picture area a Dolby Vision film declares in its own metadata.
///
/// This is the authoritative answer to "where are the black bars", and it is a different kind of
/// answer from looking at the pixels. `cropdetect` measures what a few sampled frames happen to
/// look like; Level 5 is what the studio *stated* about the framing. On a film whose picture opens
/// up part-way through — an IMAX sequence filling the frame — the sampled pixels are black in most
/// scenes and detection wants to cut, while the metadata simply says the active area is the whole
/// frame and always did.
///
/// So: when a source carries Dolby Vision, read this and don't detect anything. Detection is for
/// the files that have no metadata to consult.
enum DolbyVisionLevel5 {
    /// How many places in the film to read the metadata at.
    ///
    /// More than one because Level 5 is per-shot: a film may legitimately declare different active
    /// areas in different scenes, and that is exactly the case a single reading would get wrong.
    private static let sampleCount = 6
    /// Seconds of video to lift at each one — enough to be sure of catching a frame with an RPU.
    private static let sampleSeconds = 1

    /// Whether the film's enhancement layer carries picture — and so whether converting it to
    /// single-layer 8.1 costs real detail.
    ///
    /// MEL (minimal) carries none: dropping it costs nothing. FEL (full) carries actual refinement
    /// of the base layer, and 8.1 has nowhere to put it, so converting a FEL source loses detail
    /// permanently. That's unavoidable — but it has to be *said*, because nothing in the output
    /// would ever reveal it.
    static func enhancementLayerType(of media: SourceMedia) async -> String? {
        guard media.dolbyVision != nil,
              let ffmpeg = ConverterTools.ffmpeg,
              let doviTool = ConverterTools.doviTool else { return nil }

        let workspace = FileManager.default.temporaryDirectory
            .appending(path: "cinema-el-\(UUID().uuidString)", directoryHint: .isDirectory)
        guard (try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)) != nil
        else { return nil }
        defer { try? FileManager.default.removeItem(at: workspace) }

        let slice = workspace.appending(path: "head.hevc")
        let rpu = workspace.appending(path: "head.rpu")
        _ = try? await Process.output(of: ffmpeg, arguments: [
            "-y", "-hide_banner", "-v", "error", "-t", "2",
            "-i", media.url.path(percentEncoded: false),
            "-map", "0:v:0", "-c:v", "copy", "-bsf:v", "hevc_mp4toannexb", "-f", "hevc",
            slice.path(percentEncoded: false)
        ])
        _ = try? await Process.output(of: doviTool, arguments: [
            "extract-rpu", slice.path(percentEncoded: false), "-o", rpu.path(percentEncoded: false)
        ])
        guard let info = try? await Process.output(of: doviTool, arguments: [
            "info", "-i", rpu.path(percentEncoded: false), "-f", "0"
        ]) else { return nil }

        guard let start = info.firstIndex(of: UInt8(ascii: "{")),
              let object = try? JSONSerialization.jsonObject(with: info[start...]) as? [String: Any]
        else { return nil }
        return object["el_type"] as? String
    }

    /// The letterbox the film declares, or `nil` if it can't be read — no `dovi_tool`, no Dolby
    /// Vision, or an extraction that produced nothing. `nil` means "ask something else", never
    /// "there are no bars".
    static func read(_ media: SourceMedia) async throws -> Letterbox? {
        guard media.dolbyVision != nil,
              let ffmpeg = ConverterTools.ffmpeg,
              let doviTool = ConverterTools.doviTool,
              media.duration > 0, media.height > 0
        else { return nil }

        let workspace = FileManager.default.temporaryDirectory
            .appending(path: "cinema-level5-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        var offsets: [(top: Int, bottom: Int)] = []
        for index in 0..<sampleCount {
            try Task.checkCancellation()
            let position = media.duration * (0.05 + 0.9 * Double(index) / Double(sampleCount - 1))
            if let offset = try? await readOffsets(at: position, of: media, in: workspace,
                                                   ffmpeg: ffmpeg, doviTool: doviTool) {
                offsets.append(offset)
            }
        }

        guard !offsets.isEmpty else { return nil }

        // The smallest offsets win, for the same reason the tallest crop-detected sample does: they
        // describe the most picture anyone declared. A film that opens to the full frame anywhere
        // declares 0 there, and that single reading correctly stops the whole film being cropped.
        let top = offsets.map(\.top).min() ?? 0
        let bottom = offsets.map(\.bottom).min() ?? 0
        guard top + bottom > 0 else { return .none }
        return .bars(height: media.height - top - bottom, top: top)
    }

    /// Lifts a second of video at one position, extracts its RPU, and reads the first frame's
    /// Level 5 block.
    private static func readOffsets(at position: Double, of media: SourceMedia, in workspace: URL,
                                    ffmpeg: URL, doviTool: URL) async throws -> (top: Int, bottom: Int) {
        let slice = workspace.appending(path: "slice.hevc")
        let rpu = workspace.appending(path: "slice-rpu.bin")
        defer {
            try? FileManager.default.removeItem(at: slice)
            try? FileManager.default.removeItem(at: rpu)
        }

        _ = try await Process.output(of: ffmpeg, arguments: [
            "-y", "-hide_banner", "-v", "error",
            "-ss", String(format: "%.3f", position),
            "-i", media.url.path(percentEncoded: false),
            "-t", String(sampleSeconds),
            "-map", "0:v:0", "-c:v", "copy", "-f", "hevc",
            slice.path(percentEncoded: false)
        ])

        _ = try await Process.output(of: doviTool, arguments: [
            "extract-rpu", slice.path(percentEncoded: false),
            "-o", rpu.path(percentEncoded: false)
        ])

        let info = try await Process.output(of: doviTool, arguments: [
            "info", "-i", rpu.path(percentEncoded: false), "-f", "0"
        ])
        return try parseLevel5(from: info)
    }

    /// Pulls the Level 5 offsets out of `dovi_tool info`'s JSON.
    ///
    /// The tool prints a human line before the JSON begins, so the object is found rather than
    /// assumed to start at byte zero.
    static func parseLevel5(from data: Data) throws -> (top: Int, bottom: Int) {
        guard let start = data.firstIndex(of: UInt8(ascii: "{")) else {
            throw ConversionError.failed("dovi_tool printed no metadata")
        }
        let object = try JSONSerialization.jsonObject(with: data[start...]) as? [String: Any]
        guard let dm = object?["vdr_dm_data"] as? [String: Any] else {
            throw ConversionError.failed("the RPU carries no display metadata")
        }

        // The blocks live under whichever metadata version the film was mastered with.
        let containers = ["cmv29_metadata", "cmv40_metadata"].compactMap { dm[$0] as? [String: Any] }
        for container in containers {
            guard let blocks = container["ext_metadata_blocks"] as? [[String: Any]] else { continue }
            for block in blocks {
                guard let level5 = block["Level5"] as? [String: Any],
                      let top = level5["active_area_top_offset"] as? Int,
                      let bottom = level5["active_area_bottom_offset"] as? Int else { continue }
                return (top, bottom)
            }
        }
        throw ConversionError.failed("the RPU declares no active area")
    }
}
#endif
