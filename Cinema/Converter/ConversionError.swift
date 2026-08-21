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
    /// The re-encode returned a different number of frames than it was given.
    case frameCountChanged(source: Int, output: Int)
    /// The finished file plays, but a stricter reader can't parse it to the end.
    case malformedContainer(String)
    /// The finished file opens and reports itself playable, but no player can get a picture from it.
    case doesNotRender(String)
    /// The Dolby Vision came out in a form Apple's decoders won't render.
    case dolbyVisionNotApplePlayable(compatibility: Int)
    /// Dolby Vision profile 5, whose base layer can't be shown correctly without the metadata.
    case dolbyVisionProfile5
    case subtitleTrackMissing
    case accessibilityMarkingFailed(underlying: Int?)
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
        case .frameCountChanged(let source, let output):
            String(localized: """
                The conversion came out a different length than the original \
                (\(output) frames against \(source)), so it was deleted rather than kept — a film \
                that gains or loses frames has its sound and its Dolby Vision on the wrong ones.
                """)
        case .malformedContainer(let detail):
            String(localized: """
                The converted file came out structurally damaged (\(detail)) — it would play, and \
                then fail in ways nothing could explain later — so it was deleted rather than kept.
                """)
        case .doesNotRender(let detail):
            String(localized: """
                The converted file opened but never produced a picture\(detail.isEmpty ? "" : " (\(detail))") \
                — it would have looked like a working film and played nothing — so it was deleted \
                rather than added to your library.
                """)
        case .dolbyVisionNotApplePlayable(let compatibility):
            String(localized: """
                The Dolby Vision came out signalled as compatibility \(compatibility) rather than 1, \
                which Apple devices show as a black screen. The file was deleted rather than added \
                to your library.
                """)
        case .subtitleTrackMissing:
            String(localized: "A subtitle track named for accessibility marking isn’t in the finished file.")
        case .accessibilityMarkingFailed(let underlying):
            String(localized: "The SDH tracks couldn’t be marked as accessible\(underlying.map { " (\($0))" } ?? "").")
        case .dolbyVisionProfile5:
            String(localized: """
                This film uses Dolby Vision profile 5, whose picture can only be shown correctly \
                by a Dolby Vision display. Converting it would produce a file that looks right on \
                one and wrong on every other screen, without saying so — so it was left alone.
                """)
        case .failed(let message):
            message.isEmpty ? String(localized: "The conversion failed.") : message
        }
    }
}
#endif
