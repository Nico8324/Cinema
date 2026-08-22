/*
See the LICENSE.txt file for licensing information.

Abstract:
A view that presents the video player.
*/

import SwiftUI
import RealityKit
#if os(visionOS)
import Theater
#endif

/// Constants that define the style of controls a player presents.
enum PlayerControlsStyle {
    /// The player uses the system interface that AVPlayerViewController provides.
    case system
    /// The player uses compact controls that display a play/pause button.
    case custom
}

/// A view that presents the video player.
struct PlayerView: View {
    
    static let identifier = "player-view"
    
    let controlsStyle: PlayerControlsStyle
    @State private var showContextualActions = false
    @Environment(PlayerModel.self) private var model
    
    /// Creates a new player view.
    init(controlsStyle: PlayerControlsStyle = .system) {
        self.controlsStyle = controlsStyle
    }

    private var systemPlayerView: some View {
        #if os(macOS)
        // Adds the drag gesture to a transparent overlay and inserts
        // the overlay between the video content and the playback controls.
        let overlay = Color.clear
            .contentShape(.rect)
            .gesture(WindowDragGesture())
            // Enable the window drag gesture to receive events that activate the window.
            .allowsWindowActivationEvents(true)
        return SystemPlayerView(showContextualActions: showContextualActions, overlay: overlay)
        #else
        return SystemPlayerView(showContextualActions: showContextualActions)
        #endif
    }

    var body: some View {
        switch controlsStyle {
        case .system:
            systemPlayerView
                .overlay(alignment: .bottomTrailing) {
                    // Over the player rather than inside its controls: `AVPlayerViewController`
                    // owns its chrome, and the contextual-action route it does offer exists only
                    // on visionOS and tvOS. An overlay is the one placement all four platforms
                    // share.
                    NextEpisodeOverlay()
                        .animation(.snappy, value: model.pendingNextEpisode?.id)
                }
                .onChange(of: model.shouldProposeNextVideo) {
                    showContextualActions = model.shouldProposeNextVideo
                }
        case .custom:
            #if os(visionOS)
            InlinePlayerView()
            #endif
        }
    }
}

