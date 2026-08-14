/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A view that presents the video content details.
*/

import SwiftUI
import SwiftData

/// A view that presents the video content details.
struct DetailView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(PlayerModel.self) private var player
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    @State var video: Video
    @State private var viewSize: CGSize = CGSize(width: 0, height: 0)
    @State private var isConfirmingDelete = false
    @State private var isEditing = false
    
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack {
                VStack(alignment: .leading, spacing: Constants.verticalTextSpacing) {
                    Text(video.localizedName)
                        .font(isCompact ? .title : .largeTitle)
                        .bold()
                    
                    Text("\(video.formattedYearOfRelease) | \(video.localizedContentRating) | \(video.formattedDuration)",
                         comment: "Release Year | Rating | Duration")
                    .font(.headline)
                    .accessibilityLabel("""
                                        Released \(video.formattedYearOfRelease), rated \(video.localizedContentRating), \
                                        \(video.duration) seconds
                                        """)
                    
                    GenreView(genres: video.genres)
                    
                    Text(video.localizedSynopsis)
                        .multilineTextAlignment(.leading)
                        .font(isCompact ? .body : .headline)
                        .fontWeight(.semibold)

                    HStack {
                        // A button that plays the video in a full-window presentation.
                        Button {
                            /// Load the media item for full-window presentation.
                            player.loadVideo(video, presentation: .fullWindow)
                        } label: {
                            Label(video.isPartiallyWatched ? "Resume Movie" : "Play Movie", systemImage: "play.fill")
                        }
                        // A button that toggles whether the video is in the Up Next queue.
                        Button {
                            video.toggleUpNext(in: context)
                        } label: {
                            let isQueued = video.upNextItem != nil
                            Label(isQueued ? "In Up Next" : "Add to Up Next",
                                  systemImage: isQueued ? "checkmark" : "plus")
                        }

                        Spacer()

                    }
                    .buttonStyle(CustomButtonStyle())
                    // Make the buttons the same width.
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                }
                .padding(isCompact ? Constants.detailCompactPadding : Constants.detailPadding)
                .padding(.bottom, isCompact ? Constants.detailCompactPadding : 0)
                .padding(.trailing, isCompact ? 0 : Constants.detailTrailingPadding)
                .frame(height: viewSize.height, alignment: .bottom)
                .background(alignment: .bottom) { backgroundView }

                #if !os(tvOS)
                VStack(alignment: .leading, spacing: Constants.verticalTextSpacing) {
                    #if os(visionOS)
                    Text("Extras")
                        .font(.headline)
                    
                    // A view that plays video in an inline presentation.
                    TrailerView(video: video)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxWidth: Constants.trailerHeight)
                        .cornerRadius(Constants.cornerRadius)
                    #endif
                    
                    Text("Cast & Crew")
                        .font(.headline)
                    
                    RoleView(role: String(localized: "Stars", comment: "A participant in making a video."), people: video.actors)
                    RoleView(role: String(localized: "Director", comment: "A participant in making a video."), people: video.directors)
                    RoleView(role: String(localized: "Writers", comment: "A participant in making a video."), people: video.writers)
                    
                }
                .padding(isCompact ? Constants.detailCompactPadding : Constants.detailPadding)
                .padding(.bottom, isCompact ? Constants.detailCompactPadding : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                #endif
            }
            #if os(iOS)
            .background(.black)
            #endif
        }
        .scrollClipDisabled()
        .padding(.top, isCompact ? -Constants.compactDetailSafeAreaHeight : -Constants.detailSafeAreaHeight)
        .onGeometryChange(for: CGSize.self) { proxy in
            return proxy.size
        } action: { size in
            let heightPadding = (isCompact ? Constants.compactDetailSafeAreaHeight : Constants.detailSafeAreaHeight)
            let widthPadding = Constants.extendSafeAreaTV
            viewSize = CGSize(width: size.width + widthPadding, height: size.height + heightPadding)
        }
        // Don't show a navigation title in iOS.
        .navigationTitle("")
        .toolbarBackground(.hidden)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Edit Video", systemImage: "pencil") {
                        isEditing = true
                    }
                    Button("Delete Video", systemImage: "trash", role: .destructive) {
                        isConfirmingDelete = true
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            "Delete “\(video.localizedName)”?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Video", role: .destructive) {
                deleteVideo()
            }
        } message: {
            Text("This can’t be undone.")
        }
        .sheet(isPresented: $isEditing) {
            EditVideoView(video: video)
        }
    }

    /// Deletes the video, including the locally imported file and thumbnail backing it, and dismisses.
    private func deleteVideo() {
        video.removeLocalFiles()
        context.delete(video)
        try? context.save()
        dismiss()
    }
    
    /// Returns a background image for the view orientation.
    private var backgroundImage: Image {
        let usePortrait = viewSize.height > viewSize.width
        return (usePortrait ? video.portraitImage : video.landscapeImage).resizable()
    }
    
    private var backgroundView: some View {
        Group {
            backgroundImage
                .scaledToFill()
                .frame(width: viewSize.width, height: viewSize.height)
                .clipped()
                .accessibilityHidden(true)
            
            // Add a subtle gradient to make the text stand out.
            #if os(iOS)
            GradientView(style: .black.opacity(0.6), direction: .horizontal, width: Constants.gradientSize, startPoint: .leading)
            GradientView(style: .black, height: Constants.gradientSize, startPoint: .bottom)
            #else
            GradientView(style: .black.opacity(0.4), direction: .horizontal, width: Constants.gradientSize, startPoint: .leading)
            GradientView(style: .black.opacity(0.5), height: Constants.gradientSize, startPoint: .bottom)
            #endif
        }
        .padding([.horizontal, .bottom], -Constants.extendSafeAreaTV)
    }
}

#Preview(traits: .previewData) {
    @Previewable @Query(sort: \Video.id) var videos: [Video]
    return Group {
        if let video = videos.first {
            DetailView(video: video)
        }
    }
}

