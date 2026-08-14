/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The relationship between video, actor, writer, director, and genre.
*/

import Foundation

/// The relationship between video, actor, writer, director ,and genre.
struct RelationshipMapping: Decodable {
    let videoID: Int
    let actorIDs: [Int]
    let writerIDs: [Int]
    let directorIDs: [Int]
    let genreIDs: [Int]
}

extension SampleData {
    @MainActor static let relationships: [RelationshipMapping] = []
}
