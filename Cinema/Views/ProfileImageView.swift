/*
See the LICENSE.txt file for licensing information.

Abstract:
The profile photo store and the shared view that displays it.
*/

import SwiftUI

/// Persists the profile photo as a downscaled JPEG file in the app's container.
///
/// `@AppStorage`/UserDefaults holds only the profile name and a photo version counter —
/// never image bytes. UserDefaults is loaded wholesale into memory and synced on every
/// change, so multi-megabyte photo blobs don't belong there.
@MainActor
enum ProfileStore {
    static let nameKey = "profileName"
    static let photoVersionKey = "profilePhotoVersion"

    /// The key the app formerly used to store raw photo bytes in UserDefaults.
    private static let legacyPhotoDataKey = "profileImageData"

    /// The largest dimension the stored photo is downscaled to. Displayed at most at 96 points.
    private static let maxPhotoDimension: CGFloat = 512

    private static var cachedPhoto: PlatformImage?

    /// Loads the stored profile photo, caching the decoded image.
    static func loadPhoto() -> PlatformImage? {
        if let cachedPhoto { return cachedPhoto }
        guard let data = try? Data(contentsOf: MediaStore.profileImageURL),
              let image = PlatformImage(data: data) else { return nil }
        cachedPhoto = image
        return image
    }

    /// Downscales and saves a picked photo, bumping the version so views reload.
    static func savePhoto(_ data: Data) {
        guard let image = PlatformImage(data: data) else { return }
        let scaled = image.downscaled(maxDimension: maxPhotoDimension)
        guard let jpeg = scaled.jpegData(compressionQuality: 0.85) else { return }
        do {
            try jpeg.write(to: MediaStore.profileImageURL)
            cachedPhoto = scaled
            UserDefaults.standard.set(UserDefaults.standard.integer(forKey: photoVersionKey) + 1, forKey: photoVersionKey)
        } catch {
            logger.error("Couldn't save the profile photo: \(error.localizedDescription)")
        }
    }

    /// Moves a photo stored under the legacy UserDefaults key into the file-based store.
    static func migrateLegacyPhotoIfNeeded() {
        guard let data = UserDefaults.standard.data(forKey: legacyPhotoDataKey) else { return }
        savePhoto(data)
        UserDefaults.standard.removeObject(forKey: legacyPhotoDataKey)
    }

}

/// The circular profile photo, shared by every surface that shows it.
/// Falls back to the standard person symbol when no photo is set.
struct ProfileImageView: View {
    @AppStorage(ProfileStore.photoVersionKey) private var photoVersion = 0
    @State private var photo: PlatformImage?

    var body: some View {
        Group {
            if let photo {
                Image(platformImage: photo)
                    .resizable()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .scaledToFill()
        .task(id: photoVersion) {
            photo = ProfileStore.loadPhoto()
        }
    }
}
