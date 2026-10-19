import SwiftUI

/// Profile page: shows the Bailian temporary token fetched from the local service and the next auto-refresh time.
/// onAppear reads the TokenManager cache (no forced re-request); only the refresh button triggers invalidateAndRefresh.
struct ProfileView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var env: AppEnvironment

    @State private var tokenInfo: TokenInfo?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showServerConfig = false
    @State private var showSdkUrlEdit = false
    @State private var showSdkModelEdit = false
    @State private var isCleaningUp = false
    @State private var cleanupResult: String?

    private enum TokenField: Hashable { case expireSeconds, refreshLeeway }
    @FocusState private var focusedTokenField: TokenField?

    /// Kept in sync with TokenManager.leeway: auto-refresh fires 30s before expiry.
    private var leeway: TimeInterval { TimeInterval(env.tokenRefreshLeeway) }

    var body: some View {
        NavigationView {
            List {
                tokenSection
                tokenSettingsSection
                playSettingsSection
                devToolsSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            // A List has no reliable "tap background to dismiss" gesture (rows fill the List, so there
            // is no real blank background area); the keyboard toolbar "Done" button is the only reliable
            // path that doesn't depend on gesture hit-testing.
            // Clear @FocusState directly instead of calling UIKit's resignFirstResponder: focus state has
            // a single source of truth, and clearing it on the SwiftUI side dismisses the keyboard automatically.
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedTokenField = nil }
                }
            }
            .sheet(isPresented: $showServerConfig) {
                    ServerConfigView().environmentObject(env)
                }
            .sheet(isPresented: $showSdkUrlEdit) {
                    SdkUrlEditView().environmentObject(env)
                }
            .sheet(isPresented: $showSdkModelEdit) {
                    SdkModelEditView().environmentObject(env)
                }
            .onAppear { loadFromCache() }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Token section

    private var tokenSection: some View {
        Section {
            // Token text
            Group {
                if isLoading {
                    HStack {
                        ProgressView()
                        Text("Fetching…")
                            .foregroundStyle(.secondary)
                            .padding(.leading, 8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if let info = tokenInfo {
                    Text(info.token)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let error = errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else {
                    Text("No token yet")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            // Next auto-refresh time
            if let info = tokenInfo {
                let refreshAt = info.expiresAt.addingTimeInterval(-leeway)
                HStack {
                    Image(systemName: "arrow.clockwise.circle")
                        .foregroundStyle(.secondary)
                    Text("Next auto-refresh")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(refreshAt, style: .time)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            // Refresh button
            Button(action: forceRefresh) {
                HStack {
                    if isLoading { ProgressView().scaleEffect(0.8) }
                    Image(systemName: "arrow.clockwise")
                    Text("Refresh now")
                }
            }
            .disabled(isLoading)
        } header: {
            Text("Temporary Token")
        } footer: {
            let autoDesc = env.tokenAutoRefresh
                ? String(localized: "auto-renews \(env.tokenRefreshLeeway)s before expiry")
                : String(localized: "auto-refresh is off")
            Text("From local service POST /server-api/temp-api-key (valid for \(env.tokenExpireSeconds)s), \(autoDesc).")
        }
    }

    // MARK: - Token settings section

    private var tokenSettingsSection: some View {
        // Avoid the "tap blank area to dismiss" gesture approach, which tends to fight with in-row
        // controls (Button/Toggle) in a List. Keyboard dismissal is handled solely by the keyboard
        // toolbar "Done" button (see .toolbar(placement: .keyboard) in body), which is 100% reliable
        // for the first responder and avoids wrestling with hitTest/gesture recognizer priority.
        Section {
            // Validity period
            HStack {
                Label("Validity", systemImage: "clock")
                    .font(.subheadline)
                Spacer()
                TextField("1800", value: $env.tokenExpireSeconds, formatter: secondsFormatter)
                    .focused($focusedTokenField, equals: .expireSeconds)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("sec")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Auto-refresh toggle
            Toggle(isOn: $env.tokenAutoRefresh) {
                Label("Auto-refresh", systemImage: "arrow.clockwise.circle")
                    .font(.subheadline)
            }

            // Refresh lead time (only meaningful when auto-refresh is on)
            if env.tokenAutoRefresh {
                HStack {
                    Label("Refresh early", systemImage: "timer")
                        .font(.subheadline)
                    Spacer()
                    TextField("30", value: $env.tokenRefreshLeeway, formatter: secondsFormatter)
                        .focused($focusedTokenField, equals: .refreshLeeway)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 55)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("sec before")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Token Settings")
        } footer: {
            Text("Validity range is 1–1800 seconds. Refresh early: silently renews this many seconds before expiry.")
        }
    }

    private var secondsFormatter: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = 1
        f.maximum = 1800
        return f
    }

    // MARK: - Play settings section

    private var playSettingsSection: some View {
        Section {
            Picker(selection: $env.maxExperienceTimeSec) {
                Text("60 sec").tag(60)
                Text("90 sec").tag(90)
                Text("120 sec").tag(120)
            } label: {
                Label("Play Time", systemImage: "timer")
            }
            .pickerStyle(.menu)
        } header: {
            Text("Play Settings")
        } footer: {
            Text("Play time only affects Adventure mode.")
        }
    }

    // MARK: - Dev tools section

    private var devToolsSection: some View {
        Section {
            Button { showServerConfig = true } label: {
                HStack {
                    Label("Server Configuration", systemImage: "server.rack")
                    Spacer()
                    Text(env.localServerAddress)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Button { showSdkUrlEdit = true } label: {
                HStack {
                    Label("Bailian APIHost", systemImage: "network")
                    Spacer()
                    Text(env.apiHost.isEmpty ? String(localized: "Not configured") : env.apiHost)
                        .font(.footnote)
                        .foregroundStyle(env.apiHost.isEmpty ? .orange : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 200, alignment: .trailing)
                }
            }

            Button { showSdkModelEdit = true } label: {
                HStack(alignment: .firstTextBaseline) {
                    Label("Bailian Model", systemImage: "cpu")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(env.model.isEmpty ? String(localized: "Not configured") : env.model)
                            .font(.footnote)
                            .foregroundStyle(env.model.isEmpty ? .orange : .secondary)
                        // Entering a world auto-switches to the sibling model for that world's mode, so the
                        // running model may differ from the one configured here. The demo doesn't hide this
                        // and shows the effective model as well.
                        if let active = session.activeModel, active != env.model {
                            Text("Running: \(active)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .trailing)
                }
            }

            // SDK engine reset button
            Button(action: performCleanup) {
                HStack {
                    if isCleaningUp {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text("Reset SDK Engine")
                    Spacer()
                    if let result = cleanupResult {
                        Text(result)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(isCleaningUp)
            .foregroundColor(isCleaningUp ? .secondary : .red)
        } header: {
            Text("Developer Tools")
        } footer: {
            Text("Reset engine: runs cleanup() → initialize() → token refresh in order.\nUse it when switching the Bailian APIHost, fully clearing RTC/tokenStore state, or troubleshooting engine initialization. Not needed after a normal play session.")
        }
    }

    // MARK: - Actions

    private func loadFromCache() {
        guard !isLoading else { return }
        Task {
            if let cached = await session.tokenManager?.currentInfo {
                tokenInfo = cached
                return
            }
            await fetchToken(force: false)
        }
    }

    private func forceRefresh() {
        guard !isLoading else { return }
        Task { await fetchToken(force: true) }
    }

    @MainActor
    private func fetchToken(force: Bool) async {
        guard let tm = session.tokenManager else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            tokenInfo = force
                ? try await tm.invalidateAndRefresh()
                : try await tm.validToken()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performCleanup() {
        guard !isCleaningUp else { return }
        cleanupResult = nil
        Task {
            isCleaningUp = true
            defer { isCleaningUp = false }
            await session.cleanupAndReinitialize()
            // Refresh the token info shown on the page
            if let cached = await session.tokenManager?.currentInfo {
                tokenInfo = cached
            }
            cleanupResult = String(localized: "Reset done")
            // Clear the hint after 3 seconds
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            cleanupResult = nil
        }
    }
}

// MARK: - SDK gateway URL editor

@available(iOS 15.0, *)
private struct SdkUrlEditView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var urlText: String = ""
    @FocusState private var isUrlFieldFocused: Bool

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextEditor(text: $urlText)
                        .focused($isUrlFieldFocused)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .frame(minHeight: 80)
                } header: {
                    Text("Bailian APIHost")
                } footer: {
                    Text("Enter only the domain/host part. There is no built-in default, so it must be filled in manually; if the http(s):// prefix is omitted, https:// is added automatically on save. After changing it, tap \"Reset SDK Engine\" on the Settings page for it to take effect.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Bailian APIHost")
            .navigationBarTitleDisplayMode(.inline)
            // Keyboard dismissal goes through the keyboard toolbar "Done" button only; no container-level
            // gesture competing with TextEditor for hit-testing.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isUrlFieldFocused = false }
                }
            }
            .onAppear { urlText = env.apiHost }
        }
    }

    private func save() {
        let trimmed = urlText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        env.apiHost = trimmed
        dismiss()
    }
}

// MARK: - SDK model editor

/// Editor for the Bailian model name (including version).
/// happyoyster is split into per-mode sub-models, and the SDK's `OysterConfig.model` has no default and must be set
/// explicitly, so this page offers both free input and a quick-fill list of common values (`ModelPreset`) to avoid typing long model names.
@available(iOS 15.0, *)
private struct SdkModelEditView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var modelText: String = ""
    @FocusState private var isModelFieldFocused: Bool

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("happyoyster-1.0-adventure", text: $modelText)
                        .focused($isModelFieldFocused)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Bailian Model")
                } footer: {
                    Text("Model name including version; the SDK uses it to build the gateway path /api/v2/apps/{model}/openapi/v1. There is no built-in default, so it must be filled in manually. It must match the APIHost; a wrong value is rejected by the gateway with AccessDenied (106003). After changing it, tap \"Reset SDK Engine\" on the Settings page for it to take effect.\n\nModels are split by mode, and one initialization serves worlds of only one mode. If you pick any preset below, entering a world automatically switches to the model serving that world's mode (e.g. if Adventure is selected but you enter an Acting world, happyoyster-1.0-acting is used automatically). Manually entered legacy unsplit models or custom values are used as-is without conversion.")
                        .font(.footnote)
                }

                presetSection
            }
            .navigationTitle("Bailian Model")
            .navigationBarTitleDisplayMode(.inline)
            // Keyboard dismissal goes through the keyboard toolbar "Done" button only; no container-level gesture competing with TextField for hit-testing.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(modelText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isModelFieldFocused = false }
                }
            }
            .onAppear { modelText = env.model }
        }
    }

    /// Quick-fill section: a tap only fills the model name into the field above; it still needs "Save" to persist.
    private var presetSection: some View {
        Section("Quick Fill") {
            ForEach(ModelPreset.all) { preset in
                Button {
                    modelText = preset.name
                    isModelFieldFocused = false
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.mode.badgeLabel)
                            Text(preset.name)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if modelText.trimmingCharacters(in: .whitespaces) == preset.name {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
        }
    }

    private func save() {
        let trimmed = modelText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        env.model = trimmed
        dismiss()
    }
}
