/*
See the LICENSE.txt file for licensing information.

Abstract:
Generates a representative poster thumbnail from a local video file.
*/

import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Generates a representative poster thumbnail from a local video file, skipping frames that are too dark or blank
/// (movie trailers routinely open on a black card or studio logo fade-in, which makes a poor poster image).
enum ThumbnailGenerator {
    /// Candidate positions to sample, as a fraction of the video's duration, tried in this order until a
    /// bright-enough frame turns up. Weighted toward the first third of the video, where a representative
    /// shot is most likely, while still trying a few other spots if that whole range is dark.
    private static let candidateFractions: [Double] = [0.15, 0.3, 0.45, 0.6, 0.08]

    /// A frame is considered usable once its average brightness clears this threshold (0 = black, 1 = white).
    private static let brightnessThreshold = 0.15

    /// Returns the video's duration in whole seconds, or 0 if it can't be determined.
    static func duration(for url: URL) async -> Int {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 else {
            return 0
        }
        return Int(duration.seconds.rounded())
    }

    /// Returns JPEG data for a representative frame of the video at `url`, or nil if none could be extracted.
    static func generateThumbnailData(for url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else {
            return nil
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)

        var fallbackImage: CGImage?
        var fallbackBrightness = -1.0

        for fraction in candidateFractions {
            let seconds = min(duration.seconds * fraction, max(duration.seconds - 0.05, 0))
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let result = try? await generator.image(at: time) else { continue }

            let brightness = averageBrightness(of: result.image)
            if brightness >= brightnessThreshold {
                return jpegData(from: result.image)
            }
            if brightness > fallbackBrightness {
                fallbackBrightness = brightness
                fallbackImage = result.image
            }
        }

        // Every candidate was dark — use the brightest one we found rather than nothing.
        return fallbackImage.flatMap(jpegData)
    }

    /// Returns an approximate 0...1 brightness by averaging a small downscaled version of the image.
    private static func averageBrightness(of cgImage: CGImage) -> Double {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var total = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]), g = Double(pixels[i + 1]), b = Double(pixels[i + 2])
            total += (0.299 * r + 0.587 * g + 0.114 * b) / 255
        }
        return total / Double(side * side)
    }

    private static func jpegData(from cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
