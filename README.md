# Cinema

Cinema is a personal video library app for iOS, iPadOS, and visionOS. Import your own local video files and Cinema builds a real library around them — automatically generated poster art, resumable playback, and editable metadata — all stored on-device.

## Features

- **Add your own videos.** Pick one or several video files at once from Files; Cinema copies them into the app's own storage so they stay available across launches. Imports run in the background, so the app stays responsive even for large files.
- **Automatic poster art.** A representative frame is extracted from each video, skipping black opens and logo fades in favor of an actually-representative shot.
- **Continue Watching.** Playback position is tracked automatically. Partially watched videos show a progress bar and resume right where you left off.
- **Editable metadata.** Fix up a title, write a synopsis, set the year and content rating, and tag genres after import.
- **Search.** Find videos by title or genre from the dedicated Search tab.
- **A real profile.** Set a name and photo from Settings.
- **Native multiplatform UI.** Tab navigation and window customization built with SwiftUI, tailored to each platform.
- **visionOS immersive environment.** Play video inside a custom Reality Composer Pro environment.

## Architecture notes

- Persistence uses SwiftData with a versioned schema (`CinemaSchema.swift`) and an explicit migration plan — schema changes must add a new version and a migration stage, never mutate an old one.
- Media files live in the app's Application Support container, addressed only by filename through `MediaStore` — container-relative paths survive reinstalls.
- Import runs through `VideoImporter`, off the main actor; views never touch the filesystem directly.

## Background

Cinema is built on top of Apple's "Destination Video" sample project. For background on the architecture this evolved from, see
[Destination Video](https://developer.apple.com/documentation/visionos/destination-video) in Apple's developer documentation.
