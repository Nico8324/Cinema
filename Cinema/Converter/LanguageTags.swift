/*
See the LICENSE.txt file for licensing information.

Abstract:
Telling two subtitle tracks of the same language apart, which only a BCP-47 tag can do.
*/

#if os(macOS)
import Foundation

/// Distinguishing same-language subtitle variants — `Docs/output-spec.md` point 22.
///
/// A disc carrying "Chinese (Cantonese)" and "Chinese (Simplified)" comes out of the mux as two
/// tracks both reading "Chinese", because an Apple player builds each label from the language code
/// and ignores track *names* entirely. The one mechanism it does honour is the `elng` box — a BCP-47
/// extended tag — which `MP4Box -lang` writes and which AVFoundation renders, localised into the
/// viewer's own language, as "Chinese, Traditional" or "Cantonese".
///
/// Two rules, both learned by measurement:
///
/// - **Tag every track in a colliding group, or none of them.** AVFoundation disambiguates
///   contextually: tag one track while its neighbour keeps the plain code and *both* still display
///   as "Chinese". Half-doing this is indistinguishable from not doing it.
/// - **Classify conservatively.** The only evidence is free text a rip wrote. A wrong variant tag
///   tells a confident lie where an untagged track tells an obvious nothing, so if any track in a
///   group can't be read confidently, the whole group is left alone.
enum LanguageTags {
    /// What a title says about a variant, in the tag that claims exactly that and nothing more.
    ///
    /// Cantonese maps to `yue` rather than `zh-Hant`: Traditional and Simplified are *scripts* and
    /// Cantonese is a spoken variety. Tagging it `zh-Hant` would assert a script fact from a
    /// language fact — and collide with a genuine Traditional track, resolving the very ambiguity
    /// this exists to resolve into a duplicate. `zh-HK` is no better: AVFoundation renders it
    /// "Chinese, Traditional (Hong Kong)", asserting two things the title never said.
    static let variants: [(keyword: String, tag: String)] = [
        ("cantonese", "yue"),
        ("hong kong", "zh-HK"),
        ("traditional", "zh-Hant"),
        ("simplified", "zh-Hans"),
        ("mandarin", "zh-Hans"),
        ("brazil", "pt-BR"),
        ("portugal", "pt-PT"),
        ("european portuguese", "pt-PT"),
        ("latin", "es-419"),
        ("castilian", "es-ES"),
        ("spain", "es-ES")
    ]

    /// The tag for one track's title, or `nil` when nothing in it is unambiguous.
    static func tag(forTitle title: String?) -> String? {
        guard let title = title?.lowercased() else { return nil }
        return variants.first { title.contains($0.keyword) }?.tag
    }

    /// The `MP4Box -lang` arguments for a finished file, or an empty array when there's nothing to
    /// resolve — which is the common case, and costs nothing.
    ///
    /// - Parameter trackIDs: the MP4 track ID of each kept subtitle, read back from the finished
    ///   file rather than predicted — a tag applied to the wrong track silently rewrites *that*
    ///   track's language, which no check would catch.
    static func arguments(forSubtitles subtitles: [SourceMedia.SubtitleTrack],
                          trackIDs: [Int]) -> [String] {
        guard trackIDs.count == subtitles.count else { return [] }
        // Only languages that actually collide are worth touching.
        var byLanguage: [String: [Int]] = [:]
        for (offset, track) in subtitles.enumerated() {
            let language = TrackPlan.normalisedLanguage(track.language ?? "und")
            byLanguage[language, default: []].append(offset)
        }

        var arguments: [String] = []
        for (_, offsets) in byLanguage where offsets.count > 1 {
            let tags = offsets.map { tag(forTitle: subtitles[$0].title) }
            // Whole group or none: a partly tagged group shows no distinction at all.
            guard tags.allSatisfy({ $0 != nil }) else { continue }
            for (offset, tag) in zip(offsets, tags) {
                arguments += ["-lang", "\(trackIDs[offset])=\(tag!)"]
            }
        }
        return arguments
    }
}
#endif
