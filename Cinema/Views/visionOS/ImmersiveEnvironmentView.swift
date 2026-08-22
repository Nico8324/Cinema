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

    private static let markerID = "TheaterSeatMarker"
    private static let panelID = "TheaterSeatPanel"

    @Environment(ImmersiveEnvironment.self) private var immersiveEnvironment
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    /// Whether the seat panel is open above the floor icon.
    @State private var isSeatPanelOpen = false

    /// Anchored once to the viewer's head as the space opens: everything hung from it is
    /// placed relative to where the person actually is and faces, which the space's world
    /// origin is not (it is wherever the app launched or was last recentered).
    @State private var headAnchor = AnchorEntity(.head)

    var body: some View {
        RealityView { content, attachments in
            if let rootEntity = immersiveEnvironment.rootEntity {
                content.add(rootEntity)
            }
            headAnchor.anchoring.trackingMode = .once
            content.add(headAnchor)
            placeSeatControls(attachments)
        } update: { _, attachments in
            // Attachments are re-created when SwiftUI re-evaluates them (the space finishing
            // its opening transition is one such moment); anything not re-adopted here vanishes.
            placeSeatControls(attachments)
        } attachments: {
            Attachment(id: Self.markerID) {
                TheaterSeatMarker(isOpen: isSeatPanelOpen) {
                    withAnimation(.snappy(duration: 0.25)) { isSeatPanelOpen.toggle() }
                }
            }
            Attachment(id: Self.panelID) {
                if let seat = immersiveEnvironment.activeTheaterSeat {
                    TheaterSeatPanel(current: seat) { chosen in
                        isSeatPanelOpen = false
                        Task { await immersiveEnvironment.switchTheaterSeat(to: chosen) }
                    }
                }
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

    /// Hangs the seat icon on the floor under the viewer and the panel low in front, both
    /// relative to the head pose captured as the space opened.
    private func placeSeatControls(_ attachments: RealityViewAttachments) {
        guard immersiveEnvironment.activeTheaterSeat != nil else { return }

        if let marker = attachments.entity(for: Self.markerID) {
            if marker.parent !== headAnchor { headAnchor.addChild(marker) }
            // Flat on the floor, a little ahead of the feet — seated eye height assumed.
            marker.position = [0, -1.25, -0.5]
            marker.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        }
        if let panel = attachments.entity(for: Self.panelID) {
            if panel.parent !== headAnchor { headAnchor.addChild(panel) }
            // Low in front, tilted up toward the face: found by the same downward glance.
            panel.position = [0, -0.5, -0.8]
            panel.orientation = simd_quatf(angle: -0.5, axis: [1, 0, 0])
            panel.isEnabled = isSeatPanelOpen
        }
    }
}
