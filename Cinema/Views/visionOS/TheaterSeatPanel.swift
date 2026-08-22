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
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label {
                    Text("Seats", comment: "Theater seat panel title")
                        .font(.title3.weight(.semibold))
                } icon: {
                    Image(systemName: "chair.fill")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .padding(8)
                }
                .buttonStyle(.borderless)
                .glassBackgroundEffect(in: .circle)
                .accessibilityLabel(Text("Close", comment: "Closes the Theater seat panel"))
            }

            group(Text("Row", comment: "Theater seat panel group")) {
                Picker("", selection: Binding(
                    get: { current.row },
                    set: { select(TheaterSeat(row: $0, level: current.level)) }
                )) {
                    ForEach(TheaterSeat.Row.allCases, id: \.self) { row in
                        Text(row.displayName).tag(row)
                    }
                }
            }

            group(Text("Height", comment: "Theater seat panel group")) {
                Picker("", selection: Binding(
                    get: { current.level },
                    set: { select(TheaterSeat(row: current.row, level: $0)) }
                )) {
                    ForEach(TheaterSeat.Level.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
            }
        }
        .pickerStyle(.segmented)
        .padding(24)
        .frame(width: 380)
        .glassBackgroundEffect(in: .rect(cornerRadius: 28))
    }

    private func group<Content: View>(_ title: Text, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            title
                .font(.subheadline)
                .foregroundStyle(.secondary)
            content()
        }
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
