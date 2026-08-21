/*
See the LICENSE.txt file for licensing information.

Abstract:
Custom view modifiers that the app defines.
*/

import SwiftUI
import SwiftData

extension View {
    #if !os(visionOS)
    // Only used in iOS and tvOS for full-window modal presentation.
    func presentVideoPlayer() -> some View {
        #if os(macOS)
        self.modifier(OpenVideoPlayerModifier())
        #else
        self.modifier(FullScreenCoverModifier())
        #endif
    }
    #endif

    func navigationDestinationVideo(in namespace: Namespace.ID) -> some View {
        self.modifier(NavigationDestinationVideo(namespace: namespace))
    }

    /// Dismisses this sheet when full-window playback starts, handing the
    /// screen to the app's single player presenter at the root. Two competing
    /// fullScreenCover hosts (root + sheet) race and can cancel each other out.
    func dismissesForFullWindowPlayback() -> some View {
        self.modifier(DismissForPlaybackModifier())
    }

    func transitionSource(id: Video.ID, namespace: Namespace.ID) -> some View {
        self.modifier(TransitionSourceModifier(id: id, namespace: namespace))
    }

    /// Gives a sheet a usable size on the Mac, and leaves every other platform alone.
    ///
    /// A Mac sheet takes its size from its content, and `List` and `Form` offer no height of
    /// their own — so a sheet built from one collapses to nothing but its title bar and buttons,
    /// with the actual content rendered into zero height. The touch platforms size sheets
    /// themselves, so this is a no-op there.
    func macSheetSize(width: CGFloat = 520, height: CGFloat = 560) -> some View {
        #if os(macOS)
        self.frame(width: width, height: height)
        #else
        self
        #endif
    }
}

#if !os(macOS)
private struct FullScreenCoverModifier: ViewModifier {
    @Environment(PlayerModel.self) private var player
    @State private var isPresentingPlayer = false

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $isPresentingPlayer) {
                PlayerView()
                    .onAppear {
                        if player.shouldAutoPlay {
                            player.play()
                        }
                    }
                    .onDisappear {
                        player.reset()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            }
            // Observe the player's presentation property.
            .onChange(of: player.presentation, { _, newPresentation in
                isPresentingPlayer = newPresentation == .fullWindow
            })
    }
}
#endif

private struct DismissForPlaybackModifier: ViewModifier {
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .onChange(of: player.presentation) { _, newPresentation in
                if newPresentation == .fullWindow {
                    dismiss()
                }
            }
    }
}

private struct NavigationDestinationVideo: ViewModifier {
    @Environment(\.modelContext) private var context
    var namespace: Namespace.ID

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: NavigationNode.self) { node in
                switch node {
                case .video(let id):
                    let descriptor = FetchDescriptor<Video>(predicate: #Predicate<Video> { $0.uuid == id })
                    if let video = try? context.fetch(descriptor).first {
                        DetailView(video: video)
                            #if os(iOS)
                            .toolbarRole(.editor)
                            .navigationTransition(.zoom(sourceID: video.id, in: namespace))
                            #endif
                    } else {
                        ContentUnavailableView("This video isn’t available", systemImage: "list.and.film")
                    }

                case .show(let showName):
                    ShowView(showName: showName)
                        #if os(iOS)
                        .toolbarRole(.editor)
                        #endif
                }
            }
    }
}

private struct TransitionSourceModifier: ViewModifier {
    var id: Video.ID
    var namespace: Namespace.ID

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .matchedTransitionSource(id: id, in: namespace) { src in
                src
                    .clipShape(.rect(cornerRadius: 10.0))
                    .shadow(radius: 12.0)
                    // Theme-matched backing: hardcoded black boxed the card in
                    // a black slab in light mode and hid its title label.
                    .background(Color(.systemBackground))
            }
            #endif
    }
}

#if os(macOS)
private struct OpenVideoPlayerModifier: ViewModifier {
    @Environment(PlayerModel.self) private var player
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content
            .onChange(of: player.presentation, { oldValue, newValue in
                if newValue == .fullWindow {
                    openWindow(id: PlayerView.identifier)
                }
            })
            // Playing a second video while the window is already open doesn't change the
            // presentation, so the change above never fires: the item swapped in paused,
            // behind an unfocused window. Fronting the window and playing here covers the
            // swap; the fresh-open case (oldID == nil) keeps its autoplay in the window's
            // own onAppear.
            .onChange(of: player.currentItem?.id, { oldID, newID in
                guard player.presentation == .fullWindow else { return }
                if oldID != nil, newID != nil, oldID != newID {
                    openWindow(id: PlayerView.identifier)
                    if player.shouldAutoPlay {
                        player.play()
                    }
                } else if newID == nil {
                    // The loaded video was deleted out from under the player; an open
                    // window showing an empty player is not a state worth keeping.
                    dismissWindow(id: PlayerView.identifier)
                }
            })
    }
}
#endif
