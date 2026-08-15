/*
See the LICENSE.txt file for licensing information.

Abstract:
A view that displays a simple inline video player with custom controls.
*/

#if !os(macOS)
import AVKit
import SwiftUI

///  A view that displays a simple inline video player with custom controls.
struct InlinePlayerView: View {

    @Environment(PlayerModel.self) private var model

    var body: some View {
        ZStack {
            // A view that uses `AVPlayerViewController` to display the video content without controls.
            VideoContentView()
            // Custom inline controls to overlay on top of the video content.
            InlineControlsView()
        }
        .onDisappear {
            // If this view disappears, and it's not due to switching to full-window
            // presentation, clear the model's loaded media.
            if model.presentation != .fullWindow {
                model.reset()
            }
        }
    }
}

/// A view that defines a simple play/pause button for the trailer player,
/// fading out a few seconds after playback starts.
struct InlineControlsView: View {

    @Environment(PlayerModel.self) private var player
    @State private var isShowingControls = true
    @State private var hideControlsTask: Task<Void, Never>?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .overlay {
                if isShowingControls {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.largeTitle)
                        .padding(8)
                        .background(.thinMaterial)
                        .clipShape(.circle)
                        .transition(.opacity)
                }
            }
            .onTapGesture {
                player.togglePlayback()
                withAnimation {
                    isShowingControls = true
                }
                scheduleHide()
            }
    }

    /// Hides the controls after a delay, as long as playback is still running.
    /// Re-tapping restarts the countdown.
    private func scheduleHide() {
        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, player.isPlaying else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                isShowingControls = false
            }
        }
    }
}

/// A view that presents the video content of an player object.
///
/// This class is a view controller representable type that adapts the interface
/// of `AVPlayerViewController`. It removes the view controller's default controls
/// so it can draw custom controls over the video content.
private struct VideoContentView: UIViewControllerRepresentable {

    @Environment(PlayerModel.self) private var model

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = model.makePlayerUI()
        // Remove the default system playback controls.
        controller.showsPlaybackControls = false
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

#Preview(traits: .previewData) {
    InlineControlsView()
}
#endif
