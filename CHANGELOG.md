# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.1] - 2026-08-15

First working release of Cinema, rebranded from Apple's "Destination Video" sample into a personal video library app.

### Added
- Renamed the project, bundle identifier, and all branding from Apple's sample to Cinema; bumped deployment targets to OS 26 across iOS, iPadOS, macOS, tvOS, and visionOS.
- Add videos from Files, including picking several at once.
- Automatic poster thumbnail generation from each video's own footage, avoiding black or blank opening frames.
- Real video duration extraction on import.
- Continue Watching: playback position is saved automatically, partially watched videos show a progress bar and a "Continue Watching" row, and playback resumes from where it left off.
- Edit a video's title, synopsis, year, content rating, and genres after import.
- Delete a video, including its imported file and generated thumbnail.
- Editable profile (name and photo).
- A Settings screen: profile, library management (including clearing the library), and app/version info.
- Empty states across every tab.
- Standard community health files (contributing guide, code of conduct, security policy, issue and pull request templates).

### Removed
- Apple's original sample video catalog and placeholder artwork.

### Fixed
- Locally imported videos now keep working after an app reinstall — their file paths no longer broke when the app's sandbox container changed.
