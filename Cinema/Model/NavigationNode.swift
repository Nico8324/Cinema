/*
See the LICENSE.txt file for licensing information.

Abstract:
A single unit in the app's navigation stack.
*/

import SwiftUI

/// A single unit in the app's navigation stack.
///
/// Navigation is value-based: nodes carry a stable identity, never a model object,
/// so paths stay serializable and deep-link ready.
enum NavigationNode: Equatable, Hashable {
    case video(Video.ID)
    case show(String)
}
