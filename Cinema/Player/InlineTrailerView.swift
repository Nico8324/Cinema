/*
See the LICENSE.txt file for licensing information.

Abstract:
An inline player for a movie's YouTube trailer, embedded in the detail page.
*/

import SwiftUI
import AVKit

/// An inline player for a movie's YouTube trailer, embedded in the detail page.
///
/// The trailer prepares in the background as soon as the view appears — the stream URL
/// resolves and the player starts buffering behind the poster card — so tapping play
/// starts instantly. Tapping before it's ready shows a brief loading state; a failed
/// background preparation falls back to a fresh attempt on tap.
///
/// Trailers deliberately bypass the app's main player and its Continue Watching
/// bookkeeping; they're previews. On iPhone, rotating to landscape while playing
/// expands to full screen; rotating back returns inline — the same player drives
/// both, so playback never interrupts.
struct InlineTrailerView: View {
    @Environment(PlayerModel.self) private var mainPlayer
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    let youtubeID: String

    /// The prepared (buffering) or actively playing player.
    @State private var player: AVPlayer?
    /// Whether the player has been swapped in over the poster card.
    @State private var isShowingPlayer = false
    /// Whether the user tapped play while preparation was still in flight.
    @State private var wantsPlayback = false
    @State private var isLoading = false
    @State private var didFail = false
    @State private var isFullScreen = false
    @State private var isResolving = false
    // Extraction occasionally produces a URL YouTube then refuses; one fresh
    // re-extraction usually fixes it (same policy as the main player).
    @State private var retriesLeft = 1
    @State private var statusObservation: NSKeyValueObservation?

    var body: some View {
        ZStack {
            if isShowingPlayer, let player {
                InlineSystemPlayerView(player: player)
            } else {
                Button {
                    requestPlayback()
                } label: {
                    TrailerCardView(youtubeID: youtubeID, isLoading: isLoading, didFail: didFail)
                }
                .buttonStyle(.plain)
                .disabled(isLoading || didFail)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(.rect(cornerRadius: Constants.cornerRadius))
        // Prepare in the background so play starts instantly on tap.
        .task(id: youtubeID) {
            await loadStream()
        }
        .onDisappear {
            player?.pause()
        }
        // Don't compete with the main player when a movie starts.
        .onChange(of: mainPlayer.presentation) { _, newPresentation in
            if newPresentation == .fullWindow {
                player?.pause()
            }
        }
        // Rotating the phone to landscape while playing expands the trailer to
        // full screen; rotating back returns it inline. Playback continues
        // seamlessly — both presentations drive the same player.
        .onChange(of: verticalSizeClass) { _, newSizeClass in
            #if os(iOS)
            if newSizeClass == .compact, isShowingPlayer {
                isFullScreen = true
            } else if newSizeClass == .regular, isFullScreen {
                isFullScreen = false
            }
            #endif
        }
        .fullScreenCover(isPresented: $isFullScreen) {
            if let player {
                FullScreenTrailerView(player: player)
            }
        }
    }

    private func requestPlayback() {
        if player != nil {
            beginPlayback()
        } else {
            // Preparation is either still in flight (it will start playback when it
            // lands) or silently failed (start a fresh attempt).
            wantsPlayback = true
            isLoading = true
            Task {
                await loadStream()
            }
        }
    }

    private func beginPlayback() {
        isLoading = false
        isShowingPlayer = true
        player?.play()
    }

    private func loadStream() async {
        guard !isResolving, player == nil, !didFail else { return }
        isResolving = true
        defer { isResolving = false }

        do {
            guard let streamURL = try await YouTubeSource.streamURL(forVideoID: youtubeID) else {
                showFailureIfWaiting()
                return
            }
            let item = AVPlayerItem(url: streamURL)
            statusObservation = item.observe(\.status) { item, _ in
                guard item.status == .failed else { return }
                Task { @MainActor in
                    await retryOrFail()
                }
            }
            // Attaching the item starts buffering immediately, even before play.
            self.player = AVPlayer(playerItem: item)
            if wantsPlayback {
                beginPlayback()
            }
        } catch {
            logger.error("Couldn't load the trailer \(youtubeID): \(error.localizedDescription)")
            showFailureIfWaiting()
        }
    }

    @MainActor
    private func retryOrFail() async {
        statusObservation?.invalidate()
        statusObservation = nil

        let userIsWatching = isShowingPlayer || wantsPlayback
        player = nil
        isShowingPlayer = false
        isFullScreen = false

        guard retriesLeft > 0 else {
            if userIsWatching { showFailureIfWaiting() }
            return
        }
        retriesLeft -= 1
        if userIsWatching {
            wantsPlayback = true
            isLoading = true
        }
        await loadStream()
    }

    /// Marks the trailer as failed only when the user is actually waiting on it —
    /// a background preparation failure stays silent, and tapping retries fresh.
    private func showFailureIfWaiting() {
        guard wantsPlayback else { return }
        isLoading = false
        didFail = true
    }
}

/// The trailer expanded to full screen, sharing the inline card's player.
private struct FullScreenTrailerView: View {
    @Environment(\.dismiss) private var dismiss

    let player: AVPlayer

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: player)
                .ignoresSafeArea()
        }
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .padding(10)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .padding()
        }
        .preferredColorScheme(.dark)
    }
}

/// The system player, embedded inline. Standard controls include expand-to-full-screen.
private struct InlineSystemPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
}

/// A 16:9 trailer card — YouTube's thumbnail with a play glyph — shown before playback starts.
struct TrailerCardView: View {
    let youtubeID: String
    var isLoading = false
    var didFail = false

    var body: some View {
        AsyncImage(url: URL(string: "https://img.youtube.com/vi/\(youtubeID)/hqdefault.jpg")) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            Color(white: 0.12)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .overlay {
            if didFail {
                Label("Trailer Unavailable", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .padding(10)
                    .background(.thinMaterial, in: Capsule())
            } else if isLoading {
                ProgressView()
                    .padding(14)
                    .background(.thinMaterial, in: Circle())
            } else {
                Image(systemName: "play.fill")
                    .font(.title2)
                    .padding(14)
                    .background(.thinMaterial)
                    .clipShape(.circle)
            }
        }
        #if os(iOS) || os(visionOS)
        .hoverEffect()
        #endif
        .accessibilityLabel("Play Trailer")
    }
}

#Preview {
    TrailerCardView(youtubeID: "aqz-KE-bpKQ")
        .frame(width: 400)
        .padding()
        .preferredColorScheme(.dark)
}
