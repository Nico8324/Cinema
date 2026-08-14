/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A view that presents a profile button for touch and pointer-based platforms.
*/

import SwiftUI

/// A view that presents a profile button for touch and pointer-based platforms.
struct ProfileMenuButton: View {
    @AppStorage("profileImageData") private var profileImageData: Data?

    @State private var isShowingSettings = false

    var body: some View {
        Button {
            isShowingSettings = true
        } label: {
            profileImage
                .frame(width: 32, height: 32)
                .clipShape(Circle())
                .padding(10)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
        .padding(Constants.outerPadding)
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
    }

    private var profileImage: some View {
        Group {
            if let profileImageData, let platformImage = PlatformImage(data: profileImageData) {
                Image(platformImage: platformImage)
                    .resizable()
            } else {
                Image(systemName: "person.crop.circle")
                    .resizable()
                    .foregroundStyle(.primary)
            }
        }
        .scaledToFill()
    }
}

#Preview {
    ProfileMenuButton()
}
