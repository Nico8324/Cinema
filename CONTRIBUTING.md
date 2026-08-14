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

## Development setup

This is a multiplatform SwiftUI app (iOS, iPadOS, macOS, tvOS, and visionOS). Open `Cinema.xcodeproj` in a recent version of Xcode, pick a target/scheme, and build.
