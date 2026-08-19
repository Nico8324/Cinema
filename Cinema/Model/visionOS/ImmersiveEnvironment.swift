/*
See the LICENSE.txt file for licensing information.

Abstract:
The model that manages the environment.
*/

import SwiftUI
import RealityKit
import Studio
import Theater

///  The model that manages the environment.
@MainActor @Observable class ImmersiveEnvironment {

    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }

    /// The environment to open, and how it's configured.
    ///
    /// The two destinations are built differently — Studio loads an authored scene with light
    /// and dark states, the theater is generated in code per seat — so they can't share a single
    /// state value.
    enum Destination: Equatable {
        case studio(EnvironmentStateType)
        case theater(Theater.TheaterSeat)
    }

    public var immersiveSpaceState = ImmersiveSpaceState.closed

    /// An object that handles the state of an environment opened in an immersive space.
    private var environmentStateHandler = EnvironmentStateHandler()

    /// The destination to show after the environment finishes loading.
    private var requestedDestination: Destination = .studio(.light)

    public var contentBrightness: ImmersiveContentBrightness {
        switch requestedDestination {
        case .studio(.light): .dim
        case .studio(.dark): .dark
        case .studio(.none): .automatic
        // A cinema is the darkest room the app has; nothing should compete with the screen.
        case .theater: .dark
        }
    }

    public var surroundingsEffect: SurroundingsEffect? {
        switch requestedDestination {
        case .studio(.light): .colorMultiply(Color(red: 1.15, green: 1.2, blue: 1.4))
        case .studio(.dark): .colorMultiply(Color(red: 0.13, green: 0.12, blue: 0.09))
        case .studio(.none): nil
        // Darker still than Studio's dark state, and neutral rather than warm.
        case .theater: .colorMultiply(Color(red: 0.05, green: 0.05, blue: 0.06))
        }
    }

    /// How much of the real world the environment replaces.
    ///
    /// Both rooms dial with the Digital Crown, like the system environments. The theater opens
    /// fully sealed — a cinema starts dark — and the crown can bring the real world back in.
    /// (It was `.full` in early drafts, when the room was two floating planes and any
    /// passthrough read as a hole in the wall; the finished room tolerates dialing.)
    public var immersionStyle: any ImmersionStyle {
        switch requestedDestination {
        case .studio: .progressive
        case .theater: .progressive(0.2...1.0, initialAmount: 1.0)
        }
    }

    public private(set) var rootEntity: Entity?

    /// The seat the theater is currently showing, when the theater is the destination.
    public var activeTheaterSeat: Theater.TheaterSeat? {
        if case .theater(let seat) = requestedDestination { return seat }
        return nil
    }

    public func loadEnvironment() async -> Bool {
        switch requestedDestination {
        case .studio: await loadStudio()
        case .theater(let seat): await loadTheater(seat: seat)
        }
    }

    private func loadStudio() async -> Bool {
        do {
            let entity = try await Entity(named: "AAA_MainScene", in: studioBundle)
            environmentStateHandler.gatherEntities(from: entity)
            if case .studio(let state) = requestedDestination {
                setEnvironmentState(state)
            }

            rootEntity = entity
            return true
        } catch {
            logger.error("Failed to load Studio bundle: \(error.localizedDescription)")

            return false
        }
    }

    private func loadTheater(seat: Theater.TheaterSeat) async -> Bool {
        do {
            rootEntity = try await TheaterScene.makeEntity(seat: seat)
            return true
        } catch {
            logger.error("Failed to build the theater environment: \(error.localizedDescription)")

            return false
        }
    }

    /// Moves to another seat without leaving the theater.
    ///
    /// The room is rebuilt for the new seat — the geometry and its baked light-spill data are
    /// per-seat — and swapped under the open immersive space. The system re-docks the video to
    /// the new docking region on its own.
    /// Moves to another seat without leaving the theater.
    ///
    /// One room serves every seat, so this is a rigid move of the whole world — the head stays
    /// fixed; the theater glides until the chosen seat is under the viewer. The docking region
    /// travels with the room and the system keeps the video docked to it.
    public func switchTheaterSeat(to seat: Theater.TheaterSeat) async {
        guard case .theater(let current) = requestedDestination, current != seat,
              let container = rootEntity, container.name == "TheaterContainer" else { return }
        requestedDestination = .theater(seat)
        Self.rememberSeat(seat)

        var transform = container.transform
        transform.translation = seat.roomTransform
        container.move(to: transform, relativeTo: nil, duration: TheaterScene.seatMoveDuration, timingFunction: .easeInOut)
        TheaterScene.refreshSeatMarkers(in: container, current: seat)
    }

    public func clearEnvironment() {
        environmentStateHandler.clear()
        rootEntity = nil
    }

    public func requestEnvironmentState(_ state: EnvironmentStateType) {
        guard state != .none else {
            logger.warning("Requested environment state can not be set to none")
            return
        }
        requestedDestination = .studio(state)
    }

    public func requestTheaterSeat(_ seat: Theater.TheaterSeat) {
        requestedDestination = .theater(seat)
        Self.rememberSeat(seat)
    }

    /// The seat to open the theater at: wherever the person last sat.
    public static var rememberedSeat: TheaterSeat {
        TheaterSeat(name: UserDefaults.standard.string(forKey: "TheaterSeat") ?? "") ?? .middle
    }

    private static func rememberSeat(_ seat: TheaterSeat) {
        UserDefaults.standard.set(seat.name, forKey: "TheaterSeat")
    }

    private func setEnvironmentState(_ state: EnvironmentStateType) {
        guard state != .none else {
            logger.warning("Environment state can not be set to none")
            return
        }
        environmentStateHandler.setActiveState(state)

        switch state {
        case .light:
            setVirtualEnvironmentProbeComponent(blendParam: EnvironmentStateHandler.lightStateBlendParam)
        case .dark:
            setVirtualEnvironmentProbeComponent(blendParam: EnvironmentStateHandler.darkStateBlendParam)
        default:
            break
        }
    }

    private func findCommonEntityByName(_ name: String) -> Entity? {
        environmentStateHandler.commonEntity?.children.first(where: { $0.name == name })
    }

    private func setVirtualEnvironmentProbeComponent(blendParam: Float) {
        let virtualEnvironmentProbeEntityName = "EnvironmentProbe"

        guard let virtualEnvironmentProbeEntity = findCommonEntityByName(virtualEnvironmentProbeEntityName) else {
            logger.warning("\(virtualEnvironmentProbeEntityName) not found")
            return
        }

        if var probeComponent = virtualEnvironmentProbeEntity.components[VirtualEnvironmentProbeComponent.self] {
            if case VirtualEnvironmentProbeComponent.Source.blend(let firstProbe, let secondProbe, _) = probeComponent.source {
                probeComponent.source = .blend(from: firstProbe, to: secondProbe, t: blendParam)
                virtualEnvironmentProbeEntity.components[VirtualEnvironmentProbeComponent.self] = probeComponent
            }
        }
    }
}

