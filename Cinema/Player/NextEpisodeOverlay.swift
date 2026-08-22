/*
See the LICENSE.txt file for licensing information.

Abstract:
The offer to roll into the following episode, and the chance to decline it.
*/

import SwiftUI

/// Offers the episode that follows the one just finished.
///
/// A countdown rather than an immediate cut. Starting the next episode the instant the credits
/// roll is the behaviour people disable the whole feature over — what makes it welcome is that
/// declining takes one obvious button and no hurry, and that it says which episode is coming
/// rather than simply continuing.
struct NextEpisodeOverlay: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        if let next = model.pendingNextEpisode {
            VStack(alignment: .leading, spacing: 12) {
                Text("Up Next")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Text(next.displayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)

                HStack(spacing: 10) {
                    Button {
                        model.playNextEpisodeNow()
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    #if !os(tvOS)
                    // Return plays, Escape declines. tvOS has no keyboard and no such modifier;
                    // its remote drives the focused button directly.
                    .keyboardShortcut(.defaultAction)
                    #endif

                    Button("Cancel") { model.cancelNextEpisode() }
                    #if !os(tvOS)
                        .keyboardShortcut(.cancelAction)
                    #endif
                }
                .buttonStyle(.borderedProminent)

                // The number is the whole point: it says how long you have to object.
                Text("Starting in \(model.secondsUntilNextEpisode)s")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(18)
            .frame(maxWidth: 320, alignment: .leading)
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
            .shadow(radius: 20)
            .padding(28)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
    }
}
