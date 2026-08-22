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

    var body: some View {
        RealityView { content, attachments in
            if let rootEntity = immersiveEnvironment.rootEntity {
                content.add(rootEntity)
            }
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

    /// Tapes the seat icon to the room's floor at the occupied seat, and hangs the panel low
    /// in front of it.
    ///
    /// Both are children of the room, not of the viewer: the seat position is under the viewer
    /// by construction, so the icon lands on the carpet at the feet without guessing eye
    /// height or trusting the space's world origin (which is not under the viewer on device).
    /// They ride the glide and re-seat themselves at the new position after every move.
    private func placeSeatControls(_ attachments: RealityViewAttachments) {
        guard let seat = immersiveEnvironment.activeTheaterSeat,
              let room = immersiveEnvironment.rootEntity else { return }

        // The orchestra's carpet is the room's floor plane; the balcony has no modelled
        // tier, so its icon sits where the tier floor would be beneath the seat.
        let floorY: Float = seat.level == .floor ? TheaterScene.floorY + 0.01 : seat.eyeOffset.y - 1.25

        if let marker = attachments.entity(for: Self.markerID) {
            if marker.parent !== room { room.addChild(marker) }
            marker.position = [0, floorY, seat.eyeOffset.z - 0.5]
            marker.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        }
        if let panel = attachments.entity(for: Self.panelID) {
            if panel.parent !== room { room.addChild(panel) }
            panel.position = seat.eyeOffset + [0, -0.5, -0.8]
            panel.orientation = simd_quatf(angle: -0.5, axis: [1, 0, 0])
            panel.isEnabled = isSeatPanelOpen
        }
    }
}
