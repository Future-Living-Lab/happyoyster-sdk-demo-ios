import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Picks the first type identifier from `itemProvider.registeredTypeIdentifiers` that is "truly a static image".
///
/// We can't just take `.first`: for items like Live Photos, the first entry in `registeredTypeIdentifiers` is often
/// `com.apple.live-photo-bundle` (the container identifier for the whole Live Photo, not a single image file). Calling
/// `loadDataRepresentation` with that identifier yields unusable data (not valid image file bytes, so `UIImage` can't
/// decode it) -- the earlier bug was submitting exactly that data as an image. Here we explicitly filter by
/// `UTType.image`, skipping Live Photo containers / videos and other non-image types, to find the representation that
/// can actually be submitted as an image; if none is found there truly is no usable image (e.g. only the Live Photo's
/// motion part), and the caller should report an error.
private func firstStaticImageTypeIdentifier(in identifiers: [String]) -> String? {
    identifiers.first { UTType($0)?.conforms(to: .image) == true }
}

/// Local image pick state for one image input slot: mutually exclusive with URL text input (once a local image is picked, the caller should hide the URL field).
/// A pure value type used with `@State`; no `ObservableObject` needed.
struct LocalImagePickState {
    /// Bare base64 string (no data URI prefix), encoding the picked image's original file data directly, without transcoding or compression.
    /// Non-nil means "a local image has been picked".
    var base64: String?
    /// The picked original image (only for thumbnail preview; not submitted).
    var preview: UIImage?
    /// Message shown when picking fails or exceeds the limit.
    var error: String?
}

/// Local image size check: the API requires the decoded size (i.e. original image file bytes, not the base64 string length) to be at most 10MB.
/// No compression/transcoding/scaling -- the server accepts the common formats iOS can decode (JPEG/PNG/HEIC/GIF/TIFF/BMP...),
/// so we upload the original file data as-is; if it exceeds the limit, ask the user to pick another one rather than sacrificing quality to "fit into 10MB".
enum LocalImageLimit {
    static let maxBytes = 10 * 1024 * 1024
}

/// "Pick local image" entry button: uses `PHPickerViewController` internally (iOS 14+, a sandboxed system picker that
/// needs no photo library permission prompt / `NSPhotoLibraryUsageDescription`). After picking, it returns the original
/// file data (original format preserved) plus a `UIImage` for thumbnail preview.
struct PhotoPickerButton: View {
    /// `data` is the picked image's original file bytes (not transcoded/compressed); `preview` is only for the UI thumbnail.
    let onPick: (_ data: Data, _ preview: UIImage) -> Void
    /// Any failure in the picking flow (other than a user cancel) comes here with a specific reason, so issues can be
    /// diagnosed on real devices even without logs (e.g. iCloud image download failure, system decode failure).
    var onFailure: ((_ reason: String) -> Void)?

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "photo.badge.plus")
                .font(.subheadline)
                .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isPresented) {
            PhotoPicker { result in
                isPresented = false
                switch result {
                case .success(let picked):
                    appLog("[PhotoPickerButton] onPick data.count=\(picked.data.count)")
                    onPick(picked.data, picked.preview)
                case .failure(let reason):
                    appLog("[PhotoPickerButton] onFailure reason=\(reason)")
                    onFailure?(reason)
                case .cancelled:
                    appLog("[PhotoPickerButton] cancelled")
                }
            }
        }
    }
}

/// Pick result: distinguishes "user cancelled" (a normal action; no error should be shown) from "failed mid-flow" (the reason should be shown).
enum PhotoPickResult {
    case success(data: Data, preview: UIImage)
    case failure(reason: String)
    case cancelled
}

private struct PhotoPicker: UIViewControllerRepresentable {
    let completion: (PhotoPickResult) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let completion: (PhotoPickResult) -> Void
        init(completion: @escaping (PhotoPickResult) -> Void) { self.completion = completion }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            let completion = self.completion
            appLog("[PhotoPicker] didFinishPicking results.count=\(results.count)")
            // Empty result = the user tapped Cancel; not a failure, so no prompt should be shown.
            guard let provider = results.first?.itemProvider else {
                appLog("[PhotoPicker] cancelled (no itemProvider)")
                completion(.cancelled)
                return
            }
            appLog("[PhotoPicker] registeredTypeIdentifiers=\(provider.registeredTypeIdentifiers)")
            guard let typeIdentifier = firstStaticImageTypeIdentifier(in: provider.registeredTypeIdentifiers) else {
                appLog("[PhotoPicker] ❌ no static image type found (possibly Live Photo motion part/video)")
                completion(.failure(reason: String(localized: "The selected item is not a usable static image (it may be a Live Photo or video). Please choose another one.")))
                return
            }
            appLog("[PhotoPicker] loadDataRepresentation start typeIdentifier=\(typeIdentifier)")
            // Load file data directly by the originally registered type (keeps the original format; skips the UIImage decode/re-encode step).
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                DispatchQueue.main.async {
                    guard let data else {
                        // The error typically means the iCloud image isn't downloaded to the device yet, permission was revoked, etc.
                        // It only happens on real devices (rarely on the simulator); it used to be dropped, leaving no clues for on-device debugging.
                        appLog("[PhotoPicker] ❌ loadDataRepresentation returned no data, error=\(error?.localizedDescription ?? "nil")")
                        completion(.failure(reason: String(localized: "Failed to read image data: \(error?.localizedDescription ?? String(localized: "Unknown error"))")))
                        return
                    }
                    // The client only checks "can it be decoded": the pick succeeds only if decoding succeeds, and the
                    // original file bytes are passed through as-is. Whether the image is actually usable (format/content
                    // compliance) is validated by the backend API; no guessing/fallback here.
                    guard let preview = UIImage(data: data) else {
                        appLog("[PhotoPicker] ❌ image decode failed typeIdentifier=\(typeIdentifier)")
                        completion(.failure(reason: String(localized: "Failed to decode the image (the format may be unsupported). Please choose another one.")))
                        return
                    }
                    appLog("[PhotoPicker] ✅ data.count=\(data.count)")
                    completion(.success(data: data, preview: preview))
                }
            }
        }
    }
}

// MARK: - Multi-select (shared by Story simple mode and the Acting reference image list)

/// Max count for the Story simple-mode reference image list: URLs and local images count together; nothing more can be added beyond it.
/// Acting's reference image list (`inputImages`) uses the same limit.
enum StoryImageLimit {
    static let maxCount = 6
}

/// One entry in a reference image list: either a remote `url` or a locally picked image (`base64`), mutually exclusive;
/// shared by Story simple mode and the Acting reference image list. In Story, a single image goes to `firstFrameImage`,
/// and 2 or more all go to `inputImages` (mutually exclusive, see `MainView.storyImageFields`); in Acting they always go
/// to `inputImages` (only effective with `uploadMode=multi_ref`). URL entries and local image entries may be mixed in the list.
struct StoryImageEntry: Identifiable {
    let id = UUID()
    private(set) var url: String?
    private(set) var base64: String?
    /// Only local image entries have a preview; nil for URL entries.
    private(set) var preview: UIImage?

    init(url: String) {
        self.url = url
    }

    init(base64: String, preview: UIImage) {
        self.base64 = base64
        self.preview = preview
    }

    var imageRef: ImageRef {
        if let base64 { return ImageRef(base64: base64) }
        return ImageRef(url: url ?? "")
    }
}

/// "Multi-pick local images" entry button: also based on `PHPickerViewController`. The caller passes the remaining
/// slots as `selectionLimit` (e.g. `StoryImageLimit.maxCount - existing count`), so the system picker itself caps how
/// many the user can pick, instead of discarding the excess after the callback -- a more direct experience than
/// "error after picking too many". Passing `0` means unlimited (kept in case a future scenario needs no total cap).
struct MultiPhotoPickerButton: View {
    var selectionLimit: Int = 0
    let onPick: (_ items: [(data: Data, preview: UIImage)]) -> Void
    /// Called when some picked items failed to load (non-empty result, not a user cancel), with the failure count + the first specific reason.
    /// Successfully loaded items are still delivered via `onPick`; partial failures don't discard the whole batch.
    var onFailure: ((_ failureCount: Int, _ firstReason: String) -> Void)?

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.subheadline)
                .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isPresented) {
            MultiPhotoPicker(selectionLimit: selectionLimit) { items, failures in
                isPresented = false
                appLog("[MultiPhotoPickerButton] onPick items.count=\(items.count) failures.count=\(failures.count)")
                onPick(items)
                if let firstReason = failures.first {
                    onFailure?(failures.count, firstReason)
                }
            }
        }
    }
}

private struct MultiPhotoPicker: UIViewControllerRepresentable {
    let selectionLimit: Int
    let completion: (_ items: [(data: Data, preview: UIImage)], _ failures: [String]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = selectionLimit
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let completion: (_ items: [(data: Data, preview: UIImage)], _ failures: [String]) -> Void
        init(completion: @escaping (_ items: [(data: Data, preview: UIImage)], _ failures: [String]) -> Void) {
            self.completion = completion
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            let completion = self.completion
            appLog("[MultiPhotoPicker] didFinishPicking results.count=\(results.count)")
            // Empty result = the user tapped Cancel; not a failure.
            guard !results.isEmpty else {
                appLog("[MultiPhotoPicker] cancelled (results empty)")
                completion([], [])
                return
            }
            // Load each item's original data concurrently and return in selection order (out-of-order completions are re-sorted by index);
            // each failure records its own reason, so one failed image doesn't affect the others that loaded successfully.
            let group = DispatchGroup()
            var items: [(index: Int, data: Data, preview: UIImage)] = []
            var failures: [String] = []
            let lock = NSLock()
            for (index, result) in results.enumerated() {
                group.enter()
                appLog("[MultiPhotoPicker] image #\(index + 1) registeredTypeIdentifiers=\(result.itemProvider.registeredTypeIdentifiers)")
                guard let typeIdentifier = firstStaticImageTypeIdentifier(in: result.itemProvider.registeredTypeIdentifiers) else {
                    appLog("[MultiPhotoPicker] ❌ image #\(index + 1) no static image type found (possibly Live Photo motion part/video)")
                    lock.lock(); failures.append(String(localized: "Image \(index + 1): not a usable static image (it may be a Live Photo or video)")); lock.unlock()
                    group.leave()
                    continue
                }
                appLog("[MultiPhotoPicker] image #\(index + 1) loadDataRepresentation start typeIdentifier=\(typeIdentifier)")
                result.itemProvider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                    defer { group.leave() }
                    guard let data else {
                        appLog("[MultiPhotoPicker] ❌ image #\(index + 1) no data, error=\(error?.localizedDescription ?? "nil")")
                        lock.lock()
                        failures.append(String(localized: "Image \(index + 1): failed to read image data (\(error?.localizedDescription ?? String(localized: "Unknown error")))"))
                        lock.unlock()
                        return
                    }
                    // Same as single pick: only a binary "can it be decoded" check; a decode failure is a failure, with no guessing/fallback.
                    // Whether the image is actually usable is left to backend API validation.
                    guard let preview = UIImage(data: data) else {
                        appLog("[MultiPhotoPicker] ❌ image #\(index + 1) decode failed typeIdentifier=\(typeIdentifier)")
                        lock.lock(); failures.append(String(localized: "Image \(index + 1): failed to decode image")); lock.unlock()
                        return
                    }
                    appLog("[MultiPhotoPicker] ✅ image #\(index + 1) data.count=\(data.count)")
                    lock.lock()
                    items.append((index, data, preview))
                    lock.unlock()
                }
            }
            group.notify(queue: .main) {
                let sorted = items.sorted { $0.index < $1.index }
                appLog("[MultiPhotoPicker] all loads finished success=\(sorted.count) failures=\(failures.count)")
                completion(sorted.map { (data: $0.data, preview: $0.preview) }, failures)
            }
        }
    }
}
