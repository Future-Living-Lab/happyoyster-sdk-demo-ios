import SwiftUI
import HappyOysterSDK
import HappyOysterUI

/// 游玩全屏界面（横屏）。
/// 进入时锁横屏，离开时解锁。所有退出路径均先调 endTravel 再关闭。
@available(iOS 15.0, *)
struct TravelView: View {

    let world: WorldListItem

    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var vm = TravelViewModel()
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isInstructFieldFocused: Bool
    /// scriptlist 世界「更新剧本」编辑面板是否展示（覆盖层，独立于 vm 状态，纯本地 UI 开关）。
    @State private var isScriptEditorPresented = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 视频视图：start() 成功后才挂载，确保 SDK engine 已就绪、renderView 有真实 bounds
            //
            // 点击收起键盘的手势挂在这一层（画面本体），而不是挂在整个根 ZStack 上：
            // 它和上面 HUD 里的按钮 / Story 输入框 / Wander 摇杆是 ZStack 里的同级 sibling、不是它们的祖先，
            // 命中测试按屏幕位置走——落在按钮/摇杆可点击区域的触摸会被那些叠在上层的视图先接住，
            // 根本不会传到这一层；只有落在画面空白处的点击才会触发收键盘。
            // 手势本身是无条件挂载的（不按 isInstructFieldFocused 条件挂/卸）——之前踩过条件挂载
            // 导致 SwiftUI 视图身份变化、TextField 无法正常聚焦的坑；未聚焦时点一下只是把
            // isInstructFieldFocused 置为 false 的空操作，不会有副作用。Wander 模式下摇杆区域
            // 本身盖在这一层上面，摇杆的拖拽手势会被摇杆自己先接住，触摸根本不会穿透到这里，
            // 天然不会跟摇杆产生竞争。
            Group {
                if vm.showVideo, let travel = vm.travel {
                    OysterVideoView(travel: travel)
                } else {
                    Color.black
                }
            }
            .ignoresSafeArea()
            .onTapGesture {
                isInstructFieldFocused = false
            }

            // 主 HUD（顶部信息栏 + 底部操控区）
            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            // 右下角断线重连提示（不遮挡画面）：单独 `@ObservedObject` `vm.countdown`，
            // 不经过 `vm` 本身，避免每秒 tick 带着这个覆盖层一起被 `TravelView.body` 重新 diff。
            TravelReconnectingOverlay(countdown: vm.countdown, status: vm.status)

            if vm.isStarting { loadingOverlay }

            if let err = vm.errorMessage {
                errorOverlay(err)
            }

            // 非阻断性 toast（token 刷新进度、轻量提示）
            if let toast = vm.toastMessage {
                toastBanner(toast)
            }
        }
        .statusBar(hidden: true)
        // scriptlist 世界「更新剧本」编辑面板：用 fullScreenCover 呈现而不是内联在 ZStack 里的 `if` 分支。
        // `TravelView` 持有 `@StateObject var vm`，vm 的倒计时每秒 tick 一次都会让 `TravelView.body`
        // 整体重新求值；若面板内联在同一棵视图树里，每次重新求值都会把它带入同一趟 diff，
        // 个别系统版本上会连带把内部 `TextEditor` 的滚动位置重置回顶部（即“不停刷新回到原始位置”）。
        // fullScreenCover 呈现的内容挂在独立的 hosting controller 上，只在自身状态变化或首次呈现时
        // 重新构建，不再随外层每秒一次的重绘节拍被动跟着重新 diff，从源头切断这条重绘链路；
        // 前面给 `TextEditor` 包的 `.equatable()` 继续保留作为兜底。
        .fullScreenCover(isPresented: $isScriptEditorPresented) {
            scriptUpdateEditorOverlay
        }
        .onAppear {
            OrientationLock.shared.lock(toLandscape: true)
            Task {
                await vm.start(
                    encryptedWorldId: world.encryptedWorldId,
                    maxExperienceTimeSec: env.maxExperienceTimeSec,
                    client: env.apiClient,
                    tokenManager: session.tokenManager
                )
            }
        }
        .onDisappear {
            // 方向已在 onChange(shouldDismiss) 里 dismiss 前恢复，此处是兜底
            OrientationLock.shared.lock(toLandscape: false)
        }
        .onChange(of: vm.shouldDismiss, perform: { should in
            if should {
                // 先解锁方向，再 dismiss，确保旋转动画在退场动画之前触发
                OrientationLock.shared.lock(toLandscape: false)
                dismiss()
            }
        })
        // 「更新剧本」请求结束（成功或失败）后 isUpdatingScript 回到 false：自动收起面板，
        // 结果改用底层 toast 展示——面板本身在请求进行中保持打开、展示加载态。
        .onChange(of: vm.isUpdatingScript, perform: { isUpdating in
            if !isUpdating && isScriptEditorPresented {
                isScriptEditorPresented = false
            }
        })
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .top) {
            // 名称 + 状态胶囊 + 倒计时行：单独 `@ObservedObject` `vm.countdown`，
            // 不经过 `vm` 本身，避免每秒 tick 带着整个 `TravelView.body` 一起重新 diff。
            TravelTopBarLeading(countdown: vm.countdown, worldName: world.name, status: vm.status)
            Spacer()
            HStack(spacing: 8) {
                if vm.supportsPauseResume {
                    if case .running = vm.status { pauseButton }
                    else if case .paused = vm.status { resumeButton }
                    else if case .pausing = vm.status { resumeButton }
                }
                closeButton
            }
        }
    }

    // MARK: - 暂停 / 恢复按钮

    private var pauseButton: some View {
        Button { vm.pauseTravel() } label: {
            controlButtonLabel(systemName: "pause.fill")
        }
        .disabled(vm.isPausing)
    }

    private var resumeButton: some View {
        Button { vm.resumeTravel() } label: {
            controlButtonLabel(systemName: "play.fill")
        }
        .disabled(vm.isResuming)
    }

    private func controlButtonLabel(systemName: String) -> some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.4))
                .frame(width: 36, height: 36)
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var closeButton: some View {
        Button { vm.endAndDismiss() } label: {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.4))
                    .frame(width: 36, height: 36)
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }

    // MARK: - Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        if case .running = vm.status {
            if vm.isWanderMode {
                // 双摇杆 HUD 整宽布局：左摇杆贴左、按键 + 右摇杆贴右
                WorldTravelControlsView { params in
                    vm.sendCommand(OysterAdventureCommand(params))
                }
            } else if !vm.isCreationModelResolved {
                // creationModel 还没查回来：不知道该展示文本指令框还是「更新剧本」入口，
                // 先不展示，避免"先按 simple 展示、结果一回来又切换"的闪烁。
                EmptyView()
            } else if vm.isScriptListMode {
                // scriptlist 世界：不展示文本指令输入，改为「更新剧本」入口（与文本指令互斥）
                HStack(alignment: .bottom) {
                    scriptUpdateEntryButton
                    Spacer()
                }
            } else {
                HStack(alignment: .bottom) {
                    InstructInputView(isFocused: $isInstructFieldFocused) { text in
                        vm.sendInstruct(text)
                    }
                    Spacer()
                }
            }
        } else if case .paused = vm.status {
            HStack(spacing: 12) {
                Text("已暂停")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.15), in: Capsule())

                // Story 模式下才显示回退按钮。单独 `@ObservedObject` `vm.countdown`
                // 判断 `canRewind`（依赖 elapsedSec），不经过 `vm` 本身。
                if !vm.isWanderMode {
                    RewindButton(
                        countdown: vm.countdown,
                        isWanderMode: vm.isWanderMode,
                        status: vm.status,
                        isRewinding: vm.isRewinding,
                        onTap: { vm.rewindBack10s() }
                    )
                }

                Spacer()
            }
        } else if case .pausing = vm.status {
            HStack {
                ProgressView().tint(.white).scaleEffect(0.8)
                Text("暂停中…")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - 更新剧本（scriptlist 世界）

    /// 底部 HUD 的「更新剧本」入口按钮，样式对齐回退 10s 按钮。
    private var scriptUpdateEntryButton: some View {
        Button { isScriptEditorPresented = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 13, weight: .semibold))
                Text("更新剧本")
                    .font(.subheadline.bold())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.15), in: Capsule())
        }
    }

    /// 全屏半透明遮罩 + 居中编辑卡片；点/拖任意位置**只收起键盘、不关闭面板**——编辑内容不会
    /// 因为误触丢失，必须点「取消」才真正退出。发送后面板不会立即关闭——请求进行中保持展示
    /// 加载态，请求结束（成功/失败）由 `TravelView.body` 上的 `onChange(of: vm.isUpdatingScript)`
    /// 自动收起，结果改用 toast 展示。作为 `fullScreenCover` 内容呈现，系统默认给 cover 一层
    /// 不透明背景，这里用 `ClearFullScreenCoverBackground` 把它改成透明，保留遮罩后仍能看到
    /// 底层画面被压暗的效果。收键盘手势改用 `KeyboardDismissAssistant`（见 `AppDelegate.swift`）：
    /// 面板呈现时启动监听、消失时停止——启停时机绑在这个独立 hosting controller 自己的生命周期上，
    /// 跟外层 `TravelView` 每秒一次的倒计时刷新无关，也不涉及任何 SwiftUI 条件挂载。这是目前
    /// 项目内第一个接入这套新机制的入口，先在这个相对独立、风险最低的面板上验证。
    private var scriptUpdateEditorOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            ScriptUpdateEditorView(
                isSending: vm.isUpdatingScript,
                onSend: { scriptList in vm.updateScriptList(scriptList) },
                onCancel: { isScriptEditorPresented = false }
            )
        }
        .background(ClearFullScreenCoverBackground())
        .onAppear { KeyboardDismissAssistant.shared.start() }
        .onDisappear { KeyboardDismissAssistant.shared.stop() }
    }

    // MARK: - Overlays

    private var loadingOverlay: some View {
        VStack(spacing: 16) {
            ProgressView().tint(.white).scaleEffect(1.4)
            Text("连接中…")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.55).ignoresSafeArea())
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            ScrollView {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 240)
            Button("关闭") { vm.endAndDismiss() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.75).ignoresSafeArea())
    }

    /// 非阻断性 toast 横幅（顶部居中，3s 自动消失）。
    private func toastBanner(_ message: String) -> some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.white.opacity(0.85))
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.72), in: Capsule())
            .padding(.top, 16)
            Spacer()
        }
        .allowsHitTesting(false)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: vm.toastMessage)
    }
}

// MARK: - Story 模式文字指令输入框

/// 横屏下适用的紧凑文字输入组件：TextField + 发送按钮。
/// 发送后自动清空输入框，发送中禁用按钮防止重复提交。
@available(iOS 15.0, *)
private struct InstructInputView: View {
    /// 焦点状态由 `TravelView` 持有（供画面层的收键盘手势判断是否要挂载）。
    var isFocused: FocusState<Bool>.Binding
    let onSend: (String) -> Void

    @State private var text = ""
    @State private var isSending = false

    var body: some View {
        HStack(spacing: 8) {
            TextField("输入剧情指令…", text: $text)
                .focused(isFocused)
                .font(.subheadline)
                .foregroundStyle(.white)
                .tint(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                .frame(width: 260)
                .submitLabel(.send)
                .onSubmit { send() }

            Button(action: send) {
                Group {
                    if isSending {
                        ProgressView().tint(.white).scaleEffect(0.8)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 36, height: 36)
                .background(
                    sendDisabled
                        ? Color.white.opacity(0.1)
                        : Color.accentColor.opacity(0.85),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            }
            .disabled(sendDisabled)
        }
    }

    private var sendDisabled: Bool {
        isSending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        isSending = true
        onSend(trimmed)
        text = ""
        isFocused.wrappedValue = false
        // 给调用方一点时间异步完成，再恢复按钮状态
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { isSending = false }
    }
}

// MARK: - 倒计时相关子视图（单独 `@ObservedObject` `TravelCountdownModel`）
//
// 以下几个视图都只持有 `vm.countdown`（不是 `vm` 本身），每秒 tick 只会让它们各自的
// body 重新求值，不会带着 `TravelView.body`（以及挂在它 body 里的 fullScreenCover 更新剧本
// 面板）一起重绘。拆分之前，这几处直接读 `vm.xxx`，任何 `vm` 的 `@Published` 变化
// （包括每秒一次的倒计时）都会让 `TravelView.body` 整体重新求值一次。

private func formatSeconds(_ sec: Int) -> String {
    let m = sec / 60
    let s = sec % 60
    return String(format: "%d:%02d", m, s)
}

/// 顶部信息栏左侧：世界名 + 状态胶囊 + 倒计时行。
@available(iOS 15.0, *)
private struct TravelTopBarLeading: View {
    @ObservedObject var countdown: TravelCountdownModel
    let worldName: String?
    let status: OysterTravelStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let worldName {
                Text(worldName)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            statusPill
            if countdown.timerStarted {
                countdownRow
            }
        }
    }

    private var isPaused: Bool {
        if case .paused = status { return true }
        return false
    }

    private var statusPill: some View {
        Text(statusTitle)
            .font(.caption.monospaced())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(statusTint.opacity(0.18)))
            .foregroundColor(statusTint)
    }

    private var statusTitle: String {
        switch status {
        case .idle: return "idle"
        case .prepare: return countdown.timerStarted ? "reconnecting" : "connecting"
        case .running: return "playing"
        case .paused: return "paused"
        case .ended: return "ended"
        case .failed: return "failed"
        @unknown default: return "—"
        }
    }

    private var statusTint: Color {
        switch status {
        case .idle: return .gray
        case .prepare: return .orange
        case .running: return .green
        case .paused: return .blue
        case .ended: return .secondary
        case .failed: return .red
        @unknown default: return .gray
        }
    }

    private var countdownRow: some View {
        HStack(spacing: 8) {
            // 模式倒计时（wander 60s / story 180s，暂停时停止）
            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                Text(formatSeconds(countdown.modeCountdown))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(countdown.modeCountdown <= 10 ? Color.orange : Color.white.opacity(0.85))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.35), in: Capsule())

            // 总时长倒计时（300s，不受暂停影响）—— 仅暂停时显示
            if isPaused {
                HStack(spacing: 5) {
                    Image(systemName: "timer")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(formatSeconds(countdown.totalCountdown))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(countdown.totalCountdown <= 30 ? Color.orange : Color.white.opacity(0.6))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.25), in: Capsule())
            }
        }
    }
}

/// 右下角断线重连提示（不遮挡画面，不阻塞点击）。
@available(iOS 15.0, *)
private struct TravelReconnectingOverlay: View {
    @ObservedObject var countdown: TravelCountdownModel
    let status: OysterTravelStatus

    private var isReconnecting: Bool { countdown.timerStarted && status == .prepare }

    var body: some View {
        Group {
            if isReconnecting {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        badge
                    }
                }
                .padding(20)
                .allowsHitTesting(false)
            }
        }
    }

    private var badge: some View {
        HStack(spacing: 6) {
            ProgressView().tint(.white).scaleEffect(0.7)
            Text("重连中…")
                .font(.caption.bold())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// 暂停态下的「回退 10s」按钮：`canRewind` 依赖 `elapsedSec`，需要单独观察 `countdown`。
@available(iOS 15.0, *)
private struct RewindButton: View {
    @ObservedObject var countdown: TravelCountdownModel
    let isWanderMode: Bool
    let status: OysterTravelStatus
    let isRewinding: Bool
    let onTap: () -> Void

    private var canRewind: Bool {
        guard case .paused = status else { return false }
        return !isWanderMode && countdown.elapsedSec > 10 && !isRewinding
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                if isRewinding {
                    ProgressView().tint(.white).scaleEffect(0.7)
                } else {
                    Image(systemName: "gobackward")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text("回退 10s")
                    .font(.subheadline.bold())
            }
            .foregroundStyle(canRewind ? .white : .white.opacity(0.35))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(canRewind ? 0.15 : 0.07), in: Capsule())
        }
        .disabled(!canRewind)
    }
}

// MARK: - iOS 15 兼容辅助

/// 让 `fullScreenCover` 内容透明、可见底层画面被压暗的效果——iOS 15 无 `.presentationBackground`（iOS 16.4+），
/// 用这个常见的 UIViewRepresentable 技巧把 cover 所在的 presentation 容器背景改成 clear。
private struct ClearFullScreenCoverBackground: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        DispatchQueue.main.async {
            view.superview?.superview?.backgroundColor = .clear
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

private extension View {
    /// `TextEditor.scrollContentBackground(.hidden)` 仅 iOS 16+ 可用（PodExample 部署目标 iOS 15），
    /// iOS 15 上退化为不隐藏系统滚动背景（TextEditor 默认底色会盖住外部深色背景，仅视觉降级，不影响功能）。
    @ViewBuilder
    func hiddenScrollBackgroundIfAvailable() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}

// MARK: - scriptlist 世界「更新剧本」编辑面板

/// 独立包一层 `TextEditor` 并实现 `Equatable`，作为兜底：真正切断倒计时耦合的是
/// `TravelViewModel.countdown`（见 `TravelViewModel.swift` 顶部的 `TravelCountdownModel`）——
/// 之前倒计时四个字段直接是 `TravelViewModel` 的 `@Published` 属性，Combine 的 `objectWillChange`
/// 不区分具体哪个属性变了，只要任意一个变化，所有持有 `@StateObject var vm` 的视图（`TravelView`
/// 整体、以及它 `.fullScreenCover` 呈现的本面板）都会被标记为需要重新求值，于是每秒都被拖着
/// 重新 diff 一次；个别系统版本上这会把 `TextEditor` 的滚动位置/光标重置回顶部，表现为
/// 「选择模板后编辑器不停跳回起始位置」。拆到独立的 `TravelCountdownModel` 后，这四个字段的变化
/// 只会触发它自己的 `objectWillChange`，不会转发给 `TravelViewModel`，从根上不再有这个耦合。
/// 这里的 `.equatable()` 只是双保险：万一未来又有别的字段被错误地直接放回 `TravelViewModel`，
/// 至少这个 `TextEditor` 不会跟着遭殃。
@available(iOS 15.0, *)
private struct ScriptListTextEditor: View, Equatable {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text
    }

    var body: some View {
        TextEditor(text: $text)
            .focused(isFocused)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.white)
            .hiddenScrollBackgroundIfAvailable()
            .padding(8)
            .frame(minHeight: 220, maxHeight: 340)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            // 把这个输入框的真实 frame（`.global` 坐标，跟 window 坐标系一致）实时回填给
            // `KeyboardDismissAssistant`，让它在点击落在这块范围内时直接拒收——不用猜测
            // `touch.view` 的类型，直接用输入框自己汇报的精确范围。这个面板一旦消失，
            // `scriptUpdateEditorOverlay` 的 `onDisappear` 会调用 `stop()` 清空这个范围，
            // 不会遗留到下一次别的页面接入这套机制时误伤。
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { KeyboardDismissAssistant.shared.excludedRect = proxy.frame(in: .global) }
                        .onChange(of: proxy.frame(in: .global)) { newRect in
                            KeyboardDismissAssistant.shared.excludedRect = newRect
                        }
                }
            )
    }
}

/// 与创建世界的 scriptlist 编辑器同构：模板下拉一键填入 + 完整 JSON 编辑器 + 发送。
/// 校验规则与创建共用 `ScriptListJSONValidator`（见 `ScriptPreset.swift`），避免规则漂移。
@available(iOS 15.0, *)
private struct ScriptUpdateEditorView: View {
    /// 请求进行中：按钮切到「发送中…」态，面板保持展示，不能重复点击。
    let isSending: Bool
    let onSend: (JSONValue) -> Void
    let onCancel: () -> Void

    @State private var scriptListText = ""
    @State private var presets: [ScriptPreset] = []
    @State private var selectedPresetId: String?
    @State private var validationMessage: String?
    @FocusState private var isEditorFocused: Bool

    private var isTextEmpty: Bool {
        scriptListText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var sendDisabled: Bool { isSending || isTextEmpty }

    var body: some View {
        // 中间内容不用 ScrollView 包：`TextEditor` 嵌在 `ScrollView` 里实测会导致它的高度
        // 塌陷（`.frame(minHeight:maxHeight:)` 不生效），输入框直接"消失"、点不到光标、
        // 编辑不了内容——比"横屏+键盘遮住部分内容"更严重，所以固定高度的写法保留，
        // 不为了防溢出牺牲编辑功能本身。收键盘不依赖 `.toolbar(placement: .keyboard)`：
        // 这个面板是 `fullScreenCover` 弹出的独立视图，没有自己的 `NavigationView`，键盘
        // 工具栏机制挂不上去；补一层 `NavigationView` 又会带来它自带的不透明背景，把
        // "暗色遮罩+悬浮卡片"这层透明效果切出一道实色分割。收键盘改用 `KeyboardDismissAssistant`
        // （随 `scriptUpdateEditorOverlay` 的呈现/消失启停，键盘弹出时挂在 `keyWindow` 上，
        // `cancelsTouchesInView = false`，点/拖整个面板任意位置都能收键盘，且不影响
        // `TextEditor`/`Menu`/`Button` 自身的触摸处理）。
        VStack(alignment: .leading, spacing: 14) {
            Text("更新剧本")
                .font(.headline)
                .foregroundStyle(.white)

            // 发送中整块锁定（模板选择 + JSON 编辑器都不可交互），避免用户以为编辑会影响
            // 已经发出去的这次请求；`.disabled` 对 `Menu`/`TextEditor` 都生效，同时用透明度
            // 给出"已锁定"的视觉反馈。
            Group {
                if !presets.isEmpty {
                    presetPicker
                }

                ScriptListTextEditor(text: $scriptListText, isFocused: $isEditorFocused)
                    .equatable()
            }
            .disabled(isSending)
            .opacity(isSending ? 0.55 : 1)

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 12) {
                Spacer()
                Button("取消") {
                    isEditorFocused = false
                    onCancel()
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .disabled(isSending)

                sendButton
            }
        }
        .padding(20)
        .frame(maxWidth: 560)
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 16))
        .padding(24)
        .task {
            guard presets.isEmpty else { return }
            presets = await ScriptPresetProvider().loadPresets()
        }
    }

    private var presetPicker: some View {
        Menu {
            ForEach(presets) { preset in
                Button(preset.label) {
                    selectedPresetId = preset.id
                    scriptListText = preset.scriptListJSON
                    validationMessage = nil
                }
            }
        } label: {
            HStack {
                Text(selectedPresetLabel)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var selectedPresetLabel: String {
        presets.first(where: { $0.id == selectedPresetId })?.label ?? "选择模板…（可选，也可直接编辑下方 JSON）"
    }

    /// 自定义样式而不是 `.buttonStyle(.borderedProminent)`：系统禁用态是在原色上叠一层半透明灰，
    /// 在这个深色卡片背景（`Color(white: 0.12)`）上叠出来的颜色和背景太接近，几乎看不出按钮存在。
    /// 这里按"未就绪"（文本为空）/"发送中"/"可发送"三态分别给明确的背景色，保证任何状态下
    /// 按钮轮廓和文字都跟深色背景有足够对比度。
    private var sendButton: some View {
        Button(action: send) {
            HStack(spacing: 6) {
                if isSending {
                    ProgressView().tint(.white).scaleEffect(0.75)
                    Text("发送中…")
                } else {
                    Text("发送")
                }
            }
            .font(.subheadline.bold())
            .foregroundStyle(isTextEmpty && !isSending ? Color.white.opacity(0.45) : Color.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                (isTextEmpty && !isSending) ? Color.white.opacity(0.18) : Color.accentColor,
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: (isTextEmpty && !isSending) ? 1 : 0)
            )
        }
        .disabled(sendDisabled)
    }

    private func send() {
        switch ScriptListJSONValidator.validate(text: scriptListText) {
        case .success(let scriptList):
            validationMessage = nil
            isEditorFocused = false
            onSend(scriptList)
        case .failure(let message):
            validationMessage = message
        }
    }
}
