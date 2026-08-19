# What a finished file has to be

Agreed between this app and Cinema's converter, August 2026, after each of us had built a
pipeline and measured the other's output. Every line is here because something went wrong
without it. Where the two implementations differ, this document is the target, not either
codebase.

The goal throughout is the file **Apple would have made from this source** — not the best
file obtainable, and not a copy of Apple's own, which was made from a master we don't have.

## Picture

1. **Stream-copied whenever the file is worth keeping at its own size.** Re-encoding is a
   *storage* decision, taken knowingly, and it costs a generation. A copy is one generation
   from the studio's master, which is the parity Apple has; a re-encode makes two. Nothing
   about a 74 Mbps remux makes it worse to copy — it makes it 74 GB to keep.
2. **Apple's top rung when re-encoding**, at `min(rung, source × ratio)`, never above what
   the source was already spending.
3. **Letterbox bars removed only where the studio declared them.** Geometry comes from the
   RPU's Level 5 for any Dolby Vision source; `cropdetect` only where there is no metadata
   to consult. Six samples across the film, and the **smallest** offsets any sample declares
   are the ones used — never the agreed or majority value. One frame declaring the full
   frame is proof the film uses it; five declaring bars is no proof it never does. Odd
   offsets round *down*. A sample that can't be read abandons the crop, because under a
   minimum rule a missing sample is missing evidence.
   - `cropdetect`'s `limit` is in the picture's own units: a 10-bit source needs `limit=96`,
     not the 8-bit default of 24, or every PQ bar reads as picture and nothing appears
     letterboxed. Silent, and in the safe direction, which is why it survives unnoticed.
   - Bars under ~8 px are mastering noise, not letterboxing.
4. **A copyable file is never re-encoded merely to remove bars.** The person is told what
   cropping would cost — "keeps its black bars; cropping means re-encoding, 4h33 longer" —
   and may choose it.

## Dolby Vision

5. Profile **8.1** with HDR10 compatibility, so a player without Dolby Vision still sees a
   correct HDR10 picture.
6. **`dovi_tool` runs on every Dolby Vision source whatever its profile** — including `-m 0`
   for an already-profile-8 file, which looks like a no-op and is not: skip it and GPAC
   writes `compatibility_id=6` instead of 1.
7. An RPU on **every** frame, verified by reading the bitstream at the head and again near
   the tail — not by trusting the `dvvC` box.
8. The profile **asserted from the RPU itself** (`dovi_profile == 8`, no `el_type`). `dvvC`
   is written from whatever the muxer was told: `dvp=8.hdr10` will stamp "profile 8" onto
   profile-7 RPUs, and the result passes every other check here. Do not read
   `header.vdr_rpu_profile` — it reports `1` on a genuine 8.1 and on the impostor alike.
9. Level 5 zeroed when the picture was cropped, so the metadata describes the frame that
   exists.
10. **Frame counts identical end to end.** Any `mismatched lengths` from `inject-rpu` fails
    the conversion outright — no tolerance. The tool trims surplus metadata from the *end*,
    which is only the right repair if the lost frames were at the end; if any went missing at
    the head, every surviving frame carries an earlier frame's RPU, and the file passes
    everything else in this document while its metadata is uniformly out of step with its
    picture. A one-frame difference is indistinguishable from a one-frame shift by counts
    alone.

## HDR

11. The colour description written **into the bitstream**, not merely declared at stream
    level.
12. Mastering display and content light level carried across any re-encode.

## Audio

13. **One main track per language**, chosen by what survives without transcoding: E-AC-3
    (the only format here that can carry Atmos), then AC-3, then AAC/ALAC/MP3, otherwise
    transcode the richest source — E-AC-3 640k above stereo, AAC 256k at stereo.
14. Commentary and accessibility mixes **kept alongside** the main track, never folded into
    the de-duplication.
15. **The default is the original language**, read from the video stream's own tag — never
    inherited from the rip's flag, which is how a Russian-market disc of an English film
    opens in Russian.
16. Every track written **explicitly**: exactly one `default`, and every other track keeping
    its own `comment` / `hearing_impaired` / `visual_impaired` flags rather than being
    flattened to `0`. Two tracks both claiming `default` cannot be alternatives, so the muxer
    puts each in a group of its own — and a group of one is a track nothing can switch off,
    which is how a file ends up playing two languages at once. Flattening the rest destroys
    the only evidence that a commentary track is one.
17. All audio in **one alternate group**, so a player can actually switch between languages.

## Subtitles

18. Every text track carried as `tx3g`; bitmap subtitles dropped, and a dropped **forced**
    track says so loudly — it carries dialogue a viewer has no other way to follow.
19. All subtitles in one alternate group, **at most one** default — the forced track matching
    the default audio language, otherwise none.
20. **Sidecar `.srt` import**, so a language the disc only stored as bitmaps can be restored
    as text. OCR is not acceptable: wrong words on screen are worse than none.
21. **Terminological** ISO 639-2 codes (`zho`, not `chi`) — GPAC silently rewrites `chi` to
    `nor`.
22. **BCP-47 extended tags wherever same-language variants exist**, so two Chinese tracks read
    "Traditional" and "Simplified" rather than "Chinese" twice. This is the only mechanism an
    Apple player honours; a track *name* is written, carried, and then ignored by AVFoundation.
    Written with `MP4Box -lang <trackID>=<tag>` as a pass over the finished file — ffmpeg has
    no option that writes `elng` — at roughly 140 MB/s, so about 2½ minutes on a feature, and
    worth spending only where there is a real collision to resolve. Measured behaviour:

    - **Tag every track in a colliding group, or none.** AVFoundation disambiguates
      *contextually*: `zh-Hant` alongside a plain `zho` displays as "Chinese" for both, and the
      distinction only appears once every member of the group carries its own tag.
    - **Name the axis the source named.** Traditional and Simplified are *scripts*; Cantonese
      is a spoken variety. Map a title saying "Cantonese" to `yue`, which AVFoundation renders
      as "Cantonese" — not to `zh-Hant`, which asserts a script fact from a language fact and
      collides with a genuine Traditional track. Observed renderings: `yue` → "Cantonese",
      `zh-Hant` → "Chinese, Traditional", `zh-Hans` → "Chinese, Simplified", `zh-HK` →
      "Chinese, Traditional (Hong Kong)", `pt-BR` → "Portuguese (Brazil)", `es-419` →
      "Spanish (Latin America)".
    - **Classify only from unambiguous keywords** in the source's own title, and **if any
      track in the group can't be classified confidently, leave the whole group alone.** A
      confident lie beats an obvious nothing only from the liar's point of view — and under
      the contextual rule above, a partly-tagged group displays no distinction anyway.

## Container

23. `hvc1`, never `hev1` — `hev1` opens, enumerates and reads while reporting
    `isPlayable == false`.
24. `moov` at the front.
25. No chapters — Apple's own encodes carry none.
26. A failed conversion leaves no output.

## The pipeline that makes it

27. **The cost is known before anything is committed** — route, output size and elapsed time
    estimated from rates this machine has actually achieved, re-derived after each job. A
    29-hour queue is a decision, and nobody can take it from a progress bar starting at 0%.
28. **Every loss is declared before the conversion, not discovered after it**: subtitles that
    will be dropped, audio that must be transcoded, a film that can't be cropped.
29. **Work ordered so the library becomes usable soonest** — shortest first. The total is
    fixed; the wait isn't.
30. **Nothing is done twice.** A source with a converted file beside it is skipped, so an
    interrupted run resumes rather than restarts.
31. **One conversion at a time.** Two concurrent x265 encodes produce *different files*, not
    merely slower ones: frame threads and lookahead are sized to the cores available and
    those decisions feed back into rate control.
32. **Originals are never modified, and never deleted — only moved to the Trash.** Not
    caution: nothing either implementation verifies proves a conversion is *faithful*, only
    that it is well-formed. A conversion can satisfy every check in this document and still
    have lost a reel, and no one would know until they watched it. Deleting the original
    turns a recoverable disappointment into a permanent loss on the strength of checks never
    designed to bear that weight.
33. **Commentary and accessibility tracks are labelled by reading the DASH role box** —
    *by the library, not the converter.* ffmpeg writes the role, MP4Box carries it through,
    and ffprobe surfaces it, but AVFoundation reports every audio track as
    `main-program-content` and never reads it. So the converter's duty is to preserve the
    flag (16) and the library's is to read it and name the track. Neither half is optional:
    without the flag there is nothing to read, and without the reading a viewer sees two
    identical entries.

## Not achievable, and not defects

- **Atmos**, unless the source already carries E-AC-3 with JOC. Nothing outside Dolby's own
  encoder writes it, and ffmpeg's E-AC-3 stops at 5.1 with no objects. A TrueHD Atmos track
  cannot be carried into MP4 in any form AVFoundation will decode.
- **Subtitles a disc only stored as bitmaps**, unless a sidecar supplies the text.
- **2-second keyframes on a copied file.** Only a re-encode can give that, and it isn't worth
  a generation.
- **Detail the source never had.** A 10 Mbps download does not improve by being given 24.

A file can satisfy all thirty-three points and still lack something Apple's own copy has.
Perfect here means *everything achievable from this source with these tools* — not identical
to Apple's, which was made from a master we will never have.
