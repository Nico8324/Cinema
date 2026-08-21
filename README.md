# Cinema

Cinema is a personal video library app for iOS, iPadOS, macOS, tvOS, and visionOS. Import your own local video files and Cinema builds a real library around them — automatically generated poster art, resumable playback, and editable metadata — all stored on-device.

## Features

- **Add your own videos.** Pick one or several video files at once from Files; Cinema copies them into the app's own storage so they stay available across launches. Imports run in the background, so the app stays responsive even for large files.
- **Automatic poster art.** A representative frame is extracted from each video, skipping black opens and logo fades in favor of an actually-representative shot.
- **Continue Watching.** Playback position is tracked automatically. Partially watched videos show a progress bar and resume right where you left off.
- **Editable metadata.** Fix up a title, write a synopsis, set the year and content rating, and tag genres after import.
- **Search.** Find videos by title or genre from the dedicated Search tab.
- **A real profile.** Set a name and photo from Settings.
- **Native multiplatform UI.** Tab navigation and window customization built with SwiftUI, tailored to each platform.
- **Conversion on the Mac.** MKV and other formats Apple's frameworks can't open are converted to MP4 beside the originals, keeping Dolby Vision, cropping letterbox bars where the studio declared them, and verifying the result before keeping it. The queue plans everything first — time, size, and what each film would lose.
- **Subtitles that know what they are.** Forced and deaf-and-hard-of-hearing tracks are identified by reading their cues, not by trusting flags a disc rip often omits or titles written in whatever language pressed the disc. SDH tracks are then marked so Apple's own players name them, turning two identical "English" entries into "English" and "English SDH".
- **visionOS immersive environments.** Play video inside the Studio, or in the Theater — a recreation of the Apple TV app's Cinema with six selectable seats across floor and balcony, where the room's ribbed ceiling and floor are lit by the picture itself.

## Architecture notes

- Persistence uses SwiftData with a versioned schema (`CinemaSchema.swift`) and an explicit migration plan — schema changes must add a new version and a migration stage, never mutate an old one.
- Media files live in the app's Application Support container, addressed only by filename through `MediaStore` — container-relative paths survive reinstalls.
- Import runs through `VideoImporter`, off the main actor; views never touch the filesystem directly.

## Background

Cinema is built on top of Apple's "Destination Video" sample project. For background on the architecture this evolved from, see
[Destination Video](https://developer.apple.com/documentation/visionos/destination-video) in Apple's developer documentation.
