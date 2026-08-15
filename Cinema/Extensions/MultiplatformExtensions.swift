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
}
#else
import UIKit
public typealias PlatformImage = UIImage
#endif

extension PlatformImage {
    var imageData: Data? {
        #if os(macOS)
        tiffRepresentation
        #else
        pngData()
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
