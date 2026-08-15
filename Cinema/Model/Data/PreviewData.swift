/*
See the LICENSE.txt file for licensing information.

Abstract:
A modifier that creates a model container with sample content for previews.
*/

import Foundation
import SwiftData
import SwiftUI

/// A modifier that creates a model container with sample content for previews.
///
/// Preview videos have no media files behind them — they exist so previews show
/// realistic populated states instead of empty ones.
struct PreviewData: PreviewModifier {
    static func makeSharedContext() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Video.self, Genre.self, UpNextItem.self,
            configurations: config
        )
        makeSampleLibrary(in: container.mainContext)
        return container
    }

    private static func makeSampleLibrary(in context: ModelContext) {
        let drama = Genre(name: "Drama")
        let sciFi = Genre(name: "Sci-Fi")
        let documentary = Genre(name: "Documentary")

        let videos = [
            Video(
                name: "A Beautiful Journey",
                synopsis: "An intimate portrait of a family crossing a continent in search of a new beginning.",
                genres: [drama],
                yearOfRelease: 2024,
                duration: 7_260,
                contentRating: "PG-13",
                playbackPosition: 2_400,
                lastWatchedDate: .now
            ),
            Video(
                name: "Beyond the Outer Rim",
                synopsis: "A deep-space crew answers a distress call from a station that shouldn't exist.",
                genres: [sciFi],
                yearOfRelease: 2025,
                duration: 8_040,
                contentRating: "PG-13"
            ),
            Video(
                name: "The Reef at Dawn",
                synopsis: "A year in the life of a coral reef, filmed across four seasons.",
                genres: [documentary],
                yearOfRelease: 2023,
                duration: 3_300,
                contentRating: "G"
            )
        ]
        videos.forEach(context.insert)
        videos.last?.toggleUpNext(in: context)
        try? context.save()
    }

    func body(content: Content, context: ModelContainer) -> some View {
        content.modelContainer(context)
            .environment(PlayerModel(modelContainer: context))
            #if os(visionOS)
            .environment(ImmersiveEnvironment())
            #endif
            #if os(iOS) || os(macOS)
            .preferredColorScheme(.dark)
            #endif
    }
}

extension PreviewTrait where T == Preview.ViewTraits {
    @MainActor static var previewData: Self = .modifier(PreviewData())
}
