import Foundation
import HappyOysterSDK

/// Countdown convergence rule: different world types interpret the "primary timeline" accumulated seconds differently.
/// The mode returned by `start()` decides which rule is loaded; after that, driving logic such as `tick()` / `rewind(toSec:)`
/// doesn't care which kind of world it is — it only deals with this one enum.
/// - wander: `remaining`; the primary timeline is a "remaining time countdown" (counts from maxSec down to 0).
/// - story: `elapsed`; the primary timeline is a "story time count-up" (counts from 0 up to maxSec, shown as `mm:ss/mm:ss`;
///   exceeding maxSec does not force an end — when to end is left to the total-duration countdown below / the server).
enum TravelCountdownRule {
    case remaining(maxSec: Int)
    case elapsed(maxSec: Int)
}

/// `mm:ss` formatting: shared by the wander primary timeline and ② total duration; the place in `TravelView.swift` that shows
/// ② total duration also reuses this implementation to avoid the two drifting apart. It lives here (rather than being `private`)
/// because it is part of the "countdown convergence" logic and is easier to maintain next to `TravelCountdownRule`.
func formatSeconds(_ sec: Int) -> String {
    let m = sec / 60
    let s = sec % 60
    return String(format: "%d:%02d", m, s)
}

/// Countdown state is split into this child `ObservableObject` instead of being `@Published` properties of `TravelViewModel`.
/// Combine's `objectWillChange` only broadcasts to the owner when "an @Published property it directly holds changes";
/// changes inside nested objects are not forwarded automatically — `TravelViewModel` ticks once per second to update the fields here,
/// which does not trigger `TravelViewModel.objectWillChange`, so `TravelView` (which holds `@StateObject var vm`)
/// doesn't redraw its whole tree every second (including the countdown-unrelated "Update Script" overlay).
/// Views that need to refresh with each tick should `@ObservedObject` this child object directly, not go through `TravelViewModel`.
///
/// Display logic has already been converged inside `TravelViewModel` per `TravelCountdownRule`: only the precomputed
/// `primaryText` / `primaryIsWarning` are exposed here; the View layer does not need to (and should not) check `isWanderMode`
/// to decide which format to show.
@available(iOS 15.0, *)
@MainActor
final class TravelCountdownModel: ObservableObject {
    /// ① Primary timeline display text: remaining time "mm:ss" for wander; story time "mm:ss/mm:ss" for story.
    /// Always shown (regardless of pause state); the exact format is decided by `TravelCountdownRule`.
    @Published fileprivate(set) var primaryText: String = "0:00"
    /// ① Whether the primary timeline is in warning state (wander: remaining ≤10s; story: count-up has no warning semantics, always false).
    @Published fileprivate(set) var primaryIsWarning: Bool = false
    /// ② Overall in-room time countdown (360s): unaffected by pause, never calibrated by any API,
    /// automatically ends play when it hits zero; only shown while paused. Shared by wander / story, independent of the primary timeline rule.
    @Published fileprivate(set) var totalCountdown: Int = 360
    /// Accumulated "running" seconds of the primary timeline (stops counting while paused): in wander it is the consumed play quota,
    /// not calibrated by server APIs such as rewind; in story it is the story time position, calibrated by the `resumedAtSec`
    /// returned from the rewind API. Currently only story mode uses it for the `canRewind` threshold and rewind target computation
    /// (wander does not support rewind), but both modes compute it with the same accumulator.
    @Published fileprivate(set) var elapsedSec: Int = 0
    /// Whether the timer has started (set to true after first entering running; controls UI visibility).
    @Published fileprivate(set) var timerStarted: Bool = false
}

/// ViewModel for a play session: creates an `OysterTravel` session via `HappyOysterEngine.createTravel(ticket:)`,
/// subscribes to its `events` to drive status and errors; pause/resume/end/real-time interaction all go to that session instance (no longer passing encryptedTravelId).
/// All exit paths go through the same cleanup chain via endAndDismiss().
@available(iOS 15.0, *)
@MainActor
final class TravelViewModel: ObservableObject {

    /// Public session status (idle → prepare → running ⇄ paused → ended/failed).
    @Published private(set) var status: OysterTravelStatus = .idle
    @Published var isStarting = false
    @Published var errorMessage: String?
    @Published var shouldDismiss = false

    /// SDK session handle: assigned after createTravel; used by the video view (OysterVideoView) and real-time interaction.
    @Published private(set) var travel: OysterTravel?
    /// Set to true after start() succeeds; OysterVideoView is mounted only when this is true (ensures the engine is ready and renderView has a real size).
    @Published private(set) var showVideo = false

    // MARK: - Countdown

    /// Countdown state (see the header comment of `TravelCountdownModel`): places on the view side that need to refresh every tick
    /// should `@ObservedObject` this child object directly, not go through this class, to avoid triggering this class's objectWillChange.
    let countdown = TravelCountdownModel()

    /// Whether we are in the "reconnecting after play has started" state. The public status unifies connecting/reconnecting into prepare,
    /// so "timer started + back to prepare" is used to approximate reconnecting.
    var isReconnecting: Bool { countdown.timerStarted && status == .prepare }

    /// encryptedTravelId of this play (assigned after start succeeds; used only for logging).
    private(set) var travelId: String?
    /// World mode returned by start() (parsed from the SDK's raw mode string); nil means not started yet.
    /// `ServerWorldMode` is the single authoritative representation of "world mode" in the Demo, the same type as the creation page.
    @Published private(set) var mode: ServerWorldMode?
    /// Whether we're in wander mode (from start()'s return value, more reliable than the list's mode).
    var isWanderMode: Bool { mode == .wander }
    /// Aspect ratio returned by start() (`9:16` / `16:9`); only acting worlds have it; used to decide playback orientation.
    @Published private(set) var aspectRatio: String?
    /// World creation method ("simple" | "scriptlist"). The SDK's enter-travel doesn't include this field (SDK is not changed);
    /// after entering the session successfully we call `GET /server-api/worlds/detail` separately to get it; during play, scriptlist worlds use
    /// "Update Script" instead, mutually exclusive with text instructions. `nil` means no result yet — the bottom instruction/script entry is hidden meanwhile,
    /// to avoid the flicker of first showing the text instruction field as "simple" and then switching to the "Update Script" button when the result arrives.
    @Published private(set) var creationModel: String?
    /// Whether `creationModel` is determined (set to non-nil after success or fallback on failure; see `fetchCreationModel`).
    var isCreationModelResolved: Bool { creationModel != nil }
    /// Whether this is a scriptlist world (hides text instruction input during play, uses the "Update Script" entry instead).
    /// Compared after case normalization — consistent with how `ServerWorldMode.init(sdkRawValue:)` handles the `mode` field,
    /// so a differently-cased value from the server (e.g. "Scriptlist") isn't misjudged as a simple world.
    var isScriptListMode: Bool { creationModel?.lowercased() == "scriptlist" }
    /// Update-script request in flight: after sending, the panel stays shown (with a loading state) until this field goes back to false,
    /// at which point `TravelView` auto-dismisses the panel and shows a toast; state maps one-to-one with the request lifecycle and naturally prevents duplicate sends.
    @Published private(set) var isUpdatingScript = false
    /// travelVersion returned by start(); pause/rewind are only supported by "storyV2".
    @Published private(set) var travelVersion: String?
    /// Whether pause and resume are supported: both story (directing) and acting support it, wander does not
    /// (the SDK-side gate is `pausableTravelVersions`; this only controls UI display).
    var supportsPauseResume: Bool { mode == .story || mode == .acting }
    /// Whether rewind is allowed: **only** story mode + paused + story time over 1s (at least one valid rewind point) + no rewind in flight.
    /// Neither wander nor acting supports rewind (for acting's restriction see SDK `rewindableTravelVersions`),
    /// so the entry must be hidden, not just rely on server rejection.
    /// Must be triggered in paused state, to avoid sending unexpected rewind commands to the server while connecting / running.
    var canRewind: Bool { mode == .story && status == .paused && countdown.elapsedSec > 1 && !isRewinding }
    /// Rewind request in flight (prevents repeated taps).
    @Published private(set) var isRewinding = false
    /// Number of in-flight pause / resume calls: the pause and resume buttons are no longer grayed out or hidden by state, so multiple
    /// calls may be in flight at the same time (the extra ones get rejected by the SDK's state gate); hence a counter instead of a boolean.
    @Published private(set) var pendingPauseCount = 0
    @Published private(set) var pendingResumeCount = 0
    /// Pause confirmation in flight (used by the bottom "Pausing…").
    var isPausing: Bool { pendingPauseCount > 0 }
    /// Resume confirmation in flight.
    var isResuming: Bool { pendingResumeCount > 0 }
    /// Non-blocking toast message (auto-cleared after 3s).
    @Published private(set) var toastMessage: String?

    /// Primary timeline rule: which one is loaded is decided by the mode returned by start() (see `TravelCountdownRule`);
    /// subsequent tick/rewind only deal with this rule and no longer each check "is it wander".
    private var countdownRule: TravelCountdownRule = .remaining(maxSec: 60)
    private var countdownActive: Bool = false   // false while paused
    private var timerTask: Task<Void, Never>?
    /// Wall-clock baseline for the total-duration countdown (unaffected by pause; set only once per start).
    private var totalStartDate: Date?
    /// Wall-clock start of the current "running" interval; set to nil on pause, reset to `Date()` on resume.
    private var primaryActiveStartDate: Date?
    /// Frozen (pre-pause) accumulated primary timeline running duration: in wander it's the consumed play quota (unaffected by rewind,
    /// since wander doesn't support rewind); in story it's the story time position (calibrated by rewind results).
    /// Combined with `primaryActiveStartDate` to compute `countdown.primaryText` / `countdown.elapsedSec`.
    private var primaryAccumulatedActiveSec: TimeInterval = 0
    private var eventTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    /// Injected TokenManager, used to proactively refresh and re-inject into the SDK when the token becomes invalid.
    private weak var tokenManager: TokenManager?
    /// Injected business API client, used by "Update Script" (a world-asset API, forwarded via the business service).
    private weak var apiClient: APIClient?
    /// Mode of the world being played. Since models are split by mode, `/server-api` requests must carry it so the server can pick the gateway route
    /// (see `APIClient.modeHeaderField` for how it's passed). Passed in via `start(mode:)` and retained
    /// for reuse by later requests during play such as update-script.
    private var worldMode: ServerWorldMode = .wander

    /// Token refresh in progress: suppresses the full-screen error overlay for .failed; uses a toast + soft dismiss instead.
    private var pendingTokenRefresh = false

    // MARK: - Start

    func start(
        encryptedWorldId: String,
        mode worldMode: ServerWorldMode,
        maxExperienceTimeSec: Int,
        client: APIClient,
        tokenManager: TokenManager?
    ) async {
        guard !isStarting, travel == nil else {
            appLog("[Travel] ⚠️ start() rejected (isStarting=\(isStarting), hasTravel=\(travel != nil))")
            return
        }

        // Step 0: when the SDK is not ready (initialize failed because apiHost or model is empty/invalid), block synchronously with zero network cost.
        // One step earlier than waiting for Step 2 createTravel to throw 100001, or even for Step 3 to reach the gateway and report a 106001 network error
        // — avoids mixing "gateway misconfigured" with "real network/RTC failure", which would mislead troubleshooting.
        guard HappyOysterEngine.shared.isReady else {
            appLog("[Travel] ⚠️ start() rejected: SDK not ready (apiHost/model not configured or invalid)")
            errorMessage = String(localized: "SDK not ready: please configure a valid Bailian APIHost and model in Settings first")
            return
        }

        self.tokenManager = tokenManager
        self.apiClient = client
        self.worldMode = worldMode
        isStarting = true
        defer { isStarting = false }

        appLog("[Travel] ▶ start — worldId: \(encryptedWorldId), mode: \(worldMode.badgeLabel)")

        // Step 1: exchange a one-time travel credential from the server
        let credential: TravelCredentialResponse
        do {
            credential = try await client.travelCredential(encryptedWorldId: encryptedWorldId, mode: worldMode)
            appLog("[Travel] ✅ credential ok — ticket: \(credential.ticket.prefix(8))… expiresIn: \(credential.expiresIn)s")
        } catch {
            errorMessage = String(localized: "Failed to get credential: \(error.localizedDescription)")
            return
        }

        // Step 2: create the session and subscribe to events (subscribe before start so no events are missed)
        let session: OysterTravel
        do {
            session = try HappyOysterEngine.shared.createTravel(ticket: credential.ticket)
        } catch let err as OysterSDKError {
            errorMessage = String(localized: "Failed to create session: \(sdkErrorDescription(err))")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            endAndDismiss()
            return
        } catch {
            errorMessage = String(localized: "Failed to create session: \(error.localizedDescription)")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            endAndDismiss()
            return
        }
        travel = session
        subscribeEvents(session)

        // Step 3: start the tour (internally exchanges the ticket for a travel + joins RTC)
        // On token expiry, automatically refresh and retry once.
        do {
            let data = try await sdkCall {
                try await session.start(maxExperienceTimeSec: maxExperienceTimeSec)
            }
            travelId = data.encryptedTravelId
            mode = ServerWorldMode(sdkRawValue: data.mode.rawValue)
            aspectRatio = data.aspectRatio
            travelVersion = data.version
            // maxExperienceTimeSec only applies to wander; story and acting both ignore it and use a 180s timer display.
            countdownRule = mode == .wander
                ? .remaining(maxSec: maxExperienceTimeSec)
                : .elapsed(maxSec: 180)
            appLog("[Travel] 🚀 startTravel ok — travelId: \(data.encryptedTravelId) mode: \(mode?.badgeLabel ?? data.mode.rawValue) version: \(data.version) aspectRatio: \(data.aspectRatio ?? "-")")
            // Mount the video view only after start() succeeds: ensures the engine has bound renderView,
            // avoiding OysterVideoView being mounted into the full-screen layout with engine=nil, which would bind setRemoteViewConfig to a 0×0 view.
            showVideo = true
            // The SDK doesn't carry creationModel; query world detail once separately to decide the experience page UI (scriptlist worlds use "Update Script");
            // failure doesn't affect the main flow and silently keeps the default "simple".
            fetchCreationModel(encryptedWorldId: encryptedWorldId, mode: worldMode, client: client)
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

    /// Separately query world detail to get `creationModel` (`GET /server-api/worlds/detail`, API doc §3.1.1).
    /// The SDK's enter-travel response doesn't carry this field; the business layer queries it itself, with no coupling to the SDK.
    private func fetchCreationModel(encryptedWorldId: String, mode: ServerWorldMode, client: APIClient) {
        Task {
            do {
                let detail = try await client.worldDetail(encryptedWorldId: encryptedWorldId, mode: mode)
                let value = detail.creationModel?.isEmpty == false ? detail.creationModel! : "simple"
                creationModel = value
                appLog("[Travel] ℹ️ worldDetail ok — creationModel: \(value)")
            } catch {
                // The failure fallback must still assign explicitly (instead of leaving nil): otherwise the bottom instruction/script entry would never show.
                creationModel = "simple"
                appLog("[Travel] ⚠️ worldDetail failed (fallback creationModel=simple): \(error)")
            }
        }
    }

    /// Generic SDK call wrapper: catches token errors (101001/101002), refreshes and retries once.
    /// Every SDK method that can throw OysterSDKError goes through this wrapper, centralizing token-expiry handling instead of patching each call site.
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

    // MARK: - Pause / Resume

    /// No local deduplication: every tap really hits the SDK; duplicate / mistimed calls are rejected by the SDK's state gate,
    /// and the results are logged as-is — that's exactly what the demo wants to observe.
    func pauseTravel() {
        guard let travel else {
            appLog("[Travel] ⚠️ pauseTravel skipped (no travel)")
            return
        }
        // `pendingPauseCount` covers the whole confirmation process: the SDK's `pause()` only returns once the status actually lands on paused
        // (there's no public "pausing" status; `status` remains .running meanwhile), and the bottom "Pausing…" relies on it.
        // A counter rather than a boolean: when a concurrent second tap is rejected by the SDK, it must not clear the flag of the first one still in flight.
        pendingPauseCount += 1
        appLog("[Travel] ⏸ calling pause")
        Task {
            defer { pendingPauseCount -= 1 }
            do {
                let result = try await sdkCall { try await travel.pause() }
                appLog("[Travel] ✅ pause confirmed — status: \(result.status)")
            } catch {
                appLog("[Travel] ❌ pause failed: \(error)")
            }
        }
    }

    /// Same as `pauseTravel()`: no local deduplication; left to the SDK's state gate.
    func resumeTravel() {
        guard let travel else {
            appLog("[Travel] ⚠️ resumeTravel skipped (no travel)")
            return
        }
        pendingResumeCount += 1
        appLog("[Travel] ▶️ calling resume")
        Task {
            defer { pendingResumeCount -= 1 }
            do {
                let result = try await sdkCall { try await travel.resume() }
                appLog("[Travel] ✅ resume ok — status: \(result.status)")
            } catch {
                appLog("[Travel] ❌ resume failed: \(error)")
            }
        }
    }

    // MARK: - Rewind

    /// Whether the rewind target is valid: the rewind API means "go back to second N of the whole story", can only go backwards,
    /// and the SDK requires it to be no less than 1, so N must fall within `[1, current story time)`.
    func isValidRewindTarget(_ targetSec: Int) -> Bool {
        targetSec >= 1 && targetSec < countdown.elapsedSec
    }

    /// Go back to second `targetSec` of the story (Story mode, paused state).
    /// `targetSec` is an absolute position on the whole story timeline (same coordinate system as `countdown.elapsedSec`),
    /// not an offset relative to the current position. The resumedAtSec returned by the server is the actual resume position,
    /// used directly to calibrate the primary timeline accumulator — rewind is only available in story (`countdownRule == .elapsed`),
    /// so wander's play quota consumption is unaffected by this path.
    func rewind(toSec targetSec: Int) {
        guard let travel, canRewind, isValidRewindTarget(targetSec) else { return }
        let elapsedSec = countdown.elapsedSec
        appLog("[Travel] ⏪ rewind elapsed=\(elapsedSec)s → target=\(targetSec)s")
        isRewinding = true
        Task {
            do {
                let result = try await sdkCall { try await travel.rewind(toSec: TimeInterval(targetSec)) }
                let serverSec = Int(result.resumedAtSec)
                appLog("[Travel] ✅ rewind ok — resumedAtSec: \(serverSec)s (was \(elapsedSec)s)")
                // Calibrate the primary timeline accumulator: we're still paused (primaryActiveStartDate is already nil),
                // so only the accumulated value needs correcting; when the next .running arrives, the wall-clock start is recomputed from it.
                // Rewind is only available in story mode (canRewind already excludes isWanderMode), so changing the
                // accumulator here is equivalent to calibrating story time only and doesn't affect wander's play quota logic.
                primaryAccumulatedActiveSec = TimeInterval(serverSec)
                applyPrimaryDisplay(activeSec: primaryAccumulatedActiveSec)
            } catch {
                appLog("[Travel] ❌ rewind failed: \(error)")
                isRewinding = false
            }
        }
    }

    // MARK: - Real-time interaction

    /// Adventure mode: send a control command (fire-and-forget; errors surface via the event stream).
    /// When keys are released back to center (all three fields `.none`), additionally call `flushCommands()` so the idle command
    /// isn't delayed by the SDK-side trailing throttle until the next sampling period.
    func sendCommand(_ command: OysterAdventureCommand) {
        travel?.sendCommand(command)
        if command.translation == .none, command.rotation == .none, command.interaction == .none {
            travel?.flushCommands()
        }
    }

    /// Directing mode: send a text instruction.
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

    // MARK: - Update script (scriptlist worlds, mutually exclusive with text instructions)

    /// Replace the currently playing script wholesale with a new one. A world-asset API (forwarded via the business service),
    /// mutually exclusive with text instruction `sendInstruct`; only callable for `isScriptListMode` worlds.
    /// While `isUpdatingScript` is true the panel stays in a loading state and the send button is disabled, naturally blocking duplicate sends;
    /// once the request ends (success or failure) it goes back to false, and `TravelView` auto-dismisses the panel accordingly, then shows the result via toast —
    /// state maps one-to-one with the lifecycle of this HTTP request; the guard below is only a safety net.
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
                let result = try await apiClient.updateScript(body, mode: worldMode)
                appLog("[Script] ✅ updateScript ok — accepted: \(result.accepted)")
                showToast(result.accepted ? String(localized: "Script updated") : String(localized: "Script update not accepted"))
            } catch let err as APIError {
                appLog("[Script] ❌ updateScript failed: \(err)")
                showToast(String(localized: "Script update failed: \(err.localizedDescription)"))
            } catch {
                appLog("[Script] ❌ updateScript unexpected error: \(error)")
                showToast(String(localized: "Script update failed: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Exit (single entry point for all paths)

    /// User closes actively or the session ends naturally: close the view immediately. Idempotent.
    func endAndDismiss() {
        guard !shouldDismiss else { return }
        shouldDismiss = true
        stopSession()
    }

    /// Abnormal termination: stop the session, keep the view to show the error, auto-dismiss after 2 seconds (the user can also tap "Close" to exit immediately).
    private func terminateWithError(_ message: String) {
        stopSession()
        if errorMessage == nil { errorMessage = message }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.endAndDismiss()
        }
    }

    /// Internal cleanup: end the SDK session and stop subscriptions / timers.
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

    // MARK: - Countdown internals

    private func startTimer() {
        countdown.timerStarted = true
        let now = Date()
        totalStartDate = now
        primaryActiveStartDate = now
        primaryAccumulatedActiveSec = 0
        countdown.totalCountdown = 360
        applyPrimaryDisplay(activeSec: 0)
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
        primaryActiveStartDate = nil
    }

    /// Freeze or resume the accumulated "running" duration when toggling pause/resume.
    /// We no longer "subtract 1 per tick" because each `Task.sleep(1s)` loop iteration has scheduling overhead;
    /// over 60 iterations it drifts 1~2s beyond real wall-clock time — the UI countdown appears slower than the server's actual end time.
    /// Recomputing the remaining value from wall-clock time every time avoids accumulated error.
    private func freezeActiveAccumulation() {
        if let primaryActiveStartDate {
            primaryAccumulatedActiveSec += Date().timeIntervalSince(primaryActiveStartDate)
        }
        self.primaryActiveStartDate = nil
        applyPrimaryDisplay(activeSec: primaryAccumulatedActiveSec)
    }

    /// Interpret the accumulated "running" seconds as display text per `countdownRule` — the convergence point: the wander/story
    /// format difference branches only here; `tick()` / `rewind(toSec:)` / `startTimer()` only compute
    /// `activeSec` and leave how it's displayed to this method.
    private func applyPrimaryDisplay(activeSec: TimeInterval) {
        let activeInt = Int(activeSec)
        countdown.elapsedSec = activeInt
        switch countdownRule {
        case .remaining(let maxSec):
            let remaining = max(0, maxSec - activeInt)
            countdown.primaryText = formatSeconds(remaining)
            countdown.primaryIsWarning = remaining <= 10
        case .elapsed(let maxSec):
            countdown.primaryText = "\(formatSeconds(activeInt))/\(formatSeconds(maxSec))"
            countdown.primaryIsWarning = false
        }
    }

    private func tick() {
        guard let totalStartDate else { return }
        // ② Overall in-room time: computed from real wall-clock time since start, unaffected by pause, not calibrated;
        // automatically ends play when it hits zero. Shared by wander / story.
        let totalElapsed = Int(Date().timeIntervalSince(totalStartDate))
        countdown.totalCountdown = max(0, 360 - totalElapsed)
        // ① Primary timeline: accumulates only while not paused, recomputed from wall-clock time to avoid drift; see `applyPrimaryDisplay` for display format.
        if countdownActive, let primaryActiveStartDate {
            let delta = Date().timeIntervalSince(primaryActiveStartDate)
            applyPrimaryDisplay(activeSec: primaryAccumulatedActiveSec + delta)
        }
        // Log one line per second to line up timestamps with engine/statusSync logs; very useful when debugging end-timing issues, so keep it.
        appLog("[Travel] ⏱ tick total=\(countdown.totalCountdown)s primary=\(countdown.primaryText)")
        if countdown.totalCountdown == 0 {
            endAndDismiss()
            return
        }
    }

    // MARK: - SDK event handling

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
        // The SDK AsyncSequence may yield the same status repeatedly; defensively dedupe (already reported to the SDK side)
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
                // Resuming from pause: restart the wall-clock start of the "running" interval; the previously accumulated duration was
                // stored into primaryAccumulatedActiveSec in freezeActiveAccumulation(), so nothing is lost.
                primaryActiveStartDate = Date()
            }
            countdownActive = true
            isRewinding = false
        case .paused:
            freezeActiveAccumulation()
            countdownActive = false
        case .ended:
            if isRewinding {
                // During rewind the SDK internally goes through a leave-channel → reconnect transition and briefly pushes .ended;
                // wait up to 5s; if .running recovers, isRewinding is cleared and the wait is effectively cancelled.
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
                // .failed during token refresh: don't show the full-screen error overlay; exit silently.
                pendingTokenRefresh = false
                appLog("[Travel] ⚠️ failed during token refresh, dismiss without error overlay")
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self?.endAndDismiss()
                }
            } else {
                // Ordinary fatal error: keep the full-screen overlay; must be closed manually.
                terminateWithError(errorMessage ?? String(localized: "An error occurred during play. Please try again."))
            }
        @unknown default:
            break
        }
    }

    private func handleSDKError(_ error: OysterSDKError) {
        // Token missing (101001) or token invalid/expired (101002): recoverable non-fatal errors.
        // Don't set errorMessage (to avoid triggering the full-screen overlay); use a toast + background refresh instead.
        if error.kind == .tokenMissing || error.kind == .tokenInvalid {
            guard !pendingTokenRefresh else { return }   // prevent duplicate triggering
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
                            errorMessage = originalDesc + "\n" + String(localized: "Token refresh failed: \(error.localizedDescription)")
                        }
                    }
                }
            }
            return
        }

        // Other errors: fill in the error message and wait for the SDK to trigger termination via status → .failed.
        if errorMessage == nil { errorMessage = sdkErrorDescription(error) }
    }

    /// Show a non-blocking toast, auto-cleared after 3 seconds.
    private func showToast(_ message: String) {
        toastMessage = message
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.toastMessage = nil
        }
    }

    /// Convert an OysterSDKError into readable multi-line text, including the code, kind name, and inner OysterError details.
    private func sdkErrorDescription(_ error: OysterSDKError) -> String {
        let kindName: String
        switch error.kind {
        case .notInitialized:         kindName = String(localized: "SDK not initialized")
        case .tokenMissing:           kindName = String(localized: "Token missing")
        case .tokenInvalid:           kindName = String(localized: "Token invalid or expired")
        case .noActiveTravel:         kindName = String(localized: "No active session")
        case .invalidState:           kindName = String(localized: "Operation not allowed in current state")
        case .sendCommandInDirecting: kindName = String(localized: "Mode mismatch")
        case .concurrentTravel:       kindName = String(localized: "Concurrent session conflict")
        case .realtimeConnectFailed:  kindName = String(localized: "RTC connection failed")
        case .realtimeJoinTimeout:    kindName = String(localized: "RTC join timed out")
        case .firstFrameTimeout:      kindName = String(localized: "Timed out waiting for first frame")
        case .channelNotReady:        kindName = String(localized: "DataChannel not ready")
        case .callbackTimeout:        kindName = String(localized: "Request timed out")
        case .streamAutoEnd:          kindName = String(localized: "Ended automatically due to no stream")
        case .localNetwork:           kindName = String(localized: "Network error")
        case .responseDecodeFailed:   kindName = String(localized: "Failed to parse response")
        case .proxyOrUnrecognized:    kindName = String(localized: "Gateway/proxy error")
        case .featureGateDisabled:    kindName = String(localized: "SDK feature disabled remotely")
        case .server(let code):       kindName = String(localized: "Server error \(code)")
        case .unknown(let code):      kindName = String(localized: "Unknown error \(code)")
        }
        var lines = [String(localized: "\(kindName) (code: \(error.code))")]
        if let inner = error.raw as? OysterError {
            if !inner.message.isEmpty { lines.append(inner.message) }
            if let reqId = inner.requestId { lines.append("request_id: \(reqId)") }
        } else if let rawStr = error.raw as? String, !rawStr.isEmpty {
            lines.append(rawStr)
        }
        return lines.joined(separator: "\n")
    }

}
