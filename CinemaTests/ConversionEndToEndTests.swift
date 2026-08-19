/*
See the LICENSE.txt file for licensing information.

Abstract:
An end-to-end conversion of a real Dolby Vision slice, run through the actual pipeline.
*/

#if os(macOS)
import Testing
import Foundation
@testable import Cinema

/// Converts a real file with the real tools and checks what came out.
///
/// Off by default — it drives ffmpeg, dovi_tool and MP4Box over real media and takes minutes.
/// Run it with `CINEMA_E2E=<path to a source file>` in the environment. The slice it is pointed at
/// must be cut from **frame zero**: cutting from the middle of a film introduces a frame drift
/// between the picture and its RPU that is an artefact of the slicing, not of the pipeline.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CINEMA_E2E"] != nil))
struct ConversionEndToEndTests {

    @Test func convertsADolbyVisionSliceAndKeepsEverythingItShould() async throws {
        let source = URL(filePath: try #require(ProcessInfo.processInfo.environment["CINEMA_E2E"]))
        let plan = try await ConversionPlan.plan(for: source)

        print("E2E route: \(plan.route)")
        print("E2E letterbox: \(plan.letterbox)")
        print("E2E notes: \(plan.notes.map(\.id))")
        print("E2E estimate: \(Int(plan.estimate.total))s, \(plan.estimate.outputBytes / 1_000_000) MB")

        let outcome = try await ConversionRunner.run(plan)
        // Kept when asked, so a failure can be examined rather than only reported.
        defer {
            if ProcessInfo.processInfo.environment["CINEMA_E2E_KEEP"] == nil {
                try? FileManager.default.removeItem(at: outcome.output)
            }
        }
        print("E2E output: \(outcome.output.lastPathComponent), \(outcome.outputBytes / 1_000_000) MB, "
              + "encode \(Int(outcome.encodeSeconds))s, finish \(Int(outcome.finishSeconds))s")

        // The original is never touched.
        #expect(FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))

        let result = try await MediaProbe.probe(outcome.output)

        // Dolby Vision arrived as 8.1 — the profile Apple decodes, with the compatibility id that
        // tells an ordinary display its base layer is plain HDR10.
        #expect(result.dolbyVision?.profile == 8)
        #expect(result.dolbyVision?.compatibilityID == 1)

        // The picture is the shape the plan said, and every frame of it is there.
        if let encode = plan.route.encode {
            #expect(result.width == encode.width)
            #expect(abs(result.height - encode.height) <= 2)
        }
        let sourceFrames = try await frameCount(of: source)
        let outputFrames = try await frameCount(of: outcome.output)
        print("E2E frames: source \(sourceFrames), output \(outputFrames)")
        #expect(outputFrames == sourceFrames)

        // Sound: one English track that an Apple device can actually decode, since the source's
        // only surround mixes are TrueHD and AC-3.
        #expect(result.audio.contains { $0.language == "eng" && $0.isPlayableByApple })
        #expect(!result.audio.contains { $0.codec == "truehd" || $0.codec == "dts" })

        // Subtitles: the text ones survive, the bitmaps don't, and the language codes are
        // terminological — `chi` becomes `zho`, or GPAC turns it into Norwegian.
        #expect(!result.subtitles.isEmpty)
        #expect(result.subtitles.allSatisfy { $0.codec == "mov_text" })
        #expect(!result.subtitles.contains { $0.language == "chi" })
    }

    private func frameCount(of url: URL) async throws -> Int {
        let ffprobe = try #require(ConverterTools.ffprobe)
        let output = try await Process.output(of: ffprobe, arguments: [
            "-v", "error", "-select_streams", "v:0", "-count_packets",
            "-show_entries", "stream=nb_read_packets", "-of", "csv=p=0",
            url.path(percentEncoded: false)
        ])
        let text = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        return Int(text) ?? -1
    }
}
#endif
