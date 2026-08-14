/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A view that lets a person set their profile name and picture.
*/

import SwiftUI
#if !os(tvOS)
import PhotosUI
#endif

/// A view that lets a person set their profile name and picture.
struct EditProfileView: View {
    @AppStorage("profileName") private var profileName: String = "Anne Johnson"
    @AppStorage("profileImageData") private var profileImageData: Data?

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
                TextField("Name", text: $profileName)
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
                    profileImageData = data
                }
            }
        }
        #endif
    }

    @ViewBuilder
    private var photoButton: some View {
        #if !os(tvOS)
        PhotosPicker(selection: $selectedPhoto, matching: .images) {
            profileImage
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "camera.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.multicolor)
                        .background(Circle().fill(.background))
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose Photo")
        #else
        profileImage
        #endif
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
        .frame(width: 96, height: 96)
        .clipShape(Circle())
    }
}

#Preview {
    NavigationStack {
        EditProfileView()
    }
}
