/*
See the LICENSE.txt file for licensing information.

Abstract:
The app's top level view.
*/

import SwiftUI
import SwiftData

/// A view that presents the app's user interface.
struct ContentView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.modelContext) private var context

    /// Posters are only worth downloading for someone who's asked to see them.
    @AppStorage(ArtworkStyle.storageKey) private var artworkStyle: ArtworkStyle = .wide
    #if os(visionOS)
    @Environment(ImmersiveEnvironment.self) private var immersiveEnvironment
    #endif

    var body: some View {
        #if os(visionOS)
        Group {
            switch player.presentation {
            case .fullWindow:
                PlayerView()
                    .immersiveEnvironmentPicker {
                        ImmersiveEnvironmentPickerView()
                    }
                    .onAppear {
                        if player.shouldAutoPlay {
                            player.play()
                        }
                    }
            default:
                // Shows the app's content library by default.
                DestinationTabs()
            }
        }
        .task(id: artworkStyle) { await backfillPostersIfNeeded() }
        #else
        DestinationTabs()
            .presentVideoPlayer()
            .task(id: artworkStyle) { await backfillPostersIfNeeded() }
        #endif
    }

    /// Fetches the posters of entries matched before the app stored them, so switching the library
    /// to posters shows posters rather than backdrops squeezed into portrait frames.
    private func backfillPostersIfNeeded() async {
        guard artworkStyle == .poster else { return }
        await PosterBackfill.run(in: context)
    }
}

#Preview(traits: .previewData) {
    ContentView()
}

