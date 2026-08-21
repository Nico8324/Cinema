import AVFoundation
import Foundation

// Marks a subtitle track as SDH the only way AVFoundation reads back: QuickTime
// tagged-characteristic items in the track's own user data. ffmpeg's DASH `kind`
// box and the track name are both written, carried, and ignored by AVFoundation.
let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: sdhmark <file> list | mark <trackID> [trackID ...]\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: args[1])
let mode = args[2]

let CHARACTERISTICS = [
    AVMediaCharacteristic.transcribesSpokenDialogForAccessibility.rawValue,
    AVMediaCharacteristic.describesMusicAndSoundForAccessibility.rawValue,
]

do {
    let movie = try AVMutableMovie(url: url, options: nil)
    let subs = movie.tracks(withMediaType: .subtitle)

    func describe(_ t: AVMutableMovieTrack) -> String {
        let name = t.metadata.first {
            $0.key as? String == AVMetadataKey.quickTimeUserDataKeyTrackName.rawValue
        }?.stringValue ?? "-"
        let tags = t.metadata.filter {
            $0.key as? String == AVMetadataKey.quickTimeUserDataKeyTaggedCharacteristic.rawValue
        }.compactMap { $0.stringValue }
        return "id=\(t.trackID) name=\"\(name)\" tagged=\(tags.isEmpty ? "[]" : tags.description)"
    }

    if mode == "list" {
        for t in subs { print("  " + describe(t)) }
        exit(0)
    }

    // Every track to be marked is taken in one invocation, because the header must be
    // written exactly once: repeated passes are a documented way to make AVFoundation stop
    // reporting a track at all. Marking three tracks is three arguments, not three runs.
    let targets = args.dropFirst(3).compactMap { Int32($0) }
    guard mode == "mark", !targets.isEmpty else {
        FileHandle.standardError.write(Data("bad arguments\n".utf8)); exit(2)
    }
    var chosen: [AVMutableMovieTrack] = []
    for target in targets {
        guard let track = subs.first(where: { $0.trackID == target }) else {
            FileHandle.standardError.write(Data("no subtitle track with id \(target)\n".utf8)); exit(1)
        }
        chosen.append(track)
    }

    // Note on why there is no "already marked, skip" guard here: a `tagc` item written on a
    // previous run does NOT come back through `track.metadata` when the file is reopened —
    // the box is in the file (a raw scan finds it, and AVFoundation's own media selection
    // reports the characteristic), but this API surfaces neither it nor the track name. So
    // the in-memory view cannot be used to decide idempotency, and the caller is responsible
    // for not re-marking. Checked before writing, via the selection group, below.
    for track in chosen {
        // Append, never assign: assigning replaces the track's existing name.
        var items = track.metadata
        for value in CHARACTERISTICS {
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeUserData
            item.key = AVMetadataKey.quickTimeUserDataKeyTaggedCharacteristic as NSString
            item.value = value as NSString
            items.append(item)
        }
        track.metadata = items
    }

    // writeHeader has been observed to return -11800/-16430 on a GPAC-muxed file while
    // having patched the header correctly. The return code is therefore not trusted: the
    // write is followed by re-reading the finished file through the same API a player uses,
    // and only that decides whether this succeeded.
    // A fingerprint of the file as it stands, taken before anything is written. This tool
    // rewrites a header over a delivered artefact in place and cannot roll back, so the one
    // thing it owes the caller is to notice when the rewrite has damaged the container.
    // Verifying only that its own characteristics arrived would report success on a file
    // that no longer opens.
    struct Shape: Equatable {
        var playable = false
        var duration = 0.0
        var video = 0, audio = 0, subtitle = 0
    }
    func shape(of url: URL) async -> Shape {
        let a = AVURLAsset(url: url)
        var s = Shape()
        s.playable = (try? await a.load(.isPlayable)) ?? false
        s.duration = (try? await a.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
        s.video = ((try? await a.loadTracks(withMediaType: .video)) ?? []).count
        s.audio = ((try? await a.loadTracks(withMediaType: .audio)) ?? []).count
        s.subtitle = ((try? await a.loadTracks(withMediaType: .subtitle)) ?? []).count
        return s
    }
    var before = Shape()
    let shapeSem = DispatchSemaphore(value: 0)
    Task { before = await shape(of: url); shapeSem.signal() }
    shapeSem.wait()

    var writeError: Error?
    do {
        try movie.writeHeader(to: url, fileType: .mp4, options: .addMovieHeaderToDestination)
    } catch {
        writeError = error
    }

    let wanted = Set(CHARACTERISTICS)
    let sem = DispatchSemaphore(value: 0)
    var marked = 0
    var after = Shape()
    Task {
        defer { sem.signal() }
        after = await shape(of: url)
        let asset = AVURLAsset(url: url)
        guard let group = try? await asset.loadMediaSelectionGroup(for: .legible) else { return }
        // Each marked track yields both a full and a forced-only option, so the count is
        // compared against the number of tracks rather than asserted exactly.
        marked = group.options.filter { option in
            wanted.allSatisfy { option.hasMediaCharacteristic(AVMediaCharacteristic(rawValue: $0)) }
        }.count
    }
    sem.wait()
    let verified = marked >= chosen.count

    // Reported before and separately from the label check: "the file no longer opens" and
    // "the label did not arrive" are different failures, and only one means the artefact is
    // damaged. This cannot undo the write; it can only stop anyone being told the file is
    // fine when it is not.
    let damaged = after.playable != before.playable || after.video != before.video
        || after.audio != before.audio || after.subtitle != before.subtitle
        || abs(after.duration - before.duration) > 0.5
    if damaged {
        let b = "before: playable=\(before.playable) dur=\(Int(before.duration)) v=\(before.video) a=\(before.audio) s=\(before.subtitle)"
        let a2 = "after:  playable=\(after.playable) dur=\(Int(after.duration)) v=\(after.video) a=\(after.audio) s=\(after.subtitle)"
        FileHandle.standardError.write(Data("  *** CONTAINER DAMAGED BY THIS WRITE - RESTORE FROM SOURCE ***\n  \(b)\n  \(a2)\n".utf8))
        exit(2)
    }

    if verified {
        let ids = chosen.map { String($0.trackID) }.joined(separator: ",")
        let note = writeError.map { " (writeHeader reported \(($0 as NSError).code), outcome verified)" } ?? ""
        print("  marked tracks \(ids)\(note): \(marked) accessibility options present, container intact")
    } else {
        FileHandle.standardError.write(Data("  FAILED: characteristics absent after write\n".utf8))
        if let writeError { FileHandle.standardError.write(Data("  writeHeader: \(writeError)\n".utf8)) }
        exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1)
}
