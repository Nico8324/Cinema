/*
See the LICENSE.txt file for licensing information.

Abstract:
A view that lets a person set their profile name and picture.
*/

import SwiftUI
#if !os(tvOS)
import PhotosUI
#endif

/// A view that lets a person set their profile name and picture.
struct EditProfileView: View {
    @AppStorage(ProfileStore.nameKey) private var profileName: String = ""

    #if !os(tvOS)
    @State private var selectedPhoto: PhotosPickerItem?
    #endif

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    photoButton
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            .listRowBackground(Color.clear)

            Section("Name") {
                TextField("Name", text: $profileName, prompt: Text("Your Name"))
                    #if !os(macOS)
                    .textInputAutocapitalization(.words)
                    #endif
                    .autocorrectionDisabled()
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .navigationTitle("Edit Profile")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if !os(tvOS)
        .onChange(of: selectedPhoto) { _, newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self) {
                    ProfileStore.savePhoto(data)
                }
            }
        }
        #endif
    }

    @ViewBuilder
    private var photoButton: some View {
        #if !os(tvOS)
        PhotosPicker(selection: $selectedPhoto, matching: .images) {
            // Built inline from fresh views: the picker's label closure is Sendable,
            // so it must not reference the view's main-actor properties.
            ProfilePhotoLabel()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose Photo")
        #else
        ProfilePhotoLabel()
        #endif
    }
}

/// The circular profile photo with a camera badge, used as the photo picker's label.
private struct ProfilePhotoLabel: View {
    var body: some View {
        ProfileImageView()
            .frame(width: 96, height: 96)
            .clipShape(Circle())
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "camera.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.multicolor)
                    .background(Circle().fill(.background))
            }
    }
}

#Preview {
    NavigationStack {
        EditProfileView()
    }
}
