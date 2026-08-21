/*
See the LICENSE.txt file for licensing information.

Abstract:
What a subtitle track is, read from its cues rather than from its flags or its title.
*/

#if os(macOS)
import Foundation

/// Whether a subtitle track is forced or SDH, decided by reading it.
///
/// Both questions have an obvious answer that doesn't work. The `forced` and `hearing_impaired`
/// dispositions are routinely absent — *Predator: Badlands* declares forcedness only in
/// `title=BTM FORCED` — and the title is written in whatever language pressed the disc, so
/// *Supergirl*'s English SDH track is titled `NON UDENTI`. A keyword list in one language encodes
/// an assumption about the release and fails silently on the language nobody added.
///
/// So the last signal reads the cues themselves, and the two questions turn out to need different
/// measurements: a forced track is identified by **how little it says**, an SDH track by **what
/// kind of thing it says**. Neither reads a word of the title. See `Docs/output-spec.md` point 19.
struct SubtitleContent: Sendable, Equatable {
    /// How many cues the track carries.
    let cues: Int
    /// Cues beginning with `[` or `(` — a bracketed sound description or speaker label.
    let bracketed: Int
    /// The track's runtime, so cue rate means something.
    let duration: Double

    /// Cues per minute. A forced track runs 1–2; a full one 12–22.
    var cuesPerMinute: Double {
        guard duration > 0 else { return 0 }
        return Double(cues) / (duration / 60)
    }

    /// Whether the cues say this is SDH.
    ///
    /// **Absolute, not thresholded.** A full track carries *zero* bracketed cues — measured across
    /// six films and eleven tracks, including a same-language sibling pair where the variants
    /// differ by dialect rather than by kind. So any bracketed cue at all is the signal, and there
    /// is no ratio to tune and no sibling track required.
    ///
    /// **Both bracket styles count, and a release uses one or the other.** *Predator: Badlands*
    /// writes its entire SDH track in parentheses — `(WIND WHOOSHING)`, `(CHANTING IN YAUTJA)`,
    /// 707 cues and not one square bracket — while every other film here uses `[`. A `[`-only rule
    /// scores that track zero and reads it as ordinary subtitles. Measured across sixteen tracks in
    /// six films: **every full track scores zero on both symbols, every SDH track scores high on
    /// exactly one.** The separation is absolute either way; the styles are alternatives, not a
    /// spectrum.
    ///
    /// Two things that separation depends on, each of which one film and no other exposed:
    /// `♪` is **not** counted — song lyrics are dialogue and belong in a full track, and *Across
    /// the Spider-Verse*'s American full track carries hundreds of them — and the bracket must open
    /// the line, because the same film's "English full" track contains exactly one *inline* sound
    /// description (`It is I, the Armadillo-- [grunts] Oh!`). Counted anywhere that track scores 1
    /// and the rule is merely well-margined; anchored to the line start it scores 0 and the rule
    /// is true as stated.
    var readsAsSDH: Bool { bracketed > 0 }

    /// Whether the cue rate says this is forced.
    ///
    /// Corroboration, never a promotion on its own — this is HandBrake's "Foreign Audio Scan"
    /// reduced to a number, and the gap between 1–2 and 12–22 cues per minute is wide enough to
    /// read but not wide enough to overrule a source that says otherwise.
    var readsAsForced: Bool { cues > 0 && cuesPerMinute < 4 }
}

/// Reads what a source's subtitle tracks actually contain.
enum SubtitleScan {
    /// The cue content of the given tracks, keyed by stream index.
    ///
    /// Cheap despite converting subtitles: a text track is a few hundred kilobytes beside a 60 GB
    /// picture, and `-map` takes one stream at a time so nothing else is decoded. Scanning is
    /// deliberately limited to the tracks that will actually be kept — reading all 33 of Predator's
    /// would spend a minute answering questions about tracks nobody will see.
    ///
    /// A track that can't be read is simply absent from the result, which leaves the flag and the
    /// title as the only signals for it. That is a worse answer, not a wrong one.
    static func scan(_ tracks: [SourceMedia.SubtitleTrack], of media: SourceMedia) async -> [Int: SubtitleContent] {
        guard let ffmpeg = ConverterTools.ffmpeg else { return [:] }
        var found: [Int: SubtitleContent] = [:]
        for track in tracks {
            // `Process.output`, not `Process.diagnostics`. ffmpeg writes the subtitles to
            // **stdout** and only its complaints to stderr, so reading diagnostics returned an
            // empty string for every track — and an empty string measures as zero cues, which
            // `readsAsSDH` and `readsAsForced` both read as "no". The whole cue signal was inert
            // and nothing failed: the tests exercised `measure` directly, and the real-media check
            // extracted tracks with a shell command rather than through this function.
            guard let data = try? await Process.output(of: ffmpeg, arguments: [
                "-v", "error",
                "-i", media.url.path(percentEncoded: false),
                "-map", "0:\(track.index)",
                "-f", "srt", "-"
            ]) else { continue }
            found[track.index] = measure(String(decoding: data, as: UTF8.self),
                                         duration: media.duration)
        }
        return found
    }

    /// Counts a SubRip document, which is the same shape whatever produced it.
    ///
    /// Split out from the scan so the counting rule can be tested without running ffmpeg — it is
    /// the part with the two hard-won details in it, and the part worth being sure of.
    static func measure(_ srt: String, duration: Double) -> SubtitleContent {
        var cues = 0
        var bracketed = 0
        var isCueText = false
        for line in srt.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.contains(" --> ") {
                cues += 1
                isCueText = true
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                isCueText = false
                continue
            }
            // Only the first line of a cue is examined for its opening bracket, which is where a
            // sound description sits. A continuation line is ordinary dialogue.
            if isCueText {
                if opensWithADescription(trimmed) { bracketed += 1 }
                isCueText = false
            }
        }
        return SubtitleContent(cues: cues, bracketed: bracketed, duration: duration)
    }

    /// Whether a cue's first line opens with a bracketed description, once the things that can
    /// legitimately precede one are set aside.
    ///
    /// A bare `hasPrefix("[")` misses more than it looks. *Across the Spider-Verse*'s British SDH
    /// track writes speaker labels as `- [woman] Hey, Gwen.` — a dialogue dash, then the label —
    /// and positions others with an ASS override, `{\an8}[music turns dramatic]`. 108 of its cues
    /// open that way, and a track that used **only** that convention would score zero and be read
    /// as an ordinary subtitle.
    ///
    /// Stripping those prefixes was checked against the alternative it risks — that a *full* track
    /// writes `- ` before ordinary dialogue and would start scoring. It doesn't: across all six of
    /// that film's English text tracks the full ones stay at zero either way, while the SDH ones
    /// rise from 486 to 594. The separation is untouched and the signal is stronger.
    private static func opensWithADescription(_ line: String) -> Bool {
        var text = Substring(line)
        while true {
            if text.hasPrefix("-") {
                text = text.dropFirst().drop { $0 == " " }
            } else if text.hasPrefix("{"), let close = text.firstIndex(of: "}") {
                text = text[text.index(after: close)...]
            } else if text.hasPrefix("<"), let close = text.firstIndex(of: ">") {
                text = text[text.index(after: close)...]
            } else {
                return text.hasPrefix("[") || text.hasPrefix("(")
            }
        }
    }
}
#endif
