/*
See the LICENSE.txt file for licensing information.

Abstract:
The top level tab navigation for the app.
*/

import SwiftUI

/// The top level tab navigation for the app.
struct DestinationTabs: View {
    /// Keep track of tab view customizations in app storage.
    #if !os(macOS) && !os(tvOS)
    @AppStorage("sidebarCustomizations") var tabViewCustomization: TabViewCustomization
    #endif

    @State private var selectedTab: Tabs = .watchNow

    var body: some View {
        #if os(macOS)
        // The Mac gets a grouped source list rather than a tab strip — see `SidebarNavigation`.
        SidebarNavigation()
        #else
        tabs
        #endif
    }

    #if !os(macOS)
    private var tabs: some View {
        TabView(selection: $selectedTab) {
            Tab(Tabs.watchNow.name, systemImage: Tabs.watchNow.symbol, value: .watchNow) {
                WatchNowView()
            }
            .customizationID(Tabs.watchNow.customizationID)
            // Disable customization behavior on the watchNow tab to ensure that the tab remains visible.
            #if !os(macOS) && !os(tvOS)
            .customizationBehavior(.disabled, for: .sidebar, .tabBar)
            #endif

            Tab(Tabs.library.name, systemImage: Tabs.library.symbol, value: .library) {
                LibraryView()
            }
            .customizationID(Tabs.library.customizationID)
            // Disable customization behavior on the library tab to ensure that the tab remains visible.
            #if !os(macOS) && !os(tvOS)
            .customizationBehavior(.disabled, for: .sidebar, .tabBar)
            #endif

            Tab(value: .search, role: .search) {
                SearchView()
            }
            .customizationID(Tabs.search.customizationID)
            #if !os(macOS) && !os(tvOS)
            .customizationBehavior(.disabled, for: .sidebar, .tabBar)
            #endif
        }
        .tabViewStyle(.sidebarAdaptable)
        #if !os(macOS) && !os(tvOS)
        .tabViewCustomization($tabViewCustomization)
        #endif
    }
    #endif
}

#Preview(traits: .previewData) {
    DestinationTabs()
}
