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

    func transitionSource(id: Video.ID, namespace: Namespace.ID) -> some View {
        self.modifier(TransitionSourceModifier(id: id, namespace: namespace))
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
                    .background(.black)
            }
            #endif
    }
}

#if os(macOS)
private struct OpenVideoPlayerModifier: ViewModifier {
    @Environment(PlayerModel.self) private var player
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onChange(of: player.presentation, { oldValue, newValue in
                if newValue == .fullWindow {
                    openWindow(id: PlayerView.identifier)
                }
            })
    }
}
#endif
