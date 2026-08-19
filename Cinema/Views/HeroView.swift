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
    @Environment(\.colorScheme) private var colorScheme

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    /// A white veil reads stronger than a black one over the same artwork, so
    /// the side scrim eases off in light mode to keep the poster punchy.
    private var sideScrimOpacity: Double {
        colorScheme == .light ? 0.4 : 0.6
    }

    let video: Video
    let namespace: Namespace.ID

    /// The measured distance to the screen's top edge, provided by the
    /// presenting screen; the platform constants are the fallback. Hardcoded
    /// offsets leave a hairline of background above the poster on devices
    /// whose real inset differs.
    var topInset: CGFloat?

    private var topPull: CGFloat {
        topInset ?? (isCompact ? Constants.compactSafeAreaHeight : Constants.heroSafeAreaHeight)
    }

    var body: some View {
        // Text anchors to the poster's bottom-left, over the gradient — the sample
        // centered it vertically, which only worked with its much taller artwork.
        ZStack(alignment: .bottomLeading) {
            // The gradients overlay the poster rather than standing as siblings:
            // as siblings, their fixed heights would stretch the hero taller than
            // the 16:9 poster and break its full-bleed anchoring to the top edge.
            // A taller, cropped hero on iPhone (like the TV app) — a bare 16:9 strip
            // leaves no room for the title text above the gradient.
            // Show-level artwork when a matched episode is featured (the hero
            // is show branding, not an episode frame); movies and unmatched
            // episodes fall back to their own thumbnail.
            ShowArtworkView(cover: video)
                .aspectRatio(isCompact ? 3 / 4 : 16 / 9, contentMode: .fit)
                .overlay {
                    // Background-style scrims: black in dark mode (the original
                    // look), white in light mode — text over them stays legible
                    // with the standard semantic colors either way.
                    GradientView(style: .background.opacity(sideScrimOpacity), startPoint: .leading)
                }
                #if os(iOS)
                .overlay(alignment: .bottom) {
                    GradientView(style: .background, height: isCompact ? Constants.compactGradientSize : Constants.gradientSize / 2, startPoint: .bottom)
                }
                #endif
                .clipped()
                .accessibilityHidden(true)

            // Real-world titles and synopses can be long — cap the overlay's lines
            // so it never outgrows the poster behind it.
            VStack(alignment: .leading, spacing: Constants.verticalTextSpacing) {
                Text(video.displayName)
                    .font(isCompact ? .title : .largeTitle)
                    .fontWeight(.bold)
                    .lineLimit(2)

                Text(video.synopsis)
                    .font(isCompact ? .caption : .body)
                    .fontWeight(isCompact ? .regular : .semibold)
                    .lineLimit(isCompact ? 2 : 3)

                NavigationLink("Details", value: NavigationNode.video(video.id))
                    #if os(iOS) || os(macOS)
                    // A filled pill, like the TV app's primary hero action — a bare link
                    // disappeared into the artwork on the Mac.
                    .buttonStyle(CustomButtonStyle())
                    #endif
            }
            .frame(maxWidth: Constants.heroTextMargin, alignment: .leading)
            .padding(Constants.outerPadding)
            .padding(Constants.extendSafeAreaTV)
        }
        .transitionSource(id: video.id, namespace: namespace)
        .padding(.bottom, isCompact ? 0 : nil)
        .padding(.top, -topPull)
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
