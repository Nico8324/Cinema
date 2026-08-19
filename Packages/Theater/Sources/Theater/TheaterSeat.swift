//
//  A seat in the Theater environment.
//

import Foundation
import simd

/// A place to sit in the theater: a row on one of two levels.
///
/// Apple's Cinema environment offers exactly this grid — Front/Middle/Back on Floor or
/// Balcony. The room never changes; a seat is a position inside it, and choosing one moves the
/// whole room by the inverse of the seat's offset (the head stays fixed in visionOS — the
/// world moves). A rigid move preserves the baked light-spill UVs exactly.
public struct TheaterSeat: Hashable, Sendable {
    public enum Row: String, CaseIterable, Sendable {
        case front, middle, back
    }

    public enum Level: String, CaseIterable, Sendable {
        case floor, balcony
    }

    public var row: Row
    public var level: Level

    public init(row: Row, level: Level) {
        self.row = row
        self.level = level
    }

    /// The default seat: middle of the floor.
    public static let middle = TheaterSeat(row: .middle, level: .floor)

    public static var allCases: [TheaterSeat] {
        Level.allCases.flatMap { level in Row.allCases.map { TheaterSeat(row: $0, level: level) } }
    }

    /// A stable name for launch arguments and logs, e.g. "middle" or "back-balcony".
    public var name: String {
        level == .floor ? row.rawValue : "\(row.rawValue)-balcony"
    }

    public init?(name: String) {
        let parts = name.split(separator: "-").map(String.init)
        guard let row = Row(rawValue: parts.first ?? "") else { return nil }
        self.row = row
        self.level = parts.count > 1 && parts[1] == Level.balcony.rawValue ? .balcony : .floor
    }

    /// Where this seat's eye point sits in the room's coordinates.
    ///
    /// The room is authored around the orchestra's middle seat: its eye is the origin, the
    /// screen hangs at (0, 2.35, -10.2). The floor slopes toward the screen — front rows sit
    /// lower. The balcony is a full upper tier, not a rear deck: Apple's captures of all six
    /// seats (`~/Xcode/Cinema-Backups/cinema apple variations/`) show each balcony row keeping its floor counterpart's
    /// angular screen size, so each balcony seat preserves its row's slant distance to the
    /// screen while rising ~3 m.
    public var eyeOffset: SIMD3<Float> {
        switch (level, row) {
        case (.floor, .front): [0, -0.65, -4.65]
        case (.floor, .middle): .zero
        case (.floor, .back): [0, 0.45, 4.3]
        case (.balcony, .front): [0, 2.6, -5.3]
        case (.balcony, .middle): [0, 3.0, -0.45]
        case (.balcony, .back): [0, 3.4, 3.9]
        }
    }

    /// The transform the theater root takes so this seat lands under the viewer.
    public var roomTransform: SIMD3<Float> { -eyeOffset }
}
