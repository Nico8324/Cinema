/*
See the LICENSE.txt file for licensing information.

Abstract:
A view that presents a profile button for touch and pointer-based platforms.
*/

import SwiftUI

/// A view that presents a profile button for touch and pointer-based platforms.
struct ProfileMenuButton: View {
    @State private var isShowingSettings = false

    var body: some View {
        Button {
            isShowingSettings = true
        } label: {
            ProfileImageView()
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
}

#Preview {
    ProfileMenuButton()
}
