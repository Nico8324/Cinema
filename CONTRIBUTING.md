# Contributing to Cinema

Thanks for taking an interest in Cinema. This is a small, personally maintained project, so please keep that in mind when it comes to response times.

## Before you start

Cinema is built on top of Apple's "Destination Video" sample code and is subject to the terms in [LICENSE.txt](LICENSE.txt). By contributing, you agree that your changes may be distributed under those same terms.

## Reporting bugs

Search [existing issues](../../issues) first. If you don't find one, open a new issue using the bug report template and include:

- What you expected to happen vs. what actually happened
- Steps to reproduce
- Device/OS/Xcode version
- Screenshots or logs, if relevant

## Suggesting features

Open an issue using the feature request template. Describe the problem you're trying to solve, not just the solution — it makes it easier to evaluate alternatives.

## Submitting changes

1. Fork the repo and create a branch off `main`.
2. Make your changes, keeping them focused and scoped to a single concern.
3. Build and test locally in Xcode before opening a PR.
4. Open a pull request against `main` describing what changed and why.

## Code style

- Follow the conventions already used in the surrounding file (SwiftUI/Swift API design guidelines).
- Prefer small, readable diffs over large refactors bundled with feature work.
- Don't add abstractions or configuration for hypothetical future needs.

## Versioning

Cinema follows [Semantic Versioning](https://semver.org/) (`MAJOR.MINOR.PATCH`) and is currently in initial development (`0.x.y`):

- **Patch** (`0.0.x`): Bug fixes, stability, and polish. Nothing new to do — just fixing or smoothing out what's already there.
- **Minor** (`0.x.0`): A new feature lands, even if the app as a whole is still rough. Anything that expands what Cinema can actually do.
- **Major** (`1.0.0`): Reserved for the first release considered complete and reliable enough for regular daily use — the core loop (add, browse, watch, resume, edit, delete a video) works end-to-end with no known rough edges. Past `1.0.0`, further major bumps are reserved for changes big enough to break compatibility with existing data or expectations (for example, a data model change that requires resetting the library).

When cutting a release: bump `MARKETING_VERSION` in `Cinema.xcodeproj/project.pbxproj` (both Debug and Release configs), add a dated entry to [CHANGELOG.md](CHANGELOG.md), then tag (`git tag -a vX.Y.Z`) and publish a GitHub Release from that tag using the changelog entry as its notes.

## Development setup

This is a multiplatform SwiftUI app (iOS, iPadOS, macOS, tvOS, and visionOS). Open `Cinema.xcodeproj` in a recent version of Xcode, pick a target/scheme, and build.
