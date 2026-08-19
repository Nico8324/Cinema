/*
See the LICENSE.txt file for licensing information.

Abstract:
What a source file actually contains, read from the file rather than assumed.
*/

#if os(macOS)
import Foundation

/// Everything about a source file that decides how it converts and how long that takes.
///
/// Read from the file with `ffprobe`, never guessed from its name or extension. Two 4K films of
/// the same length can differ by hours of work — one letterboxed and one not, one Dolby Vision
/// and one plain HDR10 — and nothing outside the file says which is which.
struct SourceMedia: Sendable, Identifiable, Equatable {
    var id: URL { url }

    let url: URL
    let fileSize: Int64
    let duration: Double
    /// Frames per second as the file states it — `24000/1001`, not a rounded 24.
    ///
    /// A raw HEVC stream carries no timing of its own, so this number is handed to the muxer on
    /// trust. Rounding it desynchronises the audio a little more with every passing minute.
    let frameRate: Double
    let width: Int
    let height: Int
    let videoCodec: String
    let bitDepth: Int
    /// Whether the picture is PQ-encoded — which decides the black level that letterbox detection
    /// has to measure against.
    let isHDR: Bool
    /// The transfer function as the file states it, which is what actually distinguishes HDR10
    /// from HLG from ordinary video.
    let colorTransfer: String?
    let dolbyVision: DolbyVision?
    let audio: [AudioTrack]
    let subtitles: [SubtitleTrack]
    /// What the picture itself costs, per second. `nil` when the file won't say — in which
    /// case it is left alone rather than re-encoded on a guess.
    let videoBitrate: Int?
    /// The video stream's own language tag, which is the best evidence of what language the
    /// film was actually shot in — better than any audio track's flag, which a regional rip
    /// rewrites to whatever it dubbed.
    let originalLanguage: String?
    /// The video stream's index in the file, which the ffmpeg arguments address it by.
    let videoStreamIndex: Int

    var frameCount: Int { Int((duration * frameRate).rounded()) }

    /// The Dolby Vision the file carries, and the profile it claims.
    struct DolbyVision: Sendable, Equatable {
        let profile: Int
        /// What a non-Dolby-Vision display is told the base layer is. Only `1` means "plain HDR10",
        /// which is the fallback path for every ordinary screen.
        let compatibilityID: Int

        /// Whether the RPU needs rewriting for Apple's decoders. Profile 7 is dual-layer Blu-ray
        /// metadata; profile 8 with the wrong compatibility id still needs the pass that fixes it.
        var needsConversion: Bool { profile != 8 || compatibilityID != 1 }
    }

    struct AudioTrack: Sendable, Equatable {
        let index: Int
        let codec: String
        let profile: String?
        let channels: Int
        let language: String?
        let title: String?
        /// The source's own flags for this track, kept because clearing them destroys the only
        /// evidence of what a track is — see `TrackPlan.audioDisposition`.
        let disposition: [String: Int]

        /// Whether this is a different programme rather than another mix of the film: a
        /// commentary, or a described/captioned track. Never de-duplicated away.
        var isSecondaryProgramme: Bool {
            ["comment", "visual_impaired", "hearing_impaired"].contains { (disposition[$0] ?? 0) != 0 }
        }

        /// Whether this track carries Dolby Atmos objects that can be **copied**.
        ///
        /// Only E-AC-3 with JOC qualifies. TrueHD Atmos does not: MP4 can't hold TrueHD, and no
        /// encoder outside Dolby writes JOC, so the objects cannot be recreated from it at any
        /// effort. Atmos survives a conversion exactly when the source already has it in this form.
        var carriesCopyableAtmos: Bool {
            codec == "eac3" && profile?.localizedCaseInsensitiveContains("atmos") == true
        }

        /// Whether an Apple device can play this track at all. DTS and TrueHD can't be decoded by
        /// AVFoundation, so they have to be transcoded or left behind.
        var isPlayableByApple: Bool {
            ["aac", "ac3", "eac3", "alac", "pcm_s16le", "pcm_s24le"].contains(codec)
        }
    }

    struct SubtitleTrack: Sendable, Equatable {
        let index: Int
        let codec: String
        let language: String?
        let title: String?
        let disposition: [String: Int]

        var isForced: Bool { (disposition["forced"] ?? 0) != 0 }
        var isHearingImpaired: Bool { (disposition["hearing_impaired"] ?? 0) != 0 }

        /// Whether the track is text that can become a real MP4 subtitle.
        ///
        /// Bitmap subtitles (`hdmv_pgs_subtitle`, `dvd_subtitle`) can't: MP4 has no home for them
        /// and AVFoundation won't render one. They're dropped, and the honest thing is to say so
        /// before the conversion rather than after.
        var isText: Bool {
            ["subrip", "ass", "ssa", "mov_text", "webvtt"].contains(codec)
        }
    }

    /// The range the picture was graded in.
    var dynamicRange: DynamicRange { DynamicRange(transfer: colorTransfer) }

    /// The English-language track a viewer would end up on, or the first one if there's no English.
    var primaryAudio: AudioTrack? {
        audio.first { $0.language == "eng" && $0.channels > 2 }
            ?? audio.first { $0.language == "eng" }
            ?? audio.first
    }
}

/// Reads a source file with `ffprobe`.
enum MediaProbe {
    /// Reads one file. Fast — a fraction of a second even for an 80 GB source, because it reads
    /// the header rather than the film.
    static func probe(_ url: URL) async throws -> SourceMedia {
        guard let ffprobe = ConverterTools.ffprobe else {
            throw ConversionError.toolsMissing(installCommand: ConverterTools.installCommand)
        }

        let data = try await Process.output(of: ffprobe, arguments: [
            "-v", "error",
            "-print_format", "json",
            "-show_format", "-show_streams",
            url.path(percentEncoded: false)
        ])
        let probe = try JSONDecoder().decode(FFProbeOutput.self, from: data)

        guard let video = probe.streams.first(where: { $0.codecType == "video" }) else {
            throw ConversionError.noVideo
        }

        let dolbyVision = video.sideDataList?.compactMap { side -> SourceMedia.DolbyVision? in
            guard let profile = side.dvProfile else { return nil }
            return SourceMedia.DolbyVision(profile: profile,
                                           compatibilityID: side.dvBlSignalCompatibilityID ?? 0)
        }.first

        return SourceMedia(
            url: url,
            fileSize: Int64(probe.format.size.flatMap(Int.init) ?? 0),
            duration: probe.format.duration.flatMap(Double.init) ?? 0,
            frameRate: rate(from: video.rFrameRate),
            width: video.width ?? 0,
            height: video.height ?? 0,
            videoCodec: video.codecName ?? "",
            bitDepth: (video.pixFmt?.contains("10") == true) ? 10 : 8,
            isHDR: video.colorTransfer == "smpte2084" || video.colorTransfer == "arib-std-b67",
            colorTransfer: video.colorTransfer,
            dolbyVision: dolbyVision,
            audio: probe.streams.filter { $0.codecType == "audio" }.map {
                SourceMedia.AudioTrack(index: $0.index, codec: $0.codecName ?? "",
                                       profile: $0.profile, channels: $0.channels ?? 0,
                                       language: $0.tags?.language, title: $0.tags?.title,
                                       disposition: $0.disposition ?? [:])
            },
            subtitles: probe.streams.filter { $0.codecType == "subtitle" }.map {
                SourceMedia.SubtitleTrack(index: $0.index, codec: $0.codecName ?? "",
                                          language: $0.tags?.language, title: $0.tags?.title,
                                          disposition: $0.disposition ?? [:])
            },
            // Matroska rarely states a per-stream bit rate, so the picture's cost is derived
            // from the file: total size less what the other tracks declare, over the runtime.
            videoBitrate: videoBitrate(of: video, in: probe),
            originalLanguage: video.tags?.language,
            videoStreamIndex: video.index
        )
    }

    /// What the picture costs per second.
    ///
    /// The stream's own `bit_rate` when it has one; otherwise the file's size less everything
    /// the other tracks declare, spread over the runtime. A remux almost never states the
    /// video rate, and that number decides whether the file is worth re-encoding at all.
    private static func videoBitrate(of video: Stream, in probe: FFProbeOutput) -> Int? {
        if let stated = video.bitRate.flatMap(Int.init), stated > 0 { return stated }
        guard let size = probe.format.size.flatMap(Double.init),
              let duration = probe.format.duration.flatMap(Double.init), duration > 0
        else { return nil }
        let otherTracks = probe.streams
            .filter { $0.index != video.index }
            .compactMap { $0.bitRate.flatMap(Double.init) }
            .reduce(0, +)
        let bits = size * 8 / duration - otherTracks
        return bits > 0 ? Int(bits) : nil
    }

    /// Turns ffprobe's `"24000/1001"` into a number, keeping the ratio's precision.
    private static func rate(from text: String?) -> Double {
        guard let text else { return 0 }
        let parts = text.split(separator: "/")
        guard let numerator = Double(parts.first ?? "") else { return 0 }
        guard parts.count == 2, let denominator = Double(parts[1]), denominator != 0 else {
            return numerator
        }
        return numerator / denominator
    }

    // MARK: - ffprobe's JSON

    private struct FFProbeOutput: Decodable {
        let streams: [Stream]
        let format: Format
    }

    private struct Format: Decodable {
        let duration: String?
        let size: String?
    }

    private struct Stream: Decodable {
        let index: Int
        let codecName: String?
        let codecType: String?
        let profile: String?
        let width: Int?
        let height: Int?
        let channels: Int?
        let pixFmt: String?
        let colorTransfer: String?
        let rFrameRate: String?
        let tags: Tags?
        let sideDataList: [SideData]?
        let disposition: [String: Int]?
        let bitRate: String?

        enum CodingKeys: String, CodingKey {
            case index, profile, width, height, channels, tags, disposition
            case bitRate = "bit_rate"
            case codecName = "codec_name"
            case codecType = "codec_type"
            case pixFmt = "pix_fmt"
            case colorTransfer = "color_transfer"
            case rFrameRate = "r_frame_rate"
            case sideDataList = "side_data_list"
        }

        /// ffprobe reports an audio `profile` as a string ("Dolby TrueHD + Dolby Atmos") but a
        /// video one as a number, and a single strict type would fail to decode half the streams.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            index = try container.decode(Int.self, forKey: .index)
            codecName = try container.decodeIfPresent(String.self, forKey: .codecName)
            codecType = try container.decodeIfPresent(String.self, forKey: .codecType)
            width = try container.decodeIfPresent(Int.self, forKey: .width)
            height = try container.decodeIfPresent(Int.self, forKey: .height)
            channels = try container.decodeIfPresent(Int.self, forKey: .channels)
            pixFmt = try container.decodeIfPresent(String.self, forKey: .pixFmt)
            colorTransfer = try container.decodeIfPresent(String.self, forKey: .colorTransfer)
            rFrameRate = try container.decodeIfPresent(String.self, forKey: .rFrameRate)
            tags = try container.decodeIfPresent(Tags.self, forKey: .tags)
            sideDataList = try container.decodeIfPresent([SideData].self, forKey: .sideDataList)
            disposition = try container.decodeIfPresent([String: Int].self, forKey: .disposition)
            bitRate = try container.decodeIfPresent(String.self, forKey: .bitRate)
            if let text = try? container.decodeIfPresent(String.self, forKey: .profile) {
                profile = text
            } else if let number = try? container.decodeIfPresent(Int.self, forKey: .profile) {
                profile = String(number)
            } else {
                profile = nil
            }
        }
    }

    private struct Tags: Decodable {
        let language: String?
        let title: String?
    }

    private struct SideData: Decodable {
        let dvProfile: Int?
        let dvBlSignalCompatibilityID: Int?

        enum CodingKeys: String, CodingKey {
            case dvProfile = "dv_profile"
            case dvBlSignalCompatibilityID = "dv_bl_signal_compatibility_id"
        }
    }
}
#endif
