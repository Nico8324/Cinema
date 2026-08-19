/*
See the LICENSE.txt file for licensing information.

Abstract:
A view that presents an environment.
*/

import Studio
import SwiftUI
import RealityKit
import Theater

/// A view that presents an environment.
struct ImmersiveEnvironmentView: View {
    static let id: String = "ImmersiveEnvironmentView"

    @Environment(ImmersiveEnvironment.self) private var immersiveEnvironment
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        RealityView { content in
            if let rootEntity = immersiveEnvironment.rootEntity {
                content.add(rootEntity)
            }
        }
        // The theater's seat picker is the room itself: dim seat lights at every position,
        // lifted by the system hover effect under the gaze. Tapping one glides the room there.
        .gesture(
            TapGesture()
                .targetedToAnyEntity()
                .onEnded { value in
                    let name = value.entity.name
                    guard name.hasPrefix(TheaterScene.seatMarkerPrefix),
                          let seat = TheaterSeat(name: String(name.dropFirst(TheaterScene.seatMarkerPrefix.count)))
                    else { return }
                    Task { await immersiveEnvironment.switchTheaterSeat(to: seat) }
                }
        )
        .onDisappear {
            immersiveEnvironment.immersiveSpaceState = .closed
            immersiveEnvironment.clearEnvironment()
        }
        .onAppear {
            immersiveEnvironment.immersiveSpaceState = .open
        }
        .transition(.opacity)
    }
}
