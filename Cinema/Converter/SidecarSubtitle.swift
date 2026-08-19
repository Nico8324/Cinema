/*
See the LICENSE.txt file for licensing information.

Abstract:
Subtitle files placed beside the source, folded into the output as native text tracks.
*/

#if os(macOS)
import Foundation

/// A subtitle file found beside the source, and what its name says about it.
///
/// Blu-ray rips carry their major-language subtitles as PGS images, which have nowhere to go in
/// MP4 and are dropped — so a converted film can end up with ten minor-language text tracks and no
/// English at all. The remedy is letting a person supply the text: a plain-text subtitle file named
/// after the source, sitting beside it, is muxed in as a native `mov_text` track and the sidecar
/// can be deleted afterwards. It's the user-supplied equivalent of the iTT files studios hand
/// Apple's own pipeline, and it's why OCR is refused rather than merely unimplemented.
struct SidecarSubtitle: Sendable, Equatable {
    let url: URL
    /// The ISO 639 tag read off the file name, passed straight through — ffmpeg and MP4 accept
    /// whatever's given. `nil` for a bare `Movie.srt`, which has nothing to write.
    let language: String?
    let isForced: Bool
    /// Hearing-impaired / SDH, from an `sdh` component in the name.
    let isHearingImpaired: Bool

    /// Extensions ffmpeg turns into `mov_text` on the way into MP4.
    static let acceptedExtensions: Set<String> = ["srt", "ass", "ssa", "vtt"]

    /// Finds subtitle files beside `source` whose name starts with its stem.
    ///
    /// `Movie.srt`, `Movie.eng.srt`, `Movie.en.forced.srt` and `Movie.fre.sdh.srt` are all
    /// accepted. `Movie2.srt` is not: matching is exact on the stem plus a dot, so a sequel in the
    /// same folder is never mistaken for this film's subtitles. Unrecognised components are
    /// ignored rather than disqualifying the file — a naming scheme this doesn't understand
    /// shouldn't cost the subtitles entirely.
    static func discover(for source: URL) -> [SidecarSubtitle] {
        let directory = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        guard let siblings = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }

        return siblings
            .compactMap { url -> SidecarSubtitle? in
                guard acceptedExtensions.contains(url.pathExtension.lowercased()) else { return nil }

                let base = url.deletingPathExtension().lastPathComponent
                let remainder: Substring
                if base == stem {
                    remainder = ""
                } else if base.hasPrefix(stem + ".") {
                    remainder = base.dropFirst(stem.count + 1)
                } else {
                    return nil
                }

                var language: String?
                var isForced = false
                var isHearingImpaired = false
                for component in remainder.split(separator: ".") {
                    let token = String(component)
                    switch token.lowercased() {
                    case "forced": isForced = true
                    case "sdh": isHearingImpaired = true
                    default:
                        if (2...3).contains(token.count), token.allSatisfy(\.isLetter) {
                            language = token
                        }
                    }
                }
                return SidecarSubtitle(url: url, language: language,
                                       isForced: isForced, isHearingImpaired: isHearingImpaired)
            }
            // A stable order, so which sidecar becomes ffmpeg input 1 doesn't depend on whatever
            // order `FileManager` happened to hand them back in.
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }
}
#endif
