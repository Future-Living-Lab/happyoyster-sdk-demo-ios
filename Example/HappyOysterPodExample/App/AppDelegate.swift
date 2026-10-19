import UIKit

/// Global orientation lock manager: controls rotation via AppDelegate's supportedInterfaceOrientations.
/// TravelView locks to landscape or portrait based on the world's aspect ratio on entry, and unlocks on exit.
final class OrientationLock {
    static let shared = OrientationLock()
    private init() {}

    /// Orientation required by the player page. Acting worlds default to 9:16 and use `.portrait`; wander / story use `.landscape`.
    enum Orientation {
        case landscape
        case portrait
        /// Unlocked: restore the system default (everything except upside-down).
        case unlocked

        var mask: UIInterfaceOrientationMask {
            switch self {
            case .landscape: return .landscape
            case .portrait:  return .portrait
            case .unlocked:  return .allButUpsideDown
            }
        }

        /// Target orientation used when manually setting `UIDevice.orientation` on iOS 15.
        var legacyValue: Int {
            switch self {
            case .landscape: return UIInterfaceOrientation.landscapeRight.rawValue
            case .portrait, .unlocked: return UIInterfaceOrientation.portrait.rawValue
            }
        }
    }

    private(set) var mask: UIInterfaceOrientationMask = .allButUpsideDown

    func lock(to orientation: Orientation) {
        mask = orientation.mask
        applyRotation(orientation)
    }

    private func applyRotation(_ orientation: Orientation) {
        if #available(iOS 16.0, *) {
            let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
            scene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
            // Walk the VC chain so the currently visible VC receives the rotation update
            var vc = scene?.keyWindow?.rootViewController
            while let presented = vc?.presentedViewController {
                vc = presented
            }
            vc?.setNeedsUpdateOfSupportedInterfaceOrientations()
        } else {
            UIDevice.current.setValue(orientation.legacyValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }
}

/// Keyboard dismiss helper: observes keyboard show/hide system notifications, attaches tap/pan gestures with
/// `cancelsTouchesInView = false` to the current `keyWindow` when the keyboard appears, and removes them when it hides.
/// Attaching/removing is a pure UIKit operation (`UIWindow.addGestureRecognizer`, no views inserted/removed), entirely
/// unrelated to SwiftUI's view-tree diffing, so it never triggers the "structural position shift -> subtree treated as
/// inserted/destroyed" rebuild chain and therefore doesn't affect the first responder state of the field being edited.
///
/// Intentionally not installed globally at app launch; instead `start()`/`stop()` let specific pages opt in explicitly
/// according to their own presentation lifecycle (currently only wired to `TravelView`'s script editor panel for
/// validation). We first verify on real devices, at small scale, that this mechanism really doesn't affect focus,
/// then decide whether to roll it out to replace the existing approach on the home/settings pages.
///
/// Must subclass `NSObject`: `UIGestureRecognizerDelegate` requires `NSObjectProtocol` conformance. A pure Swift class
/// can host `@objc` methods (target-action, notification callbacks) fine, but adopting the protocol requires an `NSObject` subclass.
final class KeyboardDismissAssistant: NSObject {
    static let shared = KeyboardDismissAssistant()
    private override init() { super.init() }

    private weak var attachedWindow: UIWindow?
    private var tap: UITapGestureRecognizer?
    private var pan: UIPanGestureRecognizer?
    private var isObserving = false

    /// The area currently excluded from "tap anywhere to dismiss the keyboard" (window/`.global` coordinates). The presenter
    /// (currently `ScriptListTextEditor`) reports its real frame live via `GeometryReader`, instead of walking the view tree
    /// or guessing from the type of `touch.view`. The only thing needing special handling here is the input field itself;
    /// checking the real frame it reports is more precise than type checks and avoids enumerating `UIControl`/`UITextView` subclasses.
    var excludedRect: CGRect?

    func start() {
        guard !isObserving else { return }
        isObserving = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    func stop() {
        guard isObserving else { return }
        isObserving = false
        NotificationCenter.default.removeObserver(self)
        excludedRect = nil
        detach()
    }

    @objc private func keyboardWillShow() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }), window !== attachedWindow else { return }
        detach()
        let tap = UITapGestureRecognizer(target: self, action: #selector(handle))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handle))
        pan.cancelsTouchesInView = false
        pan.delegate = self
        window.addGestureRecognizer(tap)
        window.addGestureRecognizer(pan)
        self.tap = tap
        self.pan = pan
        attachedWindow = window
    }

    @objc private func keyboardWillHide() {
        detach()
    }

    private func detach() {
        if let tap { attachedWindow?.removeGestureRecognizer(tap) }
        if let pan { attachedWindow?.removeGestureRecognizer(pan) }
        tap = nil
        pan = nil
        attachedWindow = nil
    }

    /// `UITapGestureRecognizer`'s action fires only once at recognition, so no extra filtering is needed; but
    /// `UIPanGestureRecognizer`'s target-action fires for every gesture state (`.began`/`.changed`/
    /// `.ended`/`.cancelled`), and `.changed` fires repeatedly while dragging. Starting the drag already achieves
    /// "dismiss the keyboard", so only act on `.began` to avoid repeatedly sending `resignFirstResponder` down the
    /// responder chain within one drag (a no-op for an already-unfocused field, but no need to repeat it).
    @objc private func handle(_ gesture: UIGestureRecognizer) {
        if let pan = gesture as? UIPanGestureRecognizer, pan.state != .began {
            return
        }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

extension KeyboardDismissAssistant: UIGestureRecognizerDelegate {
    /// Touches inside `excludedRect` (currently the input field's real frame) are rejected outright, so they never enter
    /// our gesture recognition at all. This doesn't affect the field's own gestures such as "tap to position the cursor",
    /// and there's no need to race them. Outside that area, recognition and keyboard dismissal work as usual.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let window = attachedWindow, let rect = excludedRect else { return true }
        return !rect.contains(touch.location(in: window))
    }
}

/// Injected into the SwiftUI App lifecycle to control device orientation.
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLock.shared.mask
    }
}
