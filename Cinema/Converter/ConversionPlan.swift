/*
See the LICENSE.txt file for licensing information.

Abstract:
What converting one file would involve, what it would cost, and what it would lose.
*/

#if os(macOS)
import Foundation

/// What converting one source file would involve — decided before any work starts, so the queue can
/// be ordered and so a person can see what they're about to lose before they lose it.
///
/// The decisions here are `Docs/output-spec.md` points 1–5 in code. Read it before changing them.
struct ConversionPlan: Sendable, Identifiable, Equatable {
    var id: URL { source.url }

    let source: SourceMedia
    let letterbox: Letterbox
    let route: Route
    let estimate: ConversionEstimate
    let notes: [Note]

    /// A plan with one more thing said about it — for facts that cost a separate read of the file.
    func adding(_ note: Note) -> ConversionPlan {
        ConversionPlan(source: source, letterbox: letterbox, route: route,
                       estimate: estimate, notes: notes + [note])
    }

    /// A picture being re-encoded: the frame it comes out as, and what it's given to do it.
    struct Encode: Sendable, Equatable {
        let width: Int
        let height: Int
        let bitrate: Int
        /// Rows cut from the top, when letterbox bars are being removed. `nil` when the frame is
        /// being kept whole.
        let cropTop: Int?

        var isCropping: Bool { cropTop != nil }
    }

    /// How the file gets to MP4.
    enum Route: Sendable, Equatable {
        /// Streams copied into a new container. Minutes rather than hours, and not one pixel
        /// changes — the best outcome, not a compromise.
        case rewrap
        /// The Dolby Vision route: the RPU comes out, is rewritten to 8.1, and goes back in. The
        /// picture is copied when `encode` is `nil`, and re-encoded when it isn't.
        case rebuildDolbyVision(encode: Encode?)
        /// A plain re-encode, for a picture with no Dolby Vision to carry.
        case reencode(Encode)

        /// Whether any pixels are re-encoded — the difference between minutes and most of a day.
        var encode: Encode? {
            switch self {
            case .rewrap: nil
            case .rebuildDolbyVision(let encode): encode
            case .reencode(let encode): encode
            }
        }

        var isReencode: Bool { encode != nil }
        var isDolbyVision: Bool { if case .rebuildDolbyVision = self { true } else { false } }
    }

    /// Something worth knowing before starting, good or bad.
    ///
    /// These are the point of planning ahead. Every one describes something invisible in the
    /// finished file: subtitles that aren't there, an audio track that quietly became a different
    /// one, a crop that wasn't applied.
    enum Note: Sendable, Equatable, Identifiable {
        case bitmapSubtitlesDropped(languages: [String])
        case aspectRatioVaries
        case asymmetricLetterbox(top: Int, bottom: Int)
        /// The film's own soundtrack has to be rebuilt to play at all — and, when `outputChannels`
        /// is lower than `channels`, comes out with fewer channels than it went in with.
        case audioNeedsTranscode(codec: String, channels: Int, outputChannels: Int)
        case atmosPreserved
        case atmosLost
        case dolbyVisionWouldFlatten
        /// Copying this film's picture would produce Dolby Vision no Apple device renders, so it is
        /// re-encoded instead — hours rather than minutes, and a generation of picture.
        case copyWouldNotRender
        /// The source's Dolby Vision enhancement layer carries picture detail that single-layer
        /// 8.1 has nowhere to hold.
        case enhancementLayerLost
        case barsKeptToAvoidAnEncode(extraSeconds: Double)
        case encodedOnlyToCrop
        /// The file costs far more than Apple would spend on this picture, so it is rebuilt to
        /// Apple's own rung — which is what cloning Apple means for a disc remux.
        case matchedToApplesRate(sourceMbps: Double, targetMbps: Double)

        var id: String { String(describing: self) }

        /// Whether this is a loss rather than a remark. Losses are what a person needs to see.
        var isLoss: Bool {
            switch self {
            case .atmosPreserved, .asymmetricLetterbox, .barsKeptToAvoidAnEncode,
                 .encodedOnlyToCrop, .matchedToApplesRate: false
            default: true
            }
        }
    }

    /// Whether to re-encode a film that could otherwise be copied, purely to remove its black bars.
    ///
    /// Off by default. A file that can be copied is one generation from the studio's master — the
    /// same parity Apple ships. Re-encoding it makes two, and the only thing it buys is a frame
    /// without bars: presentation, not picture. A film that has to be re-encoded anyway is always
    /// cropped, because there the crop is free.
    static let cropCostingAnEncodeKey = "cropWhenItCostsAnEncode"

    static var cropsWhenItCostsAnEncode: Bool {
        UserDefaults.standard.bool(forKey: cropCostingAnEncodeKey)
    }

    /// Whether to keep the source's own picture instead of matching what Apple ships.
    ///
    /// Off by default, because matching Apple is what this app is *for*. The 1.35× test is not a
    /// storage judgement and not a quality one — it asks whether a file is already at or below what
    /// Apple would spend on this picture. Below it, copying and cloning agree, and the copy wins by
    /// being a generation closer to the master. Above it they diverge completely: a 74 Mbps disc
    /// remux in an MP4 wrapper is not the file Apple would have made, whatever else it is.
    ///
    /// The escape hatch exists because the person owns the disk, and because of what is reversible:
    /// originals are kept, so a film converted to Apple's rung today can be re-copied at disc
    /// quality tomorrow, and a copy kept today can be matched to Apple later. Neither branch is the
    /// undoable one while the source survives — which is exactly why the setting can be a
    /// preference rather than a trap.
    static let keepsSourceQualityKey = "keepSourceQuality"

    static var keepsSourceQuality: Bool {
        UserDefaults.standard.bool(forKey: keepsSourceQualityKey)
    }

    /// The plan for one file, measured rather than assumed. The letterbox reading is the slow part —
    /// seconds, not milliseconds — because it reads real metadata or decodes real frames.
    static func plan(for url: URL) async throws -> ConversionPlan {
        let source = try await MediaProbe.probe(url)
        var plan = plan(source: source, letterbox: try await LetterboxScan.scan(source))

        // A Dolby Vision film about to be copied rather than re-encoded is tried on fifteen seconds
        // first. Some sources come out of a copy declaring a Dolby Vision variant Apple renders as
        // a black screen, and nothing readable beforehand says which — so the cheap route is
        // *measured* rather than assumed, and the plan says hours instead of minutes before anyone
        // commits to it.
        if case .rebuildDolbyVision(nil) = plan.route,
           await !DolbyVisionProbe.copyKeepsApplePlayableSignalling(source) {
            plan = ConversionPlan.plan(source: source, letterbox: plan.letterbox,
                                       forcingEncode: true).adding(.copyWouldNotRender)
        }
        // Only a full enhancement layer is worth mentioning — a minimal one carries no picture,
        // so dropping it costs nothing and saying so would be noise.
        if plan.route.isDolbyVision,
           await DolbyVisionLevel5.enhancementLayerType(of: source) == "FEL" {
            return plan.adding(.enhancementLayerLost)
        }
        return plan
    }

    /// The plan for a source already read and measured — everything that follows from those two
    /// facts, and nothing that touches the disk.
    static func plan(source: SourceMedia, letterbox: Letterbox,
                     cropsWhenItCosts: Bool = ConversionPlan.cropsWhenItCostsAnEncode,
                     canRebuildDolbyVision: Bool = ConverterTools.canConvertDolbyVision,
                     forcingEncode: Bool = false,
                     matchesApplesBitrate: Bool = !ConversionPlan.keepsSourceQuality) -> ConversionPlan {
        let route = route(for: source, letterbox: letterbox, cropsWhenItCosts: cropsWhenItCosts,
                          canRebuildDolbyVision: canRebuildDolbyVision, forcingEncode: forcingEncode,
                          matchesApplesBitrate: matchesApplesBitrate)
        return ConversionPlan(
            source: source,
            letterbox: letterbox,
            route: route,
            estimate: ConversionEstimate(source: source, route: route),
            notes: notes(for: source, letterbox: letterbox, route: route,
                         canRebuildDolbyVision: canRebuildDolbyVision, forcedEncode: forcingEncode,
                         matchesApplesBitrate: matchesApplesBitrate)
        )
    }

    private static func route(for source: SourceMedia, letterbox: Letterbox,
                              cropsWhenItCosts: Bool, canRebuildDolbyVision: Bool,
                              forcingEncode: Bool = false,
                              matchesApplesBitrate: Bool = true) -> Route {
        let croppedHeight = letterbox.encodedHeight(fullHeight: source.height)
        let hasBars = croppedHeight != source.height
        // H.264 and HEVC are what MP4 carries. Anything else has to be encoded whatever its shape.
        let carriable = ["h264", "hevc"].contains(source.videoCodec)

        // The storage decision: worth re-encoding only when the file is spending far more than
        // Apple's own rung for this frame. Never a quality judgement — a copy is always the better
        // picture — and never made at all when the file won't say what it costs.
        // The Apple-parity test: is this file already at or below what Apple would spend here?
        let appleBitrate = matchesApplesBitrate ? PlaybackTarget.worthwhileBitrate(
            width: source.width, height: source.height, frameRate: source.frameRate,
            dynamicRange: source.dynamicRange, sourceCodec: source.videoCodec,
            sourceBitrate: source.videoBitrate) : nil

        let encodesPicture = forcingEncode || !carriable || appleBitrate != nil
            || (hasBars && cropsWhenItCosts)

        let encode: Encode? = encodesPicture ? {
            let geometry = encodeGeometry(source: source, letterbox: letterbox)
            // The rate is re-derived against the frame that will actually be encoded: a barless
            // 3840×1608 sits on a different rung from the 3840×2160 it was stored in.
            let reference = PlaybackTarget.referenceBitrate(
                width: geometry.width, height: geometry.height,
                frameRate: source.frameRate, dynamicRange: source.dynamicRange)

            // Two different reasons to rebuild a picture, and only one of them is about rate.
            //
            // Parity — or a codec MP4 can't carry — asks for Apple's rung, adjusted for how the two
            // codecs compare. A rebuild forced by *playability* asks for nothing of the kind: the
            // film already sits under Apple's rate, it never triggered the parity rule, and taking
            // a further third off it would be a storage cut nobody asked for on top of the
            // generation the rebuild already costs. So a forced rebuild keeps the source's own rate,
            // capped at the rung.
            let forcedByPlayability = forcingEncode && appleBitrate == nil && carriable
            let bitrate = forcedByPlayability
                ? min(reference, source.videoBitrate ?? reference)
                : PlaybackTarget.videoBitrate(
                    width: geometry.width, height: geometry.height, frameRate: source.frameRate,
                    dynamicRange: source.dynamicRange, sourceCodec: source.videoCodec,
                    sourceBitrate: source.videoBitrate ?? 0)

            return Encode(width: geometry.width, height: geometry.height,
                          bitrate: bitrate, cropTop: geometry.top)
        }() : nil

        // Dolby Vision is carried whenever the tools are here to carry it — copying the stream
        // without rewriting the RPU is what destroys it.
        if source.dolbyVision != nil, canRebuildDolbyVision,
           DolbyVisionRebuild.mode(forProfile: source.dolbyVision?.profile ?? 0) != nil {
            return .rebuildDolbyVision(encode: encode)
        }
        if let encode { return .reencode(encode) }
        return .rewrap
    }

    /// The frame an encode actually produces, which is not always the one the studio declared.
    ///
    /// A 4:2:0 picture stores one chroma sample per two rows and two columns, so **every dimension
    /// and every offset has to be even**. Spider-Verse declares its bars as 276 above and 277 below
    /// — 1607 rows of picture, an odd number, which no 4:2:0 encoder can produce. Both offsets are
    /// rounded *down* to the nearest even number, which keeps a row of black rather than cutting a
    /// row of film: the error goes into the bar, where it is invisible, instead of into the
    /// picture, where it would be permanent.
    static func encodeGeometry(source: SourceMedia,
                               letterbox: Letterbox) -> (width: Int, height: Int, top: Int?) {
        guard case .bars(let barHeight, let declaredTop) = letterbox,
              barHeight != source.height else {
            return (source.width - source.width % 2, source.height - source.height % 2, nil)
        }
        let declaredBottom = source.height - barHeight - declaredTop
        let top = declaredTop - declaredTop % 2
        let bottom = declaredBottom - declaredBottom % 2
        let height = source.height - top - bottom
        return (source.width - source.width % 2, height, top)
    }

    private static func notes(for source: SourceMedia, letterbox: Letterbox, route: Route,
                              canRebuildDolbyVision: Bool, forcedEncode: Bool = false,
                              matchesApplesBitrate: Bool = !ConversionPlan.keepsSourceQuality) -> [Note] {
        var notes: [Note] = []
        // Why this film is being re-encoded decides which remarks are true of it. An encode forced
        // by unplayable Dolby Vision is not a storage decision and is not "only to crop", and
        // saying either would put a plausible wrong reason in front of the person.
        let appleBitrate = matchesApplesBitrate ? PlaybackTarget.worthwhileBitrate(
            width: source.width, height: source.height, frameRate: source.frameRate,
            dynamicRange: source.dynamicRange, sourceCodec: source.videoCodec,
            sourceBitrate: source.videoBitrate) : nil

        // The letterbox decision, whichever way it went, and what it cost.
        if case .bars(let height, _) = letterbox, height != source.height {
            if route.encode?.isCropping == true {
                if appleBitrate == nil, !forcedEncode,
                   ["h264", "hevc"].contains(source.videoCodec) {
                    notes.append(.encodedOnlyToCrop)
                }
            } else {
                let encoded = ConversionEstimate(source: source, route: .reencode(
                    Encode(width: source.width, height: height,
                           bitrate: PlaybackTarget.referenceBitrate(
                            width: source.width, height: height, frameRate: source.frameRate,
                            dynamicRange: source.dynamicRange), cropTop: 0)))
                let kept = ConversionEstimate(source: source, route: route)
                notes.append(.barsKeptToAvoidAnEncode(extraSeconds: max(encoded.total - kept.total, 0)))
            }
        }
        if letterbox == .varies { notes.append(.aspectRatioVaries) }
        if letterbox.isAsymmetric(fullHeight: source.height), case .bars(let height, let top) = letterbox {
            notes.append(.asymmetricLetterbox(top: top, bottom: source.height - height - top))
        }

        if appleBitrate != nil, let encode = route.encode, let sourceBitrate = source.videoBitrate {
            notes.append(.matchedToApplesRate(sourceMbps: Double(sourceBitrate) / 1_000_000,
                                              targetMbps: Double(encode.bitrate) / 1_000_000))
        }

        let bitmap = source.subtitles.filter { !$0.isText }
        if !bitmap.isEmpty {
            notes.append(.bitmapSubtitlesDropped(languages: bitmap.map { $0.language ?? "und" }))
        }

        // What the audio selection will actually do, asked of the selection itself rather than
        // guessed at separately — so the warning can't drift from the behaviour.
        let selection = TrackPlan.selectAudio(from: source)
        if selection.audio.contains(where: { $0.isCopy && $0.track.carriesCopyableAtmos }) {
            notes.append(.atmosPreserved)
        } else if source.audio.contains(where: { $0.codec == "truehd" }) {
            notes.append(.atmosLost)
        }
        if let main = selection.audio.first(where: \.isDefault), !main.isCopy {
            notes.append(.audioNeedsTranscode(codec: main.track.codec,
                                              channels: main.track.channels,
                                              outputChannels: main.outputChannels))
        }

        if source.dolbyVision != nil, !canRebuildDolbyVision {
            notes.append(.dolbyVisionWouldFlatten)
        }
        return notes
    }
}

/// How long a conversion should take, and how big it should come out.
///
/// Every number traces to a measured full-length conversion rather than a guess, and the rates
/// re-derive themselves from each finished job — see `ConversionCalibration`.
struct ConversionEstimate: Sendable, Equatable {
    /// Seconds of encoding.
    let encode: Double
    /// Seconds of everything else: lifting the Dolby Vision metadata out, threading it back in, and
    /// muxing picture, sound and subtitles into the finished file.
    let finish: Double
    /// The size the finished file should be.
    let outputBytes: Int64

    var total: Double { encode + finish }

    init(source: SourceMedia, route: ConversionPlan.Route) {
        let calibration = ConversionCalibration.current
        let sourceGigabytes = Double(source.fileSize) / 1_000_000_000

        switch route.encode {
        case .some(let encode):
            // The output is what the encoder is asked to spend, plus roughly what the kept audio
            // costs — a fraction of the picture, and not worth modelling more finely than this.
            outputBytes = Int64(source.duration * Double(encode.bitrate) / 8 * 1.05)
            self.encode = Double(source.frameCount) * Double(encode.width) * Double(encode.height)
                / calibration.pixelsPerSecond
            let gigabytes = Double(outputBytes) / 1_000_000_000
            let dolbyVision = route.isDolbyVision
                ? sourceGigabytes * calibration.rpuSecondsPerGigabyte : 0
            finish = gigabytes * calibration.muxSecondsPerGigabyte + dolbyVision

        case .none:
            // A copy comes out about the size it went in — smaller where a fat lossless track is
            // dropped, and smaller again on the Dolby Vision route, which discards the enhancement
            // layer. Bounded by writing the file, not by any decision inside it.
            let shrink = route.isDolbyVision ? 0.9 : 0.95
            outputBytes = Int64(Double(source.fileSize) * shrink)
            self.encode = 0
            let gigabytes = Double(outputBytes) / 1_000_000_000
            finish = gigabytes * calibration.rewrapSecondsPerGigabyte
                + (route.isDolbyVision ? sourceGigabytes * calibration.rpuSecondsPerGigabyte : 0)
        }
    }
}

/// The rates the estimates are built from, re-derived from every conversion that finishes.
///
/// The defaults are what this Mac actually did converting a 2h04m 4K Dolby Vision feature — not a
/// specification, not a rule of thumb. They're stored so the second estimate is better than the
/// first, and they're per-machine because nothing else would be meaningful.
struct ConversionCalibration: Sendable, Equatable, Codable {
    /// Encoded pixels per second of wall-clock time.
    var pixelsPerSecond: Double
    /// Seconds per gigabyte of output for the inject-and-mux tail of a Dolby Vision job.
    var muxSecondsPerGigabyte: Double
    /// Seconds per gigabyte for a straight rewrap, which only rewrites the container.
    var rewrapSecondsPerGigabyte: Double
    /// Seconds per gigabyte of *source* to lift the Dolby Vision metadata out of it.
    var rpuSecondsPerGigabyte: Double
    /// How many real conversions have fed into each rate, counted separately.
    ///
    /// Separately because a finished job only measures the rates it exercised: a rewrap says
    /// nothing about encoding speed. A single shared counter lets a rewrap age the *encode* rate
    /// out of its replacement — the one number a queue of features is almost entirely made of.
    var encodeSamples: Int = 0
    var muxSamples: Int = 0
    var rewrapSamples: Int = 0

    static let storageKey = "conversionCalibration"

    /// Measured on this Mac: 179,328 frames at 3840×1608 encoded in 234 minutes, then 95 minutes to
    /// inject and mux 22.9 GB.
    ///
    /// Every count is zero, which is the point: these are a starting guess, not an observation to
    /// be averaged against. That distinction is worth the field. Seeded as one sample, this rate
    /// keeps half the weight of the first real job and a third of the second, and it was taken
    /// while the Mac was busy with something else — which is how a batch of four films came in at
    /// 12h57m against a prediction of 22h10m, every one of them wrong in the same direction. A
    /// guess that survives contact with measurement isn't calibration.
    static let measured = ConversionCalibration(
        pixelsPerSecond: 78_900_000,
        muxSecondsPerGigabyte: 249,
        rewrapSecondsPerGigabyte: 60,
        rpuSecondsPerGigabyte: 8
    )

    static var current: ConversionCalibration {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode(ConversionCalibration.self, from: data)
        else { return .measured }
        return stored
    }

    /// Folds a finished conversion into the stored rates.
    static func record(encodedPixels: Double, encodeSeconds: Double,
                       outputBytes: Int64, finishSeconds: Double, isRewrap: Bool) {
        let gigabytes = Double(outputBytes) / 1_000_000_000
        guard gigabytes > 0 else { return }

        let updated = current.blending(
            pixelsPerSecond: encodeSeconds > 0 && !isRewrap ? encodedPixels / encodeSeconds : nil,
            muxSecondsPerGigabyte: isRewrap ? nil : finishSeconds / gigabytes,
            rewrapSecondsPerGigabyte: isRewrap ? finishSeconds / gigabytes : nil)
        if let data = try? JSONEncoder().encode(updated) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    /// These rates moved partway towards a new measurement, weighted by how many came before.
    ///
    /// A running mean rather than a replacement: one job on battery, or against a busy disk, is a
    /// real measurement of an unusual day and shouldn't throw the estimates for everything after
    /// it. The first real measurement of a rate is the exception — it *replaces* the seed outright,
    /// because a guess isn't an observation and averaging against one only spreads it out.
    ///
    /// Each argument is optional because a finished job only measures the rates it exercised, and
    /// each rate carries its own count so an unexercised one keeps its place in the queue.
    func blending(pixelsPerSecond: Double? = nil, muxSecondsPerGigabyte: Double? = nil,
                  rewrapSecondsPerGigabyte: Double? = nil) -> ConversionCalibration {
        func blend(_ old: Double, _ new: Double?, _ count: Int) -> Double {
            guard let new, new.isFinite, new > 0 else { return old }
            // At zero samples the weight is 1 and the seed is simply overwritten.
            let weight = 1 / Double(count + 1)
            return old * (1 - weight) + new * weight
        }
        func counted(_ count: Int, _ new: Double?) -> Int {
            (new?.isFinite == true && (new ?? 0) > 0) ? count + 1 : count
        }
        var updated = self
        updated.pixelsPerSecond = blend(self.pixelsPerSecond, pixelsPerSecond, encodeSamples)
        updated.muxSecondsPerGigabyte = blend(self.muxSecondsPerGigabyte, muxSecondsPerGigabyte, muxSamples)
        updated.rewrapSecondsPerGigabyte = blend(self.rewrapSecondsPerGigabyte, rewrapSecondsPerGigabyte, rewrapSamples)
        updated.encodeSamples = counted(encodeSamples, pixelsPerSecond)
        updated.muxSamples = counted(muxSamples, muxSecondsPerGigabyte)
        updated.rewrapSamples = counted(rewrapSamples, rewrapSecondsPerGigabyte)
        return updated
    }
}
#endif
