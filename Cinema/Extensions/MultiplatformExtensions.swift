/*
See the LICENSE.txt file for licensing information.

Abstract:
Helper extensions that simplify multiplatform development.
*/

import Foundation
import SwiftUI

#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage

extension NSImage {
    var cgImage: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Stands in for `UIImage.jpegData(compressionQuality:)`, which AppKit has no direct match for.
    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
}
#else
import UIKit
public typealias PlatformImage = UIImage
#endif

extension PlatformImage {
    /// Returns a copy no larger than `maxDimension` along its longest side, or the image
    /// unchanged when it already fits.
    func downscaled(maxDimension: CGFloat) -> PlatformImage {
        let largestSide = max(size.width, size.height)
        guard largestSide > maxDimension else { return self }
        let scale = maxDimension / largestSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        #if os(macOS)
        let scaled = NSImage(size: newSize)
        scaled.lockFocus()
        draw(in: CGRect(origin: .zero, size: newSize))
        scaled.unlockFocus()
        return scaled
        #else
        let format = UIGraphicsImageRendererFormat()
        // Store pixels at the size asked for rather than multiplying by the screen scale.
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
        #endif
    }

    var imageData: Data? {
        #if os(macOS)
        tiffRepresentation
        #else
        pngData()
        #endif
    }
}

extension Color {
    /// The window's own background color — black in dark appearance, white in light — under the
    /// name each platform gives it.
    static var platformBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #elseif os(tvOS)
        // tvOS ships no `systemBackground`; its interface is dark throughout, so black matches
        // what the adaptive color would resolve to there anyway.
        Color.black
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}

extension Image {
    /// Creates an image from a platform-native image type (`NSImage` on macOS, `UIImage` elsewhere).
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}
