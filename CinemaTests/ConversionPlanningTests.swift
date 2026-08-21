/*
See the LICENSE.txt file for licensing information.

Abstract:
Tests for the conversion planner: letterbox detection, routing, estimates, and queue order.
*/

#if os(macOS)
import Testing
import Foundation
@testable import Cinema

@Suite("Conversion planning")
struct ConversionPlanningTests {

    // MARK: - Letterbox detection

    /// The bug this exists to prevent: `cropdetect`'s threshold is in the picture's own units, so
    /// a 10-bit file needs four times the 8-bit default. Left at the default, every PQ black bar
    /// reads as picture, no film anywhere appears letterboxed, and the failure is completely
    /// silent — the conversion just encodes a third more pixels than it needed to, forever.
    @Test func findsBarsInATenBitClip() async throws {
        try requireFFmpeg()
        let clip = try await makeClip(width: 640, height: 360, barHeight: 60, tenBit: true)
        defer { try? FileManager.default.removeItem(at: clip.deletingLastPathComponent()) }

        let media = try await MediaProbe.probe(clip)
        #expect(media.bitDepth == 10)

        // 60 rows top and bottom of a 360-row frame leaves 240. Read from real video, so a row
        // either way is measurement, not a bug — what matters is that the bars were found at all.
        let letterbox = try await LetterboxScan.scan(media)
        guard case .bars(let height, let top) = letterbox else {
            Issue.record("no bars found in a letterboxed 10-bit clip: \(letterbox)")
            return
        }
        #expect((234...240).contains(height))
        #expect((60...66).contains(top))
    }

    @Test func findsBarsInAnEightBitClip() async throws {
        try requireFFmpeg()
        let clip = try await makeClip(width: 640, height: 360, barHeight: 60, tenBit: false)
        defer { try? FileManager.default.removeItem(at: clip.deletingLastPathComponent()) }

        let media = try await MediaProbe.probe(clip)
        guard case .bars(let height, _) = try await LetterboxScan.scan(media) else {
            Issue.record("no bars found in a letterboxed 8-bit clip")
            return
        }
        #expect((234...240).contains(height))
    }

    @Test func leavesAFullFrameAlone() async throws {
        try requireFFmpeg()
        let clip = try await makeClip(width: 640, height: 360, barHeight: 0, tenBit: true)
        defer { try? FileManager.default.removeItem(at: clip.deletingLastPathComponent()) }

        let media = try await MediaProbe.probe(clip)
        #expect(try await LetterboxScan.scan(media) == Letterbox.none)
    }

    /// An uneven letterbox — 276 above and 277 below — is proven in the pipeline this port comes
    /// from but not yet in this code, so it at least has to be recognised.
    @Test func recognisesAnUnevenLetterbox() {
        let even = Letterbox.bars(height: 1608, top: 276)
        let uneven = Letterbox.bars(height: 1607, top: 276)
        #expect(even.isAsymmetric(fullHeight: 2160) == false)
        #expect(uneven.isAsymmetric(fullHeight: 2160) == true)
    }

    // MARK: - Routing

    @Test func cropRequiresAnEncodeButAPlainMKVDoesNot() {
        // A file already at Apple's own rate: nothing to gain by re-encoding it.
        let source = media(codec: "h264", width: 1920, height: 1080, duration: 3600, bitrate: 5_000_000)
        #expect(ConversionPlan.plan(source: source, letterbox: .none).route == .rewrap)
        // Cropping is what costs the encode — so it only happens when someone asked for it.
        let cropped = ConversionPlan.plan(source: source, letterbox: .bars(height: 800, top: 140),
                                          cropsWhenItCosts: true)
        #expect(cropped.route.encode?.height == 800)
        #expect(cropped.route.encode?.isCropping == true)
    }

    /// A film whose shape changes can't be cropped to any single size — the tall scenes would lose
    /// their tops and bottoms permanently, and nothing in the finished file would say so.
    @Test func aVariableAspectRatioIsNeverCropped() {
        let source = media(codec: "hevc", width: 3840, height: 2160, duration: 8255)
        let plan = ConversionPlan.plan(source: source, letterbox: .varies, canRebuildDolbyVision: false)
        // Whatever route it takes, the full frame survives. Re-encoding isn't the point — not
        // cutting the tall scenes is.
        #expect(plan.route.encode?.height ?? source.height == source.height)
        #expect(plan.route.encode?.isCropping != true)
        #expect(plan.notes.contains(.aspectRatioVaries))
    }

    /// The bug this exists to prevent: an uncropped Dolby Vision film looked like a container job,
    /// because nothing about its shape needed changing. Copying that stream is precisely what
    /// destroys the Dolby Vision — and the plan would have promised 24 minutes for a film that
    /// takes the better part of a day.
    /// Copying a Dolby Vision stream is what destroys it: the RPU has to be rewritten on the way
    /// into MP4, whatever else the file needs — including for an already-8.1 file, where skipping
    /// the pass leaves every ordinary display told the base layer is something it can't show.
    @Test func dolbyVisionAlwaysTakesTheRebuildRoute() {
        let profile7 = media(codec: "hevc", width: 3840, height: 2160, duration: 8255,
                             dolbyVision: .init(profile: 7, compatibilityID: 6))
        #expect(ConversionPlan.plan(source: profile7, letterbox: .varies,
                                    canRebuildDolbyVision: true).route.isDolbyVision)

        // Already 8.1 and spending less than Apple's own rung: carried across without re-encoding.
        let alreadyRight = media(codec: "hevc", width: 3840, height: 2160, duration: 6559,
                                 bitrate: 16_000_000,
                                 dolbyVision: .init(profile: 8, compatibilityID: 1))
        let plan = ConversionPlan.plan(source: alreadyRight, letterbox: .none,
                                       canRebuildDolbyVision: true)
        #expect(plan.route == .rebuildDolbyVision(encode: nil))
        #expect(plan.route.isReencode == false)
    }

    /// The Apple-parity line, which is what this app is for: a file costing far more than Apple
    /// spends on the same picture is rebuilt to Apple's rate; one already at or below it is copied,
    /// because there the copy and the clone agree and the copy is a generation closer to the master.
    @Test func aFileAboveApplesRateIsRebuiltAndOneBelowItIsCopied() {
        let discRemux = media(codec: "hevc", width: 3840, height: 2160, duration: 7000,
                              bitrate: 74_000_000)
        // Keeping the source's own picture is available, and is the only way a disc remux is copied.
        #expect(ConversionPlan.plan(source: discRemux, letterbox: .none,
                                    canRebuildDolbyVision: false,
                                    matchesApplesBitrate: false).route == .rewrap)

        let frugal = media(codec: "hevc", width: 3840, height: 2160, duration: 7000,
                           bitrate: 20_000_000)
        #expect(ConversionPlan.plan(source: frugal, letterbox: .none,
                                    canRebuildDolbyVision: false,
                                    matchesApplesBitrate: true).route == .rewrap)

        let plan = ConversionPlan.plan(source: discRemux, letterbox: .none,
                                       canRebuildDolbyVision: false, matchesApplesBitrate: true)
        #expect(plan.route.isReencode)
        // Never above what the source was spending, never above Apple's rung.
        #expect((plan.route.encode?.bitrate ?? 0) <= 74_000_000)
        #expect(plan.notes.contains { if case .matchedToApplesRate = $0 { true } else { false } })
    }

    /// A file that won't say what its picture costs is left alone rather than re-encoded on a guess.
    @Test func aFileWithNoStatedBitrateIsNeverReencodedForStorage() {
        let unknown = media(codec: "hevc", width: 3840, height: 2160, duration: 7000, bitrate: nil)
        #expect(ConversionPlan.plan(source: unknown, letterbox: .none,
                                    canRebuildDolbyVision: false,
                                    matchesApplesBitrate: true).route == .rewrap)
    }

    @Test func aCodecMP4CannotCarryIsAlwaysEncoded() {
        let source = media(codec: "vp9", width: 1920, height: 1080, duration: 600, bitrate: 2_000_000)
        #expect(ConversionPlan.plan(source: source, letterbox: .none).route.isReencode)
    }

    // MARK: - Losses worth warning about

    @Test func warnsThatBitmapSubtitlesAreDropped() {
        let source = media(codec: "hevc", width: 3840, height: 2160, duration: 7000, subtitles: [
            subtitleTrack(1, "hdmv_pgs_subtitle", language: "eng", title: "English"),
            subtitleTrack(2, "subrip", language: "dan", title: "Danish")
        ])
        let notes = ConversionPlan.plan(source: source, letterbox: .none).notes
        #expect(notes.contains(.bitmapSubtitlesDropped(languages: ["eng"])))
    }

    /// Atmos survives exactly one way — an E-AC-3 track that already carries it, copied. TrueHD
    /// Atmos can't be carried and can't be recreated, so the two cases must never read alike.
    @Test func tellsCopyableAtmosApartFromTrueHD() {
        let carried = media(codec: "hevc", width: 3840, height: 2160, duration: 6559, audio: [
            audioTrack(1, "eac3", channels: 6, language: "eng",
                       profile: "Dolby Digital Plus + Dolby Atmos")
        ])
        #expect(ConversionPlan.plan(source: carried, letterbox: .none).notes.contains(.atmosPreserved))

        let lost = media(codec: "hevc", width: 3840, height: 2160, duration: 6559, audio: [
            audioTrack(1, "truehd", channels: 8, language: "eng", profile: "Dolby TrueHD + Dolby Atmos"),
            audioTrack(2, "ac3", channels: 6, language: "eng")
        ])
        let notes = ConversionPlan.plan(source: lost, letterbox: .none).notes
        #expect(notes.contains(.atmosLost))
        #expect(!notes.contains(.atmosPreserved))
    }

    @Test func warnsWhenTheOnlyEnglishTrackCannotBePlayed() {
        let source = media(codec: "hevc", width: 3840, height: 2160, duration: 7135, audio: [
            audioTrack(1, "dts", channels: 8, language: "eng", profile: "DTS-HD MA")
        ])
        #expect(ConversionPlan.plan(source: source, letterbox: .none).notes
            .contains(.audioNeedsTranscode(codec: "dts", channels: 8, outputChannels: 6)))
    }

    /// The note has to name the channels coming *out*, not just the codec going in.
    ///
    /// Serenity shipped this way: a 7.1 DTS-HD MA track re-encoded to 5.1 E-AC-3, two channels
    /// quietly gone, and a warning that said only "has to be re-encoded to play". The channel count
    /// was in hand when the note was written and simply wasn't used — the information was present,
    /// the sentence was lazy. Nothing in the finished file says a channel is missing.
    @Test func aSevenPointOneSourceDeclaresTheChannelsItLoses() {
        let source = media(codec: "hevc", width: 3840, height: 2160, duration: 7135, audio: [
            audioTrack(1, "dts", channels: 8, language: "eng", profile: "DTS-HD MA + DTS:X")
        ])
        let note = ConversionPlan.plan(source: source, letterbox: .none).notes
            .first { if case .audioNeedsTranscode = $0 { true } else { false } }
        #expect(note == .audioNeedsTranscode(codec: "dts", channels: 8, outputChannels: 6))
    }

    /// A 5.1 source meets no ceiling, and must not be reported as though it lost something.
    @Test func aFivePointOneSourceKeepsEveryChannel() {
        let source = media(codec: "hevc", width: 3840, height: 2160, duration: 7135, audio: [
            audioTrack(1, "dts", channels: 6, language: "eng", profile: "DTS")
        ])
        #expect(ConversionPlan.plan(source: source, letterbox: .none).notes
            .contains(.audioNeedsTranscode(codec: "dts", channels: 6, outputChannels: 6)))
    }

    /// The downmix is asked for rather than inherited. ffmpeg would reach the same 5.1 on its own,
    /// which produces the right file for the wrong reason: a silent default can't be reported.
    @Test func theDownmixIsStatedInTheArguments() {
        let source = media(codec: "hevc", width: 3840, height: 2160, duration: 7135, audio: [
            audioTrack(1, "dts", channels: 8, language: "eng", profile: "DTS-HD MA + DTS:X")
        ])
        let arguments = TrackPlan.trackArguments(for: source).arguments
        #expect(arguments.contains("-ac:a:0"))
        #expect(arguments.contains("6"))
    }

    /// A track that is copied is never downmixed, so it must never carry a channel argument.
    @Test func aCopiedTrackIsNeverDownmixed() {
        let source = media(codec: "hevc", width: 3840, height: 2160, duration: 7135, audio: [
            audioTrack(1, "eac3", channels: 8, language: "eng")
        ])
        let arguments = TrackPlan.trackArguments(for: source).arguments
        #expect(!arguments.contains("-ac:a:0"))
    }

    /// A file that can be copied is one generation from the studio's master. Re-encoding it to
    /// remove black bars makes two, and turns fifteen minutes into most of a day — so it only
    /// happens when someone has asked for it.
    @Test func barsAreNotWorthAnEncodeUnlessAsked() {
        let copyable = media(codec: "hevc", width: 3840, height: 2160, duration: 6559,
                             named: "war.mkv", bitrate: 16_000_000)
        let bars = Letterbox.bars(height: 1604, top: 278)

        let kept = ConversionPlan.plan(source: copyable, letterbox: bars, cropsWhenItCosts: false,
                                       canRebuildDolbyVision: false)
        #expect(kept.route == .rewrap)
        #expect(kept.notes.contains { if case .barsKeptToAvoidAnEncode = $0 { true } else { false } })

        let cropped = ConversionPlan.plan(source: copyable, letterbox: bars, cropsWhenItCosts: true,
                                          canRebuildDolbyVision: false)
        #expect(cropped.route.encode?.height == 1604)
        #expect(cropped.notes.contains(.encodedOnlyToCrop))
        #expect(cropped.estimate.total > kept.estimate.total * 4)
    }

    /// When the file has to be encoded anyway, the crop is free and is always taken.
    @Test func aFilmBeingEncodedAnywayIsAlwaysCropped() {
        let mustEncode = media(codec: "hevc", width: 3840, height: 2160, duration: 6448,
                               bitrate: 69_000_000)
        let plan = ConversionPlan.plan(source: mustEncode,
                                       letterbox: .bars(height: 1608, top: 276),
                                       cropsWhenItCosts: false, canRebuildDolbyVision: false,
                                       matchesApplesBitrate: true)
        #expect(plan.route.encode?.height == 1608)
        #expect(plan.route.encode?.cropTop == 276)
    }

    /// With Apple-matching switched off, only the format itself can force a rebuild.
    @Test func keepingSourceQualityStillYieldsToWhatTheFormatDemands() {
        let hugeButCarriable = media(codec: "hevc", width: 3840, height: 2160, duration: 7000,
                                     bitrate: 90_000_000)
        #expect(ConversionPlan.plan(source: hugeButCarriable, letterbox: .bars(height: 1608, top: 276),
                                    cropsWhenItCosts: false, canRebuildDolbyVision: false,
                                    matchesApplesBitrate: false).route == .rewrap)

        // A codec MP4 can't carry leaves no choice, whatever anyone prefers.
        let unwrappable = media(codec: "vp9", width: 1920, height: 1080, duration: 600, bitrate: 2_000_000)
        #expect(ConversionPlan.plan(source: unwrappable, letterbox: .none,
                                    canRebuildDolbyVision: false,
                                    matchesApplesBitrate: false).route.isReencode)
    }

    // MARK: - Estimates and order

    /// Cropping is most of why one 4K film costs hours less than another of the same length.
    @Test func croppingCostsLessThanTheFullFrame() {
        let source = media(codec: "hevc", width: 3840, height: 2160, duration: 8255)
        let full = ConversionEstimate(source: source, route: .reencode(
            .init(width: 3840, height: 2160, bitrate: 24_000_000, cropTop: nil)))
        let cropped = ConversionEstimate(source: source, route: .reencode(
            .init(width: 3840, height: 1392, bitrate: 24_000_000, cropTop: 384)))
        #expect(cropped.encode < full.encode)
        // 1392 rows against 2160 is 64% of the pixels, and the encode should track that closely.
        #expect(abs(cropped.encode / full.encode - 1392.0 / 2160.0) < 0.01)
    }

    @Test func rewrappingIsFarCheaperThanEncodingTheSameFile() {
        // A real 1080p episode: rewrapping is bound by writing 14 GB, encoding by the pixels.
        let source = media(codec: "h264", width: 1920, height: 1080, duration: 4875,
                           fileSize: 14_000_000_000)
        let rewrap = ConversionEstimate(source: source, route: .rewrap)
        let encode = ConversionEstimate(source: source, route: .reencode(
            .init(width: 1920, height: 1080, bitrate: 7_000_000, cropTop: nil)))
        #expect(rewrap.encode == 0)
        #expect(rewrap.total < encode.total / 4)
    }

    @Test @MainActor func theQueueRunsShortestFirst() async {
        let queue = ConversionQueue()
        let short = plan(named: "short", duration: 1200, height: 1080, codec: "h264")
        let long = plan(named: "long", duration: 8000, height: 2160, codec: "hevc")
        let middle = plan(named: "middle", duration: 4000, height: 2160, codec: "hevc")
        queue.adopt([long, short, middle])
        #expect(queue.plans.map { $0.source.url.lastPathComponent } == ["short", "middle", "long"])
    }

    /// A source that already has an MP4 beside it has been converted. Offering to do it again is
    /// offering to spend hours reproducing a file that's already there.
    @Test func alreadyConvertedSourcesAreSkipped() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["Done.mkv", "Done.mp4", "Waiting.mkv", "Ignored.txt", "Already.mp4"] {
            try Data().write(to: folder.appending(path: name))
        }
        let found = ConversionQueue.convertibleFiles(in: folder).map(\.lastPathComponent)
        #expect(found == ["Waiting.mkv"])
    }

    // MARK: - What a subtitle track is

    /// The flag is absent far more often than it's wrong. *Predator: Badlands* declares its
    /// forced track only as `title=BTM FORCED`, with `forced=0`, and reading the flag alone
    /// leaves the film's Yautja dialogue with no track any player would auto-enable.
    @Test func aForcedTrackIsFoundWhenOnlyItsTitleSaysSo() {
        let track = subtitleTrack(9, "subrip", language: "eng", title: "BTM FORCED")
        #expect(TrackPlan.isForced(track))
    }

    /// A keyword list in one language encodes an assumption about who pressed the disc.
    /// *Supergirl* is an Italian rip whose **English** SDH track is titled `NON UDENTI`.
    @Test func anSDHTrackIsFoundWhenItsTitleIsInAnotherLanguage() {
        let track = subtitleTrack(8, "subrip", language: "eng", title: "NON UDENTI")
        #expect(TrackPlan.isHearingImpaired(track))
    }

    /// The signal that survives a language nobody anticipated: a full track carries **zero**
    /// cues opening with a bracket, an SDH track is full of them.
    @Test func theCuesIdentifySDHWithoutReadingTheTitle() {
        let full = SubtitleScan.measure("""
            1
            00:00:01,000 --> 00:00:03,000
            Are you all right?

            2
            00:00:04,000 --> 00:00:06,000
            ♪ And I'm still standing ♪

            """, duration: 600)
        let sdh = SubtitleScan.measure("""
            1
            00:00:01,000 --> 00:00:03,000
            [door creaks]

            2
            00:00:04,000 --> 00:00:06,000
            Are you all right?

            """, duration: 600)
        #expect(full.bracketed == 0)
        #expect(!full.readsAsSDH)
        #expect(sdh.bracketed == 1)
        #expect(sdh.readsAsSDH)

        // Decided by the cues even when nothing else says so — an untitled, unflagged track.
        let anonymous = subtitleTrack(3, "subrip", language: "kor")
        #expect(TrackPlan.isHearingImpaired(anonymous, content: sdh))
        #expect(!TrackPlan.isHearingImpaired(anonymous, content: full))
    }

    /// Song lyrics are dialogue and belong in a full track. *Across the Spider-Verse*'s American
    /// track carries 346 music-note cues; a rule counting any bracketing symbol reads that full
    /// track as 13% marked and misclassifies it.
    @Test func musicNotesAreNotSoundDescriptions() {
        let lyrics = SubtitleScan.measure("""
            1
            00:00:01,000 --> 00:00:03,000
            ♪ Ooh, ooh, ooh ♪

            """, duration: 600)
        #expect(lyrics.bracketed == 0)
        #expect(!lyrics.readsAsSDH)
    }

    /// Counted anywhere in the cue, the same film's "English full" track scores 1 —
    /// `It is I, the Armadillo-- [grunts] Oh!` — and the rule stops being absolute. Anchored to
    /// the line start it is zero, which is the difference between a rule that is true and one
    /// that merely has a comfortable margin.
    @Test func anInlineSoundDescriptionDoesNotMakeATrackSDH() {
        let full = SubtitleScan.measure("""
            1
            00:00:01,000 --> 00:00:03,000
            It is I, the Armadillo-- [grunts] Oh!

            """, duration: 600)
        #expect(full.cues == 1)
        #expect(full.bracketed == 0)
        #expect(!full.readsAsSDH)
    }

    /// A bare `hasPrefix("[")` misses the conventions a real SDH track actually uses: a dialogue
    /// dash before a speaker label, or an ASS position override before a sound description. 108 of
    /// *Across the Spider-Verse*'s British SDH cues open that way, and a track using only that
    /// convention would read as an ordinary subtitle.
    @Test func aDescriptionIsFoundBehindADashOrAPositionOverride() {
        let sdh = SubtitleScan.measure("""
            1
            00:00:01,000 --> 00:00:03,000
            - [woman] Hey, Gwen.

            2
            00:00:04,000 --> 00:00:06,000
            {\\an8}[music turns dramatic]

            3
            00:00:07,000 --> 00:00:09,000
            <i>[footsteps receding]</i>

            """, duration: 600)
        #expect(sdh.bracketed == 3)
        #expect(sdh.readsAsSDH)
    }

    /// And the check that stripping those prefixes risks: a full track writing a dialogue dash
    /// before ordinary speech must still score zero, or the separation the rule rests on is gone.
    @Test func aDialogueDashAloneIsNotADescription() {
        let full = SubtitleScan.measure("""
            1
            00:00:01,000 --> 00:00:03,000
            - Are you all right?

            2
            00:00:04,000 --> 00:00:06,000
            {\\an8}Meanwhile, in Brooklyn

            """, duration: 600)
        #expect(full.bracketed == 0)
        #expect(!full.readsAsSDH)
    }

    /// A release picks one bracket style and uses it throughout. *Predator: Badlands* writes its
    /// entire SDH track in parentheses — 707 cues, not one square bracket — so a `[`-only rule
    /// reads it as ordinary subtitles. Found by running the rule over real files; no amount of
    /// re-reading it would have produced `(WIND WHOOSHING)`.
    @Test func parenthesesAreSoundDescriptionsToo() {
        let sdh = SubtitleScan.measure("""
            1
            00:00:01,000 --> 00:00:03,000
            (WIND WHOOSHING)

            2
            00:00:04,000 --> 00:00:06,000
            (CHANTING IN YAUTJA)

            """, duration: 600)
        #expect(sdh.bracketed == 2)
        #expect(sdh.readsAsSDH)
    }

    /// A forced track says very little: 1–2 cues a minute against 12–22 for a full one. This is
    /// the last resort, for a source offering neither a flag nor a title in a language we know.
    @Test func cueRateIdentifiesAForcedTrack() {
        let sparse = SubtitleContent(cues: 103, bracketed: 0, duration: 5940)
        let full = SubtitleContent(cues: 1491, bracketed: 0, duration: 5940)
        #expect(sparse.readsAsForced)
        #expect(!full.readsAsForced)
        #expect(TrackPlan.isForced(subtitleTrack(5, "subrip", language: "eng"), content: sparse))
    }

    /// Density cannot answer the SDH question, which is why the cue *text* does. *Supergirl* has
    /// no full English track to compare against — only a forced one and an SDH one — so the file
    /// that motivated the rule is the file that defeats a rate-based version of it.
    @Test func cueRateCannotIdentifySDH() {
        let sdh = SubtitleContent(cues: 1491, bracketed: 610, duration: 5940)
        #expect(!sdh.readsAsForced)
        #expect(sdh.readsAsSDH)
    }

    /// A title-only forced track has to reach the finished file as `forced`, or none of this
    /// mattered: that flag is what a player reads to auto-enable it.
    @Test func aTitleOnlyForcedTrackIsWrittenForcedAndSwitchedOn() {
        let source = media(codec: "hevc", width: 3840, height: 2160, duration: 6448,
                           audio: [audioTrack(1, "eac3", channels: 6, language: "eng")],
                           subtitles: [subtitleTrack(9, "subrip", language: "eng", title: "BTM FORCED"),
                                       subtitleTrack(10, "subrip", language: "eng", title: "BTM")])
        let arguments = TrackPlan.trackArguments(for: source).arguments
        #expect(arguments.contains("default+forced"))
    }

    // MARK: - Calibration

    /// One job on battery, or against a busy disk, is a real measurement of an unusual day. It
    /// should move the estimates, not replace them.
    @Test func calibrationMovesTowardsAMeasurementWithoutJumpingToIt() {
        let measured = ConversionCalibration.measured.blending(pixelsPerSecond: 80_000_000)
        let blended = measured.blending(pixelsPerSecond: measured.pixelsPerSecond / 2)
        #expect(blended.pixelsPerSecond < measured.pixelsPerSecond)
        #expect(blended.pixelsPerSecond > measured.pixelsPerSecond / 2)
        #expect(blended.encodeSamples == measured.encodeSamples + 1)

        // A rewrap measures nothing about encoding speed, and must not be allowed to claim it does.
        let afterRewrap = measured.blending(rewrapSecondsPerGigabyte: 30)
        #expect(afterRewrap.pixelsPerSecond == measured.pixelsPerSecond)
        #expect(afterRewrap.encodeSamples == measured.encodeSamples)
    }

    /// The shipped rates are a guess, and a guess that survives contact with measurement isn't
    /// calibration. Seeded as a sample it kept half the weight of the first real job — which is how
    /// four films came in at 12h57m against a prediction of 22h10m, every one wrong the same way.
    @Test func theFirstRealMeasurementReplacesTheSeedRatherThanAveragingWithIt() {
        let seed = ConversionCalibration.measured
        let real = seed.blending(pixelsPerSecond: 120_000_000)
        #expect(real.pixelsPerSecond == 120_000_000)
        #expect(real.encodeSamples == 1)
    }

    /// Each rate keeps its own count, so a rewrap can't age the encode rate out of its replacement.
    /// One shared counter meant a single rewrap left every later encode averaging against a guess.
    @Test func aRewrapDoesNotSpendTheEncodeRatesFirstMeasurement() {
        let afterRewrap = ConversionCalibration.measured.blending(rewrapSecondsPerGigabyte: 30)
        #expect(afterRewrap.rewrapSecondsPerGigabyte == 30)
        let thenAnEncode = afterRewrap.blending(pixelsPerSecond: 120_000_000)
        #expect(thenAnEncode.pixelsPerSecond == 120_000_000)
    }

    // MARK: - Helpers

    private func requireFFmpeg() throws {
        try #require(ConverterTools.ffmpeg != nil, "ffmpeg isn't installed on this machine")
    }

    /// Builds a real clip with real black bars, since the thing under test is a measurement of
    /// pixels and a fabricated struct would prove nothing about it.
    private func makeClip(width: Int, height: Int, barHeight: Int, tenBit: Bool) async throws -> URL {
        let ffmpeg = try #require(ConverterTools.ffmpeg)
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "clip.mkv")

        let picture = height - barHeight * 2
        // A bright, moving source so nothing is mistaken for a bar, padded back to full height.
        let filter = barHeight == 0
            ? "scale=\(width):\(height)"
            : "scale=\(width):\(picture),pad=\(width):\(height):0:\(barHeight):black"

        try await Process.run(ffmpeg, arguments: [
            "-y", "-v", "error",
            "-f", "lavfi", "-i", "testsrc2=size=\(width)x\(height):rate=24:duration=4",
            "-vf", filter,
            "-pix_fmt", tenBit ? "yuv420p10le" : "yuv420p",
            "-c:v", tenBit ? "libx265" : "libx264",
            url.path(percentEncoded: false)
        ], duration: 4, holding: { _ in }, onProgress: { _ in })
        return url
    }

    private func media(codec: String, width: Int, height: Int, duration: Double,
                       named name: String = "film.mkv",
                       fileSize: Int64 = 50_000_000_000,
                       bitrate: Int? = 80_000_000,
                       dolbyVision: SourceMedia.DolbyVision? = nil,
                       audio: [SourceMedia.AudioTrack] = [],
                       subtitles: [SourceMedia.SubtitleTrack] = []) -> SourceMedia {
        SourceMedia(url: URL(filePath: "/tmp/\(name)"), fileSize: fileSize,
                    duration: duration, frameRate: 24000.0 / 1001, width: width, height: height,
                    videoCodec: codec, bitDepth: 10, isHDR: true, colorTransfer: "smpte2084",
                    dolbyVision: dolbyVision, audio: audio, subtitles: subtitles,
                    videoBitrate: bitrate, originalLanguage: "eng", videoStreamIndex: 0)
    }

    private func audioTrack(_ index: Int, _ codec: String, channels: Int, language: String?,
                            profile: String? = nil, disposition: [String: Int] = [:]) -> SourceMedia.AudioTrack {
        .init(index: index, codec: codec, profile: profile, channels: channels,
              language: language, title: nil, disposition: disposition)
    }

    private func subtitleTrack(_ index: Int, _ codec: String, language: String?,
                               title: String? = nil) -> SourceMedia.SubtitleTrack {
        .init(index: index, codec: codec, language: language, title: title, disposition: [:])
    }

    private func plan(named name: String, duration: Double, height: Int, codec: String) -> ConversionPlan {
        // Size tracks runtime, because a copy's cost is bytes rather than minutes — a longer film
        // is a bigger file, and that is what the queue is really ordering by.
        let source = media(codec: codec, width: 3840, height: height, duration: duration,
                           named: name, fileSize: Int64(duration * 8_000_000),
                           bitrate: codec == "h264" ? 4_000_000 : 74_000_000)
        return ConversionPlan.plan(source: source, letterbox: .none, canRebuildDolbyVision: false)
    }
}
#endif

#if os(macOS)
/// A 4:2:0 picture can't have an odd dimension, and the studio's declared bars sometimes imply one.
@Suite("Crop geometry")
struct CropGeometryTests {
    private func source(width: Int = 3840, height: Int = 2160) -> SourceMedia {
        SourceMedia(url: URL(filePath: "/tmp/f.mkv"), fileSize: 80_000_000_000, duration: 8418,
                    frameRate: 24000.0 / 1001, width: width, height: height, videoCodec: "hevc",
                    bitDepth: 10, isHDR: true, colorTransfer: "smpte2084",
                    dolbyVision: .init(profile: 7, compatibilityID: 6), audio: [], subtitles: [],
                    videoBitrate: 75_000_000, originalLanguage: "eng", videoStreamIndex: 0)
    }

    /// Spider-Verse's real numbers: 276 above, 277 below — 1607 rows, which no encoder can produce.
    @Test func anOddLetterboxKeepsBlackRatherThanCuttingPicture() {
        let geometry = ConversionPlan.encodeGeometry(
            source: source(), letterbox: .bars(height: 1607, top: 276))
        #expect(geometry.height == 1608)
        #expect(geometry.top == 276)
        #expect(geometry.height % 2 == 0)
        // A row of black survives; no row of film is lost.
        #expect(geometry.height > 1607)
    }

    @Test func anOddTopOffsetIsRoundedDownToo() {
        let geometry = ConversionPlan.encodeGeometry(
            source: source(), letterbox: .bars(height: 1608, top: 277))
        #expect(geometry.top == 276)
        #expect(geometry.height % 2 == 0)
        #expect(geometry.top! % 2 == 0)
    }

    @Test func anEvenLetterboxIsLeftExactlyAsDeclared() {
        let geometry = ConversionPlan.encodeGeometry(
            source: source(), letterbox: .bars(height: 1608, top: 276))
        #expect(geometry.height == 1608)
        #expect(geometry.top == 276)
    }

    @Test func aFullFrameIsNotCropped() {
        let geometry = ConversionPlan.encodeGeometry(source: source(), letterbox: .varies)
        #expect(geometry.top == nil)
        #expect(geometry.height == 2160)
    }
}
#endif

#if os(macOS)
/// Two different reasons to rebuild a picture, and only one of them is about rate.
@Suite("Rebuild rate")
struct RebuildRateTests {
    private func source(bitrate: Int) -> SourceMedia {
        SourceMedia(url: URL(filePath: "/tmp/f.mkv"), fileSize: 13_000_000_000, duration: 6559,
                    frameRate: 24, width: 3840, height: 2160, videoCodec: "hevc", bitDepth: 10,
                    isHDR: true, colorTransfer: "smpte2084",
                    dolbyVision: .init(profile: 8, compatibilityID: 1), audio: [], subtitles: [],
                    videoBitrate: bitrate, originalLanguage: "eng", videoStreamIndex: 0)
    }

    /// A film rebuilt because a copy of it wouldn't play never triggered the rate rule, so it
    /// keeps its own rate: the rebuild costs a generation, and nothing about playability asks for
    /// the picture to get smaller as well.
    @Test func aRebuildForcedByPlayabilityKeepsTheSourcesRate() {
        let film = source(bitrate: 15_900_000)          // well under Apple's 24 Mbps rung
        let forced = ConversionPlan.plan(source: film, letterbox: .none, forcingEncode: true)
        #expect(forced.route.encode?.bitrate == 15_900_000)

        // And is still capped at the rung when the source sits above it.
        let extravagant = source(bitrate: 70_000_000)
        let capped = ConversionPlan.plan(source: extravagant, letterbox: .none, forcingEncode: true)
        #expect((capped.route.encode?.bitrate ?? 0) <= 24_000_000)
    }

    /// A film rebuilt *for* parity is a different case, and does take the codec adjustment.
    @Test func aParityRebuildTakesApplesRate() {
        let discRemux = source(bitrate: 70_000_000)
        let plan = ConversionPlan.plan(source: discRemux, letterbox: .none,
                                       canRebuildDolbyVision: false, matchesApplesBitrate: true)
        #expect(plan.route.isReencode)
        #expect((plan.route.encode?.bitrate ?? 0) <= 24_000_000)
    }
}
#endif

#if os(macOS)
/// Which track a film opens in — the question a regional rip gets wrong in both directions.
@Suite("Default audio")
struct DefaultAudioTests {
    private func media(picture language: String?, audio: [SourceMedia.AudioTrack]) -> SourceMedia {
        SourceMedia(url: URL(filePath: "/tmp/f.mkv"), fileSize: 13_000_000_000, duration: 6559,
                    frameRate: 24, width: 3840, height: 2160, videoCodec: "hevc", bitDepth: 10,
                    isHDR: true, colorTransfer: "smpte2084", dolbyVision: nil,
                    audio: audio, subtitles: [], videoBitrate: 13_000_000,
                    originalLanguage: language, videoStreamIndex: 0)
    }

    private func track(_ index: Int, _ language: String, channels: Int = 6,
                       isDefault: Bool = false, isOriginal: Bool = false) -> SourceMedia.AudioTrack {
        var disposition: [String: Int] = [:]
        if isDefault { disposition["default"] = 1 }
        if isOriginal { disposition["original"] = 1 }
        return .init(index: index, codec: "eac3", profile: nil, channels: channels,
                     language: language, title: nil, disposition: disposition)
    }

    /// War Machine's real shape: three French tracks, one English, the picture carrying no language
    /// tag, and the rip flagging French as default. The English track is marked `original`, and that
    /// is the only thing in the file that knows what the film actually is.
    @Test func theTrackMarkedOriginalWinsOverTheRipsDefaultFlag() {
        let film = media(picture: nil, audio: [
            track(1, "fre", isDefault: true), track(2, "fre"), track(3, "fre"),
            track(4, "eng", isOriginal: true)
        ])
        // The winner is the same either way — this is about which track the film opens in, not
        // about how many survive.
        #expect(TrackPlan.selectAudio(from: film, keepingOnlyOneLanguage: true)
            .audio.first(where: \.isDefault)?.track.language == "eng")

        let everyLanguage = TrackPlan.selectAudio(from: film, keepingOnlyOneLanguage: false)
        #expect(everyLanguage.audio.first(where: \.isDefault)?.track.language == "eng")
        // Keeping every language, the three French tracks collapse to one and survive alongside.
        #expect(everyLanguage.audio.filter { $0.track.language == "fre" }.count == 1)
    }

    /// The picture's own tag still outranks everything, since it describes the film rather than a
    /// track's paperwork.
    @Test func thePicturesOwnLanguageTagStillWins() {
        let film = media(picture: "eng", audio: [
            track(1, "rus", isDefault: true), track(2, "eng")
        ])
        #expect(TrackPlan.selectAudio(from: film).audio.first(where: \.isDefault)?.track.language == "eng")
    }
}
#endif

#if os(macOS)
/// Labelling the subtitle tracks of a finished file — the pass that decides which languages the
/// output claims and which track starts switched on.
@Suite("Subtitle labelling")
struct SubtitleLabellingTests {
    private func subtitle(_ language: String?, _ title: String?) -> LanguageTags.Subtitle {
        LanguageTags.Subtitle(SourceMedia.SubtitleTrack(
            index: 0, codec: "subrip", language: language, title: title, disposition: [:]))
    }

    /// A sidecar becomes a track like any other, so it has to be counted like one. Counting only
    /// the source's own tracks made the whole pass skip itself the moment a sidecar existed.
    @Test func aSidecarIsOneOfTheTracksToLabel() {
        let sidecar = LanguageTags.Subtitle(SidecarSubtitle(
            url: URL(filePath: "/tmp/Film.eng.forced.srt"), language: "eng",
            isForced: true, isHearingImpaired: false))
        #expect(sidecar.language == "eng")
        #expect(sidecar.isForced)
        // Nothing in a file name describes a script variant, so there's nothing to match on.
        #expect(sidecar.title == nil)
    }

    /// Whole group or none: a partly tagged group displays no distinction at all, so a group with
    /// one unreadable title is left entirely alone.
    @Test func aGroupIsTaggedOnlyWhenEveryMemberCanBeRead() {
        let readable = [subtitle("chi", "Simplified"), subtitle("chi", "Traditional")]
        #expect(LanguageTags.arguments(forSubtitles: readable, trackIDs: [3, 4]).count == 4)

        let partly = [subtitle("chi", "Simplified"), subtitle("chi", "Chinese")]
        #expect(LanguageTags.arguments(forSubtitles: partly, trackIDs: [3, 4]).isEmpty)
    }

    /// A language appearing once needs no variant tag — there is nothing for it to be confused with.
    @Test func aLanguageAppearingOnceIsLeftAlone() {
        let single = [subtitle("dan", "Danish"), subtitle("chi", "Simplified")]
        #expect(LanguageTags.arguments(forSubtitles: single, trackIDs: [3, 4]).isEmpty)
    }

    /// Cantonese is a spoken variety, not a script: `zh-Hant` would assert a script fact from a
    /// language one, and would collide with a genuine Traditional track.
    @Test func cantoneseIsTaggedAsItsOwnLanguage() {
        let group = [subtitle("chi", "Cantonese (Traditional)"), subtitle("chi", "Simplified")]
        let arguments = LanguageTags.arguments(forSubtitles: group, trackIDs: [3, 4])
        #expect(arguments.contains("3=yue"))
        #expect(arguments.contains("4=zh-Hans"))
    }
}
#endif

#if os(macOS)
/// Keeping one language — a personal-library optimisation that departs from Apple's shape, so it
/// has to be exact about what it drops and what it keeps.
@Suite("Single language")
struct SingleLanguageTests {
    private func film(audio: [SourceMedia.AudioTrack],
                      subtitles: [SourceMedia.SubtitleTrack]) -> SourceMedia {
        SourceMedia(url: URL(filePath: "/tmp/f.mkv"), fileSize: 80_000_000_000, duration: 8418,
                    frameRate: 24000.0 / 1001, width: 3840, height: 2160, videoCodec: "hevc",
                    bitDepth: 10, isHDR: true, colorTransfer: "smpte2084", dolbyVision: nil,
                    audio: audio, subtitles: subtitles, videoBitrate: 75_000_000,
                    originalLanguage: "eng", videoStreamIndex: 0)
    }

    private func audio(_ index: Int, _ language: String, channels: Int = 6,
                       comment: Bool = false) -> SourceMedia.AudioTrack {
        .init(index: index, codec: "ac3", profile: nil, channels: channels, language: language,
              title: nil, disposition: comment ? ["comment": 1] : [:])
    }

    private func subtitle(_ index: Int, _ language: String) -> SourceMedia.SubtitleTrack {
        .init(index: index, codec: "subrip", language: language, title: nil, disposition: [:])
    }

    /// Spider-Verse's shape: the film, its commentary, and two dubs. One language keeps the film.
    @Test func keepsTheFilmsOwnLanguageAndNothingElse() {
        let source = film(audio: [audio(1, "eng"), audio(2, "eng", channels: 2, comment: true),
                                  audio(3, "rus"), audio(4, "ukr")], subtitles: [])
        let selection = TrackPlan.selectAudio(from: source, keepingOnlyOneLanguage: true)
        #expect(selection.audio.count == 1)
        #expect(selection.audio.first?.track.language == "eng")
        #expect(selection.audio.first?.isDefault == true)
        // What it dropped is said out loud, because nothing in the finished file would reveal it.
        #expect(selection.notes.contains { $0.contains("dropped") })
    }

    /// Switched off, the film keeps Apple's shape: one per language, commentary alongside.
    @Test func leavingItOffKeepsApplesShape() {
        let source = film(audio: [audio(1, "eng"), audio(2, "eng", channels: 2, comment: true),
                                  audio(3, "rus"), audio(4, "ukr")], subtitles: [])
        let selection = TrackPlan.selectAudio(from: source, keepingOnlyOneLanguage: false)
        #expect(selection.audio.count == 4)
        #expect(selection.audio.contains { $0.track.isSecondaryProgramme })
    }

    /// A film with only one language loses nothing and says nothing.
    @Test func aSingleLanguageFilmIsUnaffected() {
        let source = film(audio: [audio(1, "eng")], subtitles: [])
        let selection = TrackPlan.selectAudio(from: source, keepingOnlyOneLanguage: true)
        #expect(selection.audio.count == 1)
        #expect(!selection.notes.contains { $0.contains("dropped") })
    }
}
#endif

#if os(macOS)
/// The mux and the pass that labels the finished file must agree on which subtitles survive.
/// They didn't, and the disagreement only surfaced after two and a half hours of encoding.
@Suite("Kept subtitles")
struct KeptSubtitleTests {
    private func film() -> SourceMedia {
        SourceMedia(url: URL(filePath: "/tmp/f.mkv"), fileSize: 13_000_000_000, duration: 6559,
                    frameRate: 24, width: 3840, height: 2160, videoCodec: "hevc", bitDepth: 10,
                    isHDR: true, colorTransfer: "smpte2084", dolbyVision: nil,
                    audio: [.init(index: 1, codec: "eac3", profile: nil, channels: 6,
                                  language: "eng", title: nil, disposition: ["default": 1])],
                    subtitles: [
                        .init(index: 2, codec: "subrip", language: "eng", title: nil, disposition: [:]),
                        .init(index: 3, codec: "subrip", language: "fre", title: nil, disposition: [:]),
                        .init(index: 4, codec: "subrip", language: "fre", title: nil, disposition: [:]),
                        .init(index: 5, codec: "hdmv_pgs_subtitle", language: "eng", title: nil, disposition: [:])
                    ],
                    videoBitrate: 13_000_000, originalLanguage: "eng", videoStreamIndex: 0)
    }

    /// War Machine's real shape: six subtitle tracks in the source, one English text track kept.
    /// The labelling pass must expect exactly what the mux wrote — no more, no fewer.
    @Test func theKeptListMatchesWhatTheMuxWrites() {
        let kept = TrackPlan.keptSubtitles(for: film(), spokenLanguage: "eng")
        #expect(kept.count == 1)
        #expect(kept.first?.language == "eng")
        // The bitmap track was never a candidate: MP4 can't carry it.
        #expect(!kept.contains { $0.codec == "hdmv_pgs_subtitle" })
    }

    /// With no language to keep, every text track survives — and the count still has to match.
    @Test func withoutASpokenLanguageEveryTextTrackIsKept() {
        #expect(TrackPlan.keptSubtitles(for: film(), spokenLanguage: nil).count == 3)
    }

    /// The language the film opens in is the one the rule keeps.
    @Test func theSpokenLanguageIsTheOneTheFilmOpensIn() {
        #expect(TrackPlan.spokenLanguage(of: film()) == "eng")
    }
}
#endif
