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
        container.position = seat.roomTransform
        return container
    }

    /// How long the room takes to glide to a newly chosen seat.
    public static let seatMoveDuration: TimeInterval = 0.85

    /// The height of the orchestra's carpet in the room's coordinates (the authored floor
    /// plane in `make_theater.py`).
    public static let floorY: Float = -1.4
}

#endif
