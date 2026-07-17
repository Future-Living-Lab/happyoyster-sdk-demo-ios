import UIKit

/// 全局方向锁定管理器：通过 AppDelegate 的 supportedInterfaceOrientations 控制旋转。
/// TravelView 进入时锁横屏，离开时解锁。
final class OrientationLock {
    static let shared = OrientationLock()
    private init() {}

    private(set) var mask: UIInterfaceOrientationMask = .allButUpsideDown

    func lock(toLandscape: Bool) {
        mask = toLandscape ? .landscape : .allButUpsideDown
        applyRotation(toLandscape: toLandscape)
    }

    private func applyRotation(toLandscape: Bool) {
        if #available(iOS 16.0, *) {
            let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
            scene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
            // 遍历 VC 链，确保当前可见的 VC 都收到旋转通知
            var vc = scene?.keyWindow?.rootViewController
            while let presented = vc?.presentedViewController {
                vc = presented
            }
            vc?.setNeedsUpdateOfSupportedInterfaceOrientations()
        } else {
            let value = toLandscape
                ? UIInterfaceOrientation.landscapeRight.rawValue
                : UIInterfaceOrientation.portrait.rawValue
            UIDevice.current.setValue(value, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }
}

/// 键盘收起助手：监听键盘展示/收起系统通知，在键盘弹出时往当前 `keyWindow` 上挂
/// `cancelsTouchesInView = false` 的点击/拖动手势，收起时摘掉——挂/摘动作是纯 UIKit 操作
/// （`UIWindow.addGestureRecognizer`，不插入/移除任何 view），跟 SwiftUI 的视图树结构 diff
/// 完全无关，不会触发"结构位置偏移→子树判定为新增/销毁"的重建链路，因此不会影响正在编辑的
/// 输入框的 first responder 状态。
///
/// 有意不在 App 启动时全局常驻，而是提供 `start()`/`stop()` 由具体页面按自己的呈现生命周期
/// 显式接入（目前只接给 `TravelView` 的剧本编辑面板验证）——先小范围验证这套机制在真机上
/// 确实不影响聚焦，再决定要不要推广替换首页/设置页现有的做法。
///
/// 需要继承 `NSObject`：`UIGestureRecognizerDelegate` 要求遵从 `NSObjectProtocol`，纯 Swift 类
/// 挂 `@objc` 方法（target-action、通知回调）本身没问题，但接协议必须是 `NSObject` 子类。
final class KeyboardDismissAssistant: NSObject {
    static let shared = KeyboardDismissAssistant()
    private override init() { super.init() }

    private weak var attachedWindow: UIWindow?
    private var tap: UITapGestureRecognizer?
    private var pan: UIPanGestureRecognizer?
    private var isObserving = false

    /// 当前需要排除在"点哪都能收键盘"之外的范围（window/`.global` 坐标）。由呈现方（目前是
    /// `ScriptListTextEditor`）通过 `GeometryReader` 实时回填自己的真实 frame，不靠遍历视图树、
    /// 也不靠按 `touch.view` 的类型猜测——这个场景里唯一需要特殊处理的就是输入框本身，直接校验
    /// 它汇报的真实范围，比类型判断更精确，也不用穷举 `UIControl`/`UITextView` 等各种子类。
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

    /// `UITapGestureRecognizer` 的 action 只在识别成功那一刻调用一次，无需额外过滤；但
    /// `UIPanGestureRecognizer` 的 target-action 会在手势的每个状态（`.began`/`.changed`/
    /// `.ended`/`.cancelled`）都被调用一次，`.changed` 在拖动过程中会连续触发多次——只要一开始
    /// 拖动就已经达到"收键盘"的目的，只在 `.began` 这一次真正执行，避免同一次拖动手势里反复
    /// 对响应链发送 `resignFirstResponder`（对已失焦的输入框是空操作，但没必要重复发）。
    @objc private func handle(_ gesture: UIGestureRecognizer) {
        if let pan = gesture as? UIPanGestureRecognizer, pan.state != .began {
            return
        }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

extension KeyboardDismissAssistant: UIGestureRecognizerDelegate {
    /// 触摸落在 `excludedRect` 范围内（当前就是输入框的真实 frame）时直接拒收，这次触摸压根不会
    /// 进入我们的手势识别流程——不影响输入框自己内部"点击定位光标"等手势的识别，也不需要跟它们
    /// 抢时序。范围之外维持原样，照常识别、照常收键盘。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let window = attachedWindow, let rect = excludedRect else { return true }
        return !rect.contains(touch.location(in: window))
    }
}

/// 注入到 SwiftUI App 生命周期，用于控制设备方向。
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLock.shared.mask
    }
}
