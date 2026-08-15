/*
See the LICENSE.txt file for licensing information.

Abstract:
A view that displays the hero video banner.
*/

import SwiftUI
import SwiftData

/// A view that displays the hero video banner.
struct HeroView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    let video: Video
    let namespace: Namespace.ID

    var body: some View {
        ZStack(alignment: .leading) {
            Group {
                PosterImageView(video: video)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .accessibilityHidden(true)

                // Add a subtle gradient to make the text stand out.
                GradientView(style: .black.opacity(0.6), startPoint: .leading)
                #if os(iOS)
                GradientView(style: .black, height: isCompact ? Constants.compactGradientSize : Constants.gradientSize / 2, startPoint: .bottom)
                #endif
            }

            VStack(alignment: .leading, spacing: Constants.verticalTextSpacing) {
                Text(video.name)
                    .font(isCompact ? .title : .largeTitle)
                    .fontWeight(.bold)

                Text(video.synopsis)
                    .font(isCompact ? .caption : .body)
                    .fontWeight(isCompact ? .regular : .semibold)

                NavigationLink("Details", value: NavigationNode.video(video.id))
                    #if os(iOS)
                    .buttonStyle(CustomButtonStyle())
                    #endif
            }
            .frame(maxWidth: Constants.heroTextMargin, alignment: .leading)
            .padding(Constants.outerPadding)
            .padding(Constants.extendSafeAreaTV)
        }
        .transitionSource(id: video.id, namespace: namespace)
        .padding(.bottom, isCompact ? 0 : nil)
        .padding(.top, isCompact ? -Constants.compactSafeAreaHeight : -Constants.heroSafeAreaHeight)
        .padding(.horizontal, -Constants.extendSafeAreaTV)
        #if os(tvOS)
        .focusSection()
        #endif
    }
}

#Preview(traits: .previewData) {
    @Previewable @Query(sort: \Video.dateAdded, order: .reverse) var videos: [Video]
    @Previewable @Namespace var namespace

    return NavigationStack {
        ScrollView {
            if let video = videos.first {
                HeroView(video: video, namespace: namespace)
            }
        }
    }
}
