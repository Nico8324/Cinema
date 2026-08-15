/*
See the LICENSE.txt file for licensing information.

Abstract:
The main app structure.
*/

import SwiftUI
import SwiftData
import os

/// The main app structure.
@main
struct Cinema: App {
    /// An object that manages the model storage configuration.
    private let modelContainer: ModelContainer

    /// An object that controls the video playback behavior.
    @State private var player: PlayerModel

    #if os(visionOS)
    /// An object that stores the app's level of immersion.
    @State private var immersiveEnvironment = ImmersiveEnvironment()
    /// The content brightness to apply to the immersive space.
    @State private var contentBrightness: ImmersiveContentBrightness = .automatic
    /// The effect modifies the passthrough in immersive space.
    @State private var surroundingsEffect: SurroundingsEffect? = nil
    #endif

    var body: some Scene {
        // The app's primary content window.
        WindowGroup {
            ContentView()
                .environment(player)
                .modelContainer(modelContainer)
                #if os(visionOS)
                .environment(immersiveEnvironment)
                #endif
                #if os(macOS)
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                #endif
                // Set minimum window size
                #if os(macOS) || os(visionOS)
                .frame(minWidth: Constants.contentWindowWidth, maxWidth: .infinity, minHeight: Constants.contentWindowHeight, maxHeight: .infinity)
                #endif
                // Use a dark color scheme on supported platforms.
                #if os(iOS) || os(macOS)
                .preferredColorScheme(.dark)
                #endif
        }
        #if !os(tvOS)
        .windowResizability(.contentSize)
        #endif

        // The video player window
        #if os(macOS)
        PlayerWindow(player: player)
        #endif

        #if os(visionOS)
        // Defines an immersive space to present a destination in which to watch the video.
        ImmersiveSpace(id: ImmersiveEnvironmentView.id) {
            ImmersiveEnvironmentView()
                .environment(immersiveEnvironment)
                .onAppear {
                    immersiveEnvironment.immersiveSpaceState = .open
                    contentBrightness = immersiveEnvironment.contentBrightness
                    surroundingsEffect = immersiveEnvironment.surroundingsEffect
                }
                .onDisappear {
                    immersiveEnvironment.immersiveSpaceState = .closed
                    contentBrightness = .automatic
                    surroundingsEffect = nil
                }
            // Apply a custom tint color for the video passthrough of a person's hands and surroundings.
                .preferredSurroundingsEffect(surroundingsEffect)
        }
        // Set the content brightness for the immersive space.
        .immersiveContentBrightness(contentBrightness)
        // Set the immersion style to progressive, so the user can use the Digital Crown to dial in their experience.
        .immersionStyle(selection: .constant(.progressive), in: .progressive)
        #endif
    }

    /// Initialize the model container and video player model.
    init() {
        // As a unit-test host, boot with a throwaway in-memory store and touch
        // nothing real: tests create their own containers, and registering the
        // model classes twice with mismatched schemas traps inside SwiftData.
        if NSClassFromString("XCTestCase") != nil {
            let schema = Schema(versionedSchema: CinemaSchemaV3.self)
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            guard let container = try? ModelContainer(for: schema, configurations: [config]) else {
                fatalError("Couldn't create the test-host model container.")
            }
            self.modelContainer = container
            self._player = State(initialValue: PlayerModel(modelContainer: container))
            return
        }

        let modelContainer = Self.makeModelContainer()
        self.modelContainer = modelContainer
        self._player = State(initialValue: PlayerModel(modelContainer: modelContainer))
        ProfileStore.migrateLegacyPhotoIfNeeded()
        // Sweep stranded files/entries once per launch, before any import can run.
        LibraryReconciler.reconcile(in: modelContainer.mainContext)
    }

    /// Opens the video library store, migrating it if needed.
    ///
    /// If the store can't be opened — a failed migration, corruption — the app must not crash
    /// at launch: the imported video files on disk are the source of truth for the heavy data,
    /// and the metadata is rebuildable. Instead, the broken store is moved aside and a fresh
    /// one is created.
    private static func makeModelContainer() -> ModelContainer {
        do {
            return try openModelContainer()
        } catch {
            logger.error("Couldn't open the video library store: \(error.localizedDescription)")
            moveBrokenStoreAside()
            do {
                return try openModelContainer()
            } catch {
                // Even a fresh store failed — something is wrong beyond the store itself.
                fatalError("Couldn't create a video library store: \(error.localizedDescription)")
            }
        }
    }

    private static func openModelContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CinemaSchemaV3.self)
        return try ModelContainer(
            for: schema,
            migrationPlan: CinemaMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema)]
        )
    }

    /// Renames the default store files so a fresh store can be created, preserving the broken
    /// one on disk for potential recovery instead of destroying data.
    private static func moveBrokenStoreAside() {
        let storeURL = URL.applicationSupportDirectory.appending(path: "default.store")
        let marker = UUID().uuidString
        for suffix in ["", "-shm", "-wal"] {
            let source = URL(filePath: storeURL.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let destination = URL(filePath: storeURL.path + ".broken-\(marker)" + suffix)
            try? FileManager.default.moveItem(at: source, to: destination)
        }
        logger.error("Moved the unreadable video library store aside; starting with a fresh library.")
    }
}

/// A global log of events for the app.
let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Cinema", category: "App")
