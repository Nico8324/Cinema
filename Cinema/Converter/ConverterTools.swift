/*
See the LICENSE.txt file for licensing information.

Abstract:
Finding the command-line tools the converter drives, rather than shipping them.
*/

#if os(macOS)
import Foundation

/// The command-line tools the Mac's converter drives.
///
/// Deliberately the ones already on the machine rather than copies inside the app bundle.
/// ffmpeg is LGPL, and shipping it inside an app carries obligations — notices, the right to
/// relink — that this app has no business taking on. Invoking separate processes keeps that
/// boundary clean, at the cost of asking for an install.
///
/// This is macOS-only for a reason that can't be engineered around: it launches subprocesses,
/// and `Process` doesn't exist usefully on iOS, tvOS or visionOS. Cinema on the Mac prepares
/// files; the other platforms play them.
enum ConverterTools {
    /// Where Homebrew, MacPorts and a hand-built install put things, in that order.
    private static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    static let ffmpeg = locate("ffmpeg")
    static let ffprobe = locate("ffprobe")

    /// Rewrites a Dolby Vision RPU to a profile Apple decodes. Optional: without it, Dolby Vision
    /// content still converts, it just arrives as its HDR10 base layer.
    static let doviTool = locate("dovi_tool")

    /// Writes the `dvvC` box that marks a track as Dolby Vision. ffmpeg's MP4 muxer has no way to
    /// add one to a raw stream — verified on ffmpeg 8.1.2, where a plain remux of a profile-8
    /// source produced no `dvvC` at all — which is why GPAC is here.
    static let mp4box = locate("MP4Box")

    /// Whether conversion is possible at all.
    static var isInstalled: Bool {
        ffmpeg != nil && ffprobe != nil
    }

    /// Whether the Dolby Vision route is available. A missing optional tool must never refuse a
    /// job outright — it downgrades the result to HDR10, it doesn't prevent one.
    static var canConvertDolbyVision: Bool {
        doviTool != nil && mp4box != nil
    }

    /// What the converter can do with what's installed.
    ///
    /// Three states rather than two, because a missing *optional* tool must never refuse a job:
    /// without `dovi_tool` and `MP4Box` a Dolby Vision film still converts, it just arrives as
    /// its HDR10 base layer. Saying so plainly is the difference between a person choosing that
    /// and discovering it later in a file they can't get back.
    enum Readiness: Equatable {
        /// Everything present, including the Dolby Vision route.
        case ready
        /// ffmpeg is here, but Dolby Vision would be flattened to HDR10.
        case readyWithoutDolbyVision
        /// Nothing can be converted.
        case unavailable
    }

    static var readiness: Readiness {
        guard isInstalled else { return .unavailable }
        return canConvertDolbyVision ? .ready : .readyWithoutDolbyVision
    }

    /// The `brew install` line to put in front of someone who's missing something.
    static var installCommand: String {
        var missing: [String] = []
        if ffmpeg == nil || ffprobe == nil { missing.append("ffmpeg") }
        if doviTool == nil { missing.append("dovi_tool") }
        if mp4box == nil { missing.append("gpac") }
        return missing.isEmpty ? "" : "brew install " + missing.joined(separator: " ")
    }

    private static func locate(_ name: String) -> URL? {
        searchPaths
            .map { URL(filePath: $0).appending(path: name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
    }
}
#endif
