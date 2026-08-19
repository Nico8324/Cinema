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

    /// The copy-versus-re-encode line: a storage decision, never a quality one. Below the
    /// threshold the storage saved doesn't pay for the generation of picture it costs.
    @Test func onlyAFileSpendingFarOverApplesRateIsReencoded() {
        let frugal = media(codec: "hevc", width: 3840, height: 2160, duration: 7000,
                           bitrate: 20_000_000)
        #expect(ConversionPlan.plan(source: frugal, letterbox: .none,
                                    canRebuildDolbyVision: false).route == .rewrap)

        let discRemux = media(codec: "hevc", width: 3840, height: 2160, duration: 7000,
                              bitrate: 74_000_000)
        let plan = ConversionPlan.plan(source: discRemux, letterbox: .none, canRebuildDolbyVision: false)
        #expect(plan.route.isReencode)
        // Never above what the source was spending, never above Apple's rung.
        #expect((plan.route.encode?.bitrate ?? 0) <= 74_000_000)
        #expect(plan.notes.contains { if case .reencodedForStorage = $0 { true } else { false } })
    }

    /// A file that won't say what its picture costs is left alone rather than re-encoded on a guess.
    @Test func aFileWithNoStatedBitrateIsNeverReencodedForStorage() {
        let unknown = media(codec: "hevc", width: 3840, height: 2160, duration: 7000, bitrate: nil)
        #expect(ConversionPlan.plan(source: unknown, letterbox: .none,
                                    canRebuildDolbyVision: false).route == .rewrap)
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
            .contains(.audioNeedsTranscode(codec: "dts", channels: 8)))
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
                                       cropsWhenItCosts: false, canRebuildDolbyVision: false)
        #expect(plan.route.encode?.height == 1608)
        #expect(plan.route.encode?.cropTop == 276)
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

    // MARK: - Calibration

    /// One job on battery, or against a busy disk, is a real measurement of an unusual day. It
    /// should move the estimates, not replace them.
    @Test func calibrationMovesTowardsAMeasurementWithoutJumpingToIt() {
        let start = ConversionCalibration.measured
        let blended = start.blending(pixelsPerSecond: start.pixelsPerSecond / 2)
        #expect(blended.pixelsPerSecond < start.pixelsPerSecond)
        #expect(blended.pixelsPerSecond > start.pixelsPerSecond / 2)
        #expect(blended.samples == start.samples + 1)

        // A rewrap measures nothing about encoding speed, and must not be allowed to claim it does.
        let afterRewrap = start.blending(rewrapSecondsPerGigabyte: 30)
        #expect(afterRewrap.pixelsPerSecond == start.pixelsPerSecond)
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
        let source = media(codec: codec, width: 3840, height: height, duration: duration,
                           named: name, bitrate: codec == "h264" ? 4_000_000 : 74_000_000)
        return ConversionPlan.plan(source: source, letterbox: .none)
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
