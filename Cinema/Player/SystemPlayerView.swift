/*
See the LICENSE.txt file for licensing information.

Abstract:
A view that provides a platform-specific playback user interface.
*/

import AVKit
import SwiftUI
import SwiftData

#if os(macOS)
// A SwiftUI wrapper on `AVPlayerViewController`.
struct SystemPlayerView<Overlay: View>: NSViewRepresentable {
    @Environment(PlayerModel.self) private var model
    
    let showContextualActions: Bool
    private let overlay: Overlay

    init(showContextualActions: Bool, overlay: Overlay) {
        self.showContextualActions = showContextualActions
        self.overlay = overlay
    }

    final class Coordinator: NSObject, AVPlayerViewDelegate {
        /// The hosting view for the SwiftUI content overlay view.
        weak var overlayHostingView: NSHostingView<Overlay>?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = model.makePlayerUI()
        playerView.controlsStyle = .floating
        playerView.delegate = context.coordinator
        // Create the hosting view for the SwiftUI content overlay view.
        if let contentOverlayView = playerView.contentOverlayView {
            let overlayHostingView = NSHostingView(rootView: overlay)
            context.coordinator.overlayHostingView = overlayHostingView
            // Add the hosting view to the player view's content overlay view.
            contentOverlayView.addSubview(overlayHostingView)
            overlayHostingView.translatesAutoresizingMaskIntoConstraints = false
            overlayHostingView.topAnchor.constraint(equalTo: contentOverlayView.topAnchor).isActive = true
            overlayHostingView.trailingAnchor.constraint(equalTo: contentOverlayView.trailingAnchor).isActive = true
            overlayHostingView.bottomAnchor.constraint(equalTo: contentOverlayView.bottomAnchor).isActive = true
            overlayHostingView.leadingAnchor.constraint(equalTo: contentOverlayView.leadingAnchor).isActive = true
        }
        return playerView
    }

    func updateNSView(_ nsView: NSViewType, context: Context) {
        context.coordinator.overlayHostingView?.rootView = overlay
    }
}
#else
// A SwiftUI wrapper on `AVPlayerViewController`.
struct SystemPlayerView: UIViewControllerRepresentable {
    @Environment(PlayerModel.self) private var model
    
    @Query(sort: \UpNextItem.createdAt)
    private var playlist: [UpNextItem]
    
    let showContextualActions: Bool

    init(showContextualActions: Bool) {
        self.showContextualActions = showContextualActions
    }
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {

        // Create a player view controller.
        let controller = model.makePlayerUI()

        // Enable Picture in Picture in iOS and tvOS.
        controller.allowsPictureInPicturePlayback = true

        #if !os(tvOS)
        // The app hosts this controller itself rather than letting AVKit present it, so AVKit
        // reads the video as inline and won't pop it out on its own. This says the video is the
        // screen's primary focus, which is what earns the automatic hand-off when the app leaves
        // the foreground mid-playback.
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        #endif

        #if os(visionOS) || os(tvOS)
        // Display an Up Next tab in the player UI.
        if let upNextViewController {
            controller.customInfoViewControllers = [upNextViewController]
        }
        #endif

        // Return the configured controller object.
        return controller
    }
    
    func updateUIViewController(_ controller: UIViewControllerType, context: Context) {
        #if os(visionOS) || os(tvOS)
        // Everything the actions depend on has to be read HERE, synchronously: this is the only
        // scope where SwiftUI's observation registers the reads, and the seat pill appearing at
        // all depends on this method re-running when the immersive space opens.
        let customInfoViewControllers = [upNextViewController].compactMap { $0 }

        var actions: [UIAction] = []
        if let upNextAction, showContextualActions {
            actions.append(upNextAction)
        }
        let contextualActions = actions
        Task { @MainActor in
            controller.customInfoViewControllers = customInfoViewControllers
            controller.contextualActions = contextualActions
        }
        #endif
    }
    


    // A view controller that presents a list of Up Next videos.
    var upNextViewController: UIViewController? {
        guard let video = model.currentItem else { return nil }
        
        // Find the Up Next list for this video. Return early if there aren't any videos.
        let videos = playlist
            .compactMap(\.video)
            .filter { $0.id != video.id }
        
        if videos.isEmpty { return nil }

        let view = UpNextView(videos: videos, model: model)
        let controller = UIHostingController(rootView: view)
        // `AVPlayerViewController` uses the view controller's title as the tab name.
        // Specify the view controller's title before setting it as a `customInfoViewControllers` value.
        controller.title = view.title
        // Set the preferred content size for the tab.
        #if os(tvOS)
        controller.preferredContentSize = CGSize(width: 500, height: 250)
        #else
        controller.preferredContentSize = CGSize(width: 600, height: 150)
        #endif
        
        return controller
    }
    
    var upNextAction: UIAction? {
        // If there's no video loaded, return `nil`.
        guard let video = model.currentItem else { return nil }

        // Find the next video to play.
        guard let item = video.upNextItem,
              let index = playlist.firstIndex(of: item),
              playlist.indices.contains(index + 1),
              let nextVideo = playlist[index + 1].video
        else { return nil }
        
        return UIAction(title: String(localized: "Play Next"), image: UIImage(systemName: "play.fill")) { _ in
            // Load the video for full-window presentation.
            model.loadVideo(nextVideo, presentation: .fullWindow)
        }
    }
}

#endif

