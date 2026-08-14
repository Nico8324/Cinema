/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A model class that defines the properties of a person.
*/

import Foundation
import SwiftData

/// A model class that defines the properties of a person.
@Model
final class Person {
    @Relationship
    var appearsIn: [Video]
    
    @Relationship
    var wrote: [Video]
    
    @Relationship
    var directed: [Video]
    
    var id: Int
    var initial: String
    var surname: String
    
    init(
        id: Int,
        initial: String,
        surname: String,
        appearsIn: [Video] = [],
        wrote: [Video] = [],
        directed: [Video] = []
    ) {
        self.appearsIn = appearsIn
        self.wrote = wrote
        self.directed = directed
        self.id = id
        self.initial = initial
        self.surname = surname
    }
}

extension Person {
    var displayName: String {
        PersonNameComponents(givenName: initial, familyName: surname).formatted()
    }
}

extension SampleData {
    @MainActor static let people: [Person] = []
}
