/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A model class that defines the properties of a genre.
*/

import Foundation
import SwiftData

/// A model class that defines the properties of a genre.
@Model
final class Genre: Identifiable {
    @Relationship
    var videos: [Video]
    
    var id: Int
    var name: String
    
    init(
        id: Int,
        name: String,
        videos: [Video] = []
    ) {
        self.videos = videos
        self.id = id
        self.name = name
    }
}

extension Genre {
    var localizedName: String {
        String(localized: LocalizedStringResource(stringLiteral: self.name))
    }
}

extension SampleData {
    @MainActor static let genres: [Genre] = []
}
