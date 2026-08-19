/*
See the LICENSE.txt file for licensing information.

Abstract:
Which audio and subtitle tracks survive a conversion, and how each one gets there.
*/

#if os(macOS)
import Foundation

/// The audio and subtitles the output keeps, and the ffmpeg arguments that carry them.
///
/// Ported from Immersive Companions, which learned each of these rules from a file that came out
/// wrong. `Docs/output-spec.md` points 13–24 are what this implements.
enum TrackPlan {
    /// Audio codecs MP4 carries and AVFoundation decodes.
    static let passthroughAudio: Set<String> = ["aac", "ac3", "eac3", "alac", "mp3"]
    /// Subtitle codecs that survive into MP4's text track. Bitmap subtitles have no home there.
    static let textSubtitles: Set<String> = ["subrip", "srt", "ass", "ssa", "mov_text", "text", "webvtt"]

    /// One audio track as it survives into the output.
    struct AudioChoice: Sendable, Equatable {
        let track: SourceMedia.AudioTrack
        let isCopy: Bool
        let targetCodec: String?
        let bitrate: String?
        /// The one track the file opens in. Exactly one kept track carries this.
        let isDefault: Bool
    }

    struct Selection: Sendable {
        var audio: [AudioChoice] = []
        var notes: [String] = []
        var isTranscodingAudio: Bool { audio.contains { !$0.isCopy } }
    }

    /// Groups audio by language, keeps one main track per group plus anything that's a different
    /// programme rather than another mix of it, and decides how each survivor reaches the output.
    ///
    /// E-AC-3 is preferred first because it is the only format here that can carry Atmos's JOC
    /// metadata, then AC-3, then whatever else MP4 already holds. Only when nothing in a language
    /// passes through is anything transcoded, and then it's the richest source that's taken: a
    /// stray stereo track never wins over a surround mix merely for being in a copyable codec.
    static func selectAudio(from media: SourceMedia,
                            preferredLanguage: String? = nil) -> Selection {
        let passthroughPriority: [String: Int] = ["eac3": 0, "ac3": 1, "aac": 2, "alac": 2, "mp3": 2]

        // Grouped in the file's own order, so a language appearing twice isn't reshuffled.
        var order: [String] = []
        var groups: [String: [SourceMedia.AudioTrack]] = [:]
        for track in media.audio {
            let key = track.language ?? "und"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(track)
        }

        var kept: Set<Int> = []
        var mainKept: Set<Int> = []
        var duplicatesDropped = 0

        for key in order {
            let tracks = groups[key] ?? []
            let secondary = tracks.filter(\.isSecondaryProgramme)
            let candidates = tracks.filter { !$0.isSecondaryProgramme }

            // Best copyable candidate by codec, channels breaking ties — a 5.1 AC-3 beats a
            // stereo AC-3, not merely a stereo AAC.
            let byPriority = candidates.compactMap { track in
                passthroughPriority[track.codec].map { (track, $0) }
            }
            let bestPassthrough = byPriority.min { ($0.1, -$0.0.channels) < ($1.1, -$1.0.channels) }?.0
            let richest = candidates.max { $0.channels < $1.channels }

            if let main = bestPassthrough, main.channels > 2 || (richest?.channels ?? 0) <= 2 {
                kept.insert(main.index)
                mainKept.insert(main.index)
            } else if let richest {
                kept.insert(richest.index)
                mainKept.insert(richest.index)
            }
            if candidates.count > 1 { duplicatesDropped += candidates.count - 1 }
            kept.formUnion(secondary.map(\.index))
        }

        var orderedKept = media.audio.filter { kept.contains($0.index) }

        // Which kept main track becomes the default — the one a player opens the film in:
        //   a. the person's own setting, when a kept main track has it;
        //   b. the original language, from the *picture's* own tag;
        //   c. the source's own default flag, if it survived selection;
        //   d. the first kept main track.
        //
        // A rip's own flag is exactly what a Russian-market disc of an English film gets wrong:
        // the dub sits first and flagged default, and copying that through is what makes a player
        // open an English film in Russian. Only a main track is ever a candidate — a commentary
        // that happened to carry the preferred language is never the winner.
        let mainTracks = orderedKept.filter { mainKept.contains($0.index) }
        let originalLanguage = media.originalLanguage.map(normalisedLanguage)

        var winner: SourceMedia.AudioTrack?
        var defaultNote: String?

        if let preferredLanguage, !preferredLanguage.isEmpty,
           let match = mainTracks.first(where: { normalisedLanguage($0.language ?? "") == preferredLanguage }) {
            winner = match
            defaultNote = String(localized: "\(autonym(for: preferredLanguage)) by default — your setting")
        } else if let originalLanguage,
                  let match = mainTracks.first(where: { normalisedLanguage($0.language ?? "") == originalLanguage }) {
            winner = match
            defaultNote = String(localized: "\(autonym(for: originalLanguage)) by default — the original language")
        } else if let match = mainTracks.first(where: { ($0.disposition["default"] ?? 0) != 0 }) {
            winner = match
        } else {
            winner = mainTracks.first
        }

        if let winner, let index = orderedKept.firstIndex(where: { $0.index == winner.index }) {
            orderedKept.insert(orderedKept.remove(at: index), at: 0)
        }

        var selection = Selection()
        selection.audio = orderedKept.map { track in
            let isDefault = track.index == winner?.index
            guard !passthroughAudio.contains(track.codec) else {
                return AudioChoice(track: track, isCopy: true, targetCodec: nil,
                                   bitrate: nil, isDefault: isDefault)
            }
            // Multichannel lands on E-AC-3 — the format Apple ships surround in — where AAC is
            // what it ships stereo in.
            let targetCodec = track.channels > 2 ? "eac3" : "aac"
            let bitrate = track.channels > 2 ? "640k" : "256k"
            selection.notes.append("\(track.codec.uppercased()) → \(displayName(forAudioCodec: targetCodec))")
            return AudioChoice(track: track, isCopy: false, targetCodec: targetCodec,
                               bitrate: bitrate, isDefault: isDefault)
        }
        if duplicatesDropped > 0 {
            selection.notes.append(String(localized: "\(duplicatesDropped) duplicate audio tracks dropped"))
        }
        if let defaultNote { selection.notes.append(defaultNote) }
        return selection
    }

    /// The audio and subtitle arguments, identical on both routes.
    ///
    /// - Parameter sidecars: subtitle files found beside the source, each already its own ffmpeg
    ///   input — a sidecar at `sidecars[offset]` is always input `offset + 1`.
    static func trackArguments(for media: SourceMedia, sidecars: [SidecarSubtitle] = [],
                               preferredLanguage: String? = nil) -> (arguments: [String], notes: [String]) {
        var arguments: [String] = []
        var notes: [String] = []

        let selection = selectAudio(from: media, preferredLanguage: preferredLanguage)
        for (offset, choice) in selection.audio.enumerated() {
            arguments += ["-map", "0:\(choice.track.index)"]
            if choice.isCopy {
                arguments += ["-c:a:\(offset)", "copy"]
            } else {
                arguments += ["-c:a:\(offset)", choice.targetCodec!, "-b:a:\(offset)", choice.bitrate!]
            }
            arguments += ["-disposition:a:\(offset)", audioDisposition(for: choice)]
            // Written explicitly rather than trusted to travel: the Dolby Vision route carries
            // audio through an intermediate that MP4Box imports separately, and one came out the
            // far end with `language: und` on every track.
            if let language = choice.track.language {
                arguments += ["-metadata:s:a:\(offset)", "language=\(normalisedLanguage(language))"]
            }
        }
        notes += selection.notes

        let text = media.subtitles.filter { textSubtitles.contains($0.codec) }

        // Which subtitle track, if any, starts switched on: a forced track in the language the
        // film will actually open in, since that one carries dialogue a viewer can't otherwise
        // follow. Everything else starts off — and exactly one `default` is what lets the muxer
        // group them at all.
        let defaultAudioLanguage = selection.audio.first(where: \.isDefault)?
            .track.language.map(normalisedLanguage)
        let forcedLanguages: [String?] =
            text.map { $0.isForced ? $0.language.map(normalisedLanguage) : nil }
            + sidecars.map { $0.isForced ? $0.language.map(normalisedLanguage) : nil }
        let defaultSubtitle = forcedLanguages.firstIndex { $0 != nil && $0 == defaultAudioLanguage }

        for (offset, track) in text.enumerated() {
            arguments += ["-map", "0:\(track.index)"]
            arguments += ["-disposition:s:\(offset)", subtitleDisposition(
                isDefault: offset == defaultSubtitle,
                isForced: track.isForced,
                isHearingImpaired: track.isHearingImpaired
            )]
            if let language = track.language {
                arguments += ["-metadata:s:s:\(offset)", "language=\(normalisedLanguage(language))"]
            }
        }

        for (offset, sidecar) in sidecars.enumerated() {
            let outputIndex = text.count + offset
            arguments += ["-map", "\(offset + 1):0"]
            arguments += ["-disposition:s:\(outputIndex)", subtitleDisposition(
                isDefault: outputIndex == defaultSubtitle,
                isForced: sidecar.isForced,
                isHearingImpaired: sidecar.isHearingImpaired
            )]
            if let language = sidecar.language {
                arguments += ["-metadata:s:s:\(outputIndex)", "language=\(normalisedLanguage(language))"]
            }
        }

        arguments += (text.isEmpty && sidecars.isEmpty) ? ["-sn"] : ["-c:s", "mov_text"]

        let dropped = media.subtitles.filter { !textSubtitles.contains($0.codec) }
        let droppedForced = dropped.filter(\.isForced)
        if !droppedForced.isEmpty {
            notes.append(String(localized: "\(droppedForced.count) forced subtitle tracks were dropped — the film may need a subtitle file beside it"))
        }
        let droppedOther = dropped.count - droppedForced.count
        if droppedOther > 0 {
            notes.append(String(localized: "\(droppedOther) image subtitles dropped"))
        }
        if !sidecars.isEmpty {
            notes.append(String(localized: "\(sidecars.count) subtitles added from files beside the movie"))
        }

        // Chapters go on both routes. Apple's own encodes carry none, and ffmpeg writes a chapter
        // as a timed-text track that GPAC turns into a phantom `bin_data` stream running the
        // length of the film.
        arguments += ["-map_chapters", "-1"]

        return (arguments, notes)
    }

    /// The audio and subtitles alone, for the intermediate GPAC adds to the rebuilt video.
    static func trackOnlyArguments(for media: SourceMedia, from source: URL, to destination: URL,
                                   sidecars: [SidecarSubtitle] = [],
                                   preferredLanguage: String? = nil) -> [String] {
        ["-y", "-loglevel", "error", "-i", source.path(percentEncoded: false)]
            + sidecars.flatMap { ["-i", $0.url.path(percentEncoded: false)] }
            + ["-vn"]
            + trackArguments(for: media, sidecars: sidecars, preferredLanguage: preferredLanguage).arguments
            + ["-progress", "pipe:1", "-nostats", destination.path(percentEncoded: false)]
    }

    /// One audio track's `-disposition` value.
    ///
    /// Exactly one track carries `default`, and every other is written explicitly so the muxer
    /// groups them as alternatives rather than scattering them into groups of one. What the rest
    /// carry matters too: a bare `0` clears the source's `comment` / `hearing_impaired` /
    /// `visual_impaired` flags, and that is the only thing in the file saying a track isn't the
    /// film. AVFoundation won't act on it — but ffmpeg writes it as a DASH role, MP4Box carries it
    /// through, and a library that looks can label it.
    static func audioDisposition(for choice: AudioChoice) -> String {
        if choice.isDefault { return "default" }
        let flags = ["comment", "hearing_impaired", "visual_impaired"]
            .filter { (choice.track.disposition[$0] ?? 0) != 0 }
        return flags.isEmpty ? "0" : flags.joined(separator: "+")
    }

    /// One subtitle track's `-disposition`, written for *every* track rather than only the ones
    /// with a flag to set.
    ///
    /// The empty case is why this returns `"0"` rather than nothing: ffmpeg builds each track's
    /// alternate group from this flag, and two tracks both claiming `default` cannot be
    /// alternatives — so the muxer gives each a group of its own, and a group of one is a track
    /// nothing can switch off. A rip that flags every track default is all it takes for a film to
    /// play two languages at once.
    static func subtitleDisposition(isDefault: Bool, isForced: Bool, isHearingImpaired: Bool) -> String {
        var flags: [String] = []
        if isDefault { flags.append("default") }
        if isForced { flags.append("forced") }
        if isHearingImpaired { flags.append("hearing_impaired") }
        return flags.isEmpty ? "0" : flags.joined(separator: "+")
    }

    /// ISO 639-2 bibliographic codes mapped to their terminological equivalents.
    ///
    /// Both name the same language and either is a legal Matroska tag, but GPAC doesn't treat them
    /// as interchangeable: a subtitle track carrying `chi` came out of `MP4Box -add` as `nor` —
    /// Norwegian — which is how a real conversion shipped with two Chinese subtitle tracks
    /// labelled Norwegian.
    static let bibliographicToTerminological: [String: String] = [
        "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "chi": "zho",
        "cze": "ces", "dut": "nld", "fre": "fra", "geo": "kat", "ger": "deu",
        "gre": "ell", "ice": "isl", "mac": "mkd", "mao": "mri", "may": "msa",
        "per": "fas", "rum": "ron", "slo": "slk", "tib": "bod", "wel": "cym"
    ]

    static func normalisedLanguage(_ language: String) -> String {
        bibliographicToTerminological[language] ?? language
    }

    /// The language's own name for itself — "français", not "French" — the way Apple's own
    /// language pickers read.
    private static func autonym(for language: String) -> String {
        Locale(identifier: language).localizedString(forLanguageCode: language) ?? language.uppercased()
    }

    private static func displayName(forAudioCodec codec: String) -> String {
        switch codec {
        case "eac3": "E-AC-3"
        case "ac3": "AC-3"
        default: codec.uppercased()
        }
    }
}
#endif
