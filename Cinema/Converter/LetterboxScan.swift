/*
See the LICENSE.txt file for licensing information.

Abstract:
Finding the black bars in a film, and refusing to guess when the film changes shape.
*/

#if os(macOS)
import Foundation

/// What the black bars in a film turned out to be.
///
/// Cropping them is worth real time — a 2.39:1 film is a quarter fewer pixels to encode than the
/// frame it's stored in — but a wrong crop cuts picture off permanently and nothing in the output
/// says it happened. So this answers with `varies` rather than a number whenever the evidence
/// disagrees with itself.
enum Letterbox: Sendable, Equatable {
    /// The picture fills the frame.
    case none
    /// Bars in every sample, in the same place.
    case bars(height: Int, top: Int)
    /// The film changes shape as it plays — an IMAX sequence opening to the full frame, most often.
    /// Any single crop would cut the tall scenes, so nothing is cropped.
    case varies

    /// The height the picture should be encoded at, given the source's own height.
    func encodedHeight(fullHeight: Int) -> Int {
        if case .bars(let height, _) = self { height } else { fullHeight }
    }

    /// Whether the bars sit unevenly — 276 above and 277 below, say.
    ///
    /// Worth knowing because an odd total can't be split evenly in a 4:2:0 picture, so the rounding
    /// decides which row of the image is lost. Proven on real media in the pipeline this port comes
    /// from — a film declaring 276 above and 277 below came out 3840×1608 with its Level 5 zeroed —
    /// but never yet exercised by this code.
    func isAsymmetric(fullHeight: Int) -> Bool {
        guard case .bars(let height, let top) = self else { return false }
        return fullHeight - height - top != top
    }
}

/// Measures the black bars in a film, by reading what it declares or, failing that, by looking.
///
/// Sampling rather than scanning: reading every frame of an 80 GB source would cost most of an
/// hour before any work starts, and a handful of moments spread through the film answers the same
/// question. What it costs instead is certainty, which is why disagreement is resolved by cropping
/// less rather than more — and why `DolbyVisionLevel5` is preferred wherever it can answer.
///
/// The asymmetry that governs both routes: missing bars leaves a letterboxed frame, which is
/// harmless. Cropping a film that opens up cuts picture permanently and nothing in the output says
/// so. Every judgement call here is settled in the first direction.
enum LetterboxScan {
    /// How many moments through the film to look at.
    private static let sampleCount = 7
    /// How many frames to let `cropdetect` settle over at each one.
    private static let framesPerSample = 40
    /// How much taller one sample may be than the rest before the film is called variable.
    ///
    /// Deliberately small. A false "varies" costs encoding time; a false crop costs picture.
    private static let variationTolerance = 32
    /// Bars smaller than this aren't worth an encode — a two-pixel edge is mastering noise, not
    /// letterboxing, and cropping it would turn a free remux into hours of work.
    private static let minimumBarHeight = 8

    static func scan(_ media: SourceMedia) async throws -> Letterbox {
        // A Dolby Vision film states its own active area, and a statement beats an inference: this
        // reads what the studio declared instead of guessing from a handful of frames. Detection is
        // the fallback for files that carry no such metadata.
        if let declared = try await DolbyVisionLevel5.read(media) {
            return declared
        }

        guard let ffmpeg = ConverterTools.ffmpeg, media.duration > 0, media.height > 0 else {
            return .none
        }

        // `cropdetect`'s threshold is in the picture's own units, so a 10-bit file needs four times
        // the 8-bit default. Left at 24, every PQ black bar reads as picture and no film anywhere
        // appears to be letterboxed — the failure is silent and total.
        let limit = media.bitDepth >= 10 ? 96 : 24

        var samples: [(height: Int, top: Int)] = []
        for index in 0..<sampleCount {
            try Task.checkCancellation()
            // Spread across the middle of the film: opening logos and closing credits are black
            // enough to measure nothing at all.
            let position = media.duration * (0.08 + 0.84 * Double(index) / Double(sampleCount - 1))
            let output = try await Process.diagnostics(of: ffmpeg, arguments: [
                "-hide_banner", "-loglevel", "info",
                "-ss", String(format: "%.3f", position),
                "-i", media.url.path(percentEncoded: false),
                "-vf", "cropdetect=limit=\(limit):round=2:reset=0",
                "-frames:v", String(framesPerSample),
                "-f", "null", "-"
            ])
            if let sample = lastCrop(in: output) {
                samples.append(sample)
            }
        }

        guard !samples.isEmpty else { return .none }

        // A dark scene reads as smaller than the picture really is, never larger, so the tallest
        // sample is the closest thing to the truth. The rest are evidence about consistency.
        let tallest = samples.max { $0.height < $1.height }!
        let commonest = samples.map(\.height).mostCommon()

        // One sample reaching much higher than the others is a film that changes shape. It may
        // also be one lucky bright frame among six dark ones — indistinguishable from here, and
        // both are answered correctly by not cropping.
        if tallest.height - commonest > variationTolerance {
            return .varies
        }

        let bars = media.height - tallest.height
        guard bars >= minimumBarHeight else { return .none }
        return .bars(height: tallest.height, top: tallest.top)
    }

    /// The last `crop=W:H:X:Y` ffmpeg printed — cropdetect refines its answer as it goes, so the
    /// final line is the one that saw every frame in the sample.
    private static func lastCrop(in output: String) -> (height: Int, top: Int)? {
        let matches = output.matches(of: /crop=(\d+):(\d+):(\d+):(\d+)/)
        guard let last = matches.last,
              let height = Int(last.output.2), let top = Int(last.output.4) else { return nil }
        return (height, top)
    }
}

private extension Array where Element: Hashable {
    /// The value that appears most often, ties broken by the largest — which for crop heights
    /// means the reading that keeps the most picture.
    func mostCommon() -> Element where Element: Comparable {
        let counts = reduce(into: [Element: Int]()) { $0[$1, default: 0] += 1 }
        return counts.max { ($0.value, $0.key) < ($1.value, $1.key) }!.key
    }
}
#endif
