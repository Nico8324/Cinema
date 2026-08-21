/*
See the LICENSE.txt file for licensing information.

Abstract:
A model object that manages the playback of video.
*/

import AVKit
import SwiftData

/// The presentation modes the player supports.
enum Presentation {
    /// Presents the player as a child of a parent user interface.
    case inline
    /// Presents the player in full-window exclusive mode.
    case fullWindow
}

/// A model object that manages the playback of video.
@MainActor @Observable class PlayerModel {

    /// A Boolean value that indicates whether playback is currently active.
    private(set) var isPlaying = false

    /// The presentation in which to display the current media.
    private(set) var presentation: Presentation = .inline

    /// The currently loaded video.
    private(set) var currentItem: Video? = nil

    /// A Boolean value that indicates whether the player should propose playing the next video in the Up Next list.
    private(set) var shouldProposeNextVideo = false

    /// A Boolean value that indicates whether the video is currently playing in a Picture in Picture window.
    ///
    /// Picture in Picture outlives the app's own player UI — dismissing that UI is precisely what
    /// hands the video to the floating window — so this flag marks the window as playback's owner
    /// and keeps `reset()` from tearing down a player that's still on screen.
    private(set) var isPictureInPictureActive = false

    /// Whether AVKit asked the app to restore its player interface as Picture in Picture ends.
    ///
    /// The restore callback arrives *before* the did-stop callback, which is what lets the latter
    /// tell "the person tapped return-to-app" apart from "the person closed the floating window."
    private var isRestoringFromPictureInPicture = false

    /// An object that manages the playback of a video's media.
    private var player: AVPlayer

    /// The currently presented platform-specific video player user interface.
    ///
    /// On iOS, tvOS, and visionOS, the app uses `AVPlayerViewController` to present the video player user interface.
    /// The life cycle of an `AVPlayerViewController` object is different than a typical view controller. In addition
    /// to displaying the video player UI within your app, the view controller also manages the presentation of the media
    /// outside your app's UI such as when using AirPlay, Picture in Picture, or docked full window. To ensure the view
    /// controller instance is preserved in these cases, the app stores a reference to it here
    /// as an environment-scoped object.
    ///
    /// Call the `makePlayerUI()` method to set this value.
    private var playerUI: AnyObject? = nil
    private var playerUIDelegate: AnyObject? = nil

    private(set) var shouldAutoPlay = true

    /// A token for periodic observation of the video player's time.
    private var timeObserver: Any? = nil

    /// Long-lived notification-observation loops, retained so they can be cancelled on teardown.
    private var observationTasks: [Task<Void, Never>] = []

    /// The in-flight stream resolution for a YouTube item, cancelled when a new
    /// video loads or the player resets.
    private var streamResolutionTask: Task<Void, Never>?

    /// Observes the current player item for load failures.
    private var itemStatusObservation: NSKeyValueObservation?

    /// Remaining automatic retries for the current YouTube item. Extraction
    /// occasionally produces URLs YouTube then refuses (HTTP 403); fresh
    /// re-extractions usually fix it.
    private var youTubeRetriesLeft = 2

    /// Whether the app has already performed its one-time resume/start-time seek for the currently loaded item.
    /// Without this guard, the `timeControlStatus` observer below would re-seek on every play/pause toggle.
    private var hasSeekedForCurrentItem = false

    /// The playback time last saved to the current video's `playbackPosition`, used to throttle writes.
    private var lastSavedPlaybackTime: TimeInterval = 0

    /// The main-actor model context shared with the app's views. Using the same context the
    /// views mutate keeps every write-and-save pair in one place — a private context here
    /// would silently save the wrong one.
    private let modelContext: ModelContext

    private var playerObservationToken: NSKeyValueObservation?

    init(modelContainer: ModelContainer) {
        self.modelContext = modelContainer.mainContext
        self.player = AVPlayer()

        observePlayback()
        configureAudioSession()
    }

    // Runs on the main actor so it can tear down isolated observation state.
    isolated deinit {
        playerObservationToken?.invalidate()
        for task in observationTasks {
            task.cancel()
        }
    }

    #if os(macOS)
    /// Creates a new player view object.
    /// - Returns: a configured player view.
    func makePlayerUI() -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = player

        // Set the model state
        playerUI = playerView
        playerUIDelegate = nil

        return playerView
    }
    #else
    /// Creates a new player view controller object.
    /// - Returns: a configured player view controller.
    func makePlayerUI() -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        playerUI = controller

        let delegate = PlayerUIDelegate(model: self)
        controller.delegate = delegate
        playerUIDelegate = delegate

        return controller
    }
    #endif

    // MARK: - Picture in Picture

    /// Hands playback to the floating window and dismisses the app's own player.
    ///
    /// Without the dismissal the person is left on AVKit's "playing in Picture in Picture"
    /// placeholder, which carries no controls — so the library stays unreachable for as long as
    /// the video plays, defeating the one thing Picture in Picture is for.
    fileprivate func pictureInPictureWillStart() {
        isPictureInPictureActive = true
        // A restore that was interrupted before its did-stop callback would otherwise leave this
        // set, and the next close of the floating window would skip its teardown entirely.
        isRestoringFromPictureInPicture = false
        presentation = .inline
    }

    /// Restores full-window playback when the person taps return-to-app on the floating window.
    fileprivate func restoreUserInterfaceForPictureInPictureStop() {
        isRestoringFromPictureInPicture = true
        presentation = .fullWindow
    }

    /// Releases the floating window's claim on playback.
    ///
    /// Closing the window ends playback outright, so the model tears down; returning to the app
    /// doesn't, because `restoreUserInterfaceForPictureInPictureStop()` already put the player
    /// back on screen.
    fileprivate func pictureInPictureDidStop() {
        isPictureInPictureActive = false
        if isRestoringFromPictureInPicture {
            isRestoringFromPictureInPicture = false
        } else {
            reset()
        }
    }

    private func observePlayback() {
        // Return early if the model calls this more than once.
        guard playerObservationToken == nil else { return }

        // Observe the time control status to determine whether playback is active.
        playerObservationToken = player.observe(\.timeControlStatus) { observed, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = observed.timeControlStatus == .playing
                self.performOneTimeSeekIfNeeded()
            }
        }

        let center = NotificationCenter.default

        // Observe this notification to identify when a video plays to its end.
        observationTasks.append(Task { [weak self] in
            for await notification in center.notifications(named: .AVPlayerItemDidPlayToEndTime) {
                guard let self else { return }
                // Only this player's own item counts. The notification fires for every
                // AVPlayerItem in the process — including the trailer player's — and a trailer
                // finishing must not clear the loaded movie's resume point.
                guard let item = notification.object as? AVPlayerItem,
                      item === self.player.currentItem else { continue }
                // A finished video has nothing left to "continue watching" — clear its saved position.
                self.currentItem?.playbackPosition = 0
                self.modelContext.saveReportingErrors()
            }
        })

        #if !os(macOS)
        // Observe audio session interruptions.
        observationTasks.append(Task { [weak self] in
            for await notification in center.notifications(named: AVAudioSession.interruptionNotification) {
                guard let self else { return }
                guard let result = InterruptionResult(notification) else { continue }
                // Resume playback, if appropriate.
                if result.type == .ended && result.options == .shouldResume {
                    self.player.play()
                }
            }
        })
        #endif

        // Add an observer of the player object's current time. The app observes
        // the player's current time to determine when to propose playing the next
        // video in the Up Next list.
        addTimeObserver()
    }

    /// Configures the audio session for video playback.
    private func configureAudioSession() {
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        do {
            // Configure the audio session for playback. Set the `moviePlayback` mode
            // to reduce the audio's dynamic range to help normalize audio levels.
            try session.setCategory(.playback, mode: .moviePlayback)
        } catch {
            logger.error("Unable to configure audio session: \(error.localizedDescription)")
        }
        #endif
    }

    /// Loads a video for playback in the requested presentation.
    /// - Parameters:
    ///   - video: The video to load for playback.
    ///   - presentation: The style in which to present the player.
    ///   - autoplay: A Boolean value that indicates whether to automatically play the content when presented.
    func loadVideo(_ video: Video, presentation: Presentation = .inline, autoplay: Bool = true) {
        // Update the model state for the request.
        currentItem = video
        shouldAutoPlay = autoplay
        youTubeRetriesLeft = 2

        streamResolutionTask?.cancel()
        if video.isYouTubeVideo {
            // YouTube stream URLs expire, so a fresh one is resolved for every playback.
            // The player presents immediately and shows its loading state meanwhile.
            streamResolutionTask = Task {
                await loadYouTubeItem(for: video)
            }
        } else {
            replaceCurrentItem(with: video, url: video.mediaURL)
        }

        // In visionOS, configure the spatial experience for either .inline or .fullWindow playback.
        configureAudioExperience(for: presentation)

        // Set the presentation, which typically presents the player full window.
        self.presentation = presentation
   }

    /// Resolves a fresh stream URL for a YouTube entry and starts playback with it.
    private func loadYouTubeItem(for video: Video) async {
        do {
            guard let remoteURL = video.remoteURL,
                  let videoID = YouTubeSource.videoID(from: remoteURL),
                  let streamURL = try await YouTubeSource.streamURL(forVideoID: videoID) else {
                logger.error("No playable YouTube stream found for \(video.name).")
                if currentItem === video { reset() }
                return
            }
            // The user may have loaded something else while the stream resolved.
            guard !Task.isCancelled, currentItem === video else { return }
            replaceCurrentItem(with: video, url: streamURL)
            // The presentation's onAppear autoplay fired before the item existed, so play here.
            if shouldAutoPlay {
                player.play()
            }
        } catch {
            logger.error("Couldn't resolve a YouTube stream for \(video.name): \(error.localizedDescription)")
            // Close the player rather than leaving an eternal loading spinner.
            if currentItem === video { reset() }
        }
    }

    private func replaceCurrentItem(with video: Video, url: URL?) {
        guard let url else {
            logger.error("\(video.name) has no playable media.")
            return
        }
        // Create a new player item and set it as the player's current item.
        let playerItem = AVPlayerItem(url: url)
        // Set external metadata on the player item for the current video.
        #if !os(macOS)
        playerItem.externalMetadata = createMetadataItems(for: video)
        #endif
        // Reset per-item playback bookkeeping so the resume seek and progress-save throttle start fresh.
        hasSeekedForCurrentItem = false
        lastSavedPlaybackTime = 0
        // Watch for the item failing to load, to drive the YouTube retry.
        itemStatusObservation = playerItem.observe(\.status) { item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in
                self?.handlePlaybackFailure(error: item.error)
            }
        }
        // Set the new player item as current, and begin loading its data.
        player.replaceCurrentItem(with: playerItem)
        logger.debug("🍿 \(video.name) enqueued for playback.")
    }

    /// Handles a player item that failed to load. YouTube items get one automatic
    /// retry with a freshly extracted stream URL; anything else closes the player
    /// rather than leaving a dead error state on screen.
    private func handlePlaybackFailure(error: Error?) {
        guard let video = currentItem else { return }
        logger.error("Playback failed for \(video.name): \(error?.localizedDescription ?? "unknown error")")

        if video.isYouTubeVideo, youTubeRetriesLeft > 0 {
            youTubeRetriesLeft -= 1
            streamResolutionTask?.cancel()
            streamResolutionTask = Task {
                await loadYouTubeItem(for: video)
            }
        } else {
            reset()
        }
    }

    /// Seeks to a saved "Continue Watching" position exactly once per loaded item.
    /// Only runs once because `timeControlStatus` can change repeatedly (play/pause/buffering) for one item,
    /// and re-seeking on every change would fight a person scrubbing through the video.
    private func performOneTimeSeekIfNeeded() {
        guard !hasSeekedForCurrentItem, let video = currentItem else { return }
        // Latch on the first status change whether or not a seek happens. A video started
        // fresh has nothing to resume, but leaving the guard unlatched meant that once the
        // periodic saver pushed its position past the partially-watched threshold, the next
        // pause or stall would "resume" it backwards to the last saved position.
        hasSeekedForCurrentItem = true
        if video.isPartiallyWatched {
            player.seek(to: CMTime(seconds: video.playbackPosition, preferredTimescale: 600))
        }
    }

    /// Saves the player's current time as the video's playback position, for "Continue Watching" to resume from later.
    private func saveCurrentProgress() {
        guard let currentItem else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds >= 0 else { return }
        lastSavedPlaybackTime = seconds
        currentItem.playbackPosition = seconds
        currentItem.lastWatchedDate = Date()
        modelContext.saveReportingErrors()
    }

    /// Lets go of a video that is about to be deleted from the library.
    ///
    /// Called *before* the model row is deleted. The player otherwise keeps its reference,
    /// and the periodic progress saver — or a pause, or play-to-end — would write to the
    /// invalidated model within seconds and trap. Progress is deliberately not saved here:
    /// the row it would be saved to is the one being destroyed.
    func videoWillBeDeleted(_ video: Video) {
        guard currentItem === video else { return }
        currentItem = nil
        // A Picture in Picture window can't outlive its item; clear the ownership flag so
        // `reset()` performs a real teardown instead of deferring to the floating window.
        isPictureInPictureActive = false
        reset()
    }

    /// Clears any loaded media and resets the player model to its default state.
    func reset() {
        // The app's player UI disappearing is the *start* of Picture in Picture, not the end of
        // playback: the video is still on screen in the floating window. Clearing the player item
        // here would kill that window the instant it appeared.
        guard !isPictureInPictureActive else {
            saveCurrentProgress()
            return
        }
        streamResolutionTask?.cancel()
        streamResolutionTask = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        saveCurrentProgress()
        currentItem = nil
        player.replaceCurrentItem(with: nil)
        playerUI = nil
        playerUIDelegate = nil
        // Reset the presentation state on the next cycle of the run loop.
        Task {
            presentation = .inline
        }
    }

    /// Creates metadata items from the video items data.
    /// - Parameter video: the video to create metadata for.
    /// - Returns: An array of `AVMetadataItem` to set on a player item.
    private func createMetadataItems(for video: Video) -> [AVMetadataItem] {
        var mapping: [AVMetadataIdentifier: Any] = [
            .commonIdentifierTitle: video.name,
            .commonIdentifierDescription: video.synopsis,
            .commonIdentifierCreationDate: video.yearOfRelease,
            .iTunesMetadataContentRating: video.contentRating,
            // The player's title view expects a single string here, not an array.
            .quickTimeMetadataGenre: video.genres.map(\.name).joined(separator: ", ")
        ]

        // The subtitle line under the title in the player bar: the show context for an
        // episode, the year and genres for a matched movie.
        if video.isEpisode, let show = video.showName {
            var subtitle = show
            if let season = video.seasonNumber, let episode = video.episodeNumber {
                subtitle += " · S\(season), E\(episode)"
            }
            mapping[.iTunesMetadataTrackSubTitle] = subtitle
        } else if video.yearOfRelease > 0 {
            let genres = video.genres.map(\.name).prefix(2).joined(separator: ", ")
            mapping[.iTunesMetadataTrackSubTitle] = genres.isEmpty
                ? String(video.yearOfRelease)
                : "\(video.yearOfRelease) · \(genres)"
        }
        // Artwork: the generated thumbnail, read once per playback start.
        if let thumbnailURL = video.thumbnailURL, let artwork = try? Data(contentsOf: thumbnailURL) {
            mapping[.commonIdentifierArtwork] = artwork
        }
        return mapping.compactMap { createMetadataItem(for: $0, value: $1) }
    }

    /// Creates a metadata item for a the specified identifier and value.
    /// - Parameters:
    ///   - identifier: an identifier for the item.
    ///   - value: a value to associate with the item.
    /// - Returns: a new `AVMetadataItem` object.
    private func createMetadataItem(for identifier: AVMetadataIdentifier,
                                    value: Any) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as? NSCopying & NSObjectProtocol
        // Specify "und" to indicate an undefined language.
        item.extendedLanguageTag = "und"
        return item.copy() as! AVMetadataItem
    }

    /// Configures the spatial audio experience to best fit the presentation.
    /// - Parameter presentation: the requested player presentation.
    private func configureAudioExperience(for presentation: Presentation) {
        #if os(visionOS)
        do {
            let experience: AVAudioSessionSpatialExperience
            switch presentation {
            case .inline:
                // Set a small, focused sound stage when watching trailers.
                experience = .headTracked(soundStageSize: .small, anchoringStrategy: .automatic)
            case .fullWindow:
                // Set a large sound stage size when viewing full window.
                experience = .headTracked(soundStageSize: .large, anchoringStrategy: .automatic)
            }
            try AVAudioSession.sharedInstance().setIntendedSpatialExperience(experience)
        } catch {
            logger.error("Unable to set the intended spatial experience. \(error.localizedDescription)")
        }
        #endif
    }

    // MARK: - Transport Control

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
        saveCurrentProgress()
    }

    func togglePlayback() {
        player.timeControlStatus == .paused ? play() : pause()
    }

    // MARK: - Time Observation
    private func addTimeObserver() {
        removeTimeObserver()
        // Observe the player's timing once every second.
        let timeInterval = CMTime(value: 1, timescale: 1)
        timeObserver = player
            .addPeriodicTimeObserver(forInterval: timeInterval, queue: .main) { time in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let duration = self.player.currentItem?.duration {
                        let isInProposalRange = time.seconds >= duration.seconds - 10.0
                        if self.shouldProposeNextVideo != isInProposalRange {
                            self.shouldProposeNextVideo = isInProposalRange
                        }
                    }
                    // Throttle progress saves to roughly every 5 seconds of playback rather than every tick.
                    if abs(time.seconds - self.lastSavedPlaybackTime) >= 5 {
                        self.saveCurrentProgress()
                    }
                }
            }
    }

    private func removeTimeObserver() {
        guard let timeObserver = timeObserver else { return }
        player.removeTimeObserver(timeObserver)
        self.timeObserver = nil
    }
}

#if !os(macOS)
/// Routes `AVPlayerViewController`'s life-cycle callbacks back into the model.
///
/// These callbacks are the only place that can tell why the app's player UI is going away:
/// the person left playback, or the video moved to a Picture in Picture window that's still
/// playing. The model can't distinguish the two on its own.
@MainActor
private final class PlayerUIDelegate: NSObject, AVPlayerViewControllerDelegate {

    private weak var model: PlayerModel?

    init(model: PlayerModel) {
        self.model = model
        super.init()
    }

    #if os(visionOS)
    nonisolated func playerViewController(
        _ playerViewController: AVPlayerViewController,
        willEndFullScreenPresentationWithAnimationCoordinator coordinator: any UIViewControllerTransitionCoordinator
    ) {
        Task { @MainActor [weak self] in
            self?.model?.reset()
        }
    }
    #endif

    nonisolated func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        Task { @MainActor [weak self] in
            self?.model?.pictureInPictureWillStart()
        }
    }

    nonisolated func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        Task { @MainActor [weak self] in
            self?.model?.pictureInPictureDidStop()
        }
    }

    nonisolated func playerViewController(
        _ playerViewController: AVPlayerViewController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // Restoring synchronously puts the player back before the handler reports success, which
        // is what lets AVKit animate the video home instead of dropping it. AVKit delivers this
        // on the main thread in practice, but `assumeIsolated` is a precondition rather than a
        // check — it would terminate the app rather than degrade — so the main-thread case is
        // tested rather than assumed, and anything else hops instead of trapping.
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                model?.restoreUserInterfaceForPictureInPictureStop()
            }
        } else {
            Task { @MainActor [weak self] in
                self?.model?.restoreUserInterfaceForPictureInPictureStop()
            }
        }
        // Outside the closure either way: the handler is task-isolated, so capturing it inside a
        // main-actor closure would be sending it across isolation domains.
        completionHandler(true)
    }
}
#endif
