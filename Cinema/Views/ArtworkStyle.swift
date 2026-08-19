/*
See the LICENSE.txt file for licensing information.

Abstract:
Whether the library shows films as wide cards or as portrait posters.
*/

import SwiftUI

/// How artwork is shaped throughout the app.
///
/// The two shapes come from different sources and say different things. A wide card is the film's
/// backdrop — a frame from the film, which reads as "this is playing". A poster is the artwork the
/// studio designed to be recognised at a glance in a grid. Neither is right for everyone, so it's a
/// choice rather than a decision.
enum ArtworkStyle: String, CaseIterable, Identifiable {
    case wide
    case poster

    /// The Settings key holding the choice.
    static let storageKey = "artworkStyle"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wide: String(localized: "Wide")
        case .poster: String(localized: "Poster")
        }
    }

    /// The current choice, for the places that need it outside a SwiftUI view.
    static var current: ArtworkStyle {
        UserDefaults.standard.string(forKey: storageKey).flatMap(ArtworkStyle.init(rawValue:)) ?? .wide
    }

    /// How wide a card is compared to the wide-artwork card it replaces.
    ///
    /// A poster at the backdrop's width would tower over the row — a 300-point card would stand
    /// 450 points tall. Narrowing it keeps rows roughly the height they already are.
    var cardWidthScale: Double {
        switch self {
        case .wide: 1
        case .poster: 0.62
        }
    }

    /// How wide a card of this style is, so every row showing the same shape lines up.
    ///
    /// Discovery rows used to size themselves independently, which was right when they were the
    /// only portrait posters on the screen — a 2:3 card beside a 16:9 one reads as a different kind
    /// of thing, deliberately. In poster mode everything is a poster, and the same difference stops
    /// being a distinction and becomes a row that doesn't line up.
    func cardWidth(isCompact: Bool) -> Double {
        (isCompact ? Constants.compactVideoCardWidth : Constants.videoCardWidth) * cardWidthScale
    }

    /// How many extra grid columns fit, now that each card is narrower.
    var extraGridColumns: Int {
        switch self {
        case .wide: 0
        case .poster: 2
        }
    }

    /// The shape a card takes: 16:9 for a backdrop, 2:3 for a poster — the ratios the artwork is
    /// actually published at, so neither is cropped to fit.
    var aspectRatio: Double {
        switch self {
        case .wide: 16.0 / 9.0
        case .poster: 2.0 / 3.0
        }
    }
}
