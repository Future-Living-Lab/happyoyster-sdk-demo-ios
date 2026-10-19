import SwiftUI
import HappyOysterSDK
import HappyOysterUI

/// Full-screen play view.
/// On entry, locks orientation by the world's aspect ratio (acting defaults to portrait 9:16, others landscape); unlocks on leave.
/// All exit paths call endTravel first, then close.
@available(iOS 15.0, *)
struct TravelView: View {

    let world: WorldListItem

    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var vm = TravelViewModel()
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isInstructFieldFocused: Bool
    /// Focus of the paused-state "Back to N s" field (the number pad has no return key; dismissed by tapping blank video area or tapping "Rewind").
    @FocusState private var isRewindFieldFocused: Bool
    /// Whether the scriptlist world's "Update Script" editor panel is shown (an overlay, independent of vm state; a purely local UI toggle).
    @State private var isScriptEditorPresented = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Video view: mounted only after start() succeeds, ensuring the SDK engine is ready and renderView has real bounds
            //
            // The tap-to-dismiss-keyboard gesture is attached to this layer (the video itself), not to the whole root ZStack:
            // it is a sibling in the ZStack of the HUD buttons / Story input field / Wander joysticks above, not their ancestor,
            // and hit testing goes by screen position — touches landing on the tappable areas of buttons/joysticks are caught first by those views layered on top
            // and never reach this layer; only taps on blank video area trigger keyboard dismissal.
            // The gesture itself is mounted unconditionally (not mounted/unmounted based on isInstructFieldFocused) — we previously hit a pitfall where conditional mounting
            // changed SwiftUI view identity and the TextField couldn't focus properly; a tap while unfocused merely sets
            // isInstructFieldFocused to false as a no-op with no side effects. In Wander mode the joystick area
            // sits on top of this layer, so the joystick's drag gesture is caught by the joystick first and touches never pass through here,
            // so it naturally doesn't compete with the joystick.
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
                isRewindFieldFocused = false
            }

            // Main HUD (top info bar + bottom control area)
            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            // Bottom-right reconnecting hint (doesn't cover the video): `@ObservedObject` `vm.countdown` separately,
            // not via `vm` itself, so this overlay isn't re-diffed along with `TravelView.body` on every tick.
            TravelReconnectingOverlay(countdown: vm.countdown, status: vm.status)

            if vm.isStarting { loadingOverlay }

            if let err = vm.errorMessage {
                errorOverlay(err)
            }

            // Non-blocking toast (token refresh progress, lightweight hints)
            if let toast = vm.toastMessage {
                toastBanner(toast)
            }
        }
        .statusBar(hidden: true)
        // scriptlist world "Update Script" editor panel: presented via fullScreenCover rather than an inline `if` branch in the ZStack.
        // `TravelView` holds `@StateObject var vm`; each per-second countdown tick of vm causes `TravelView.body`
        // to be fully re-evaluated; if the panel were inline in the same view tree, every re-evaluation would bring it into the same diff pass,
        // and on some OS versions this would also reset the inner `TextEditor`'s scroll position back to the top (i.e. "keeps refreshing back to the original position").
        // Content presented by fullScreenCover lives on its own hosting controller and is rebuilt only when its own state changes or on first presentation,
        // no longer passively re-diffed with the outer once-per-second redraw cadence, cutting off this redraw chain at the source;
        // the `.equatable()` wrapped around `TextEditor` earlier is kept as a fallback.
        .fullScreenCover(isPresented: $isScriptEditorPresented) {
            scriptUpdateEditorOverlay
        }
        .onAppear {
            // Pre-lock once using the list's mode first to avoid a "landscape then portrait" jump; once start() gets the real
            // aspectRatio, the onChange below corrects it (the server may deliver a 16:9 acting world).
            OrientationLock.shared.lock(to: world.mode == .acting ? .portrait : .landscape)
            Task {
                // happyoyster is split into different sub-models by mode; one initialize only serves worlds of one mode,
                // while this demo's world list comes from the app's own backend with all three modes mixed. So before entering, switch the SDK
                // to the model serving this world's mode (a no-op if already on the target model). It goes before vm.start
                // because switching models does cleanup + initialize, which rebuilds the engine state checked in vm.start's Step 0.
                await session.ensureModel(for: world.mode)
                await vm.start(
                    encryptedWorldId: world.encryptedWorldId,
                    mode: world.mode,
                    maxExperienceTimeSec: env.maxExperienceTimeSec,
                    client: env.apiClient,
                    tokenManager: session.tokenManager
                )
            }
        }
        .onDisappear {
            // Orientation is already restored before dismiss in onChange(shouldDismiss); this is a fallback
            OrientationLock.shared.lock(to: .unlocked)
        }
        // The aspectRatio returned by enter-travel is authoritative: decide orientation by the `width:height` ratio,
        // without enumerating values — if the server delivers 3:4 / 4:3 in the future, no change is needed here.
        .onChange(of: vm.aspectRatio, perform: { ratio in
            guard let ratio, let isPortrait = Self.isPortraitRatio(ratio) else { return }
            OrientationLock.shared.lock(to: isPortrait ? .portrait : .landscape)
        })
        .onChange(of: vm.shouldDismiss, perform: { should in
            if should {
                // Unlock orientation first, then dismiss, so the rotation animation fires before the exit animation
                OrientationLock.shared.lock(to: .unlocked)
                dismiss()
            }
        })
        // After the "Update Script" request ends (success or failure), isUpdatingScript goes back to false: auto-dismiss the panel,
        // and show the result with the underlying toast — the panel itself stays open with a loading state while the request is in flight.
        .onChange(of: vm.isUpdatingScript, perform: { isUpdating in
            if !isUpdating && isScriptEditorPresented {
                isScriptEditorPresented = false
            }
        })
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .top) {
            // Name + status pill + countdown row: `@ObservedObject` `vm.countdown` separately,
            // not via `vm` itself, so a per-second tick doesn't re-diff the whole `TravelView.body`.
            TravelTopBarLeading(countdown: vm.countdown, worldName: world.name, status: vm.status)
            Spacer()
            HStack(spacing: 8) {
                if vm.supportsPauseResume {
                    // Buttons are always present, neither hidden nor grayed out by state: the demo must be able to really send calls to the SDK at any moment
                    // (including "reconnecting" and pause/resume confirmations in flight), letting the SDK's state gate produce the result,
                    // rather than having the UI block them in advance — blocking would hide the SDK's real behavior at those moments.
                    // Which one is shown depends only on the current state: resume when paused, pause otherwise (including prepare / pause confirming).
                    if case .paused = vm.status { resumeButton } else { pauseButton }
                }
                closeButton
            }
        }
    }

    // MARK: - Pause / resume buttons

    private var pauseButton: some View {
        Button { vm.pauseTravel() } label: {
            controlButtonLabel(systemName: "pause.fill")
        }
    }

    private var resumeButton: some View {
        Button { vm.resumeTravel() } label: {
            controlButtonLabel(systemName: "play.fill")
        }
    }

    private func controlButtonLabel(systemName: String) -> some View {
        ControlButtonLabel(systemName: systemName)
    }

    /// Split into a standalone view (instead of reading `@Environment(\.isEnabled)` directly in `controlButtonLabel`):
    /// `.disabled(...)` only passes the `isEnabled` environment value to the button label's view hierarchy, but a solid circle background/icon
    /// doesn't automatically fade along with it — with a fixed `Color.black.opacity(0.4)` / `.foregroundStyle(.white)`,
    /// it looks the same whether disabled or not, just unresponsive to taps, so the user can't tell "resuming / finishing pause, button is locked".
    private struct ControlButtonLabel: View {
        let systemName: String
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(isEnabled ? 0.4 : 0.2))
                    .frame(width: 36, height: 36)
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
            .opacity(isEnabled ? 1 : 0.4)
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

    /// Parse `"width:height"` to determine portrait; returns nil for unrecognized formats (keep current orientation).
    private static func isPortraitRatio(_ raw: String) -> Bool? {
        let parts = raw.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return parts[0] < parts[1]
    }

    // MARK: - Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        // The two "in-flight" branches must come before the status branches: the SDK only flips status once the state actually settles;
        // during pause confirmation it's still .running publicly (would be covered by the control HUD below), and during resume, before `POST /resume`
        // returns, it's still .paused (would show as "Paused") — feedback between the tap and the status flip can only rely on
        // `isPausing` / `isResuming`, which become true the moment the tap happens.
        if vm.isPausing {
            inFlightHUD("Pausing…")
        } else if vm.isResuming {
            inFlightHUD("Resuming…")
        } else if case .running = vm.status {
            if vm.isWanderMode {
                // Dual-joystick HUD full-width layout: left joystick on the left, buttons + right joystick on the right
                WorldTravelControlsView { params in
                    vm.sendCommand(OysterAdventureCommand(params))
                }
            } else if vm.mode == .acting {
                // acting supports text instructions only: it's not scriptlist (no need to wait for creationModel),
                // and has no joystick (the SDK-side sendCommand rejects non-adventure worlds directly with 103003).
                HStack(alignment: .bottom) {
                    InstructInputView(isFocused: $isInstructFieldFocused) { text in
                        vm.sendInstruct(text)
                    }
                    Spacer()
                }
            } else if !vm.isCreationModelResolved {
                // creationModel hasn't come back yet: we don't know whether to show the text instruction field or the "Update Script" entry,
                // so show nothing for now, avoiding the flicker of "show as simple first, then switch when the result arrives".
                EmptyView()
            } else if vm.isScriptListMode {
                // scriptlist world: no text instruction input; show the "Update Script" entry instead (mutually exclusive with text instructions)
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
                Text("Paused")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.15), in: Capsule())

                // Rewind controls only in Story mode: neither wander nor acting supports rewind
                // (for acting's restriction see the SDK's rewindableTravelVersions), so the entry must be hidden.
                // `@ObservedObject` `vm.countdown` separately to evaluate `canRewind` (depends on elapsedSec),
                // not via `vm` itself.
                if vm.mode == .story {
                    RewindControl(
                        countdown: vm.countdown,
                        isFocused: $isRewindFieldFocused,
                        allowsRewind: vm.mode == .story,
                        status: vm.status,
                        isRewinding: vm.isRewinding,
                        onRewind: { sec in vm.rewind(toSec: sec) }
                    )
                }

                Spacer()
            }
        }
    }

    /// Bottom feedback while pause / resume is in flight (shown immediately on tap, until the SDK actually flips the status).
    private func inFlightHUD(_ title: LocalizedStringKey) -> some View {
        HStack {
            ProgressView().tint(.white).scaleEffect(0.8)
            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Update script (scriptlist worlds)

    /// Bottom HUD "Update Script" entry button, styled like the rewind button.
    private var scriptUpdateEntryButton: some View {
        Button { isScriptEditorPresented = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 13, weight: .semibold))
                Text("Update Script")
                    .font(.subheadline.bold())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.15), in: Capsule())
        }
    }

    /// Full-screen translucent scrim + centered editor card; tapping/dragging anywhere **only dismisses the keyboard, not the panel** — edits won't
    /// be lost by accidental touches; you must tap "Cancel" to really exit. After sending, the panel does not close immediately — it stays in a
    /// loading state while the request is in flight; when the request ends (success/failure), `onChange(of: vm.isUpdatingScript)` on `TravelView.body`
    /// auto-dismisses it and the result is shown via toast. Presented as `fullScreenCover` content, which by default gets an
    /// opaque system background; `ClearFullScreenCoverBackground` makes it transparent here so the dimmed underlying video
    /// is still visible behind the scrim. Keyboard dismissal uses `KeyboardDismissAssistant` (see `AppDelegate.swift`):
    /// monitoring starts when the panel appears and stops when it disappears — start/stop is bound to this standalone hosting controller's own lifecycle,
    /// unrelated to the outer `TravelView`'s per-second countdown refresh, and involves no SwiftUI conditional mounting. This is currently
    /// the first entry point in the project to adopt this new mechanism, validated first on this relatively isolated, lowest-risk panel.
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
            Text("Connecting…")
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
            Button("Close") { vm.endAndDismiss() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.75).ignoresSafeArea())
    }

    /// Non-blocking toast banner (top center, auto-disappears after 3s).
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

// MARK: - Story mode text instruction input

/// Compact text input component suited for landscape: TextField + send button.
/// Clears the field automatically after sending; disables the button while sending to prevent duplicate submissions.
@available(iOS 15.0, *)
private struct InstructInputView: View {
    /// Focus state is owned by `TravelView` (used by the video-layer keyboard-dismiss gesture to decide whether to mount).
    var isFocused: FocusState<Bool>.Binding
    let onSend: (String) -> Void

    @State private var text = ""
    @State private var isSending = false

    var body: some View {
        HStack(spacing: 8) {
            TextField("Enter a story instruction…", text: $text)
                .focused(isFocused)
                .font(.subheadline)
                .foregroundStyle(.white)
                .tint(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                // In portrait (acting 9:16) the screen is narrower and a fixed 260pt would squeeze out the send button: give an upper bound and let it adapt.
                .frame(maxWidth: 260)
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
        // Give the caller a moment to finish asynchronously, then restore the button state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { isSending = false }
    }
}

// MARK: - Countdown-related subviews (separately `@ObservedObject` `TravelCountdownModel`)
//
// The views below hold only `vm.countdown` (not `vm` itself), so each per-second tick only re-evaluates their own
// bodies, without redrawing `TravelView.body` (and the "Update Script" panel attached to its body via fullScreenCover)
// along with them. Before the split, these places read `vm.xxx` directly, so any `@Published` change on `vm`
// (including the once-per-second countdown) re-evaluated the whole `TravelView.body`.

/// Left side of the top info bar: world name + status pill + countdown row.
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
        case .idle: return String(localized: "idle")
        case .prepare: return countdown.timerStarted ? String(localized: "reconnecting") : String(localized: "connecting")
        case .running: return String(localized: "playing")
        case .paused: return String(localized: "paused")
        case .ended: return String(localized: "ended")
        case .failed: return String(localized: "failed")
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
            // ① Primary timeline (wander: remaining time countdown; story: story time count-up "xx/180") —
            // which format it is has already been converged in `TravelViewModel` per `TravelCountdownRule`;
            // this only displays `primaryText`/`primaryIsWarning` and doesn't care about the current mode.
            // Stops counting while paused; always shown.
            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                Text(countdown.primaryText)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(countdown.primaryIsWarning ? Color.orange : Color.white.opacity(0.85))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.35), in: Capsule())

            // ② Overall in-room time (360s, unaffected by pause, not calibrated, auto-ends at zero) — shown only while paused,
            // shared by wander / story.
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

/// Bottom-right reconnecting hint (doesn't cover the video, doesn't block taps).
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
            Text("Reconnecting…")
                .font(.caption.bold())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Paused-state "Back to [N] s + Rewind" control: the rewind API means go back to second N of the whole story (absolute position);
/// N is entered manually by the user, valid range `[1, current story time)` (SDK requires N ≥ 1). `canRewind` depends on `elapsedSec`, so `countdown` must be observed separately.
@available(iOS 15.0, *)
private struct RewindControl: View {
    @ObservedObject var countdown: TravelCountdownModel
    var isFocused: FocusState<Bool>.Binding
    /// Whether the current mode allows rewind (story only; false for both wander and acting).
    let allowsRewind: Bool
    let status: OysterTravelStatus
    let isRewinding: Bool
    let onRewind: (Int) -> Void

    /// Defaults to 5 seconds: the control is only mounted in paused state and recreated on every pause, so each pause resets to the default.
    @State private var text = "5"

    private var targetSec: Int? { Int(text.trimmingCharacters(in: .whitespaces)) }

    private var isTargetValid: Bool {
        guard let targetSec else { return false }
        return targetSec >= 1 && targetSec < countdown.elapsedSec
    }

    private var canRewind: Bool {
        guard case .paused = status else { return false }
        return allowsRewind && countdown.elapsedSec > 1 && !isRewinding && isTargetValid
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text("Back to")
                TextField("1-\(max(countdown.elapsedSec - 1, 1))", text: $text)
                    .focused(isFocused)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .tint(.white)
                    .frame(width: 56)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: text) { newValue in
                        // Keep digits only, to prevent pasting non-numeric content
                        let digits = newValue.filter(\.isNumber)
                        if digits != newValue { text = digits }
                    }
                Text("s")
            }
            .font(.subheadline.bold())
            .foregroundStyle(.white)

            Button {
                guard let targetSec, canRewind else { return }
                isFocused.wrappedValue = false
                onRewind(targetSec)
            } label: {
                HStack(spacing: 5) {
                    if isRewinding {
                        ProgressView().tint(.white).scaleEffect(0.7)
                    } else {
                        Image(systemName: "gobackward")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Text("Rewind")
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
}

// MARK: - iOS 15 compatibility helpers

/// Makes `fullScreenCover` content transparent so the dimmed underlying video is visible — iOS 15 has no `.presentationBackground` (iOS 16.4+),
/// so this common UIViewRepresentable trick sets the background of the cover's presentation container to clear.
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
    /// `TextEditor.scrollContentBackground(.hidden)` is only available on iOS 16+ (PodExample's deployment target is iOS 15);
    /// on iOS 15 it falls back to not hiding the system scroll background (TextEditor's default background covers the outer dark background — a visual downgrade only, no functional impact).
    @ViewBuilder
    func hiddenScrollBackgroundIfAvailable() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}

// MARK: - scriptlist world "Update Script" editor panel

/// Wraps `TextEditor` in its own layer and implements `Equatable` as a fallback: what really cuts the countdown coupling is
/// `TravelViewModel.countdown` (see `TravelCountdownModel` at the top of `TravelViewModel.swift`) —
/// previously the four countdown fields were `@Published` properties of `TravelViewModel` directly, and Combine's `objectWillChange`
/// doesn't distinguish which property changed; whenever any of them changed, every view holding `@StateObject var vm` (the whole `TravelView`
/// and this panel presented via its `.fullScreenCover`) was marked for re-evaluation, so it got dragged into
/// a re-diff every second; on some OS versions this reset the `TextEditor`'s scroll position/cursor back to the top, appearing as
/// "after choosing a template the editor keeps jumping back to the start". After moving to a separate `TravelCountdownModel`, changes to these four fields
/// only trigger its own `objectWillChange` and aren't forwarded to `TravelViewModel`, eliminating this coupling at the root.
/// The `.equatable()` here is just double insurance: if some other field is ever mistakenly put back directly on `TravelViewModel`,
/// at least this `TextEditor` won't suffer for it.
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
            // Feed this input field's real frame (`.global` coordinates, matching the window coordinate system) back to
            // `KeyboardDismissAssistant` in real time, so it rejects taps landing within this area — no need to guess
            // the type of `touch.view`; just use the exact area reported by the input field itself. Once this panel disappears,
            // `scriptUpdateEditorOverlay`'s `onDisappear` calls `stop()` to clear this area,
            // so it doesn't linger and accidentally affect the next page that adopts this mechanism.
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

/// Same structure as the scriptlist editor for creating worlds: one-tap fill from a template dropdown + full JSON editor + send.
/// Validation rules are shared with creation via `ScriptListJSONValidator` (see `ScriptPreset.swift`) to avoid rule drift.
@available(iOS 15.0, *)
private struct ScriptUpdateEditorView: View {
    /// Request in flight: the button switches to the "Sending…" state, the panel stays shown, and it can't be tapped again.
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
        // The middle content isn't wrapped in a ScrollView: embedding `TextEditor` in a `ScrollView` was observed to collapse its height
        // (`.frame(minHeight:maxHeight:)` has no effect), so the field effectively "disappears", the cursor can't be placed,
        // and content can't be edited — worse than "landscape + keyboard covering part of the content", so the fixed-height approach is kept
        // rather than sacrificing editing itself to prevent overflow. Keyboard dismissal doesn't rely on `.toolbar(placement: .keyboard)`:
        // this panel is a standalone view presented by `fullScreenCover` without its own `NavigationView`, so the keyboard
        // toolbar mechanism can't attach; adding a `NavigationView` would bring its own opaque background, cutting a solid-color seam into
        // the transparent "dark scrim + floating card" effect. Keyboard dismissal uses `KeyboardDismissAssistant` instead
        // (started/stopped with the presentation/dismissal of `scriptUpdateEditorOverlay`; attached to `keyWindow` when the keyboard shows,
        // `cancelsTouchesInView = false`, so tapping/dragging anywhere on the panel dismisses the keyboard without affecting
        // the touch handling of `TextEditor`/`Menu`/`Button` themselves).
        VStack(alignment: .leading, spacing: 14) {
            Text("Update Script")
                .font(.headline)
                .foregroundStyle(.white)

            // While sending, lock the whole block (template picker + JSON editor are both non-interactive), so the user doesn't think edits
            // will affect the request already sent; `.disabled` works for both `Menu`/`TextEditor`, and opacity
            // gives "locked" visual feedback.
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
                Button("Cancel") {
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
        presets.first(where: { $0.id == selectedPresetId })?.label ?? String(localized: "Choose a template… (optional; you can also edit the JSON below directly)")
    }

    /// Custom style instead of `.buttonStyle(.borderedProminent)`: the system disabled state overlays a translucent gray on the original color,
    /// which on this dark card background (`Color(white: 0.12)`) ends up too close to the background, making the button nearly invisible.
    /// Here the three states "not ready" (empty text) / "sending" / "ready to send" each get an explicit background color, ensuring
    /// the button outline and text have enough contrast against the dark background in every state.
    private var sendButton: some View {
        Button(action: send) {
            HStack(spacing: 6) {
                if isSending {
                    ProgressView().tint(.white).scaleEffect(0.75)
                    Text("Sending…")
                } else {
                    Text("Send")
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
