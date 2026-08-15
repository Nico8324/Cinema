/*
See the LICENSE.txt file for licensing information.

Abstract:
A view that presents the app's content library.
*/

import SwiftUI
import SwiftData

/// A view that presents the app's content library.
struct WatchNowView: View {
    @State private var navigationPath = [NavigationNode]()
    @Namespace private var namespace

    @Query(sort: \Video.dateAdded, order: .reverse)
    private var recentlyAddedVideos: [Video]

    @Query(sort: \UpNextItem.createdAt)
    private var playlist: [UpNextItem]

    @Query(filter: #Predicate<Video> { $0.playbackPosition > 5 }, sort: \.lastWatchedDate, order: .reverse)
    private var recentlyPlayedVideos: [Video]

    /// Videos with meaningful, unfinished progress, most recently watched first.
    private var continueWatchingVideos: [Video] {
        recentlyPlayedVideos.filter(\.isPartiallyWatched)
    }

    /// Which TMDB lists feed the discovery rows — the user picks them in Settings.
    @AppStorage(TMDB.MovieList.storageKey) private var discoveryList: TMDB.MovieList = .nowPlaying
    @AppStorage(TMDB.ShowList.storageKey) private var tvDiscoveryList: TMDB.ShowList = .popular

    /// Discovery content below the personal rows, from the chosen TMDB lists.
    /// An empty array (offline, API trouble) just hides the row.
    @State private var discoveryMovies: [TMDB.Movie] = []
    @State private var discoveryShows: [TMDB.Show] = []

    #if os(visionOS)
    @State private var isShowingSettings = false
    #endif

    var body: some View {
        // Wrap the content in a vertically scrolling view.
        NavigationStack(path: $navigationPath) {
            Group {
                if recentlyAddedVideos.isEmpty {
                    ContentUnavailableView(
                        "Nothing to Watch Yet",
                        systemImage: "play.rectangle.on.rectangle",
                        description: Text("Videos you add to your library will appear here.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack {
                            // Feature the latest addition to the library.
                            if let heroVideo = recentlyAddedVideos.first {
                                HeroView(video: heroVideo, namespace: namespace)
                            }

                            // Display a horizontally scrolling list of videos and playlists.
                            VStack(spacing: 20) {
                                if !continueWatchingVideos.isEmpty {
                                    VideoListView(title: "Continue Watching",
                                                  videos: continueWatchingVideos,
                                                  cardStyle: .half, namespace: namespace)
                                }

                                if !playlist.isEmpty {
                                    VideoListView(title: "Up Next",
                                                  videos: playlist.compactMap(\.video),
                                                  cardStyle: .half, namespace: namespace)
                                }

                                VideoListView(title: "Recently Added",
                                              videos: recentlyAddedVideos,
                                              cardStyle: .full, namespace: namespace)

                                if !discoveryMovies.isEmpty {
                                    DiscoveryRow(title: discoveryList.displayName, movies: discoveryMovies)
                                }

                                if !discoveryShows.isEmpty {
                                    TVDiscoveryRow(title: tvDiscoveryList.displayName, shows: discoveryShows)
                                }
                            }
                            .padding(.bottom, Constants.outerPadding)
                        }
                    }
                    .scrollClipDisabled()
                }
            }
            .navigationDestinationVideo(in: namespace)
            // Refetches when the Settings choices change.
            .task(id: discoveryList) {
                discoveryMovies = (try? await TMDB.movies(from: discoveryList)) ?? []
            }
            .task(id: tvDiscoveryList) {
                discoveryShows = (try? await TMDB.shows(from: tvDiscoveryList)) ?? []
            }
            .toolbarBackground(.hidden)
            .overlay(alignment: .topLeading) {
                #if os(visionOS)
                ProfileButtonView(action: { isShowingSettings = true })
                #else
                ProfileMenuButton()
                #endif
            }
            #if os(visionOS)
            .sheet(isPresented: $isShowingSettings) {
                SettingsView()
            }
            #endif
        }
    }
}

#Preview(traits: .previewData) {
    WatchNowView()
}
