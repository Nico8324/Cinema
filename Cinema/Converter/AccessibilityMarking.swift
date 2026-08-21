/*
See the LICENSE.txt file for licensing information.

Abstract:
Marking an SDH track so an Apple player can tell it apart, which only AVFoundation can do.
*/

#if os(macOS)
import AVFoundation
import Foundation

/// Writes the accessibility characteristics that make an SDH track distinguishable.
///
/// This is the one step in the pipeline that no command-line tool can perform. ffmpeg writes the
/// DASH `caption` role, MP4Box carries it, ffprobe reports it — and **AVFoundation reads none of
/// it**: a finished file's SDH track comes back with no accessibility characteristics at all, so
/// on the platform the file is made for it is indistinguishable from an ordinary subtitle. The
/// remedy is a QuickTime tagged-characteristic item written through `AVMutableMovie`, and the
/// consequence is that a converter built only on ffmpeg and GPAC cannot satisfy point 33 of
/// `Docs/output-spec.md`. An app on Apple's own frameworks can, which is why this lives here.
///
/// The visible effect is that a picker showing two identical "English" entries reads "English" and
/// "English SDH" instead — AVFoundation renames the option from the characteristics, not from any
/// track name, which it ignores.
enum AccessibilityMarking {
    private static let characteristics: [AVMediaCharacteristic] = [
        .transcribesSpokenDialogForAccessibility,
        .describesMusicAndSoundForAccessibility
    ]

    /// Marks the subtitle tracks at the given MP4 track IDs, in **one** header write.
    ///
    /// One write is a rule, not tidiness: repeated header passes have been observed to make
    /// AVFoundation stop reporting a track altogether. Marking three tracks is three IDs, never
    /// three calls.
    ///
    /// The file is patched rather than rewritten — `mdat` is never touched, so an 11 GB film takes
    /// about a second — but the whole `moov` is regenerated, which costs GPAC's `©too` writing-tool
    /// string. That loss is the only one measured, and it doubles as the cheapest way to tell a
    /// marked file from an unmarked one from outside.
    ///
    /// - Returns: how many legible options came back carrying every characteristic.
    @discardableResult
    static func mark(trackIDs: [CMPersistentTrackID], in url: URL) async throws -> Int {
        guard !trackIDs.isEmpty else { return 0 }

        let movie = try AVMutableMovie(url: url, options: nil)
        let subtitles = movie.tracks(withMediaType: .subtitle)
        let chosen = trackIDs.compactMap { id in subtitles.first { $0.trackID == id } }
        guard chosen.count == trackIDs.count else {
            throw ConversionError.subtitleTrackMissing
        }

        for track in chosen {
            // Appended, never assigned: assigning replaces the track's existing name, which is how
            // a commentary track lost its label the first time this was attempted.
            var items = track.metadata
            for characteristic in characteristics {
                let item = AVMutableMetadataItem()
                item.keySpace = .quickTimeUserData
                item.key = AVMetadataKey.quickTimeUserDataKeyTaggedCharacteristic as NSString
                item.value = characteristic.rawValue as NSString
                items.append(item)
            }
            track.metadata = items
        }

        // `writeHeader` returns -11800 / -16430 on a GPAC-muxed file and patches it correctly
        // anyway; only the Dolby Vision route's output errors, and an ffmpeg-muxed file returns
        // cleanly. Trusting the status would reject good files, so it is recorded and set aside —
        // the finished file is then read back through the same API a player uses, and that decides.
        var reported: Error?
        do {
            try movie.writeHeader(to: url, fileType: .mp4, options: .addMovieHeaderToDestination)
        } catch {
            reported = error
        }

        let marked = await countMarkedOptions(in: url)
        guard marked >= chosen.count else {
            throw ConversionError.accessibilityMarkingFailed(
                underlying: (reported as NSError?)?.code)
        }
        return marked
    }

    /// How many legible options the finished file reports as carrying every characteristic.
    ///
    /// Read through `loadMediaSelectionGroup` because that is what a player uses, and because the
    /// obvious alternative doesn't work: a `tagc` item written on a previous run does **not** come
    /// back through `track.metadata` when the file is reopened. The box is provably in the file and
    /// AVFoundation's own selection reports it, but that API surfaces neither it nor the track name
    /// — so an "already marked, skip" guard written against `track.metadata` would always believe
    /// the file was unmarked and mark it again, which is the one thing that must not happen twice.
    static func countMarkedOptions(in url: URL) async -> Int {
        guard let group = try? await AVURLAsset(url: url).loadMediaSelectionGroup(for: .legible)
        else { return 0 }
        // Each marked track yields both a whole and a forced-only option, so this is compared
        // against the number of tracks rather than asserted exactly.
        return group.options.filter { option in
            characteristics.allSatisfy(option.hasMediaCharacteristic)
        }.count
    }
}
#endif
