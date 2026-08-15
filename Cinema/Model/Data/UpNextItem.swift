/*
See the LICENSE.txt file for licensing information.

Abstract:
A model class that defines the properties of a video item in the up next queue.
*/

import Foundation
import SwiftData

/// A model class that defines the properties of a video item in the up next queue.
///
/// `Video.upNextItem` declares a cascade delete rule toward this entity, so deleting a
/// video also removes its queue entry.
@Model
final class UpNextItem {
    @Relationship(deleteRule: .nullify)
    var video: Video?

    var createdAt: Date

    init(video: Video, createdAt: Date = .now) {
        self.video = video
        self.createdAt = createdAt
    }
}
