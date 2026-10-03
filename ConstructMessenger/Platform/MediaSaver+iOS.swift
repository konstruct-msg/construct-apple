#if os(iOS)
import Photos
import UIKit

extension MediaSaver {
    /// `true` if the image reached the photo library; `false` if access was refused.
    @MainActor
    static func save(_ image: UIImage) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        return true
    }
}
#endif
