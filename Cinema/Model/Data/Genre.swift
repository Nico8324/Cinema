/*
See the LICENSE.txt file for licensing information.

Abstract:
A model class that defines the properties of a genre.
*/

import Foundation
import SwiftData

/// A model class that defines the properties of a genre.
///
/// Genres come from a fixed vocabulary (see `EditVideoView.genreChoices`) and are found-or-created
/// by name, so the name effectively is the identity.
@Model
final class Genre {
    @Relationship
    var videos: [Video]

    var name: String

    init(name: String, videos: [Video] = []) {
        self.videos = videos
        self.name = name
    }
}

extension Genre {
    /// The display name. Genre names come from the app's own fixed vocabulary, so they're
    /// legitimate localization keys (unlike user-entered text, which must never be localized).
    var localizedName: String {
        String(localized: LocalizedStringResource(stringLiteral: self.name))
    }

    /// Deletes genres that no longer have any videos, so the Library's filter row
    /// doesn't accumulate dead pills.
    static func deleteOrphaned(in context: ModelContext) {
        guard let genres = try? context.fetch(FetchDescriptor<Genre>()) else { return }
        for genre in genres where genre.videos.isEmpty {
            context.delete(genre)
        }
    }
}
