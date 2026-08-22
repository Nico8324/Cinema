/*
See the LICENSE.txt file for licensing information.

Abstract:
A view that presents app settings, library management, and about info.
*/

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// A view that presents app settings, library management, and about info.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(PlayerModel.self) private var player

    @Query private var videos: [Video]

    @AppStorage(ProfileStore.nameKey) private var profileName: String = ""
    @AppStorage(TMDB.MovieList.storageKey) private var discoveryList: TMDB.MovieList = .nowPlaying
    @AppStorage(TMDB.ShowList.storageKey) private var tvDiscoveryList: TMDB.ShowList = .popular
    @AppStorage(AppearanceSetting.storageKey) private var appearance: AppearanceSetting = .system
    @AppStorage(ArtworkStyle.storageKey) private var artworkStyle: ArtworkStyle = .wide

    @State private var isConfirmingClear = false
    #if os(macOS)
    @AppStorage(MediaFolderScanner.folderPathKey) private var mediaFolderPath = ""

    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @AppStorage(ConversionPlan.cropCostingAnEncodeKey) private var cropsWhenItCostsAnEncode = false
    @AppStorage(AutomaticConversion.enabledKey) private var convertsAutomatically = false
    @AppStorage(ConversionQueue.trashesOriginalsKey) private var trashesOriginals = false
    @State private var isTidying = false
    @AppStorage(PlayerModel.playsNextEpisodeKey) private var playsNextEpisode = true
    @AppStorage(ConversionPlan.keepsSourceQualityKey) private var keepsSourceQuality = false
    @AppStorage(TrackPlan.singleLanguageKey) private var keepsOnlyOriginalLanguage = true
    #endif
    @State private var isChoosingMediaFolder = false
    @State private var didCopyInstallCommand = false
    @State private var isScanningFolder = false
    @State private var scanSummary: String?
    #endif
    @State private var refreshProgress: (completed: Int, total: Int)?
    @State private var refreshSummary: String?

    /// Only matched titles have metadata to refresh.
    private var hasMatchedTitles: Bool {
        videos.contains { $0.tmdbID != nil || $0.tmdbShowID != nil }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    var body: some View {
        NavigationStack {
            container
                #if os(iOS)
                .listStyle(.insetGrouped)
                #endif
                .navigationTitle("Settings")
                #if !os(macOS) && !os(tvOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                // A Mac settings window closes itself from the menu bar or ⌘W; only the
                // platforms that present this as a sheet need a Done button.
                #if !os(macOS)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
                #endif
                .alert(
                    "Metadata Refreshed",
                    isPresented: .init(
                        get: { refreshSummary != nil },
                        set: { isPresented in if !isPresented { refreshSummary = nil } }
                    ),
                    presenting: refreshSummary
                ) { _ in
                    Button("OK") { }
                } message: { summary in
                    Text(summary)
                }
                .confirmationDialog(
                    "Clear your entire library?",
                    isPresented: $isConfirmingClear,
                    titleVisibility: .visible
                ) {
                    Button("Clear Library", role: .destructive) {
                        clearLibrary()
                    }
                } message: {
                    Text("This removes every video you’ve added. This can’t be undone.")
                }
                #if os(macOS)
                .fileImporter(
                    isPresented: $isChoosingMediaFolder,
                    allowedContentTypes: [.folder]
                ) { result in
                    switch result {
                    case .success(let folder):
                        mediaFolderPath = folder.path(percentEncoded: false)
                        scanMediaFolder()
                    case .failure(let error):
                        scanSummary = error.localizedDescription
                    }
                }
                #endif
        }
        #if os(macOS)
        // A settings window has no sheet to size it, and `Form` offers no height of its own.
        .frame(width: 540, height: 600)
        #endif
    }

    /// The settings rows, in whichever container the platform expects.
    @ViewBuilder
    private var container: some View {
        #if os(macOS)
        // Grouped `Form` is the Mac's settings idiom; a `List` there reads as a source list.
        Form { sections }
            .formStyle(.grouped)
            .sheet(isPresented: $isTidying) {
                if let folder = MediaFolderScanner.folderURL {
                    MediaFolderTidyView(folder: folder)
                }
            }
        #else
        List { sections }
        #endif
    }

    /// The settings content, shared by every platform.
    @ViewBuilder
    private var sections: some View {
                Section {
                    Toggle("Play Next Episode Automatically", isOn: $playsNextEpisode)
                } header: {
                    Text("Playback")
                } footer: {
                    Text("""
                        When an episode ends, the next one is offered with ten seconds to decline. \
                        Only for series — a film has no next episode, and rolling from one film \
                        into an unrelated one is what a channel does, not a library.
                        """)
                }

                Section("Profile") {
                    NavigationLink {
                        EditProfileView()
                    } label: {
                        HStack(spacing: 12) {
                            ProfileImageView()
                                .frame(width: 44, height: 44)
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profileName.isEmpty ? String(localized: "Set Up Your Profile") : profileName)
                                Text("Edit profile")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    LabeledContent("Videos", value: "\(videos.count)")
                    if let progress = refreshProgress {
                        HStack {
                            Text("Refreshing Metadata…")
                            Spacer()
                            if progress.total > 0 {
                                Text("\(progress.completed)/\(progress.total)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            ProgressView()
                                .controlSize(.small)
                        }
                    } else {
                        Button("Refresh Metadata") {
                            refreshMetadata()
                        }
                        .disabled(!hasMatchedTitles)
                    }
                    Button("Clear Library", role: .destructive) {
                        isConfirmingClear = true
                    }
                    .disabled(videos.isEmpty)
                } header: {
                    Text("Library")
                } footer: {
                    Text("Refresh Metadata re-downloads titles, artwork, and details from The Movie Database for every matched video and show.")
                }

                Section {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppearanceSetting.allCases) { setting in
                            Text(setting.displayName).tag(setting)
                        }
                    }
                    Picker("Artwork", selection: $artworkStyle) {
                        ForEach(ArtworkStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                } footer: {
                    Text("Automatic follows your device’s light or dark setting. Artwork chooses the shape of every card in your library: wide scene images, or portrait posters.")
                }

                Section {
                    Picker("Movies Row", selection: $discoveryList) {
                        ForEach(TMDB.MovieList.allCases) { list in
                            Text(list.displayName).tag(list)
                        }
                    }
                    Picker("Shows Row", selection: $tvDiscoveryList) {
                        ForEach(TMDB.ShowList.allCases) { list in
                            Text(list.displayName).tag(list)
                        }
                    }
                } header: {
                    Text("Watch Now")
                } footer: {
                    Text("Which movies and TV shows from The Movie Database appear at the bottom of Watch Now.")
                }

                #if os(macOS)
                Section {
                    if mediaFolderPath.isEmpty {
                        Button("Choose Folder…") { isChoosingMediaFolder = true }
                    } else {
                        LabeledContent("Folder") {
                            Text(URL(filePath: mediaFolderPath).lastPathComponent)
                                .foregroundStyle(.secondary)
                                .truncationMode(.middle)
                                .help(mediaFolderPath)
                        }
                        HStack {
                            Button("Change…") { isChoosingMediaFolder = true }
                                .disabled(isScanningFolder)
                            Button("Scan Now") { scanMediaFolder() }
                                .disabled(isScanningFolder)
                            if isScanningFolder {
                                ProgressView().controlSize(.small)
                            }
                            Spacer()
                            Button("Stop Scanning", role: .destructive) { mediaFolderPath = "" }
                        }
                        if let scanSummary {
                            Text(scanSummary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Media Folder")
                } footer: {
                    Text("Videos in this folder are added to your library and played where they are — they aren't copied, and Cinema never moves or deletes them. The folder is rescanned each time the app opens.")
                }

                Section {
                    LabeledContent("Video Tools") {
                        Label {
                            Text(converterStatusText)
                        } icon: {
                            Image(systemName: converterStatusSymbol)
                                .foregroundStyle(converterStatusTint)
                        }
                        .labelStyle(.titleAndIcon)
                    }
                    if !ConverterTools.installCommand.isEmpty {
                        HStack {
                            Text(ConverterTools.installCommand)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer(minLength: 12)
                            Button(didCopyInstallCommand ? "Copied" : "Copy") {
                                copyInstallCommand()
                            }
                            .disabled(didCopyInstallCommand)
                        }
                    }
                    Toggle("Convert Automatically", isOn: $convertsAutomatically)
                    Toggle("Move Originals to Trash", isOn: $trashesOriginals)
                        .disabled(!convertsAutomatically)
                    Toggle("Keep Original Quality", isOn: $keepsSourceQuality)
                    Toggle("One Language Only", isOn: $keepsOnlyOriginalLanguage)
                    Toggle("Crop Black Bars", isOn: $cropsWhenItCostsAnEncode)
                    Button("Show Conversion Queue…") {
                        openWindow(id: ConversionQueueView.windowID)
                    }
                    .disabled(ConverterTools.readiness == .unavailable || mediaFolderPath.isEmpty)
                    Button("Tidy Media Folder…") { isTidying = true }
                        .disabled(mediaFolderPath.isEmpty)
                } header: {
                    Text("Conversion")
                } footer: {
                    Text("""
                        Videos that aren’t MP4 — MKV and the rest — can’t join your library until they’re \
                        converted. Cinema uses the tools already installed on this Mac rather than shipping \
                        copies of them, and never modifies your originals. Converting is available on Mac only.
                        
                        One Language Only keeps the language a film was made in and drops every dub, \
                        commentary and foreign subtitle — a couple of per cent on one film, tens of \
                        gigabytes across a hundred. Your originals keep everything, so a film can be \
                        converted again with its other languages whenever you want them.
                        
                        Cinema aims for the file Apple would have made from the same source: a film \
                        costing far more than Apple spends is rebuilt to Apple’s own rate, and a 74 GB \
                        disc becomes about 22 GB. Keep Original Quality copies those films untouched \
                        instead — the studio’s own picture and its black bars, at several times the size.
                        
                        Crop Black Bars re-encodes widescreen films that could otherwise be copied straight \
                        across. Copying keeps the picture exactly as the studio mastered it and takes minutes; \
                        cropping gives a frame without bars and takes hours.
                        
                        Convert Automatically converts anything you drop into the media folder without \
                        being asked, one film at a time. It’s off to begin with, because a conversion \
                        takes hours and makes choices about your films — the queue window shows what \
                        those choices would be, and it’s worth reading a few before leaving it running.
                        
                        Tidy Media Folder renames videos converted before these rules existed — \
                        the release group's name becomes the film's, and episodes move into folders \
                        by show and season. It lists everything it would do first, and updates your \
                        library so nothing stops playing.
                        
                        Move Originals to Trash puts each source in the Trash once its converted copy \
                        has been checked for a picture that renders, a container that parses, Dolby \
                        Vision an Apple device accepts, and frame-for-frame parity. A conversion that \
                        fails any of those deletes itself and leaves the original where it is. Nothing \
                        is ever deleted outright, so the Trash is your way back.
                        """)
                }
                #endif

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Build", value: buildNumber)
                }
    }

    #if os(macOS)
    /// What the converter can do right now, said in terms of what it means for the library
    /// rather than which binaries happen to be on disk.
    private var converterStatusText: String {
        switch ConverterTools.readiness {
        case .ready:
            String(localized: "Ready, including Dolby Vision")
        case .readyWithoutDolbyVision:
            String(localized: "Ready — Dolby Vision films convert as HDR10")
        case .unavailable:
            String(localized: "ffmpeg not found")
        }
    }

    private var converterStatusSymbol: String {
        switch ConverterTools.readiness {
        case .ready: "checkmark.circle.fill"
        case .readyWithoutDolbyVision: "exclamationmark.triangle.fill"
        case .unavailable: "xmark.circle.fill"
        }
    }

    private var converterStatusTint: Color {
        switch ConverterTools.readiness {
        case .ready: .green
        case .readyWithoutDolbyVision: .orange
        case .unavailable: .red
        }
    }

    private func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ConverterTools.installCommand, forType: .string)
        didCopyInstallCommand = true
        // Return the button to its resting label so it reads as a control rather than a receipt.
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopyInstallCommand = false
        }
    }

    /// Adds any videos in the chosen folder that the library doesn't already reference.
    private func scanMediaFolder() {
        // Non-reentrant: two overlapping scans each read the set of already-known paths before
        // either has saved, so every file they share is inserted twice. Disabling the buttons
        // isn't enough on its own — the folder picker calls straight through to here.
        guard !isScanningFolder, let folder = MediaFolderScanner.folderURL else { return }
        isScanningFolder = true
        Task {
            let outcome = await MediaFolderScanner.scan(folder: folder, into: context)
            isScanningFolder = false
            if outcome.folderUnreachable {
                scanSummary = String(localized: "That folder can’t be reached right now.")
            } else if outcome.added == 0 {
                scanSummary = String(localized: "No new videos found.")
            } else {
                let added = outcome.added == 1
                    ? String(localized: "Added 1 video.")
                    : String(localized: "Added \(outcome.added) videos.")
                scanSummary = outcome.matched > 0
                    ? added + " " + String(localized: "Matched \(outcome.matched) with The Movie Database.")
                    : added
            }
        }
    }
    #endif

    /// Re-downloads TMDB metadata for every matched title, with live progress.
    private func refreshMetadata() {
        refreshProgress = (0, 0)
        Task {
            let outcome = await TMDB.refreshLibraryMetadata(in: context) { completed, total in
                refreshProgress = (completed, total)
            }
            refreshProgress = nil

            var parts = [outcome.updated == 1
                         ? String(localized: "Updated 1 title.")
                         : String(localized: "Updated \(outcome.updated) titles.")]
            if outcome.failed > 0 {
                parts.append(outcome.failed == 1
                             ? String(localized: "1 title couldn’t be refreshed.")
                             : String(localized: "\(outcome.failed) titles couldn’t be refreshed."))
            }
            refreshSummary = parts.joined(separator: " ")
        }
    }

    /// Deletes every video from the library, including the locally imported files and thumbnails backing them.
    private func clearLibrary() {
        for video in videos {
            // The player writes progress to its loaded video on a timer; deleting that row
            // without telling it traps within seconds.
            player.videoWillBeDeleted(video)
            video.removeLocalFiles()
            context.delete(video)
        }
        // A cleared library keeps no series either — a Show row is meaningless without the
        // possibility of the episodes it groups, and stale rows would hand a future re-import
        // an identity it never asked for.
        for show in (try? context.fetch(FetchDescriptor<Show>())) ?? [] {
            context.delete(show)
        }
        Genre.deleteOrphaned(in: context)
        context.saveReportingErrors()
    }
}

#Preview(traits: .previewData) {
    SettingsView()
}
