/*
See the LICENSE.txt file for licensing information.

Abstract:
A view that presents an environment.
*/

import Studio
import SwiftUI
import RealityKit

/// A view that presents an environment.
struct ImmersiveEnvironmentView: View {
    static let id: String = "ImmersiveEnvironmentView"

    @Environment(ImmersiveEnvironment.self) private var immersiveEnvironment
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        RealityView { content, attachments in
            if let rootEntity = immersiveEnvironment.rootEntity {
                content.add(rootEntity)
            }
            // The seat pill spawns in front of wherever the viewer's head actually is —
            // `AnchorEntity(.head)` with one-shot tracking is the documented pattern for
            // placing UI in an immersive space (world coordinates put it at guessed heights,
            // which is why earlier attempts never appeared).
            if immersiveEnvironment.activeTheaterSeat != nil,
               let pill = attachments.entity(for: "TheaterSeats") {
                let headAnchor = AnchorEntity(.head)
                headAnchor.anchoring.trackingMode = .once
                // Beside where the system's floating control bar materializes — the bar is
                // system UI with no attachment or pose API, so this is adjacency by
                // construction: both are placed head-relative at spawn.
                pill.position = [0.52, -0.32, -1.1]
                headAnchor.addChild(pill)
                content.add(headAnchor)
            }
        } attachments: {
            Attachment(id: "TheaterSeats") {
                TheaterSeatsView(environment: immersiveEnvironment)
            }
        }
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
