/*
See the LICENSE.txt file for licensing information.

Abstract:
A description of the tabs that the app can present.
*/

import SwiftUI

/// A description of the tabs that the app can present.
enum Tabs: Equatable, Hashable, Identifiable {
    case watchNow
    case library
    case search

    var id: Int {
        switch self {
        case .watchNow: 2001
        case .library: 2004
        case .search: 2005
        }
    }

    var name: String {
        switch self {
        case .watchNow: String(localized: "Watch Now", comment: "Tab title")
        case .library: String(localized: "Library", comment: "Tab title")
        case .search: String(localized: "Search", comment: "Tab title")
        }
    }

    var customizationID: String {
        return "com.vanardoisnicolas.Cinema." + self.name
    }

    var symbol: String {
        switch self {
        case .watchNow: "play"
        case .library: "books.vertical"
        case .search: "magnifyingglass"
        }
    }
}
