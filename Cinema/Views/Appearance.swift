/*
See the LICENSE.txt file for licensing information.

Abstract:
The user's appearance choice: follow the system, or force light or dark.
*/

import SwiftUI

/// The user's appearance choice, picked in Settings. The default follows the
/// device's light/dark setting.
enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    /// The Settings key holding the user's choice.
    static let storageKey = "appearance"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: String(localized: "Automatic")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    /// The scheme to apply; `nil` follows the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Applies the user's appearance choice. Sheets present in their own window
/// context, so every sheet root applies this too — matching the app's root.
private struct AppAppearanceModifier: ViewModifier {
    @AppStorage(AppearanceSetting.storageKey) private var appearance: AppearanceSetting = .system

    func body(content: Content) -> some View {
        content.preferredColorScheme(appearance.colorScheme)
    }
}

extension View {
    func appAppearance() -> some View {
        modifier(AppAppearanceModifier())
    }
}
