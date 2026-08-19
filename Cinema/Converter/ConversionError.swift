/*
See the LICENSE.txt file for licensing information.

Abstract:
What can go wrong while converting, said plainly enough to act on.
*/

#if os(macOS)
import Foundation

/// Why a conversion couldn't be done, or couldn't be trusted once it was.
///
/// Several of these describe a file that was produced and then deleted. That's deliberate: a
/// conversion that silently loses Dolby Vision, or renders at the wrong size, is worse than one
/// that fails — it looks like a success and replaces something that worked.
enum ConversionError: LocalizedError {
    case toolsMissing(installCommand: String)
    case noVideo
    case notEnoughSpace(needed: Int64, free: Int64)
    case unplayableResult
    case dolbyVisionLost
    /// The RPU and the encoded picture disagreed on frame count.
    ///
    /// Never tolerated, even by one frame: `inject-rpu` trims RPUs from the *end*, so frames lost
    /// at the head shift every remaining RPU onto the wrong picture — and that file passes every
    /// other check, including profile, compatibility and RPU presence.
    case frameCountMismatch(video: Int, rpu: Int)
    case letterboxCropLost(expected: CGSize, actual: CGSize)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .toolsMissing(let installCommand):
            String(localized: "ffmpeg wasn’t found. Install it with `\(installCommand)`.")
        case .noVideo:
            String(localized: "That file doesn’t contain a video track.")
        case .notEnoughSpace(let needed, let free):
            String(localized: """
                Not enough room: needs about \(needed.formatted(.byteCount(style: .file))), \
                \(free.formatted(.byteCount(style: .file))) free.
                """)
        case .unplayableResult:
            String(localized: "The converted file came out unplayable, so it was deleted rather than left to find later.")
        case .dolbyVisionLost:
            String(localized: """
                The Dolby Vision metadata didn’t survive the rebuild, so the file was deleted rather \
                than kept looking like Dolby Vision when it no longer is.
                """)
        case .frameCountMismatch(let video, let rpu):
            String(localized: """
                The picture and its Dolby Vision metadata came out different lengths \
                (\(video) frames against \(rpu)), which would put the metadata on the wrong frames. \
                The file was deleted rather than kept.
                """)
        case .letterboxCropLost(let expected, let actual):
            String(localized: """
                The letterbox crop didn’t survive the rebuild — expected \(Int(expected.width))×\(Int(expected.height)) \
                but the file plays at \(Int(actual.width))×\(Int(actual.height)), so it was deleted rather than kept \
                looking cropped when it isn’t.
                """)
        case .failed(let message):
            message.isEmpty ? String(localized: "The conversion failed.") : message
        }
    }
}
#endif
