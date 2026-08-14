/*
See the LICENSE.txt file for this sample’s licensing information.

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

    @AppStorage("profileName") private var profileName: String = "Anne Johnson"
    @AppStorage("profileImageData") private var profileImageData: Data?

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
                            profileImage
                                .frame(width: 44, height: 44)
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profileName)
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

    private var profileImage: some View {
        Group {
            if let profileImageData, let platformImage = PlatformImage(data: profileImageData) {
                Image(platformImage: platformImage)
                    .resizable()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .scaledToFill()
    }

    /// Deletes every video from the library, including the locally imported files and thumbnails backing them.
    private func clearLibrary() {
        for video in videos {
            video.removeLocalFiles()
            context.delete(video)
        }
        try? context.save()
    }
}

#Preview(traits: .previewData) {
    SettingsView()
}
