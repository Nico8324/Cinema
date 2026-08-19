/*
See the LICENSE.txt file for licensing information.

Abstract:
The Mac's source-list navigation, in the shape of the TV app's sidebar.
*/

#if os(macOS)
import SwiftUI

/// The Mac's top-level navigation: a source list on the left, content on the right.
///
/// The other platforms use a `TabView`, which on the Mac collapses into a flat strip of
/// destinations. The TV app instead groups its sidebar — a few top-level places, then the
/// library broken out by kind — and keeps the account at the bottom edge. This mirrors that,
/// which is also why the library's slice is chosen here rather than by a segmented control
/// inside the content.
struct SidebarNavigation: View {

    /// The places the sidebar can send you.
    private enum Destination: Hashable, Identifiable {
        case search
        case watchNow
        case movies
        case shows

        var id: Self { self }

        var name: LocalizedStringKey {
            switch self {
            case .search: "Search"
            case .watchNow: "Watch Now"
            case .movies: "Movies"
            case .shows: "TV Shows"
            }
        }

        var symbol: String {
            switch self {
            case .search: "magnifyingglass"
            case .watchNow: "play"
            case .movies: "film"
            case .shows: "tv"
            }
        }
    }

    @State private var selection: Destination = .watchNow

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                row(.search)
                row(.watchNow)

                Section("Library") {
                    row(.movies)
                    row(.shows)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: Constants.sidebarWidth, max: 320)
            // Pinned to the bottom edge, out of the scrolling list, the way the TV app keeps
            // the account row anchored no matter how long the source list grows.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SidebarProfileRow()
            }
        } detail: {
            switch selection {
            case .search: SearchView()
            case .watchNow: WatchNowView()
            case .movies: LibraryView(filter: .movies)
            case .shows: LibraryView(filter: .shows)
            }
        }
    }

    private func row(_ destination: Destination) -> some View {
        Label(destination.name, systemImage: destination.symbol)
            .tag(destination)
    }
}

/// The account row pinned to the bottom of the sidebar.
private struct SidebarProfileRow: View {
    @AppStorage(ProfileStore.nameKey) private var profileName = ""
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            // The same window the app menu's Settings… item opens, so there's only ever one.
            openSettings()
        } label: {
            HStack(spacing: 8) {
                ProfileImageView()
                    .frame(width: 26, height: 26)
                    .clipShape(.circle)
                Text(profileName.isEmpty ? String(localized: "Profile", comment: "Placeholder name for the sidebar account row") : profileName)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

#Preview(traits: .previewData) {
    SidebarNavigation()
}
#endif
