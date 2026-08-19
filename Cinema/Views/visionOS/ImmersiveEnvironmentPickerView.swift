/*
See the LICENSE.txt file for licensing information.

Abstract:
A view that adds the custom environments to the immersive environment picker in an undocked video player view controller.
*/

import SwiftUI
import Theater

/// A view that populates the ImmersiveEnvironmentPicker in an undocked AVPlayerViewController.
struct ImmersiveEnvironmentPickerView: View {

    var body: some View {
        StudioButton(state: .dark)
        StudioButton(state: .light)
        TheaterButton()
    }
}

/// A view for the buttons that appear in the environment picker menu.
private struct StudioButton: View {
    var state: EnvironmentStateType

    var body: some View {
        EnvironmentButton {
            $0.requestEnvironmentState(state)
        } label: {
            Label {
                Text("Studio", comment: "Show Studio environment")
            } icon: {
                Image(["studio_thumbnail", state.displayName.lowercased()].joined(separator: "_"))
            }
            Text(state.displayName)
        }
    }
}

/// A button that opens the theater.
///
/// One entry, matching how the picker offers Apple's own Cinema environment; the seat is
/// changed from inside the player, not chosen here.
private struct TheaterButton: View {
    var body: some View {
        EnvironmentButton {
            $0.requestTheaterSeat(.middle)
        } label: {
            Label {
                Text("Theater", comment: "Show Theater environment")
            } icon: {
                Image(systemName: "film")
            }
        }
    }
}

/// The shared work behind every environment button: note the choice, load the environment,
/// then open the immersive space only if the load succeeded.
private struct EnvironmentButton<Label: View>: View {
    @Environment(ImmersiveEnvironment.self) private var immersiveEnvironment
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    /// Records which environment this button asks for.
    var request: (ImmersiveEnvironment) -> Void
    @ViewBuilder var label: Label

    var body: some View {
        Button {
            request(immersiveEnvironment)
            Task {
                guard await immersiveEnvironment.loadEnvironment() else { return }

                immersiveEnvironment.immersiveSpaceState = .inTransition
                switch await openImmersiveSpace(id: ImmersiveEnvironmentView.id) {
                case .opened:
                    // Don't set immersiveSpaceState to .open because there
                    // may be multiple paths to ImmersiveView.onAppear().
                    // Only set .open in ImmersiveView.onAppear().
                    break

                case .userCancelled, .error:
                    // On error, we need to mark the immersive space
                    // as closed because it failed to open.
                    fallthrough
                @unknown default:
                    // On unknown response, assume space did not open.
                    immersiveEnvironment.immersiveSpaceState = .closed
                }
            }
        } label: {
            label
        }
    }
}

