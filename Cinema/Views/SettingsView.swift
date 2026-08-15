/*
See the LICENSE.txt file for licensing information.

Abstract:
A view that presents app settings, library management, and about info.
*/

import SwiftUI
import SwiftData

/// A view that presents app settings, library management, and about info.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @Query private var videos: [Video]

    @AppStorage(ProfileStore.nameKey) private var profileName: String = ""
    @AppStorage(TMDB.MovieList.storageKey) private var discoveryList: TMDB.MovieList = .nowPlaying
    @AppStorage(TMDB.ShowList.storageKey) private var tvDiscoveryList: TMDB.ShowList = .popular

    @State private var isConfirmingClear = false
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
            List {
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

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Build", value: buildNumber)
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .navigationTitle("Settings")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
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
        }
    }

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
