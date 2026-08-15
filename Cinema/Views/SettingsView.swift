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

                Section("Library") {
                    LabeledContent("Videos", value: "\(videos.count)")
                    Button("Clear Library", role: .destructive) {
                        isConfirmingClear = true
                    }
                    .disabled(videos.isEmpty)
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
