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
    /// How much of the real world the open environment replaces.
    @State private var immersionStyle: any ImmersionStyle = .progressive
    #endif

    #if os(macOS)
    @State private var automaticConversion = AutomaticConversion()
    @AppStorage(AutomaticConversion.enabledKey) private var automaticallyConverts = false
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
                // Episodes that arrived before shows were rows of their own, or from an older
                // build, get the series they belong to. On **every** platform: the V7 → V8
                // backfill is not a Mac concern, and an iPhone library that never ran it would
                // keep `show == nil` on every existing episode for good. It was inside the macOS
                // block only because the folder scan it sat next to is Mac-only.
                //
                // Cheap and idempotent: on a library that is already correct it fetches nothing.
                .task { ShowReconciler.reconcile(in: modelContainer.mainContext) }
                #if os(macOS)
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                // Pick up whatever landed in the media folder since the app last ran, so the
                // library reflects the folder without anyone having to ask it to.
                .task {
                    guard let folder = MediaFolderScanner.folderURL else { return }
                    _ = await MediaFolderScanner.scan(folder: folder, into: modelContainer.mainContext)
                    // Then, if it's been asked for, convert whatever the library couldn't take —
                    // after the scan rather than before, so a film converted on a previous run is
                    // already in the library and isn't planned a second time.
                    automaticConversion.start(folder: folder) {
                        Task {
                            _ = await MediaFolderScanner.scan(folder: folder,
                                                              into: modelContainer.mainContext)
                        }
                    }
                }
                .onChange(of: automaticallyConverts) { _, isOn in
                    guard isOn, let folder = MediaFolderScanner.folderURL else {
                        automaticConversion.stop()
                        return
                    }
                    automaticConversion.start(folder: folder) {
                        Task {
                            _ = await MediaFolderScanner.scan(folder: folder,
                                                              into: modelContainer.mainContext)
                        }
                    }
                }
                #endif
                // Set minimum window size
                #if os(macOS) || os(visionOS)
                .frame(minWidth: Constants.contentWindowWidth, maxWidth: .infinity, minHeight: Constants.contentWindowHeight, maxHeight: .infinity)
                #endif
                // Follow the user's appearance choice (Settings > Appearance);
                // the default tracks the device's light/dark setting.
                #if os(iOS) || os(macOS)
                .appAppearance()
                #endif
        }
        #if os(macOS)
        // Open at the TV app's window size rather than collapsing onto the content's minimum.
        // `.contentSize` would pin the window to that minimum and ignore this; `.contentMinSize`
        // keeps the minimum as a floor and lets the person resize above it.
        .defaultSize(width: Constants.defaultWindowWidth, height: Constants.defaultWindowHeight)
        .windowResizability(.contentMinSize)
        #elseif !os(tvOS)
        .windowResizability(.contentSize)
        #endif

        // The video player window
        #if os(macOS)
        PlayerWindow(player: player)

        // The conversion queue gets a window rather than a Settings pane: it's a working list a
        // person leaves open next to the library, not a preference they set once.
        Window("Conversion Queue", id: ConversionQueueView.windowID) {
            ConversionQueueView()
                .appAppearance()
        }
        .defaultSize(width: 760, height: 560)
        .keyboardShortcut("k", modifiers: [.command, .shift])

        // Settings belong in their own window off the app menu on the Mac (⌘,), the way every
        // Mac app puts them, rather than in a sheet over the library.
        Settings {
            SettingsView()
                .environment(player)
                .modelContainer(modelContainer)
        }
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
                    immersionStyle = immersiveEnvironment.immersionStyle
                }
                .onDisappear {
                    immersiveEnvironment.immersiveSpaceState = .closed
                    contentBrightness = .automatic
                    surroundingsEffect = nil
                    immersionStyle = .progressive
                }
            // Apply a custom tint color for the video passthrough of a person's hands and surroundings.
                .preferredSurroundingsEffect(surroundingsEffect)
        }
        // Set the content brightness for the immersive space.
        .immersiveContentBrightness(contentBrightness)
        // Studio is progressive, so the user can use the Digital Crown to dial in their
        // experience; the theater is full, because a cinema with the wall open isn't one.
        .immersionStyle(selection: $immersionStyle, in: .progressive, .full)
        #endif
    }

    /// Initialize the model container and video player model.
    init() {
        // As a unit-test host, boot with a throwaway in-memory store and touch
        // nothing real: tests create their own containers, and registering the
        // model classes twice with mismatched schemas traps inside SwiftData.
        if NSClassFromString("XCTestCase") != nil {
            let schema = Schema(versionedSchema: CinemaSchemaV8.self)
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            guard let container = try? ModelContainer(for: schema, configurations: [config]) else {
                fatalError("Couldn't create the test-host model container.")
            }
            self.modelContainer = container
            self._player = State(initialValue: PlayerModel(modelContainer: container))
            return
        }

        #if os(macOS)
        // Move the media directories into the app's own root before anything reads the store —
        // the reconciler below judging rows against a still-empty new root would strand every
        // imported file.
        MediaStore.migrateLegacySharedDirectoriesIfNeeded()
        #endif
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

    /// Where the library lives on disk.
    ///
    /// Explicit rather than SwiftData's default, because the default is
    /// `Application Support/default.store` — a path every unsandboxed app that takes the default
    /// shares. The Mac app runs without a sandbox, and another app's store was found at that path:
    /// Cinema couldn't migrate it, filed it as broken, and took the location over, leaving two
    /// apps trading one file back and forth. A name of Cinema's own ends the fight.
    /// iOS and visionOS keep the historical default; inside a sandbox it was never shared, and
    /// moving it would orphan every existing library.
    private static var storeURL: URL {
        #if os(macOS)
        URL.applicationSupportDirectory.appending(path: "Cinema/Cinema.store")
        #else
        URL.applicationSupportDirectory.appending(path: "default.store")
        #endif
    }

    private static func openModelContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CinemaSchemaV8.self)
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return try ModelContainer(
            for: schema,
            migrationPlan: CinemaMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: storeURL)]
        )
    }

    /// Renames the default store files so a fresh store can be created, preserving the broken
    /// one on disk for potential recovery instead of destroying data.
    private static func moveBrokenStoreAside() {
        let storeURL = Self.storeURL
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
