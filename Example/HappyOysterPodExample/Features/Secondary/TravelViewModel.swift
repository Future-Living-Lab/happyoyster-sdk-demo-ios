import Foundation
import HappyOysterSDK

/// 倒计时状态单独拆到这个子 `ObservableObject`，不作为 `TravelViewModel` 的 `@Published` 属性。
/// Combine 的 `objectWillChange` 只在“自身直接持有的 @Published 属性变化”时才广播给持有者，
/// 嵌套对象内部的变化不会自动转发——`TravelViewModel` 每秒 tick 一次更新这里的字段，
/// 不会连带触发 `TravelViewModel.objectWillChange`，进而不会让持有 `@StateObject var vm` 的
/// `TravelView` 每秒重绘整棵树（包括跟倒计时无关的「更新剧本」覆盖层）。
/// 需要跟着 tick 实时刷新的视图，直接 `@ObservedObject` 这个子对象，不要经过 `TravelViewModel`。
@available(iOS 15.0, *)
@MainActor
final class TravelCountdownModel: ObservableObject {
    /// 当前模式倒计时（冒险模式使用设置值 / directing=180s），暂停时停止，最小为 0。
    @Published fileprivate(set) var modeCountdown: Int = 0
    /// 总使用时长倒计时（300s），不受暂停影响；归零时自动结束游玩。
    @Published fileprivate(set) var totalCountdown: Int = 300
    /// 已累计运行秒数（暂停期间不增加），用于计算回溯目标时间。
    @Published fileprivate(set) var elapsedSec: Int = 0
    /// 计时是否已启动（首次进入 running 状态后置 true，用于控制 UI 可见性）。
    @Published fileprivate(set) var timerStarted: Bool = false
}

/// 游玩会话的 ViewModel：经 `HappyOysterEngine.createTravel(ticket:)` 创建 `OysterTravel` 会话，
/// 订阅其 `events` 驱动状态与错误；暂停/恢复/结束/实时互动都打在该会话实例上（不再传 encryptedTravelId）。
/// 所有退出路径均通过 endAndDismiss() 走同一条清理链路。
@available(iOS 15.0, *)
@MainActor
final class TravelViewModel: ObservableObject {

    /// 对外会话状态（idle → prepare → running ⇄ paused → ended/failed）。
    @Published private(set) var status: OysterTravelStatus = .idle
    @Published var isStarting = false
    @Published var errorMessage: String?
    @Published var shouldDismiss = false

    /// SDK 会话句柄：createTravel 后赋值，供视频视图（OysterVideoView）与实时互动使用。
    @Published private(set) var travel: OysterTravel?
    /// start() 成功后置 true；OysterVideoView 仅在此为 true 时挂载（确保 engine 已就绪、renderView 有真实尺寸）。
    @Published private(set) var showVideo = false

    // MARK: - 倒计时

    /// 倒计时状态（见 `TravelCountdownModel` 顶部注释）：视图侧需要跟着每秒 tick 刷新的地方
    /// 应直接 `@ObservedObject` 这个子对象，不要经过本类，避免连带触发本类的 objectWillChange。
    let countdown = TravelCountdownModel()

    /// 是否处于「已开始游玩后的重连态」。对外状态把 connecting/reconnecting 统一为 prepare，
    /// 故用「已计时 + 回到 prepare」近似判定重连。
    var isReconnecting: Bool { countdown.timerStarted && status == .prepare }

    /// 本次游玩的 encryptedTravelId（start 成功后赋值，仅用于日志）。
    private(set) var travelId: String?
    /// start() 返回的标准化模式（"wander" | "directing"），nil 表示尚未 start。
    @Published private(set) var modeText: String?
    /// 当前是否为 wander 模式（来自 start() 返回值，比列表 mode 更可靠）。
    var isWanderMode: Bool { modeText == "wander" }
    /// 世界创建方式（"simple" | "scriptlist"）。SDK 的 enter-travel 不带该字段（不改动 SDK），
    /// 进入会话成功后单独调用 `GET /server-api/worlds/detail` 获取；scriptlist 世界游玩中改走
    /// 「更新剧本」，与文本指令互斥。`nil` 表示尚未拿到结果——底部指令/剧本入口在此期间不展示，
    /// 避免先按 "simple" 展示文本指令框、结果一回来又跳成「更新剧本」按钮的闪烁。
    @Published private(set) var creationModel: String?
    /// `creationModel` 是否已确定（成功或失败兜底后都会置为非 nil，见 `fetchCreationModel`）。
    var isCreationModelResolved: Bool { creationModel != nil }
    /// 是否为 scriptlist 世界（游玩中隐藏文本指令输入，改用「更新剧本」入口）。
    /// 归一化大小写后比较——和 `normalizedMode` 对 `mode` 字段的处理方式保持一致，
    /// 避免服务端返回大小写不同的值（如 "Scriptlist"）时被误判成 simple 世界。
    var isScriptListMode: Bool { creationModel?.lowercased() == "scriptlist" }
    /// 更新剧本请求进行中：面板发送后保持展示（显示加载态），直到这个字段回到 false 才由
    /// `TravelView` 自动收起面板并展示 toast，状态与请求生命周期一一对应，也天然防止重复发送。
    @Published private(set) var isUpdatingScript = false
    /// start() 返回的 travelVersion；暂停/回溯仅 "storyV2" 支持。
    @Published private(set) var travelVersion: String?
    /// 是否支持暂停与回溯（非 wander 模式即展示；不支持时由服务端 API 返回 103002 拒绝）。
    var supportsPauseResume: Bool { !isWanderMode }
    /// 是否允许回溯：Story 模式 + 已暂停 + 运行超 10s + 无进行中回溯。
    /// 必须在 paused 状态下触发，避免在 connecting / running 时向服务端发出非预期的回溯指令。
    var canRewind: Bool { !isWanderMode && status == .paused && countdown.elapsedSec > 10 && !isRewinding }
    /// 回溯请求进行中（防止重复点击）。
    @Published private(set) var isRewinding = false
    /// 暂停请求进行中（防止重复点击）。
    @Published private(set) var isPausing = false
    /// 恢复请求进行中（防止重复点击）。
    @Published private(set) var isResuming = false

    /// 非阻断性 toast 消息（3s 后自动清除）。
    @Published private(set) var toastMessage: String?

    private var modeCountdownMax: Int = 60      // 冒险模式使用设置值 / directing=180，由 start() 返回值确定
    private var countdownActive: Bool = false   // 暂停时 false
    private var timerTask: Task<Void, Never>?
    /// 总时长倒计时的挂钟基准（不受暂停影响，一次 start 只设一次）。
    private var totalStartDate: Date?
    /// 当前「运行中」区间的挂钟起点；暂停时置 nil，恢复时重置为 `Date()`。
    private var modeActiveStartDate: Date?
    /// 已冻结（暂停前）累计的运行时长；配合 `modeActiveStartDate` 算出总运行时长。
    private var modeAccumulatedActiveSec: TimeInterval = 0
    private var eventTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    /// 注入 TokenManager，用于 token 失效时主动刷新并重注入 SDK。
    private weak var tokenManager: TokenManager?
    /// 注入的业务接口客户端，供「更新剧本」（世界资产类接口，走业务服务转发）使用。
    private weak var apiClient: APIClient?

    /// Token 刷新中：屏蔽 .failed 的全屏错误 overlay，改为 toast + 轻提示 dismiss。
    private var pendingTokenRefresh = false

    // MARK: - 启动

    func start(
        encryptedWorldId: String,
        maxExperienceTimeSec: Int,
        client: APIClient,
        tokenManager: TokenManager?
    ) async {
        guard !isStarting, travel == nil else {
            appLog("[Travel] ⚠️ start() rejected (isStarting=\(isStarting), hasTravel=\(travel != nil))")
            return
        }

        // Step 0：SDK 未就绪（apiHost 为空/非法导致 initialize 失败）时同步、零网络开销拦截。
        // 比等 Step 2 createTravel 抛 100001、甚至 Step 3 走到网关请求才报 106001 网络错误
        // 更早一步——避免"apiHost 没配对"和"真的网络/RTC 异常"混在一起，误导排查方向。
        guard HappyOysterEngine.shared.isReady else {
            appLog("[Travel] ⚠️ start() rejected: SDK not ready (apiHost not configured or invalid)")
            errorMessage = "SDK 未就绪：请先在设置页配置有效的百炼 APIHost"
            return
        }

        self.tokenManager = tokenManager
        self.apiClient = client
        isStarting = true
        defer { isStarting = false }

        appLog("[Travel] ▶ start — worldId: \(encryptedWorldId)")

        // Step 1：向服务端换取一次性漫游凭证
        let credential: TravelCredentialResponse
        do {
            credential = try await client.travelCredential(encryptedWorldId: encryptedWorldId)
            appLog("[Travel] ✅ credential ok — ticket: \(credential.ticket.prefix(8))… expiresIn: \(credential.expiresIn)s")
        } catch {
            errorMessage = "获取凭证失败：\(error.localizedDescription)"
            return
        }

        // Step 2：创建会话并订阅事件（start 前订阅，确保不漏事件）
        let session: OysterTravel
        do {
            session = try HappyOysterEngine.shared.createTravel(ticket: credential.ticket)
        } catch let err as OysterSDKError {
            errorMessage = "创建会话失败：\(sdkErrorDescription(err))"
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            endAndDismiss()
            return
        } catch {
            errorMessage = "创建会话失败：\(error.localizedDescription)"
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            endAndDismiss()
            return
        }
        travel = session
        subscribeEvents(session)

        // Step 3：启动游览（内部用 ticket 换 travel + RTC 入会）
        // token 过期时自动刷新后重试一次。
        do {
            let data = try await sdkCall {
                try await session.start(maxExperienceTimeSec: maxExperienceTimeSec)
            }
            travelId = data.encryptedTravelId
            modeText = normalizedMode(data.mode.rawValue)
            travelVersion = data.version
            modeCountdownMax = modeText == "wander" ? maxExperienceTimeSec : 180
            appLog("[Travel] 🚀 startTravel ok — travelId: \(data.encryptedTravelId) mode: \(modeText ?? data.mode.rawValue) version: \(data.version)")
            // start() 成功后才挂载视频视图：确保 engine 已绑定 renderView，
            // 避免 OysterVideoView 在 engine=nil 时挂入全屏布局导致 setRemoteViewConfig 绑到 0×0 view。
            showVideo = true
            // SDK 不带 creationModel，单独查一次世界详情决定体验页 UI（scriptlist 世界改走「更新剧本」）；
            // 失败不影响主流程，静默保留缺省 "simple"。
            fetchCreationModel(encryptedWorldId: encryptedWorldId, client: client)
        } catch let err as OysterSDKError {
            errorMessage = sdkErrorDescription(err)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            endAndDismiss()
        } catch {
            errorMessage = error.localizedDescription
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            endAndDismiss()
        }
    }

    /// 单独查询世界详情获取 `creationModel`（`GET /server-api/worlds/detail`，接口文档 §3.1.1）。
    /// SDK 的 enter-travel 返回不带该字段，业务层自行补查，与 SDK 无耦合。
    private func fetchCreationModel(encryptedWorldId: String, client: APIClient) {
        Task {
            do {
                let detail = try await client.worldDetail(encryptedWorldId: encryptedWorldId)
                let value = detail.creationModel?.isEmpty == false ? detail.creationModel! : "simple"
                creationModel = value
                appLog("[Travel] ℹ️ worldDetail ok — creationModel: \(value)")
            } catch {
                // 失败兜底仍要显式赋值（而不是留 nil）：否则底部指令/剧本入口会一直不展示。
                creationModel = "simple"
                appLog("[Travel] ⚠️ worldDetail failed (fallback creationModel=simple): \(error)")
            }
        }
    }

    /// 通用 SDK 调用包装：捕获 token 类错误（101001/101002），刷新后重试一次。
    /// 所有会抛出 OysterSDKError 的 SDK 方法都经此包装，集中处理 token 过期，无需单点修补。
    private func sdkCall<T>(_ call: () async throws -> T) async throws -> T {
        do {
            return try await call()
        } catch let err as OysterSDKError where err.kind == .tokenMissing || err.kind == .tokenInvalid {
            appLog("[Travel] 🔑 token error in SDK call (\(err.code)), refreshing and retrying…")
            guard let tm = tokenManager else {
                appLog("[Travel] ⚠️ no tokenManager, cannot retry")
                throw err
            }
            _ = try await tm.invalidateAndRefresh()
            appLog("[Travel] ✅ token refreshed, retrying…")
            return try await call()
        }
    }

    // MARK: - 暂停 / 恢复

    func pauseTravel() {
        guard let travel, !isPausing else {
            appLog("[Travel] ⚠️ pauseTravel skipped (isPausing=\(isPausing), hasTravel=\(travel != nil))")
            return
        }
        isPausing = true
        appLog("[Travel] ⏸ calling pause")
        Task {
            defer { isPausing = false }
            do {
                let result = try await sdkCall { try await travel.pause() }
                appLog("[Travel] ✅ pause ok — status: \(result.status)")
            } catch {
                appLog("[Travel] ❌ pause failed: \(error)")
            }
        }
    }

    func resumeTravel() {
        guard let travel, !isResuming else {
            appLog("[Travel] ⚠️ resumeTravel skipped (isResuming=\(isResuming), hasTravel=\(travel != nil))")
            return
        }
        isResuming = true
        appLog("[Travel] ▶️ calling resume")
        Task {
            defer { isResuming = false }
            do {
                let result = try await sdkCall { try await travel.resume() }
                appLog("[Travel] ✅ resume ok — status: \(result.status)")
            } catch {
                appLog("[Travel] ❌ resume failed: \(error)")
            }
        }
    }

    // MARK: - 回溯

    /// 回退 10 秒（Story 模式暂停态）。
    /// 以客户端累计运行时长为基准，向服务端请求回退到 elapsedSec - 10 秒处。
    /// Server 返回的 resumedAtSec 是实际恢复位置，用于矫正客户端计时器。
    func rewindBack10s() {
        guard let travel, canRewind else { return }
        let elapsedSec = countdown.elapsedSec
        let targetSec = TimeInterval(elapsedSec - 10)
        appLog("[Travel] ⏪ rewind elapsed=\(elapsedSec)s → target=\(Int(targetSec))s")
        isRewinding = true
        Task {
            do {
                let result = try await sdkCall { try await travel.rewind(toSec: targetSec) }
                let serverSec = Int(result.resumedAtSec)
                appLog("[Travel] ✅ rewind ok — resumedAtSec: \(serverSec)s (was \(elapsedSec)s)")
                // 用 Server 返回的实际进度秒数矫正本地计时器基准，避免客户端/服务端偏差累积；
                // 此时仍处于 paused（modeActiveStartDate 已是 nil），只需矫正累计值，
                // 下次 .running 到来时会以此为基础重新起算挂钟起点。
                modeAccumulatedActiveSec = TimeInterval(serverSec)
                countdown.elapsedSec = serverSec
                countdown.modeCountdown = max(0, modeCountdownMax - serverSec)
            } catch {
                appLog("[Travel] ❌ rewind failed: \(error)")
                isRewinding = false
            }
        }
    }

    // MARK: - 实时互动

    /// 冒险模式：发送操控指令（fire-and-forget，错误经事件流透出）。
    func sendCommand(_ command: OysterAdventureCommand) {
        travel?.sendCommand(command)
    }

    /// 导演模式：发送文本指令。
    func sendInstruct(_ content: String) {
        guard let travel else { return }
        appLog("[Prompt] sending — content: \(content)")
        Task {
            do {
                let result = try await sdkCall { try await travel.sendInstruct(content: content) }
                appLog("[Prompt] ✅ ok — accepted: \(result.accepted)")
            } catch {
                appLog("[Prompt] ❌ failed: \(error)")
            }
        }
    }

    // MARK: - 更新剧本（scriptlist 世界，与文本指令互斥）

    /// 用一份新剧本整体替换当前正在播放的剧本。世界资产类接口（走业务服务转发），
    /// 与文本指令 `sendInstruct` 互斥，仅 `isScriptListMode` 世界可调用。
    /// `isUpdatingScript` 为 true 期间面板保持展示加载态、发送按钮 disabled，天然挡掉重复发送；
    /// 请求结束（无论成败）后回到 false，由 `TravelView` 据此自动收起面板，再用 toast 展示结果——
    /// 状态与这次 HTTP 请求的生命周期一一对应，下面的 guard 只是兜底。
    func updateScriptList(_ scriptList: JSONValue) {
        guard let travelId, let apiClient, !isUpdatingScript else {
            appLog("[Script] ⚠️ updateScriptList skipped (hasTravelId=\(travelId != nil), hasClient=\(apiClient != nil), isUpdating=\(isUpdatingScript))")
            return
        }
        isUpdatingScript = true
        appLog("[Script] 📝 updateScript sending — travelId: \(travelId)")
        Task {
            defer { isUpdatingScript = false }
            do {
                let body = UpdateScriptRequest(encryptedTravelId: travelId, scriptList: scriptList)
                let result = try await apiClient.updateScript(body)
                appLog("[Script] ✅ updateScript ok — accepted: \(result.accepted)")
                showToast(result.accepted ? "剧本已更新" : "剧本更新未受理")
            } catch let err as APIError {
                appLog("[Script] ❌ updateScript failed: \(err)")
                showToast("剧本更新失败：\(err.localizedDescription)")
            } catch {
                appLog("[Script] ❌ updateScript unexpected error: \(error)")
                showToast("剧本更新失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 退出（所有路径统一入口）

    /// 用户主动关闭或会话自然结束：立即关闭视图。幂等。
    func endAndDismiss() {
        guard !shouldDismiss else { return }
        shouldDismiss = true
        stopSession()
    }

    /// 异常终止：停止会话，保留视图展示错误信息，2 秒后自动收起（用户也可点"关闭"立即退出）。
    private func terminateWithError(_ message: String) {
        stopSession()
        if errorMessage == nil { errorMessage = message }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.endAndDismiss()
        }
    }

    /// 内部清理：结束 SDK 会话并停止订阅 / 计时。
    private func stopSession() {
        stopTimer()
        eventTask?.cancel()
        eventTask = nil
        showVideo = false
        let session = travel
        travel = nil
        Task {
            do {
                if let data = try await sdkCall({ try await session?.end() }) {
                    appLog("[Travel] 🛑 end ok — status: \(data.status) duration: \(Int(data.duration))s")
                }
            } catch {
                appLog("[Travel] ⚠️ end failed: \(error)")
            }
        }
    }

    // MARK: - 倒计时内部

    private func startTimer() {
        countdown.timerStarted = true
        let now = Date()
        totalStartDate = now
        modeActiveStartDate = now
        modeAccumulatedActiveSec = 0
        countdown.modeCountdown = modeCountdownMax
        countdown.totalCountdown = 300
        countdown.elapsedSec = 0
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
        countdownActive = false
        modeActiveStartDate = nil
    }

    /// 暂停/恢复切换时冻结或续算「运行中」累计时长。
    /// 之所以不再用"每次 tick 减 1"，是因为 `Task.sleep(1s)` 每轮循环都有调度开销，
    /// 60 轮下来会比真实挂钟时间多出 1~2s——UI 倒计时看起来比服务端实际结束时刻慢。
    /// 改成每次都用挂钟时间重算剩余值，就不会有累积误差。
    private func freezeActiveAccumulation() {
        if let modeActiveStartDate {
            modeAccumulatedActiveSec += Date().timeIntervalSince(modeActiveStartDate)
        }
        self.modeActiveStartDate = nil
    }

    private func tick() {
        guard let totalStartDate else { return }
        // 总时长：从 start 起点的真实挂钟耗时算，不受暂停影响。
        let totalElapsed = Int(Date().timeIntervalSince(totalStartDate))
        countdown.totalCountdown = max(0, 300 - totalElapsed)
        // 模式倒计时 & 已运行时长：只在非暂停态累加，用挂钟时间重算，避免 tick 计数漂移。
        if countdownActive, let modeActiveStartDate {
            let activeElapsed = modeAccumulatedActiveSec + Date().timeIntervalSince(modeActiveStartDate)
            countdown.elapsedSec = Int(activeElapsed)
            countdown.modeCountdown = max(0, modeCountdownMax - countdown.elapsedSec)
        }
        // 每秒打一行，方便跟引擎/statusSync 日志对时间戳，排查结束时序问题时很有用，保留。
        appLog("[Travel] ⏱ tick total=\(countdown.totalCountdown)s mode=\(countdown.modeCountdown)s")
        if countdown.totalCountdown == 0 {
            endAndDismiss()
            return
        }
    }

    // MARK: - SDK 事件处理

    private func subscribeEvents(_ travel: OysterTravel) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in travel.events {
                guard let self else { return }
                switch event {
                case .statusChanged(let value):
                    self.handleStatusChange(value)
                case .error(let error):
                    self.handleSDKError(error)
                @unknown default:
                    break
                }
            }
        }
    }

    private func handleStatusChange(_ value: OysterTravelStatus) {
        // SDK AsyncSequence 存在同一状态重复 yield 的问题，防御性去重，已向 SDK 侧反馈
        guard value != status else { return }
        status = value
        appLog("[Travel] 🔄 status → \(value)")
        switch value {
        case .idle, .prepare:
            break
        case .running:
            if !countdown.timerStarted {
                startTimer()
            } else if !countdownActive {
                // 从暂停恢复：重新起算「运行中」区间的挂钟起点，之前累计的时长已在
                // freezeActiveAccumulation() 里存进 modeAccumulatedActiveSec，不会丢。
                modeActiveStartDate = Date()
            }
            countdownActive = true
            isRewinding = false
        case .pausing:
            freezeActiveAccumulation()
            countdownActive = false
        case .paused:
            freezeActiveAccumulation()
            countdownActive = false
        case .ended:
            if isRewinding {
                // SDK 回溯时内部走离频道→重连过渡，会短暂推 .ended；
                // 等待最多 5s，若 .running 恢复则 isRewinding 会被清除，直接取消等待。
                appLog("[Travel] ⚠️ ended during rewind, waiting for recovery…")
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard let self, self.isRewinding else { return }
                    appLog("[Travel] ⛔️ rewind recovery timeout, ending")
                    self.isRewinding = false
                    self.endAndDismiss()
                }
            } else {
                appLog("[Travel] ⛔️ ended, auto-dismiss")
                endAndDismiss()
            }
        case .failed:
            if pendingTokenRefresh {
                // Token 刷新期间的 .failed：不展示全屏错误 overlay，静默退出。
                pendingTokenRefresh = false
                appLog("[Travel] ⚠️ failed during token refresh, dismiss without error overlay")
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self?.endAndDismiss()
                }
            } else {
                // 普通致命错误：保留全屏 overlay，需手动关闭。
                terminateWithError(errorMessage ?? "游玩出现错误，请重试")
            }
        @unknown default:
            break
        }
    }

    private func handleSDKError(_ error: OysterSDKError) {
        // Token 缺失（101001）或 Token 失效/过期（101002）：可恢复的非致命错误。
        // 不设 errorMessage（避免触发全屏 overlay），改用 toast + 后台刷新。
        if error.kind == .tokenMissing || error.kind == .tokenInvalid {
            guard !pendingTokenRefresh else { return }   // 防止重复触发
            pendingTokenRefresh = true
            let originalDesc = sdkErrorDescription(error)
            appLog("[Travel] 🔑 token error (\(error.code)), refreshing token…")
            Task { [weak self] in
                guard let self else { return }
                guard let tm = tokenManager else {
                    appLog("[Travel] ⚠️ tokenManager not available, skip refresh")
                    await MainActor.run { pendingTokenRefresh = false }
                    return
                }
                do {
                    _ = try await tm.invalidateAndRefresh()
                    appLog("[Travel] ✅ token refreshed & injected to SDK")
                    await MainActor.run { pendingTokenRefresh = false }
                } catch {
                    appLog("[Travel] ❌ token refresh failed: \(error)")
                    await MainActor.run {
                        pendingTokenRefresh = false
                        if errorMessage == nil {
                            errorMessage = originalDesc + "\nToken 刷新失败：\(error.localizedDescription)"
                        }
                    }
                }
            }
            return
        }

        // 其他错误：填充错误信息，等待 SDK 通过 status → .failed 触发终止。
        if errorMessage == nil { errorMessage = sdkErrorDescription(error) }
    }

    /// 展示非阻断性 toast，3 秒后自动清除。
    private func showToast(_ message: String) {
        toastMessage = message
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.toastMessage = nil
        }
    }

    /// 把 OysterSDKError 转成可读的多行文本，包含 code、kind 名称、内部 OysterError 详情。
    private func sdkErrorDescription(_ error: OysterSDKError) -> String {
        let kindName: String
        switch error.kind {
        case .notInitialized:         kindName = "SDK 未初始化"
        case .tokenMissing:           kindName = "Token 缺失"
        case .tokenInvalid:           kindName = "Token 无效或已过期"
        case .noActiveTravel:         kindName = "无活跃会话"
        case .invalidState:           kindName = "状态不允许该操作"
        case .sendCommandInDirecting: kindName = "模式不匹配"
        case .concurrentTravel:       kindName = "并发会话冲突"
        case .realtimeConnectFailed:  kindName = "RTC 连接失败"
        case .realtimeJoinTimeout:    kindName = "RTC 入会超时"
        case .firstFrameTimeout:      kindName = "等待首帧超时"
        case .channelNotReady:        kindName = "DataChannel 未就绪"
        case .callbackTimeout:        kindName = "请求超时"
        case .streamAutoEnd:          kindName = "无推流自动结束"
        case .localNetwork:           kindName = "网络错误"
        case .responseDecodeFailed:   kindName = "响应解析失败"
        case .proxyOrUnrecognized:    kindName = "网关/代理错误"
        case .featureGateDisabled:    kindName = "SDK 功能已被远程禁用"
        case .server(let code):       kindName = "服务端错误 \(code)"
        case .unknown(let code):      kindName = "未知错误 \(code)"
        }
        var lines = ["\(kindName)（code: \(error.code)）"]
        if let inner = error.raw as? OysterError {
            if !inner.message.isEmpty { lines.append(inner.message) }
            if let reqId = inner.requestId { lines.append("request_id: \(reqId)") }
        } else if let rawStr = error.raw as? String, !rawStr.isEmpty {
            lines.append(rawStr)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 工具

    /// 将 start() 返回的 mode 原始值标准化为 "wander" / "directing"。
    private func normalizedMode(_ raw: String) -> String {
        switch raw.lowercased() {
        case "1", "wander", "adventure", "vendor": return "wander"
        case "2", "directing": return "directing"
        default: return raw
        }
    }
}
