/*
See the LICENSE.txt file for licensing information.

Abstract:
The seat picker shown alongside the player while the Theater environment is open.
*/

import SwiftUI
import Theater

/// The seat control: a small chair button that unfolds into a seating panel.
///
/// The panel mirrors Apple's Cinema seating grid — a row choice and a level choice.
struct TheaterSeatsView: View {
    var environment: ImmersiveEnvironment

    @State private var isExpanded = false

    var body: some View {
        if let current = environment.activeTheaterSeat {
            Group {
                if isExpanded {
                    panel(current: current)
                } else {
                    chairButton
                }
            }
            .glassBackgroundEffect()
            .animation(.snappy(duration: 0.25), value: isExpanded)
        }
    }

    private var chairButton: some View {
        Button {
            isExpanded = true
        } label: {
            Image(systemName: "chair")
                .font(.title3)
                .padding(14)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("Choose seat", comment: "Opens the Theater seat panel"))
    }

    private func panel(current: TheaterSeat) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(TheaterSeat.Row.allCases, id: \.self) { row in
                    choice(row.displayName, isCurrent: row == current.row) {
                        select(TheaterSeat(row: row, level: current.level))
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                ForEach(TheaterSeat.Level.allCases, id: \.self) { level in
                    choice(level.displayName, isCurrent: level == current.level) {
                        select(TheaterSeat(row: current.row, level: level))
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minWidth: 300)
    }

    private func choice(_ title: String, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .fontWeight(isCurrent ? .semibold : .regular)
        }
        .buttonStyle(.bordered)
        .tint(isCurrent ? Color.white : Color.secondary)
    }

    private func select(_ seat: TheaterSeat) {
        isExpanded = false
        Task { await environment.switchTheaterSeat(to: seat) }
    }
}

extension TheaterSeat.Row {
    var displayName: String {
        switch self {
        case .front: String(localized: "Front", comment: "Theater row")
        case .middle: String(localized: "Middle", comment: "Theater row")
        case .back: String(localized: "Back", comment: "Theater row")
        }
    }
}

extension TheaterSeat.Level {
    var displayName: String {
        switch self {
        case .floor: String(localized: "Floor", comment: "Theater level")
        case .balcony: String(localized: "Balcony", comment: "Theater level")
        }
    }
}
