import Foundation
import Photos

/// Saves finished clips to the photo library.
///
/// 🔑 Why this exists: renders land in the app's temporary directory, which iOS is free to purge,
/// and the attendant screen auto-advances after a few seconds. A guest's clip that nobody happened
/// to tap Share on was simply gone. At an event that is the difference between a deliverable and a
/// shrug, so every finished take is saved without anyone having to remember.
///
/// Add-only access, so the app can never read the user's library.
enum MediaLibrary {

    /// Ask for permission during setup, NOT on the first save.
    ///
    /// ⚠️ Requesting lazily meant the system dialog appeared **on the booth screen in front of a
    /// guest**, mid-flow, covering the Start button. Permission prompts belong in the operator's
    /// hands during setup; by the time anyone is at the booth this is already settled.
    static func prepare() async {
        guard PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined else { return }
        _ = await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { cont.resume(returning: $0) }
        }
    }

    @discardableResult
    static func save(_ url: URL) async -> Bool {
        // Never prompts here — `prepare()` settled it during setup. If permission was refused the
        // save is skipped silently rather than interrupting a guest.
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .authorized || status == .limited else {
            GlamaticLink.plog("photo save skipped — no add-only permission")
            return false
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
            }
            GlamaticLink.plog("saved take to Photos")
            return true
        } catch {
            GlamaticLink.plog("photo save failed: \(error.localizedDescription)")
            return false
        }
    }
}
