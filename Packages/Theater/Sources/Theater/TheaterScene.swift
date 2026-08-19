//
//  Loads the Theater environment.
//

#if os(visionOS)

import Foundation
import RealityKit

/// Loads the theater.
///
/// One authored room — the middle seat's bake — serves every seat: `TheaterMiddle.usda`
/// carries the docking region and the light-spill surfaces with their baked UVs, and seats are
/// rigid moves of the whole room (see ``TheaterSeat/roomTransform``). See
/// `Tools/make_theater.py` for how the scene is generated.
public enum TheaterScene {

    /// Builds the theater with `seat` under the viewer.
    ///
    /// - Returns: The root entity to add to the immersive space's scene.
    @MainActor
    public static func makeEntity(seat: TheaterSeat) async throws -> Entity {
        let room = try await Entity(named: "TheaterMiddle", in: theaterBundle)
        let container = Entity()
        container.name = "TheaterContainer"
        container.addChild(room)
        container.addChild(makeSeatMarkers(current: seat))
        container.position = seat.roomTransform
        return container
    }

    /// How long the room takes to glide to a newly chosen seat.
    public static let seatMoveDuration: TimeInterval = 0.85

    /// The prefix a seat marker's entity name carries; the rest is the seat's `name`.
    public static let seatMarkerPrefix = "SeatMarker:"

    /// The seat picker, as part of the room: a dim light at every seat, the way a real
    /// cinema marks its rows. Gazing at one lifts it with the system hover effect; the app
    /// moves the room when one is tapped. The seat you occupy stays dark.
    @MainActor
    private static func makeSeatMarkers(current: TheaterSeat) -> Entity {
        let markers = Entity()
        markers.name = "SeatMarkers"

        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: .init(white: 0.32, alpha: 1))

        for seat in TheaterSeat.allCases {
            let marker = ModelEntity(
                mesh: .generateCylinder(height: 0.012, radius: 0.09),
                materials: [material]
            )
            marker.name = seatMarkerPrefix + seat.name
            // A low light where the seat's floor is — on the orchestra that is the carpet,
            // on the balcony the (unmodelled) tier floor implied by the glow.
            marker.position = seat.eyeOffset + [0, -1.32, 0]
            marker.components.set(InputTargetComponent())
            marker.components.set(HoverEffectComponent())
            marker.components.set(CollisionComponent(
                shapes: [.generateSphere(radius: 0.22)], mode: .trigger, filter: .default
            ))
            marker.isEnabled = seat != current
            markers.addChild(marker)
        }
        return markers
    }

    /// Shows every marker except the seat now occupied.
    @MainActor
    public static func refreshSeatMarkers(in container: Entity, current: TheaterSeat) {
        guard let markers = container.children.first(where: { $0.name == "SeatMarkers" }) else { return }
        for marker in markers.children {
            let name = String(marker.name.dropFirst(seatMarkerPrefix.count))
            marker.isEnabled = TheaterSeat(name: name) != current
        }
    }
}

#endif
