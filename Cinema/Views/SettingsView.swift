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

    @Query private var videos: [Video]

    @AppStorage(ProfileStore.nameKey) private var profileName: String = ""
    @AppStorage(TMDB.MovieList.storageKey) private var discoveryList: TMDB.MovieList = .nowPlaying
    @AppStorage(TMDB.ShowList.storageKey) private var tvDiscoveryList: TMDB.ShowList = .popular
    @AppStorage(AppearanceSetting.storageKey) private var appearance: AppearanceSetting = .system

    @State private var isConfirmingClear = false
    #if os(macOS)
    @AppStorage(MediaFolderScanner.folderPathKey) private var mediaFolderPath = ""
    @State private var isChoosingMediaFolder = false
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
        #else
        List { sections }
        #endif
    }

    /// The settings content, shared by every platform.
    @ViewBuilder
    private var sections: some View {
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
                } footer: {
                    Text("Automatic follows your device’s light or dark setting.")
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
                #endif

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Build", value: buildNumber)
                }
    }

    #if os(macOS)
    /// Adds any videos in the chosen folder that the library doesn't already reference.
    private func scanMediaFolder() {
        guard let folder = MediaFolderScanner.folderURL else { return }
        isScanningFolder = true
        Task {
            let outcome = await MediaFolderScanner.scan(folder: folder, into: context)
            isScanningFolder = false
            if outcome.folderUnreachable {
                scanSummary = String(localized: "That folder can’t be reached right now.")
            } else if outcome.added == 0 {
                scanSummary = String(localized: "No new videos found.")
            } else if outcome.added == 1 {
                scanSummary = String(localized: "Added 1 video.")
            } else {
                scanSummary = String(localized: "Added \(outcome.added) videos.")
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
            video.removeLocalFiles()
            context.delete(video)
        }
        Genre.deleteOrphaned(in: context)
        context.saveReportingErrors()
    }
}

#Preview(traits: .previewData) {
    SettingsView()
}
