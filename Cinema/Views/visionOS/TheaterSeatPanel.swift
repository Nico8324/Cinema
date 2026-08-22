/*
See the LICENSE.txt file for licensing information.

Abstract:
The seat controls of the Theater: an icon at the viewer's feet, and the panel it opens.
*/

import SwiftUI
import Theater

/// The icon lying on the floor under the viewer. Tapping it opens the seat panel.
struct TheaterSeatMarker: View {
    var isOpen: Bool
    var toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: isOpen ? "chair.fill" : "chair")
                .font(.system(size: 34, weight: .medium))
                .padding(22)
        }
        .buttonStyle(.borderless)
        .glassBackgroundEffect(in: .circle)
        .accessibilityLabel(Text("Choose seat", comment: "Opens the Theater seat panel"))
    }
}

/// The seat panel: Row and Height, mirroring Apple's Cinema seating grid.
struct TheaterSeatPanel: View {
    var current: TheaterSeat
    var select: (TheaterSeat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Row", comment: "Theater seat panel group")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(TheaterSeat.Row.allCases, id: \.self) { row in
                    choice(row.displayName, isCurrent: row == current.row) {
                        select(TheaterSeat(row: row, level: current.level))
                    }
                }
            }
            Text("Height", comment: "Theater seat panel group")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(TheaterSeat.Level.allCases, id: \.self) { level in
                    choice(level.displayName, isCurrent: level == current.level) {
                        select(TheaterSeat(row: current.row, level: level))
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(minWidth: 320)
        .glassBackgroundEffect()
    }

    private func choice(_ title: String, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).fontWeight(isCurrent ? .semibold : .regular)
        }
        .buttonStyle(.bordered)
        .tint(isCurrent ? Color.white : Color.secondary)
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
        case .floor: String(localized: "Orchestra", comment: "Theater level")
        case .balcony: String(localized: "Balcony", comment: "Theater level")
        }
    }
}
