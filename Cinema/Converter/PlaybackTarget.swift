/*
See the LICENSE.txt file for licensing information.

Abstract:
The encode this app aims for: what Apple ships, with the encoder that can reach it.
*/

#if os(macOS)
import Foundation

/// The range a picture was graded in.
enum DynamicRange: Sendable {
    case standard
    case hdr10
    case hlg

    /// Read from the transfer function, which is what actually distinguishes them.
    init(transfer: String?) {
        switch transfer {
        case "smpte2084": self = .hdr10
        case "arib-std-b67": self = .hlg
        default: self = .standard
        }
    }

    var isHighDynamicRange: Bool { self != .standard }

    /// Writes the colour description into the bitstream itself.
    ///
    /// `-color_primaries` and `-color_trc` are not enough on their own: a PQ picture whose
    /// transfer characteristic never reached the stream is the washed-out grey one, because
    /// nothing downstream knows to apply the curve. The `hevc_metadata` filter rewrites the VUI
    /// directly. The numbers are H.273 code points, not names.
    var bitstreamColourArguments: [String] {
        let (primaries, transfer, matrix) = switch self {
        case .standard: (1, 1, 1)      // BT.709 throughout
        case .hdr10: (9, 16, 9)        // BT.2020 primaries, ST 2084, BT.2020 non-constant
        case .hlg: (9, 18, 9)          // as HDR10 but ARIB STD-B67
        }
        return [
            "-bsf:v",
            "hevc_metadata=colour_primaries=\(primaries)"
                + ":transfer_characteristics=\(transfer)"
                + ":matrix_coefficients=\(matrix)"
        ]
    }
}

/// The encode Cinema aims for, ported from Immersive Companions with its measurements.
///
/// One target rather than one per device: Apple Vision Pro, Apple TV 4K and Apple silicon Macs all
/// decode HEVC Main 10 up to 4K in hardware, so a single file satisfies all three. The rates are
/// the top HEVC rung of each tier in Apple's *HLS Authoring Specification for Apple Devices*, with
/// the specification's own 20% reduction for 24 fps content applied on top.
///
/// `Docs/measurements.md` records how every number here was arrived at; `Docs/output-spec.md`
/// records what they are for. Read both before changing any of them.
enum PlaybackTarget {
    /// Seconds between key frames.
    static let keyFrameIntervalInSeconds = 2.0

    /// The rung of Apple's ladder a picture sits on, chosen by pixel count rather than height: a
    /// 2.39:1 feature stored without its bars is 3840×1600 — three-quarters of a 4K frame but only
    /// middling by height. The boundaries are the midpoints between neighbouring frame sizes.
    private static func megabitsPerSecond(pixels: Int, dynamicRange: DynamicRange) -> Double {
        let isHDR = dynamicRange.isHighDynamicRange
        return switch pixels {
        case ..<460_800: isHDR ? 1.93 : 1.6
        case ..<1_382_400: isHDR ? 4.08 : 3.4
        case ..<2_764_800: isHDR ? 7.0 : 5.8
        case ..<5_529_600: isHDR ? 9.7 : 8.1
        default: isHDR ? 20.0 : 16.8
        }
    }

    /// How many bits HEVC needs to hold what another codec was holding, as a ratio. Above one
    /// where the other codec is the more efficient one: an AV1 file re-encoded at its own rate
    /// comes out visibly worse, because AV1 was doing more with those bits than HEVC can.
    private static func bitrateRatio(replacing codec: String) -> Double {
        switch codec {
        case "h264", "mpeg4", "msmpeg4v3", "vc1", "mpeg2video": 0.65
        case "vp9", "vp8": 0.95
        case "av1": 1.3
        case "hevc": 0.9
        default: 1.0
        }
    }

    /// How far above the target a source has to sit before re-encoding is worth it.
    ///
    /// Below this, the storage saved doesn't pay for the generation of quality it costs. Above it,
    /// re-encoding is a **storage decision taken knowingly** — never a quality one, because a copy
    /// is always the better picture.
    static let bitrateTolerance = 1.35

    /// The frame rate below which the specification's 24 fps reduction applies. Catches 23.976 and
    /// 24 and leaves 25 alone.
    static let filmFrameRateCeiling = 24.5

    /// How far above the published table Apple's own top rung actually sits — measured off their
    /// reference Dolby Vision stream: 24.33 Mbps shipped against the table's 16.0.
    static let appleTopRungMultiplier = 1.5

    /// What Apple ships this picture at — both the rate to aim for and the yardstick a source is
    /// judged against. One function on purpose: as two, the "is this worth re-encoding" test and
    /// the encode itself drifted apart, and a 22 Mbps source came out *larger* than it went in.
    static func referenceBitrate(width: Int, height: Int, frameRate: Double,
                                 dynamicRange: DynamicRange) -> Int {
        let frameRateFactor = frameRate < filmFrameRateCeiling ? 0.8 : 1.0
        return Int(megabitsPerSecond(pixels: width * height, dynamicRange: dynamicRange)
                   * frameRateFactor * appleTopRungMultiplier * 1_000_000)
    }

    /// Whether this picture is spending enough over Apple's rung to be worth re-encoding, and at
    /// what rate. `nil` means leave it alone — including when the file won't say what it costs,
    /// since a guess is not grounds for spending a generation of quality.
    static func worthwhileBitrate(width: Int, height: Int, frameRate: Double,
                                  dynamicRange: DynamicRange, sourceCodec: String,
                                  sourceBitrate: Int?) -> Int? {
        guard let sourceBitrate, sourceBitrate > 0 else { return nil }
        let reference = referenceBitrate(width: width, height: height,
                                         frameRate: frameRate, dynamicRange: dynamicRange)
        guard Double(sourceBitrate) > Double(reference) * bitrateTolerance else { return nil }
        return videoBitrate(width: width, height: height, frameRate: frameRate,
                            dynamicRange: dynamicRange, sourceCodec: sourceCodec,
                            sourceBitrate: sourceBitrate)
    }

    /// The rate to encode at: never above Apple's rung for the frame, never above what the source
    /// was already spending. Detail a file has already thrown away doesn't come back when you
    /// spend more bits on it.
    static func videoBitrate(width: Int, height: Int, frameRate: Double,
                             dynamicRange: DynamicRange, sourceCodec: String,
                             sourceBitrate: Int) -> Int {
        let reference = referenceBitrate(width: width, height: height,
                                         frameRate: frameRate, dynamicRange: dynamicRange)
        guard sourceBitrate > 0 else { return reference }
        return min(reference, Int(Double(sourceBitrate) * bitrateRatio(replacing: sourceCodec)))
    }

    /// The encoder, and how to ask it for a rate.
    ///
    /// x265 rather than VideoToolbox, measured on a 4K Dolby Vision feature against its own
    /// 74 Mbps source with VMAF's 4K model, scored on the active picture:
    ///
    ///     rate      x265     VideoToolbox
    ///     16 Mbps   93.91    91.82
    ///     26 Mbps   95.02    93.09
    ///     30 Mbps   95.66    93.74
    ///
    /// Two VMAF at every rate — **VideoToolbox needs 1.87× the bit rate for the same picture**.
    /// One pass, not two: a file on a disc has no ladder to fall down, and over a feature one pass
    /// converges anyway — asked for 24 Mbps, a 2h04 encode delivered 23.85.
    static func rateControlArguments(bitrate: Int) -> [String] {
        ["-c:v", "libx265", "-preset", encoderPreset, "-b:v", "\(bitrate)"]
    }

    /// The x265 preset, which matters far less than its name suggests: across five presets at a
    /// matched rate the entire spread was 0.44 VMAF, and none of it came from search effort.
    /// ultrafast differs from superfast in one tool — sign data hiding — and buying that back
    /// matches superfast exactly while running 13% faster.
    static let encoderPreset = "ultrafast"

    /// The x265 parameters that go with it. `tune` inside `--x265-params` is silently ignored —
    /// only ffmpeg's own `-tune` reaches the encoder — and `-tune grain` measured as a null result
    /// anyway, because psy-rd only operates inside RDO and this preset runs `rd=2`.
    static func encoderParameters(bitrate: Int, framesPerSecond: Double, dynamicRange: DynamicRange,
                                  masteringDisplay: String?, contentLightLevel: String?) -> [String] {
        let keyInterval = max(Int((framesPerSecond * keyFrameIntervalInSeconds).rounded()), 1)
        var params = [
            "signhide=1",
            "vbv-maxrate=\(bitrate / 1000 * 2)",
            "vbv-bufsize=\(bitrate / 1000 * 2)",
            "keyint=\(keyInterval)",
            "min-keyint=\(max(keyInterval / 2, 1))",
            "no-open-gop=1"
        ]
        switch dynamicRange {
        case .hdr10:
            params += ["colorprim=bt2020", "transfer=smpte2084", "colormatrix=bt2020nc",
                       "range=limited", "hdr10=1"]
        case .hlg:
            params += ["colorprim=bt2020", "transfer=arib-std-b67", "colormatrix=bt2020nc",
                       "range=limited"]
        case .standard:
            params += ["colorprim=bt709", "transfer=bt709", "colormatrix=bt709", "range=limited"]
        }
        if let masteringDisplay { params.append("master-display=\(masteringDisplay)") }
        if let contentLightLevel { params.append("max-cll=\(contentLightLevel)") }
        return ["-x265-params", params.joined(separator: ":")]
    }

    /// The pixel-format and colour arguments for a range — ten bits for HDR, eight for the rest.
    /// Decoding HDR into eight-bit buffers is where banding in a sky comes from, and no bit rate
    /// afterwards puts it back.
    static func pictureArguments(for range: DynamicRange) -> [String] {
        switch range {
        case .hdr10, .hlg:
            ["-profile:v", "main10", "-pix_fmt", "yuv420p10le",
             "-color_primaries", "bt2020",
             "-color_trc", range == .hlg ? "arib-std-b67" : "smpte2084",
             "-colorspace", "bt2020nc"]
        case .standard:
            ["-pix_fmt", "yuv420p", "-color_primaries", "bt709",
             "-color_trc", "bt709", "-colorspace", "bt709"]
        }
    }
}
#endif
