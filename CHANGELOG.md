# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- The detail page's artwork now reaches the very top of the screen on every iPhone: the poster was pulled up by a hardcoded offset that came up short on newer devices, leaving a background strip above it (invisible in dark mode, obvious in light). The offset is now the measured safe-area inset.
- Light mode. The app now follows your device's light/dark setting, with an Appearance choice in Settings (Automatic, Light, Dark). The cinematic surfaces adapt like the TV app: poster scrims and page blends fade into white in light mode and into black in dark mode — the dark look is pixel-identical to before. Fixed along the way: the zoom-transition backing boxed Library movie cards in a black slab in light mode and hid their titles, and the hero's buttons washed out over light scrims.
- A Movies / TV Shows switcher in the Library, in the toolbar next to the add button, combining with the genre pills. A side with nothing to show gets a clear empty state instead of a blank grid.
- Refresh Metadata in Settings: one tap re-downloads titles, synopses, ratings, genres, trailers, and artwork from The Movie Database for every matched movie and show — with live progress and a summary of how many titles were updated. Unmatched entries are left alone; individual failures skip that title and keep going.

## [0.3.0] - 2026-08-15

The TV shows update: episodes, show pages, TMDB TV metadata, and full movie/TV parity across every surface.

### Added
- TV shows, first milestone: files named like "Silo S02E04" import as episodes. The Library groups a show's episodes into one card with an episode-count badge; a show page lists episodes by season with thumbnails, durations, and watch progress; episode titles read "Show S1, E2" across Watch Now and search; Continue Watching works per episode. Stored in schema V4 (lightweight migration).
- TMDB TV matching, completing the shows milestone: "Match Show" on a show page searches TMDB's TV catalog and applies the official title, genres, rating, show trailer, and — per episode — real titles, overviews, air years, and still artwork. The show page then reads like the TV app: first-aired/seasons/rating/score facts, genre pills, overview, inline trailer, and a Cast & Crew row built from aggregate credits; episode rows become "3. The Engineer" with TMDB stills. Episode detail pages lead with the episode title under a show-name caption and say "Play Episode". Stored in schema V5 (lightweight migration). A show's internal grouping key never changes when matched, so open pages and navigation stay stable while the display name switches to the official one.
- Actor pages now include TV credits: the filmography mixes movies and shows in one list, newest first, with titles from your library still sorted to the top and badged. A show you own opens your library's show page, episodes ready to play; other shows open their TMDB page with facts, trailer, and cast — completing the movie/TV parity across every surface.
- A TV shows discovery row on Watch Now, exactly like the movies one: fed by your choice of TMDB TV list in Settings — Airing Today, On the Air, Popular Shows (default), Top Rated Shows, or Trending Shows — locale-aware. Tapping a poster opens a show sheet with backdrop, first-aired/seasons/rating/score facts, genres, overview, the official trailer inline, and Cast & Crew; a show already in your library opens your own show page instead, episodes ready to play. Settings now has separate Movies Row and Shows Row pickers.

### Fixed
- Movie metadata now applies genres in your language: the movie details request skipped the language parameter, so a French device got English genre pills from movie matches but French ones from TV matches.

## [0.2.0] - 2026-08-15

The discovery update: a TMDB-powered browsing layer woven into the library, plus a hardened import pipeline with tests and CI.

### Fixed
- Importing large movies no longer gets the app killed by the platform memory limit: the chunked copy accumulated every chunk in an undrained autorelease pool, so a multi-gigabyte import ballooned memory until visionOS terminated the app (found on Vision Pro, `EXC_RESOURCE` at the 5GB limit; verified fixed on hardware with a 20GB import). The copy loop now drains a pool per chunk.

### Added
- Cast members are tappable everywhere they appear: a person's page shows their portrait, biography, and full filmography — with movies already in your library sorted first and badged. Owned movies open your library's own page, ready to play (the sheet hands the screen to the player); the rest open their TMDB page with trailer and cast. The discovery row does the same when it shows a movie you own.
- Cast & Crew and Information in the TV-app style — on the detail page for TMDB-matched videos and on the discovery sheet: a scrolling row of cast and key crew with photos and roles, plus released year, runtime, rating, and TMDB score. Fetched live per visit — nothing new stored.
- A discovery row on Watch Now, fed by your choice of TMDB list in Settings: In Theatres (default), Coming Soon, Popular, Top Rated, or Trending This Week — locale- and region-aware. Tapping a poster opens a detail sheet with the backdrop, overview, and the official trailer playing inline — pre-buffered like the library's trailers.
- Duplicate detection on import: files whose content is already in the library (same size and leading hash) are skipped with an "Already in your library" notice instead of silently doubling disk usage.
- Startup reconciliation: orphaned media files (copied but never registered, e.g. after a crash mid-import) and library entries whose backing file vanished are swept once per launch.
- A unit test suite (schema migration V1→V3 against a real store file, import pipeline including duplicates, reconciliation, YouTube URL parsing, TMDB matching, model heuristics) and a GitHub Actions CI workflow building iOS + visionOS and running the tests on every push.

## [0.1.0] - 2026-08-15

Foundation overhaul following a full architecture and Apple-guidelines review, plus YouTube, TMDB, and trailer integrations.

### Changed
- Focused the app on iOS, iPadOS, and visionOS. tvOS and macOS are no longer built — tvOS has no Files app to import from, and both targets had stopped compiling; they can return with a dedicated ingestion path.
- Persistence now uses a versioned SwiftData schema with an explicit V1→V2 migration plan. Existing libraries migrate in place.
- Videos are identified by UUID instead of hand-incremented integers, and imported files are referenced by an explicit stored filename instead of a filename smuggled through a URL's host component.
- The import pipeline moved out of the Library view into `VideoImporter` and runs off the main actor — the UI no longer freezes while multi-gigabyte files copy.
- Poster thumbnails load asynchronously with an in-memory cache instead of decoding JPEGs from disk on every scroll frame.
- The profile photo is stored as a downscaled JPEG file instead of raw bytes in UserDefaults.
- Playback progress saves now go through the shared main-actor model context (previously they saved a context that never held the changes and only worked by autosave accident).
- Durations display as "1h 32m" instead of "92:00", with matching VoiceOver phrasing.
- iPhone now supports landscape orientation — required for a video app; iPad multitasking is no longer opted out via `UIRequiresFullScreen`.
- Localization reduced to English until real translations exist (the previous catalog translated Apple's sample strings but none of Cinema's actual UI).

### Added
- Trailers: matching a video against TMDB now also finds its official YouTube trailer. A "Trailer" card on the detail page (both iOS and visionOS) plays it inline, in place, with system controls — and on iPhone, rotating to landscape expands it to full screen and rotating back returns it inline, without interrupting playback. The trailer prepares in the background as soon as the detail page opens (stream resolved, player buffering), so tapping play starts instantly. Streams resolve through the YouTube resolver with the same automatic retry as the main player. Replaces the old visionOS-only "Extras" section, which just played the movie itself. Stored in a new schema version (V3) with a lightweight migration.
- Match metadata from The Movie Database: a "Match Metadata" action on each video searches TMDB (locale-aware) and applies the official title, synopsis, release year, US certification, genres, and the movie's landscape backdrop as the poster. The API key lives in a gitignored `Secrets.swift` (see `Secrets.swift.example`).
- Add videos from YouTube: paste a watch/share link and the video joins the library with its real title, description, duration, and a generated poster. Playback resolves a fresh stream at play time (YouTube stream URLs expire), with one automatic retry on a bad stream; nothing is downloaded to disk. Powered by the YouTubeKit package. Note: stream extraction is against YouTube's terms of service — this feature is for personal builds and would need removal for App Store submission.
- Import progress: the Library's add button becomes an App Store-style progress ring while files copy, with real byte-level progress (imports now copy in chunks, and failed copies clean up their partial files).
- A working Search tab (title and genre).
- A designed poster placeholder for videos without a generated thumbnail.
- A privacy manifest (`PrivacyInfo.xcprivacy`) and App Store compliance keys (encryption exemption, app category).
- Launch recovery: if the library store can't be opened, it's moved aside and the app starts with a fresh library instead of crashing (imported files remain on disk).

### Removed
- The last of Apple's sample scaffolding: the empty Category/collections system, Person/cast models, sample importer, placeholder New/Favorites tabs, sample poster assets, sample translations, and the sample xcconfig wiring.
- SharePlay/GroupActivities (inherited from the sample) — it could never work for local files: remote participants received only a local database ID and no media.
- Release-blocking build settings (`ONLY_ACTIVE_ARCH` in Release, a hard-coded development signing identity) and unused entitlements.

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
