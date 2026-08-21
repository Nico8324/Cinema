# What a finished file has to be

Agreed between this app and Cinema's converter, August 2026, after each of us had built a
pipeline and measured the other's output. Every line is here because something went wrong
without it. Where the two implementations differ, this document is the target, not either
codebase.

The goal throughout is the file **Apple would have made from this source** — not the best
file obtainable, and not a copy of Apple's own, which was made from a master we don't have.

## Picture

1. **Re-encoded to Apple's own rung whenever the source exceeds it by more than a third;
   copied when it doesn't.** This is neither a storage decision nor a quality one — it is what
   cloning Apple *means* for a file spending three times what Apple would spend on the same
   picture. Below the threshold the two goals agree, and copying wins because a copy is one
   generation from the studio's master, which is the parity Apple has, where a re-encode makes
   two. Above it they diverge completely, and the rule is: match Apple.

   Stated the other way, because it is the sentence that keeps getting lost: **a copy is the
   better picture, and it is not the file Apple would have made.** A 77 Mbps disc remux
   rewrapped into MP4 is a disc remux in an MP4, three times Apple's rate with the letterbox
   Apple removes. Calling the threshold a storage preference is what turns this rule into a
   checkbox, and the day it becomes a checkbox the ladder, the multiplier and the crop rules
   all become code that never runs.

   A person may overrule it for a film, or for a library that won't fit — that is an escape
   hatch, not the default.
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

   **Apple's HLS authoring specification says Profile 5, and that is not a contradiction to
   resolve in its favour.** Item 1.9 requires Dolby Vision streams to be "Profile 5 (single
   layer 10-bit HEVC)" — but that document governs *adaptive streaming*, where a separate SDR
   ladder is mandatory anyway (item 1.24) and so the base layer never has to stand on its own.
   A local file has no such ladder: profile 5's base layer is IPT, and a player that ignores
   the RPU renders it as the washed-out wrong-colour picture. 8.1 exists precisely so the base
   layer is legal HDR10. Both files play on Apple hardware; only one degrades correctly. Do
   not "correct" this to Profile 5 on the strength of that citation.

   **This is now measured rather than argued.** A store purchase of *Tenet* was taken apart —
   the `.movpkg`'s init segments are unencrypted even though the media is not — and Apple's own
   delivery is exactly what the specification says and exactly what our reasoning predicted:

   ```
   video rendition 1   frma dvh1   dvcC: profile=5 level=1 rpu=1 el=0 bl=1 compat=0
   video rendition 2   frma avc1   colr nclx 1/1/1  (BT.709 SDR)
   both                1422x646, pasp 1:1, cbcs encryption, ftyp iso5
   ```

   Profile 5 with **compatibility 0** — no HDR10 fallback at all — carried alongside **a
   separate H.264 SDR rendition of the same picture**. That second stream is the ladder that
   makes profile 5 safe, and it is why the citation does not transfer: a player that cannot do
   Dolby Vision is not asked to decode Apple's base layer, it is handed a different file. Ours
   has no second file, so the base layer must stand on its own, so it must be 8.1.

   The codec tag follows from the same fact and is not a free choice. Apple writes **`dvh1`**,
   which declares "this is Dolby Vision, do not attempt to read it as plain HEVC" — correct for
   profile 5, whose IPT base layer genuinely is not HDR10. We write `hvc1`, which invites
   exactly that reading — correct for 8.1, whose base layer genuinely is. The pair
   `dvh1`/profile 5 and the pair `hvc1`/profile 8.1 are each internally consistent; mixing them
   produces either a file no ordinary player will touch or one that will touch it and be
   wrong. Likewise the box name: `dvcC` is what profile 5 carries, `dvvC` what profile 8
   carries, and neither is a stylistic variant of the other.
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

    **What Apple actually ships, measured — not inferred from the authoring specification.**
    A real store purchase (*Tenet*, "1080p HD", French region) was taken apart: a downloaded
    `.movpkg` keeps its HLS manifests in plain text, so the segment tables give real byte
    counts and durations even though the media is FairPlay-encrypted. Every audio rendition in
    it, both languages:

    | rendition | codec | labelled | measured |
    |---|---|---|---|
    | `audio_en_gr384_mp4a-A5` | AC-3 (Dolby Digital) 5.1 | 384 | **386 kb/s** |
    | `audio_en_gr160_mp4a-40-2` | AAC-LC stereo | 160 | **161 kb/s** |

    So **the authoring specification's audio figures are store parity, not streaming floors.**
    That had been guessed the other way here — the reasoning was that a purchased film would
    carry more than an adaptive ladder's recommendation, and it is simply wrong: Apple ships
    5.1 at 384 kb/s AC-3, exactly the published number, and offers no richer surround option
    at all. This library's copied tracks run 448–768 kb/s, i.e. **above** what Apple ships.
    Whether to follow them down is a separate decision from knowing where they are, and
    re-encoding lossy to lossy costs a generation that copying does not — but nobody should
    argue from the spec numbers being conservative again, because they aren't.

    Two things measured in the same file that bear on other points: the video is
    **1422×646**, an exact 2.2012:1 against *Tenet*'s 2.20:1 theatrical ratio, confirming
    point 4's barless requirement from Apple's own delivery rather than from inference; and
    the subtitle renditions are tagged `cmn-Hans`, `cmn-Hant`, `yue-Hant`, `pt-BR`, `pt-PT`,
    `es-ES`, `fr-FR`, which is point 22's BCP-47 rule — including `yue` for Cantonese —
    matching Apple's own practice exactly. Forced subtitles are a **separate rendition**
    (`fr-FR_subtitles_forced`), not a flag on the full one.

    A caution on the video rate for anyone tempted to reuse it: 2588 kb/s average, 4521 peak,
    is **one persisted rung of a ladder**, and at 1422×646 it is plainly not a 1080p-width
    rendition, so it is not evidence of what Apple's top 1080p rung spends. The audio numbers
    carry no such doubt — every audio rendition in the package was persisted in full, and
    there are only two per language.

    **`-ac` fixes the channel count and says nothing about the layout.** A DTS-HD MA 5.1
    source transcoded to E-AC-3 with `-ac:a:0 6` and no other channel argument comes out
    `5.1(side)`, not `5.1` — two independent implementations produced the identical layout from
    the same source while neither passed one, so it is the decoder's layout carried through
    rather than anything the encoder chose. Two files that both report six channels can
    disagree about where two of them go. The count is what we control; the layout is what we
    inherit — which is the same shape as trusting any other default, one level further down.

    A channel ceiling is **stated to the encoder** (`-ac:a:N 6`) rather than left to it, and
    declared as a channel change — "7.1 DTS re-encoded to 5.1", never "has to be re-encoded
    to play". **The ceiling is ffmpeg's, not the format's**: `ffmpeg -h encoder=eac3` lists
    its supported layouts ending at `5.1`, and a 7.1 input silently comes out `5.1(side)`,
    while E-AC-3 itself carries 7.1 and Apple's own HLS authoring specification lists
    7.1 Dolby Digital Plus at 384 kbit/s. So the honest sentence is "the encoder here cannot write more than 5.1", not
    "the surround format MP4 carries holds no more" — the second blames the container for a
    limitation belonging to one tool, and would stop anyone reaching for a better encoder. ffmpeg downmixes to 5.1 on its own, which produces the right file for the wrong
    reason: a silent default is indistinguishable from a decision, and only a decision can be
    reported. Both implementations shipped the hollow version first, with the channel count
    sitting unused three lines from the sentence that omitted it.
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

    **A forced track is identified by more than its forced flag.** Sources routinely declare
    forcedness in the track *title* and leave the disposition at zero: a real disc remux of
    *Predator: Badlands* carries `title=BTM FORCED, forced=0`. Trusting the flag alone
    produced an output whose forced track was flagged `default=0 forced=0`, which AVFoundation
    reported as `defaultOption: none` — the film's Yautja dialogue had no track any player
    would auto-enable. **That file has since been repaired by hand** (`MP4Box -kind
    <id>=urn:mpeg:dash:role:2011=forced-subtitle -enable <id>`, one invocation), so the
    delivered file now reads `defaultOption: English Forced` and no longer demonstrates the
    defect. Anyone re-deriving this rule from the library will find the evidence already
    cleaned up; the source MKV still shows the title-only declaration, and that is where to
    look. So the flag is one signal of three, in order: the `forced` disposition; a
    title matching `forced` (or `signs`, `songs & signs`); and, last, **cue density** — a
    forced track runs around 1–2 cues per minute against 12–22 for a full one, which is
    HandBrake's "Foreign Audio Scan" reduced to a number and the only signal available when
    a source offers neither of the others. Density alone promotes nothing on its own; it
    corroborates, and it flags a file for a human to look at.

    **The title signal is language-specific, and must never be the only non-flag signal.**
    *Supergirl* is an Italian-language rip whose English SDH track is titled `NON UDENTI`
    ("not hearing"), with `hearing_impaired=0`. A keyword list reading `forced`/`signs`/`sdh`
    catches that same file's `FORCED` track and misses its SDH one completely — and the mirror
    case is an Italian release labelling forced subtitles `FORZATI`, a French one `FORCÉS`, a
    German `ERZWUNGEN`. A keyword list in one language silently encodes an assumption about who
    pressed the disc, and it fails quietly on the language nobody added.

    For SDH the language-independent signal is **not** cue density. Density needs a sibling
    full track to compare against, and *Supergirl* has none — its only two English text tracks
    are the forced one and the SDH one, which is precisely the shape that defeats it. What
    separates them is the cue *text*: an SDH track carries bracketed sound descriptions and
    speaker labels, a full track carries none at all.

    | track | cues | bracketed |
    |---|---|---|
    | Predator, full | 539 | **0** |
    | Predator, SDH | 1216 | 777 (64%) |
    | Sinners, full | 1848 | **0** |
    | Sinners, SDH | 2377 | 668 (28%) |
    | Supergirl, `NON UDENTI` | 1491 | 610 (41%) |
    | Supergirl, forced | 103 | **0** |

    Confirmed on a fourth film, and on the hardest case — a same-language sibling pair, where
    the two variants differ by dialect rather than by kind. *Across the Spider-Verse* carries
    six English text tracks in three pairs:

    | track | cues | `[` at line start | `[` anywhere | `♪` |
    |---|---|---|---|---|
    | American | 2604 | **0** | 0 | 346 |
    | American / SDH | 3028 | 659 | 713 | 410 |
    | British | 1989 | **0** | 0 | 0 |
    | British / SDH | 2241 | 498 | 745 | 0 |
    | English full | 1993 | **0** | 1 | 0 |
    | English SDH | 2241 | 498 | 745 | 0 |

    And across the whole library, first line after stripping, `[` against `(`:

    | track | cues | `[` | `(` |
    |---|---|---|---|
    | Predator, full | 539 | 0 | 0 |
    | **Predator, SDH** | 1216 | **0** | **707** |
    | Sinners, full | 1848 | 0 | 0 |
    | Sinners, SDH | 2377 | 579 | 0 |
    | Supergirl, forced | 103 | 0 | 0 |
    | Supergirl, `NON UDENTI` | 1491 | 571 | 0 |
    | The Invite, full | 2332 | 0 | 0 |
    | The Invite, SDH | 2401 | 296 | 0 |
    | War Machine, SDH | 1357 | 571 | 0 |

    Two things the rule has to say precisely, both of which this film and no other exposed:

    - **Count `[` and `(` — never `♪`.** The American *full* track carries 346 music-note
      cues, because song lyrics are dialogue and belong in a full track. A rule counting any
      "bracketing" symbol reads that track as 13% marked and misclassifies it, so the note
      stays out.

      `(` was originally excluded on the same reasoning — it measured zero everywhere we had
      looked — and that was wrong, because of where we had looked. Run across every English
      text subtitle track in the library rather than one film's, **`Predator: Badlands` writes
      its entire SDH track in parentheses**: `(WIND WHOOSHING)`, `(CHANTING IN YAUTJA)`, 707
      cues of it and not one square bracket. A `[`-only rule scores that track zero and reads
      it as ordinary subtitles; it classified correctly only because its `hearing_impaired`
      flag happened to be set, which is precisely the crutch this signal exists to replace.
      Measured over 16 tracks in 6 films, every full track scores **zero on both symbols** and
      every SDH track scores high on **exactly one** — so including `(` costs nothing and
      closes a hole that would have swallowed any paren-style release with no flag.
    - **Anchor at line start.** Counted anywhere in the cue, the "English full" track scores
      1 — `It is I, the Armadillo-- [grunts] Oh!`, an inline sound description an author let
      slip into a dialogue track. One cue in 1993 would not misclassify anything under a ratio
      test, but it is the difference between a rule that is absolute and a rule that merely
      has a comfortable margin. Anchored to line start it is zero, and the claim holds
      literally.

    Tighter still, and this is the form to implement: count a cue only when **its first text
    line** opens with `[`, rather than any line of it. Measured across all six of the tracks
    above, full tracks stay at zero and the SDH counts fall — American/SDH 537 against 636
    counted line-wise, British/SDH 495 against 498. The separation is identical and the margin
    is larger, because a full track quoting a bracket on a continuation line can no longer
    reach the count at all.

    **Strip a leading dialogue dash, ASS override or markup tag before testing.** Two
    independent implementations of the strict test disagreed by nine cues on one track, which
    looked like a rounding difference in multi-line handling and was not. The British SDH
    track writes its descriptions as `- [woman] Hey, Gwen.` and `{\an8}[music turns dramatic]`,
    and a test anchored to the literal first character sees **none of them**:

    | track | strict `[` | after stripping `-` / `{…}` / `<…>` |
    |---|---|---|
    | American | 0 | 0 |
    | American / SDH | 537 | 537 |
    | British | 0 | 0 |
    | British / SDH | 495 | **594** |
    | English full | 0 | 0 |
    | English SDH | 495 | **594** |

    American/SDH is unchanged because it doesn't use the convention, which is why one film
    exposed the hole and three others didn't — and why the two implementations *nearly* agreed
    while both missing the same hundred cues. Stripping makes them agree exactly.

    Nothing in this library misclassifies without it; these tracks still score hundreds either
    way. **The hole is a release that uses only that convention** — every description behind a
    dash or an override — which would score zero and read as an ordinary subtitle track. That
    is the exact misclassification the signal exists to prevent, reached through an authoring
    house style rather than through a language, so no title list would have caught it either.

    The obvious risk of stripping the dash was checked before adopting it: a *full* track
    writing `- Are you all right?` before ordinary dialogue does not start scoring. All three
    full tracks stay at zero with stripping on. The separation is untouched and the signal is
    about 20% stronger wherever the convention appears.

    So: **a cue counts when its first text line opens with `[` or `(`, and a full track scores
    zero.**
    No tuned threshold, no sibling track, no word of the title in any language. Brackets are
    structural; only what sits inside them is localised.
20. **Sidecar `.srt` import**, so a language the disc only stored as bitmaps can be restored
    as text. OCR is not acceptable: wrong words on screen are worse than none.

    **Import, never acquisition.** A file placed beside the source is picked up; nothing goes
    looking for one. Fetching subtitles from an online source was considered and declined
    (August 2026) — it adds a network dependency and a correctness risk to a pipeline whose
    whole argument is that every claim it makes is checkable locally.

    The consequence is accepted rather than outstanding: where a disc carried only bitmaps and
    no sidecar is supplied, the file ships with no subtitles. Three in this library do, and it
    would recur on every episode of a series. That was put to the owner with the per-episode
    framing and declined on the grounds that subtitles are not a requirement for this library.
    Verified before accepting, because the one case where subtitles are not optional is
    foreign dialogue in an English film: **none of the three has an English forced track** —
    what they lost is full subtitles, SDH and commentary, so no dialogue goes untranslated.
    A source that *did* declare an English forced track and stored it only as bitmaps would be
    a different question, and should be raised rather than dropped silently.
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
    - **`ffprobe` cannot verify this pass, and will report it as a failure.** It reads the
      track's `mdhd` language, where the variants do not live, so a correctly tagged group
      comes back as N identical `eng` rows. *Across the Spider-Verse* reads six `eng` tracks
      and renders as `English (US)`, `English (US) SDH`, `English (UK)`, `English (UK) SDH`,
      `English`, `English SDH`. Verify through AVFoundation or `MP4Box -info`, never ffprobe.
    - **Assert what the title says and nothing more.** That film's three English pairs are
      titled "American", "British" and "English full". The third takes plain `en`: inventing a
      region collides with the American pair and recreates the duplicate the pass exists to
      remove, and leaving it untagged triggers the partial-group fallback above. The rule that
      picks the right tag here is the same one that keeps `yue` off a Traditional track.
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

    **But a check that deletes its subject must distinguish "the file failed" from "I failed
    to observe it."** Verification here is destructive: a file that does not pass is removed
    rather than left looking importable, which is right — and it means every verifier is one
    harness bug away from destroying hours of good encoding. The failure is not hypothetical.
    A render check built on `AVPlayerItemVideoOutput` reported an episode as never becoming
    `readyToPlay`, **with no error**, which reads exactly like a corrupt output. The file was
    perfect: an `AVPlayerItem` advances its status on the main run loop, and the check polled
    it from a task that only slept, so the loop never turned. Pumping
    `RunLoop.main.run(mode:before:)` explicitly, the same file is ready in four seconds and
    renders at every sample point. Both implementations of this project's verification walked
    into the same trap independently, and the one that reported a bare `doesNotRender("")`
    would have deleted the file on the strength of it.

    So a destructive check states *which* thing failed: "the player never became ready, and
    reported no error" is a different sentence from "no frame arrived in fifteen seconds", and
    the first is almost always the caller. When the two cannot be told apart, the check must
    not delete.

    **The rule has two halves that look nothing alike in code, and point in opposite
    directions.** Count against the *source* rather than arithmetic, so a real observation
    isn't misread; and **pass when the observation itself fails**, so a missing observation
    isn't read at all. A destructive check has to be wrong in the safe direction both times.

    Both halves are live in this project's own `Verification`, and it currently gets one right
    and one wrong in the same file. `checkDolbyVisionProfile` is correct throughout — missing
    tools, an unwritable scratch directory, a tool that returns nothing, JSON that won't parse
    all `return` and pass, and it throws only on a *positive* reading of a profile that isn't
    8. `checkDolbyVisionRPU`, forty lines above it, does the opposite:

    ```swift
    let output = try? await Process.output(of: ffprobe, arguments: [...])
    guard let output, Verification.hasDolbyVisionRPU(in: output) else {
        throw ConversionError.dolbyVisionLost
    }
    ```

    `try?` discards the error and the `guard` then treats "ffprobe produced nothing" and
    "ffprobe produced frames with no RPU in them" as the same event. The first is a failure to
    observe — a killed process, a timeout, a transient read error — and it is reported as
    `dolbyVisionLost`, on which the caller **deletes the file**. A perfect twenty-gigabyte
    Dolby Vision conversion is destroyed because a probe hiccupped, and the error message names
    the wrong culprit so nobody re-runs it. Neither check's doc comment marks its choice as
    deliberate, which is how two opposite behaviours came to sit in one file unremarked.

    A `return` that passes on an unobservable check is not an oversight to be tidied into a
    `throw` later; it is the rule, and it should say so where it sits.

    **The boundary, so this rule isn't applied until the check does nothing.** Delete when the
    failed observation *is* the criterion; pass when it was merely the instrument. ffprobe not
    finding an RPU is instrumental — ffprobe failing to launch says nothing about whether the
    file plays, so it must not delete. But `AVURLAsset.load(.isPlayable, .duration)` throwing
    *is* the criterion: the question being asked is "can AVFoundation use this file", the
    library's own optimizer opens it exactly this way, and a load that fails has answered.
    Those throws stay. Someone reading the rule quickly could make every load in
    `Verification` non-throwing and leave a check that passes everything, which is worse than
    the bug it was fixing — the file survives and the library can't play it.

    **And the exposure is procedural, not per-tool.** A pipeline covers its in-place rewrites
    by ordering — the GPAC `-lang`/`-kind`/`-enable` passes and the accessibility marking pass
    all run before verification, so a mutation that damages the container is caught before the
    file ships. Run *by hand* for a one-off repair, every one of them loses that cover, and so
    will any future tool written for the same purpose. The hole was never in a particular
    tool; it is in hand-running a mutation without the check that follows it in the pipeline.
    A repair tool that cannot roll back must therefore carry its own container check — not
    because the tool is special, but because nothing else is going to look.

    Note also that this ordering is easy to lose: "fail fast, don't verify a file you are about
    to modify" is a plausible-sounding change that would silently remove the only coverage the
    mutations have. Where an invariant is load-bearing by accident, say so at the site.

    An audit of the whole project on this basis found five destructive sites, and only the two
    in `checkDolbyVisionRPU` were wrong. Deleting a half-written output when the *conversion*
    failed is right — it looks importable and isn't. Deleting on cancellation is right — the
    user asked. Throwing `toolsMissing` from `Probe` and `ConversionQueue` is right, and is not
    an exception to any of this: those fire before an output exists, so there is nothing to
    lose, and a plan that can't find ffmpeg should fail early rather than four hours in. This is the morning's write-path/claim-path asymmetry with the roles collapsed
    — here the claim *is* the write, and a wrong claim destroys the artefact it was describing.

## The pipeline that makes it

27. **The cost is known before anything is committed** — route, output size and elapsed time
    estimated from rates this machine has actually achieved, re-derived after each job. A
    29-hour queue is a decision, and nobody can take it from a progress bar starting at 0%.

    A shipped starting rate counts as **zero** observations, so the first real measurement
    replaces it rather than averaging with it, and each rate keeps **its own** sample count so
    a rewrap can't spend the encode rate's one chance to shed the guess. Seeded as one sample,
    a rate measured on a busy machine kept half the weight of the first real job and a third
    of the second: four films came in at 12h57m against a prediction of 22h10m, every one
    wrong in the same direction.
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
33. **A commentary or accessibility track is marked so an Apple player can tell it apart** —
    and there is exactly one way to do it. ffmpeg writes the DASH role box, MP4Box carries it
    through, and ffprobe surfaces it, but **AVFoundation never reads it**: four constructions
    were tried — the `comment` disposition alone, and `MP4Box -kind` with the bare
    characteristic, with Apple's own scheme URI, and with the DASH role — and every one reads
    back as `main-program`.

    What works is AVFoundation writing its own: a `quickTimeUserData` metadata item keyed
    `quickTimeUserDataKeyTaggedCharacteristic`, valued `public.auxiliary-content`, applied
    with `AVMutableMovie.writeHeader(to:fileType:options:.addMovieHeaderToDestination)`.
    Verified independently — the option flips from `main-program` to `auxiliary`, the file
    stays byte-identical in size, GPAC still parses it. Three rules, each learned by breaking
    it: **append to `track.metadata`, never assign** (assigning destroys the track's existing
    name); write it **once** (repeated header passes made AVFoundation stop reporting a track
    altogether); and it patches the header rather than rewriting the file, which makes it the
    cheapest safe modification in this whole document.

    **The same hole swallows SDH, and that is measured, not assumed.** Apple's HLS authoring
    specification (item 4.5) asks for a deaf/hard-of-hearing track to carry
    `public.accessibility.transcribes-spoken-dialog` and
    `public.accessibility.describes-music-and-sound`. ffmpeg writes its nearest equivalent —
    the DASH role `caption`, from `AV_DISPOSITION_HEARING_IMPAIRED|CAPTIONS` — and a finished
    file's SDH track still reports **no accessibility characteristics whatsoever** to
    AVFoundation: probed on a real output, every legible option came back
    `main-program-content` and nothing else. So an SDH track is indistinguishable from an
    ordinary subtitle track on the platform the file is made for, and the remedy is the
    tagged characteristic above rather than another role box.

    **Verified, on real Dolby Vision output rather than in principle.** Appending
    `tagc` items carrying the two accessibility strings makes AVFoundation report the option
    as `transcribes-spoken-dialog, describes-music-and-sound, main-program-content` — and it
    renames the option itself, so a picker that showed two identical "English" entries now
    reads "English" and "English SDH". Three things learned doing it, none of them guessable:

    - **`writeHeader` returns `-11800` / `-16430` on a GPAC-muxed file and patches it
      correctly anyway.** An ffmpeg-muxed file returns cleanly; only the Dolby Vision route's
      output errors. Trusting the return code would reject a good file, so the write must be
      followed by re-reading the finished file through `loadMediaSelectionGroup` — the
      outcome decides, never the status.
    - **AVFoundation rewrites the whole `moov`, it does not append to it.** The header came
      back 39 bytes *smaller*, the gap padded with a `free` box, `mdat` untouched at its
      original offset. `dvvC`, `hvc1`, every disposition, the `kind` boxes and the track names
      all survived; the single casualty was GPAC's own `©too` writing-tool string. A forced
      track flagged earlier with `MP4Box -kind` still read back as the default option
      afterwards, which is the interaction that actually had to be checked.
    - It is genuinely cheap: `mdat` is never touched, so an 11 GB file is patched in about a
      second.
    - **The dropped `©too` is a free audit trail.** Because AVFoundation regenerates the moov
      without GPAC's or ffmpeg's writing-tool string, `ffprobe -show_entries format_tags=encoder`
      distinguishes a marked file from an unmarked one for one cheap call, with no `udta`
      parsing — across this library the five files that went through the pass report nothing
      and the three that didn't still report `GPAC-26.02-revrelease` or `Lavf62.12.102`. Given
      that `tagc` does not round-trip through `track.metadata`, this is the most practical
      idempotency signal available. It is evidence, not proof: anything else that rewrites the
      header erases it too, so it answers "has this been touched" rather than "has this been
      marked".

    The consequence worth stating plainly: **a converter built only on ffmpeg and GPAC cannot
    satisfy this point.** An app on Apple's own frameworks can. Preserving the role box (16)
    remains the converter's duty regardless — it is the record of *which* track is which, and
    without it there is nothing for the marking pass to act on.

    Why it matters beyond a label: two audio options identical in name, locale and
    characteristics are indistinguishable to AVKit's own control, which appears to collapse
    them — a film with a main mix and a commentary in the same language shows neither in
    Apple's chrome. Marking one makes them different.

## The failure this document exists to catch

Points 13 and 27 were both learned by breaking them, and they broke the same way: **a number
applied where it wasn't measured.** The audio note declared a codec change while the channel
count sat unused three lines away; the estimates averaged against a seeded guess as though it
were an observation. Neither announced itself, because in both cases the output is merely
wrong rather than broken — a file that plays, an estimate that is only pessimistic. A rule
that says what a stage must *report* is worth little unless the same value it reports is the
one it was told to *use*.

The same reasoning reaches past either point: **a default is the part of a toolchain that
changes without telling you.** Relying on ffmpeg to downmix 7.1 a particular way is depending
on a decision someone else can revise in a point release, silently, in a direction nobody here
tests for. Stating the value converts an assumption into a claim, and claims can be checked —
which is the argument for reading the RPU rather than the `dvvC` box, and for counting frames
rather than trusting a warning that only fires one way.

**Count frames against the source, never against arithmetic.** A converted episode carried
116,881 frames while its own stated duration and frame rate predict 116,882.8 — one short, and
entirely ordinary: a container's duration and the last frame's presentation interval do not
have to agree to the frame. Checking a count against `duration x rate` therefore raises a false
alarm on a correct file, and on a destructive verifier that is the expensive kind of wrong.
Source count against output count is the comparison that carries information; the arithmetic is
a sanity check that is allowed to be off by one.

**It has a sibling, found while writing this document rather than while converting: a
conclusion drawn wider than the query that produced it.** A filter is chosen for a good
reason, the query answers exactly what it was asked, and by the time the sentence is written
the filter has been forgotten — so a result about *some* files is reported as a fact about
*all* of them. It went wrong six times in a single day across both implementations:

- A forced-subtitle sweep filtered to `language=eng`, reported as "no other source in the
  library declares forcedness by any signal". Twelve title-only forced tracks across five
  other films say otherwise; they are all non-English, which is why the filter was reasonable
  and why the sentence was not.
- A writing-tool audit hand-listed its files instead of globbing the directory; the file that
  fell off the list was then reported as evidence of a clean result.
- A count of SDH tracks taken from the *sources* and reported as a gap in the *outputs* — 8 of
  9 against an actual 4 of 8, because several of those films ended up with no text subtitles at
  all.
- Two subtitle tracks with identical cue counts called duplicates; their hashes differ.
- `ffprobe`'s disposition fields read positionally in the order they were *requested*, which is
  not the order it emits, so every column was mislabelled and a correct file looked wrong.
- A decode check that reported `DECODE FAILED` on three good files because the value it
  grepped for was not on the line it read.

A seventh has a different mechanism and is worth separating: **a pending result reported as a
finished one.** A frame-parity count was still running in the background when its result was
written up as "completed and agrees" and sent to both the user and the other implementation.
The number was right when it did arrive — 116,881 against 116,881 — which is luck rather than
verification, and it happened in the same message that argued for making failure states
legible. The others claimed more than the query could see; this one claimed the query had
answered.

The last three of the six above are the same error wearing a different hat: **the query was
believed instead of the thing it was querying.** All six survive review for the same reason as the numbers above —
the output reads fluently and looks complete. The habit that catches them is not more care but
a different sentence: state the finding *with the query attached*, so "no film declares
forcedness" is written as "no film whose subtitle language is `eng` declares forcedness", where
the missing scope is visible on the page instead of only in the shell history.

**And the tidy summary is a claim too.** The day these were catalogued closed with "seven
errors from me, seven from you" — invented, never counted, reached for because the symmetry
made a satisfying final sentence. It differs from every case above in having no ground truth to
skip measuring: it was a claim about the authors rather than about the files. Nobody expects a
summary sentence to be a factual claim, including whoever is writing it, which is what makes it
the easiest of the lot.

What did work is worth stating exactly, because the obvious paraphrase overshoots.
**Nothing here was found by re-reading one's own work unprompted.** Self-audit found plenty —
the second conflation twelve lines above the first, the five deletion sites, the boundary that
keeps this rule from gutting the verifier — but every one of those audits was *started* by
something the other implementation had written for its own reasons. The rule travelled; the
instance was local. So the practice to keep is not "review your own code more carefully" but
"walk someone else's rule through your own code", and the corollary: write the rule down where
the other side can read it, because that is what causes the looking.

**An eighth, and the only one that reached the document: an unstated premise.** The rule
counted `[` and excluded `(`, on the grounds that `(` "was zero everywhere we looked" — which
was true, and which quietly became "it isn't there". Nobody had measured Predator's SDH track,
which is written entirely in parentheses. Two things make this shape distinct from the seven
above:

- **It sat in the half of the rule that felt most examined.** Three separate refinements —
  excluding `♪`, anchoring to line start, stripping leading markers — each made the bracket
  test feel more scrutinised without once testing which bracket. Attention on a neighbourhood
  reads as attention on the thing.
- **It survived every control that had worked all day.** Re-running the other side's query,
  chasing a discrepancy, walking a rule through foreign code, refusing a framing — all four
  operate on something one of us *said*, and nobody ever said "Predator's SDH uses square
  brackets". It was assumed by the shape of the rule, silently, and **an assumption nobody
  utters cannot be refused.**

Which gives the fifth and last control, and the only one that catches this: **run the rule
against real data.** Re-running a query catches a wrong claim; chasing a discrepancy catches a
wrong measurement; walking a rule through unfamiliar code catches an unclaimed bug; refusing a
framing catches a wrong conclusion; and running against real files catches an unstated premise.
Thirty-eight passing unit tests did not, because the fixtures were written by the same people
holding the assumption. Sixteen real subtitle tracks did, immediately.

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
