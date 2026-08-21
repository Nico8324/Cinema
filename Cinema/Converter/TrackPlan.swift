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
    /// Whether to keep only the language the film opens in, dropping every dub, every commentary
    /// and every subtitle in another language.
    ///
    /// This deliberately departs from `Docs/output-spec.md` points 13, 14 and 18, which describe
    /// what Apple ships: one main track *per language*, commentary alongside, every text subtitle
    /// carried. Keeping one language is a personal-library optimisation, not Apple parity — about
    /// 2% on a single film, but tens of gigabytes across a hundred of them, which is the argument
    /// that actually holds.
    ///
    /// Safe as a preference because of an asymmetry: dropping a language is irreversible *in the
    /// output* and completely recoverable *from the source*, which is never modified. A film can be
    /// reconverted with its dubs whenever someone wants them back.
    static let singleLanguageKey = "keepOnlyOriginalLanguage"

    static var keepsOnlyOriginalLanguage: Bool {
        UserDefaults.standard.object(forKey: singleLanguageKey) as? Bool ?? true
    }

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
        /// How many channels this track has **after** the conversion.
        ///
        /// Not always what it went in with. E-AC-3 holds 5.1 and no more, so a 7.1 source loses two
        /// channels — and the encoder does that silently, as a default nobody asked for. Carrying
        /// the number here is what lets the plan say so before the work starts instead of leaving
        /// it to be discovered by probing the finished file.
        let outputChannels: Int
    }

    /// The most channels this machine's encoder can actually write.
    ///
    /// **A tool limit, not a format one.** E-AC-3 itself carries 7.1 — Apple's own authoring
    /// specification lists it at 384 kbit/s — but `ffmpeg -h encoder=eac3` stops at `5.1`, and a
    /// 7.1 input silently comes back `5.1(side)`. Every 7.1 disc soundtrack meets that ceiling.
    /// Naming it after the format would blame the container for one encoder's limitation and
    /// discourage anyone from reaching for a better one.
    static func channelCeiling(for codec: String) -> Int {
        switch codec {
        case "eac3", "ac3": 6
        default: 8
        }
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
                            preferredLanguage: String? = nil,
                            keepingOnlyOneLanguage: Bool = TrackPlan.keepsOnlyOriginalLanguage) -> Selection {
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
        //   c. a track the source itself marks as the original language;
        //   d. the source's own default flag, if it survived selection;
        //   e. the first kept main track.
        //
        // A rip's own flag is exactly what a Russian-market disc of an English film gets wrong:
        // the dub sits first and flagged default, and copying that through is what makes a player
        // open an English film in Russian. Only a main track is ever a candidate — a commentary
        // that happened to carry the preferred language is never the winner.
        let mainTracks = orderedKept.filter { mainKept.contains($0.index) }
        let originalLanguage = media.originalLanguage.map(normalisedLanguage)

        var winner: SourceMedia.AudioTrack?
        var defaultNote: String?
        var selectionNotes: [String] = []

        if let preferredLanguage, !preferredLanguage.isEmpty,
           let match = mainTracks.first(where: { normalisedLanguage($0.language ?? "") == preferredLanguage }) {
            winner = match
            defaultNote = String(localized: "\(autonym(for: preferredLanguage)) by default — your setting")
        } else if let originalLanguage,
                  let match = mainTracks.first(where: { normalisedLanguage($0.language ?? "") == originalLanguage }) {
            winner = match
            defaultNote = String(localized: "\(autonym(for: originalLanguage)) by default — the original language")
        } else if let match = mainTracks.first(where: \.isOriginalLanguage) {
            // The picture often carries no language tag at all, and then the rip's own default is
            // the only thing left — which is how a film with three French tracks and one English
            // one, marked `original`, would open in French. The flag saying "this is the film's own
            // language" outranks the flag saying "this is the one this disc opens with".
            winner = match
            defaultNote = match.language.map {
                String(localized: "\(autonym(for: normalisedLanguage($0))) by default — the source marks it the original")
            }
        } else if let match = mainTracks.first(where: { ($0.disposition["default"] ?? 0) != 0 }) {
            winner = match
        } else {
            winner = mainTracks.first
        }

        if let winner, let index = orderedKept.firstIndex(where: { $0.index == winner.index }) {
            orderedKept.insert(orderedKept.remove(at: index), at: 0)
        }

        // One language: the track the film opens in, and nothing else — no dubs, no commentary.
        if keepingOnlyOneLanguage, let winner {
            let dropped = orderedKept.count - 1
            orderedKept = [winner]
            if dropped > 0 {
                selectionNotes.append(String(localized: "\(dropped) audio tracks dropped — only the film’s own language is kept"))
            }
        }

        var selection = Selection()
        selection.audio = orderedKept.map { track in
            let isDefault = track.index == winner?.index
            guard !passthroughAudio.contains(track.codec) else {
                return AudioChoice(track: track, isCopy: true, targetCodec: nil,
                                   bitrate: nil, isDefault: isDefault,
                                   outputChannels: track.channels)
            }
            // Multichannel lands on E-AC-3 — the format Apple ships surround in — where AAC is
            // what it ships stereo in.
            let targetCodec = track.channels > 2 ? "eac3" : "aac"
            let bitrate = track.channels > 2 ? "640k" : "256k"
            let outputChannels = min(track.channels, channelCeiling(for: targetCodec))
            if outputChannels < track.channels {
                selection.notes.append("\(track.codec.uppercased()) \(layoutName(forChannels: track.channels)) → \(displayName(forAudioCodec: targetCodec)) \(layoutName(forChannels: outputChannels))")
            } else {
                selection.notes.append("\(track.codec.uppercased()) → \(displayName(forAudioCodec: targetCodec))")
            }
            return AudioChoice(track: track, isCopy: false, targetCodec: targetCodec,
                               bitrate: bitrate, isDefault: isDefault,
                               outputChannels: outputChannels)
        }
        if duplicatesDropped > 0 {
            selection.notes.append(String(localized: "\(duplicatesDropped) duplicate audio tracks dropped"))
        }
        if let defaultNote { selection.notes.append(defaultNote) }
        selection.notes += selectionNotes
        return selection
    }

    // MARK: - What a subtitle track is

    /// Words that name a forced track, in the languages this library actually contains.
    ///
    /// Deliberately short, and deliberately **not** the last word. Every list like this encodes an
    /// assumption about who pressed the disc: an Italian release writes `FORZATI`, a French one
    /// `FORCÉS`, a German `ERZWUNGEN`, and the entry nobody added fails silently. The list is a
    /// cheap first pass over the common cases; `SubtitleContent` is what catches the rest.
    private static let forcedWords = ["forced", "forcés", "forces", "forzati", "erzwungen", "signs"]

    /// Words that name an SDH track. Same caveat, same backstop — `NON UDENTI` is why.
    private static let sdhWords = ["sdh", "hearing", "non udenti", "hörgeschädigte", "sourds"]

    /// Whether a track is forced, from every signal available in the order they can be trusted.
    ///
    /// The disposition first, because a source that sets it means it. Then the title, which is
    /// where most rips actually declare it. Then the cue rate, which is the only signal that
    /// survives a language nobody anticipated — a forced track runs 1–2 cues a minute against
    /// 12–22 for a full one, because it translates the alien dialogue and nothing else.
    static func isForced(_ track: SourceMedia.SubtitleTrack,
                         content: SubtitleContent? = nil) -> Bool {
        if track.isForced { return true }
        if let title = track.title?.lowercased(), forcedWords.contains(where: title.contains) {
            return true
        }
        return content?.readsAsForced ?? false
    }

    /// Whether a track is SDH, by the same ladder — flag, title, then the cues.
    ///
    /// The last rung is a different measurement from the forced one and has to be: cue *rate*
    /// needs a sibling full track to compare against, and *Supergirl* has none. What separates
    /// them is the cue text — see `SubtitleContent.readsAsSDH`.
    static func isHearingImpaired(_ track: SourceMedia.SubtitleTrack,
                                  content: SubtitleContent? = nil) -> Bool {
        if track.isHearingImpaired { return true }
        if let title = track.title?.lowercased(), sdhWords.contains(where: title.contains) {
            return true
        }
        return content?.readsAsSDH ?? false
    }

    /// The subtitle tracks that actually reach the output, after the single-language rule.
    ///
    /// One definition, read by the mux *and* by the pass that labels the finished file. When those
    /// two disagreed — the mux keeping English, the labelling still counting every language — the
    /// labelling pass found fewer tracks than it expected and refused to tag them, which is the
    /// right response to a mismatch and the wrong thing to have to discover after an encode.
    static func keptSubtitles(for media: SourceMedia, spokenLanguage: String?) -> [SourceMedia.SubtitleTrack] {
        let text = media.subtitles.filter { textSubtitles.contains($0.codec) }
        guard keepsOnlyOriginalLanguage, let spokenLanguage else { return text }
        return text.filter { $0.language.map(normalisedLanguage) == spokenLanguage }
    }

    /// The language a film opens in, which is what the single-language rule keeps.
    static func spokenLanguage(of media: SourceMedia, preferredLanguage: String? = nil) -> String? {
        selectAudio(from: media, preferredLanguage: preferredLanguage)
            .audio.first(where: \.isDefault)?.track.language.map(normalisedLanguage)
    }

    /// The audio and subtitle arguments, identical on both routes.
    ///
    /// - Parameter sidecars: subtitle files found beside the source, each already its own ffmpeg
    ///   input — a sidecar at `sidecars[offset]` is always input `offset + 1`.
    /// - Parameter content: what each kept subtitle track's cues contain, keyed by stream index,
    ///   from `SubtitleScan`. Empty is legal and means forced and SDH are decided from the flag and
    ///   the title alone — the answer a source in an unanticipated language gets wrong.
    static func trackArguments(for media: SourceMedia, sidecars: [SidecarSubtitle] = [],
                               preferredLanguage: String? = nil,
                               content: [Int: SubtitleContent] = [:]) -> (arguments: [String], notes: [String]) {
        var arguments: [String] = []
        var notes: [String] = []

        let selection = selectAudio(from: media, preferredLanguage: preferredLanguage)
        for (offset, choice) in selection.audio.enumerated() {
            arguments += ["-map", "0:\(choice.track.index)"]
            if choice.isCopy {
                arguments += ["-c:a:\(offset)", "copy"]
            } else {
                arguments += ["-c:a:\(offset)", choice.targetCodec!, "-b:a:\(offset)", choice.bitrate!]
                // Stated rather than left to the encoder. ffmpeg downmixes to its ceiling on its
                // own, which produces the right file for the wrong reason: a silent default is
                // indistinguishable from a decision, and only a decision can be reported.
                if choice.outputChannels != choice.track.channels {
                    arguments += ["-ac:a:\(offset)", "\(choice.outputChannels)"]
                }
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

        let spoken = selection.audio.first(where: \.isDefault)?.track.language.map(normalisedLanguage)
        let allText = media.subtitles.filter { textSubtitles.contains($0.codec) }
        let text = keptSubtitles(for: media, spokenLanguage: spoken)
        if allText.count > text.count {
            notes.append(String(localized: "\(allText.count - text.count) subtitle tracks dropped — only the film’s own language is kept"))
        }

        // Which subtitle track, if any, starts switched on: a forced track in the language the
        // film will actually open in, since that one carries dialogue a viewer can't otherwise
        // follow. Everything else starts off — and exactly one `default` is what lets the muxer
        // group them at all.
        let defaultAudioLanguage = selection.audio.first(where: \.isDefault)?
            .track.language.map(normalisedLanguage)
        let forcedLanguages: [String?] =
            text.map { isForced($0, content: content[$0.index]) ? $0.language.map(normalisedLanguage) : nil }
            + sidecars.map { $0.isForced ? $0.language.map(normalisedLanguage) : nil }
        let defaultSubtitle = forcedLanguages.firstIndex { $0 != nil && $0 == defaultAudioLanguage }

        for (offset, track) in text.enumerated() {
            arguments += ["-map", "0:\(track.index)"]
            arguments += ["-disposition:s:\(offset)", subtitleDisposition(
                isDefault: offset == defaultSubtitle,
                isForced: isForced(track, content: content[track.index]),
                isHearingImpaired: isHearingImpaired(track, content: content[track.index])
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

    /// A channel count as people say it: 7.1, not "8-channel".
    static func layoutName(forChannels channels: Int) -> String {
        switch channels {
        case 1: String(localized: "mono")
        case 2: String(localized: "stereo")
        case 6: "5.1"
        case 7: "6.1"
        case 8: "7.1"
        default: String(localized: "\(channels)-channel")
        }
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
