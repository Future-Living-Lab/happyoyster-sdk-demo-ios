import SwiftUI

/// 个人页：展示从本地服务获取的百炼临时 Token，以及下次自动刷新时间。
/// onAppear 读取 TokenManager 缓存（不强制重请求）；刷新按钮才触发 invalidateAndRefresh。
struct ProfileView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var env: AppEnvironment

    @State private var tokenInfo: TokenInfo?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showServerConfig = false
    @State private var showSdkUrlEdit = false
    @State private var isCleaningUp = false
    @State private var cleanupResult: String?

    private enum TokenField: Hashable { case expireSeconds, refreshLeeway }
    @FocusState private var focusedTokenField: TokenField?

    /// 与 TokenManager.leeway 保持一致：到期前 30s 触发自动刷新。
    private var leeway: TimeInterval { TimeInterval(env.tokenRefreshLeeway) }

    var body: some View {
        NavigationView {
            List {
                tokenSection
                tokenSettingsSection
                playSettingsSection
                devToolsSection
            }
            .navigationTitle("配置")
            .navigationBarTitleDisplayMode(.inline)
            // List 场景没有可靠的"点背景收起"手势（List 铺满行内容，没有真正意义上的
            // 空白背景区），键盘工具栏「完成」按钮是唯一不依赖手势命中测试的可靠路径。
            // 直接清空 @FocusState 而不是调 UIKit 的 resignFirstResponder：焦点状态
            // 只有一个事实源，SwiftUI 侧清空后会自动同步收起键盘。
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedTokenField = nil }
                }
            }
            .sheet(isPresented: $showServerConfig) {
                    ServerConfigView().environmentObject(env)
                }
            .sheet(isPresented: $showSdkUrlEdit) {
                    SdkUrlEditView().environmentObject(env)
                }
            .onAppear { loadFromCache() }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Token section

    private var tokenSection: some View {
        Section {
            // Token 文本
            Group {
                if isLoading {
                    HStack {
                        ProgressView()
                        Text("获取中…")
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
                    Text("暂无 Token")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            // 下次自动刷新时间
            if let info = tokenInfo {
                let refreshAt = info.expiresAt.addingTimeInterval(-leeway)
                HStack {
                    Image(systemName: "arrow.clockwise.circle")
                        .foregroundStyle(.secondary)
                    Text("下次自动刷新")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(refreshAt, style: .time)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            // 刷新按钮
            Button(action: forceRefresh) {
                HStack {
                    if isLoading { ProgressView().scaleEffect(0.8) }
                    Image(systemName: "arrow.clockwise")
                    Text("立即刷新")
                }
            }
            .disabled(isLoading)
        } header: {
            Text("临时 Token")
        } footer: {
            let autoDesc = env.tokenAutoRefresh
                ? "到期前 \(env.tokenRefreshLeeway)s 自动续期"
                : "自动刷新已关闭"
            Text("来自本地服务 POST /server-api/temp-api-key（有效期 \(env.tokenExpireSeconds)s），\(autoDesc)。")
        }
    }

    // MARK: - Token settings section

    private var tokenSettingsSection: some View {
        // 不依赖"点空白处收起"这套在 List 场景下容易跟行内控件（Button/Toggle）
        // 打架的手势方案——收起键盘统一交给键盘工具栏的「完成」按钮（见 body 里的
        // .toolbar(placement: .keyboard)），对 first responder 100% 可靠，不用
        // 跟 hitTest/手势识别器优先级较劲。
        Section {
            // 有效期
            HStack {
                Label("有效期", systemImage: "clock")
                    .font(.subheadline)
                Spacer()
                TextField("1800", value: $env.tokenExpireSeconds, formatter: secondsFormatter)
                    .focused($focusedTokenField, equals: .expireSeconds)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("秒")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // 自动刷新开关
            Toggle(isOn: $env.tokenAutoRefresh) {
                Label("自动刷新", systemImage: "arrow.clockwise.circle")
                    .font(.subheadline)
            }

            // 提前刷新间隔（仅自动刷新开启时有意义）
            if env.tokenAutoRefresh {
                HStack {
                    Label("提前刷新", systemImage: "timer")
                        .font(.subheadline)
                    Spacer()
                    TextField("30", value: $env.tokenRefreshLeeway, formatter: secondsFormatter)
                        .focused($focusedTokenField, equals: .refreshLeeway)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 55)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("秒前")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Token 设置")
        } footer: {
            Text("有效期范围 1–1800 秒。提前刷新：到期前该秒数触发静默续期。")
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
                Text("60 秒").tag(60)
                Text("90 秒").tag(90)
                Text("120 秒").tag(120)
            } label: {
                Label("游玩时间", systemImage: "timer")
            }
            .pickerStyle(.menu)
        } header: {
            Text("游玩设置")
        } footer: {
            Text("游玩时间只影响冒险模式。")
        }
    }

    // MARK: - Dev tools section

    private var devToolsSection: some View {
        Section {
            Button { showServerConfig = true } label: {
                HStack {
                    Label("服务器配置", systemImage: "server.rack")
                    Spacer()
                    Text(env.localServerAddress)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Button { showSdkUrlEdit = true } label: {
                HStack {
                    Label("百炼 APIHost", systemImage: "network")
                    Spacer()
                    Text(env.apiHost.isEmpty ? "未配置" : env.apiHost)
                        .font(.footnote)
                        .foregroundStyle(env.apiHost.isEmpty ? .orange : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 200, alignment: .trailing)
                }
            }

            // SDK 引擎重置按钮
            Button(action: performCleanup) {
                HStack {
                    if isCleaningUp {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text("重置 SDK 引擎")
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
            Text("开发工具")
        } footer: {
            Text("重置引擎：依次执行 cleanup() → initialize() → token 刷新。\n适用场景：切换百炼 APIHost、彻底清除 RTC/tokenStore 状态、排查引擎初始化问题。正常游玩结束无需执行此操作。")
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
            // 刷新页面上展示的 token 信息
            if let cached = await session.tokenManager?.currentInfo {
                tokenInfo = cached
            }
            cleanupResult = "已重置"
            // 3 秒后清除提示
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            cleanupResult = nil
        }
    }
}

// MARK: - SDK 网关 URL 编辑页

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
                    Text("百炼 APIHost")
                } footer: {
                    Text("只填域名/host 部分；无内置默认值，必须手动填写；未带 http(s):// 前缀时保存后自动补全 https://。修改后需在配置页点击「重置 SDK 引擎」才能生效。")
                        .font(.footnote)
                }
            }
            .navigationTitle("百炼 APIHost")
            .navigationBarTitleDisplayMode(.inline)
            // 收起键盘统一走键盘工具栏「完成」按钮，不用容器级手势跟 TextEditor
            // 抢占命中测试。
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { isUrlFieldFocused = false }
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
