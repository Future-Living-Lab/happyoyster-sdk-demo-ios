import SwiftUI

/// 创建页：顶部 Segmented 切换 Wander / Story 模式，
/// 各子页填写参数后点击创建，成功后 Toast 提示并跳转游玩 Tab。
struct MainView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var navigation: AppNavigation

    @State private var mode: ServerWorldMode = .wander
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var toast: String?

    // MARK: Wander 参数
    @State private var wanderPrompt = ""
    @State private var wanderPerspective: WorldPerspective = .thirdPerson
    @State private var wanderUploadMode: WanderUploadMode = .firstFrame
    /// first_frame 模式 — 首帧图 URL（直接透传，上传由调用方实现）
    @State private var firstFrameImageUrl = ""
    /// scenario_role 模式 — 场景图 URL
    @State private var sceneImageUrl = ""
    /// scenario_role 模式 — 场景描述（最多 2000 字）
    @State private var scenePromptText = ""
    /// scenario_role 模式 — 角色图 URL
    @State private var roleImageUrl = ""
    /// scenario_role 模式 — 角色描述（最多 2000 字）
    @State private var rolePromptText = ""

    // MARK: Story 参数
    @State private var storyPrompt = ""
    @State private var storyImageUrl = ""
    @State private var storyResolution: StoryResolution = .r720p
    @State private var storyNarrative: StoryNarrative = .normal

    // MARK: Story - creationModel=scriptlist 子模式
    @State private var storyCreationModel: StoryCreationModel = .simple
    @State private var scriptFirstFrameUrl = ""
    @State private var scriptListText = ""
    @State private var selectedPresetId: String?
    @State private var scriptPresets: [ScriptPreset] = []

    // MARK: - 轮询状态（Wander / Story 各自独立）
    @State private var wanderPollingId: String?
    @State private var wanderPollStatus: BuildStatusResponse?
    @State private var wanderPollTask: Task<Void, Never>?

    @State private var storyPollingId: String?
    @State private var storyPollStatus: BuildStatusResponse?
    @State private var storyPollTask: Task<Void, Never>?

    private var currentPollingId: String?       { mode == .wander ? wanderPollingId   : storyPollingId }
    private var currentPollStatus: BuildStatusResponse? { mode == .wander ? wanderPollStatus : storyPollStatus }

    // MARK: - 字数上限
    private let promptLimitFirstFrame = 4000
    private let promptLimitScenario   = 2000

    // MARK: - 焦点状态（用于 .focused() 绑定；收键盘统一走键盘工具栏「完成」按钮）
    private enum Field: Hashable {
        case prompt, firstFrameImageUrl, storyImageUrl
        case sceneImageUrl, scenePrompt, roleImageUrl, rolePrompt
        case scriptFirstFrameUrl, scriptListEditor
    }
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                modePicker
                Divider()
                globalToolbar
                Divider()
                createForm
                Spacer()
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("创建")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .bottom) { toastBanner }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil }
                }
            }
            .task { await loadScriptPresetsIfNeeded() }
        }
        .navigationViewStyle(.stack)
    }

    /// 首次进入 Story 剧本子模式前预取预置列表；已加载过则跳过。
    private func loadScriptPresetsIfNeeded() async {
        guard scriptPresets.isEmpty else { return }
        let presets = await ScriptPresetProvider().loadPresets()
        scriptPresets = presets
        if selectedPresetId == nil, let first = presets.first {
            applyScriptPreset(first)
        }
    }

    // MARK: - Global toolbar（固定在 picker 下方，位置不随表单内容变化）

    private var globalToolbar: some View {
        HStack(spacing: 8) {
            if mode == .wander {
                perspectiveMenuButton(selection: $wanderPerspective)
                uploadModeMenuButton
            } else {
                creationModelMenuButton
                if storyCreationModel == .simple {
                    resolutionMenuButton
                    narrativeMenuButton
                } else {
                    resolutionMenuButton
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        Picker("模式", selection: $mode) {
            Text("Wander").tag(ServerWorldMode.wander)
            Text("Story").tag(ServerWorldMode.story)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
        .onChange(of: mode, perform: { _ in errorMessage = nil })
    }

    // MARK: - Create form

    private var createForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if currentPollingId != nil {
                    buildingStatusView
                } else if mode == .wander && wanderUploadMode == .scenarioRole {
                    scenarioRoleSection
                } else if mode == .story && storyCreationModel == .scriptlist {
                    scriptListSection
                } else {
                    promptCard
                    if mode == .wander && wanderUploadMode == .firstFrame {
                        firstFrameImageCard
                    }
                    if mode == .story {
                        storyImageCard
                    }
                }
                if currentPollingId == nil {
                    if let msg = errorMessage {
                        Text(msg)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }
                    createButton
                }
            }
            .padding(.top, 24)
        }
    }

    // MARK: - Building status view（轮询期间替换输入区域）

    @ViewBuilder
    private var buildingStatusView: some View {
        VStack(spacing: 16) {
            // 预览图 / 占位渐变
            buildingPreview
                .frame(height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)

            // 状态信息
            VStack(spacing: 10) {
                if let s = currentPollStatus {
                    if let name = s.name, !name.isEmpty {
                        Text(name)
                            .font(.headline)
                    }
                    Text(s.encryptedWorldId)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal)

                    buildingStatusBadge(s.status)
                } else {
                    ProgressView()
                    Text("正在获取世界信息…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)

            // 取消按钮
            Button {
                clearPolling(mode: mode)
            } label: {
                Text("取消并返回")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
        .animation(.default, value: currentPollStatus?.status)
    }

    @ViewBuilder
    private var buildingPreview: some View {
        if let urlStr = currentPollStatus?.firstFrame ?? currentPollStatus?.previewUrl,
           let url = URL(string: urlStr) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default:               buildingGradient
                }
            }
        } else {
            buildingGradient
                .overlay {
                    if currentPollStatus?.status == .failed {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.7))
                    } else {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.4)
                    }
                }
        }
    }

    private var buildingGradient: some View {
        LinearGradient(
            colors: mode == .wander
                ? [Color(hue: 0.55, saturation: 0.5, brightness: 0.55),
                   Color(hue: 0.65, saturation: 0.4, brightness: 0.4)]
                : [Color(hue: 0.08, saturation: 0.5, brightness: 0.6),
                   Color(hue: 0.03, saturation: 0.4, brightness: 0.45)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func buildingStatusBadge(_ status: ServerWorldStatus) -> some View {
        HStack(spacing: 6) {
            switch status {
            case .generating:
                ProgressView().scaleEffect(0.7)
                Text("生成中…")
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("就绪")
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text("生成失败")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    // MARK: - Prompt card（textOnly / firstFrame / Story 通用）

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("世界描述")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer()
                if mode == .wander && wanderUploadMode == .firstFrame {
                    charCountLabel(wanderPrompt.count, limit: promptLimitFirstFrame)
                } else if mode == .story {
                    charCountLabel(storyPrompt.count, limit: promptLimitFirstFrame)
                }
            }
            .padding(.horizontal)

            VStack(spacing: 0) {
                let binding = mode == .wander ? $wanderPrompt : $storyPrompt
                TextEditor(text: binding)
                    .focused($focusedField, equals: .prompt)
                    .font(.body)
                    .frame(minHeight: 120, maxHeight: 200)
                    .padding(12)
                    .overlay(alignment: .topLeading) {
                        let prompt = mode == .wander ? wanderPrompt : storyPrompt
                        if prompt.isEmpty {
                            Text(promptPlaceholder)
                                .font(.body)
                                .foregroundStyle(Color(.placeholderText))
                                .padding(.horizontal, 16)
                                .padding(.top, 20)
                                .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: wanderPrompt, perform: { val in
                        if mode == .wander && wanderUploadMode == .firstFrame
                            && val.count > promptLimitFirstFrame {
                            wanderPrompt = String(val.prefix(promptLimitFirstFrame))
                        }
                    })
                    .onChange(of: storyPrompt, perform: { val in
                        if mode == .story && val.count > promptLimitFirstFrame {
                            storyPrompt = String(val.prefix(promptLimitFirstFrame))
                        }
                    })
            }
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator), lineWidth: 0.5))
            .padding(.horizontal)
        }
    }

    // MARK: - Story 参考图卡片

    private var storyImageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("参考图")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    TextField("图片 URL（可选）", text: $storyImageUrl)
                        .focused($focusedField, equals: .storyImageUrl)
                        .font(.body)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(12)

                Divider()

                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("图片 URL 将直接透传至接口，图片上传及获取逻辑需客户自行实现")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator), lineWidth: 0.5))
            .padding(.horizontal)
        }
    }

    // MARK: - Story creationModel=scriptlist 表单

    private var scriptListSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            scriptPresetPickerCard
            scriptFirstFrameImageCard
            scriptListEditorCard
        }
    }

    /// 剧本模板下拉：选中后将对应 `scriptList` 填入下方 JSON 编辑器。
    private var scriptPresetPickerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("剧本模板")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Menu {
                ForEach(scriptPresets) { preset in
                    Button {
                        applyScriptPreset(preset)
                    } label: {
                        HStack {
                            Text(preset.label)
                            if selectedPresetId == preset.id { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                HStack {
                    Text(scriptPresets.first(where: { $0.id == selectedPresetId })?.label ?? "选择模板")
                        .foregroundStyle(selectedPresetId == nil ? Color(.placeholderText) : Color.primary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.body)
                .padding(12)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator), lineWidth: 0.5))
            }
            .padding(.horizontal)
        }
    }

    private func applyScriptPreset(_ preset: ScriptPreset) {
        selectedPresetId = preset.id
        scriptListText = preset.scriptListJSON
        if let url = preset.firstFrameImageUrl, !url.isEmpty {
            scriptFirstFrameUrl = url
        }
        errorMessage = nil
    }

    /// 首帧图 URL 卡片（必填，仅校验合法 http(s)），样式对齐 `firstFrameImageCard`。
    private var scriptFirstFrameImageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("首帧图（必填）")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    TextField("首帧图 URL（http/https）", text: $scriptFirstFrameUrl)
                        .focused($focusedField, equals: .scriptFirstFrameUrl)
                        .font(.body)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(12)

                Divider()

                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("直接复用为世界首帧，跳过 AI 首帧生成；图片上传逻辑需客户自行实现")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator), lineWidth: 0.5))
            .padding(.horizontal)
        }
    }

    /// scriptList JSON 大文本编辑器（预填预置），等宽字体便于阅读。
    private var scriptListEditorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("剧本 scriptList（JSON，必填）")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            TextEditor(text: $scriptListText)
                .focused($focusedField, equals: .scriptListEditor)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 260, maxHeight: 420)
                .padding(8)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator), lineWidth: 0.5))
                .padding(.horizontal)
        }
    }

    // MARK: - First frame 图片卡片

    private var firstFrameImageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("首帧图")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    TextField("图片 URL（可选）", text: $firstFrameImageUrl)
                        .focused($focusedField, equals: .firstFrameImageUrl)
                        .font(.body)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(12)

                Divider()

                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("图片 URL 将直接透传至接口，图片上传及获取逻辑需客户自行实现")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator), lineWidth: 0.5))
            .padding(.horizontal)
        }
    }

    // MARK: - Scenario role 场景 + 角色双卡片

    private var scenarioRoleSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            imagePromptCard(
                title: "场景",
                imageUrl: $sceneImageUrl,
                promptText: $scenePromptText,
                promptLimit: promptLimitScenario,
                imagePlaceholder: "场景图片 URL（可选）",
                promptPlaceholder: "场景描述（可选），例如：废弃的深海科研站…",
                imageField: .sceneImageUrl,
                promptField: .scenePrompt
            )
            imagePromptCard(
                title: "角色",
                imageUrl: $roleImageUrl,
                promptText: $rolePromptText,
                promptLimit: promptLimitScenario,
                imagePlaceholder: "角色图片 URL（可选）",
                promptPlaceholder: "角色描述（可选），例如：宇宙探险家…",
                imageField: .roleImageUrl,
                promptField: .rolePrompt
            )
        }
    }

    /// 图片 URL + 文字描述复合卡片（scene / role 共用）
    private func imagePromptCard(
        title: String,
        imageUrl: Binding<String>,
        promptText: Binding<String>,
        promptLimit: Int,
        imagePlaceholder: String,
        promptPlaceholder: String,
        imageField: Field,
        promptField: Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            VStack(spacing: 0) {
                // 图片 URL 输入
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    TextField(imagePlaceholder, text: imageUrl)
                        .focused($focusedField, equals: imageField)
                        .font(.body)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(12)

                Divider()

                // 文字描述输入（可选）
                ZStack(alignment: .topLeading) {
                    if promptText.wrappedValue.isEmpty {
                        Text(promptPlaceholder)
                            .font(.body)
                            .foregroundStyle(Color(.placeholderText))
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: promptText)
                        .focused($focusedField, equals: promptField)
                        .font(.body)
                        .frame(minHeight: 80, maxHeight: 120)
                        .padding(12)
                        .onChange(of: promptText.wrappedValue, perform: { val in
                            if val.count > promptLimit {
                                promptText.wrappedValue = String(val.prefix(promptLimit))
                            }
                        })
                }

                Divider()

                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("图片 URL 将直接透传至接口，图片上传及获取逻辑需客户自行实现")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    charCountLabel(promptText.wrappedValue.count, limit: promptLimit)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator), lineWidth: 0.5))
            .padding(.horizontal)
        }
    }

    // MARK: - 工具栏按钮

    private func perspectiveMenuButton(selection: Binding<WorldPerspective>) -> some View {
        Menu {
            ForEach(WorldPerspective.allCases) { p in
                Button {
                    selection.wrappedValue = p
                } label: {
                    HStack {
                        Text(p.label)
                        if selection.wrappedValue == p { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            toolbarPill(icon: "person.crop.square", title: selection.wrappedValue.label)
        }
    }

    private var uploadModeMenuButton: some View {
        Menu {
            ForEach(WanderUploadMode.allCases) { m in
                Button {
                    wanderUploadMode = m
                } label: {
                    HStack {
                        Text(m.label)
                        if wanderUploadMode == m { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            toolbarPill(icon: "photo", title: wanderUploadMode.label)
        }
    }

    private var resolutionMenuButton: some View {
        Menu {
            ForEach(StoryResolution.allCases) { r in
                Button {
                    storyResolution = r
                } label: {
                    HStack {
                        Text(r.label)
                        if storyResolution == r { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            toolbarPill(icon: "aspectratio", title: storyResolution.label)
        }
    }

    private var creationModelMenuButton: some View {
        Menu {
            ForEach(StoryCreationModel.allCases) { m in
                Button {
                    storyCreationModel = m
                    errorMessage = nil
                } label: {
                    HStack {
                        Text(m.label)
                        if storyCreationModel == m { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            toolbarPill(icon: "doc.text", title: storyCreationModel.label)
        }
    }

    private var narrativeMenuButton: some View {
        Menu {
            ForEach(StoryNarrative.allCases) { n in
                Button {
                    storyNarrative = n
                } label: {
                    HStack {
                        Text(n.label)
                        if storyNarrative == n { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            toolbarPill(icon: "theatermasks", title: storyNarrative.label)
        }
    }

    private func toolbarPill(icon: String, title: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 13))
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .fixedSize()
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemFill), in: Capsule())
        // transaction 优先级高于父层 withAnimation（包括 Menu 内部触发的动画），
        // 确保标签文字宽度变化时 Capsule 背景直接跳变，不出现截断过渡帧。
        .transaction { $0.animation = nil }
    }

    // MARK: - 字数计数器

    private func charCountLabel(_ count: Int, limit: Int) -> some View {
        Text("\(count) / \(limit)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(count > limit ? Color.red : Color(.tertiaryLabel))
    }

    // MARK: - 创建按钮

    private var createButton: some View {
        let disabled = isCreateDisabled
        return Button(action: createWorld) {
            HStack(spacing: 8) {
                if isCreating {
                    ProgressView().scaleEffect(0.85).tint(.white)
                }
                Text(isCreating ? "创建中…" : "创建世界")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(disabled ? Color(.systemFill) : Color.accentColor)
            .foregroundStyle(disabled ? Color(.secondaryLabel) : .white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
        }
        .disabled(disabled)
    }

    /// 各模式的启用条件：必填项不为空即可点击创建。
    private var isCreateDisabled: Bool {
        if isCreating { return true }
        switch mode {
        case .story:
            if storyCreationModel == .scriptlist {
                // 细粒度错误在点击时由 validateScriptList() 给出，这里只做粗粒度非空判断。
                return scriptListText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || scriptFirstFrameUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            // prompt 必填，参考图可选
            return storyPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .wander:
            switch wanderUploadMode {
            case .firstFrame:
                // prompt 必填，首帧图可选
                return wanderPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .scenarioRole:
                // 图片均可选，场景描述和角色描述至少填写其中一项
                return scenePromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && rolePromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    // MARK: - Toast

    @ViewBuilder
    private var toastBanner: some View {
        if let message = toast {
            Text(message)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color(.label).opacity(0.85))
                .clipShape(Capsule())
                .padding(.bottom, 32)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Helpers

    private var promptPlaceholder: String {
        if mode == .wander && wanderUploadMode == .firstFrame {
            return "描述你的世界场景，例如：一座漂浮在云端的古城…"
        }
        switch mode {
        case .wander: return "描述你的世界场景，例如：一座漂浮在云端的古城…"
        case .story:  return "描述故事背景，例如：在遥远的未来，人类移居火星…"
        }
    }

    // MARK: - 创建请求

    private func createWorld() {
        guard !isCreateDisabled else { return }

        if mode == .story && storyCreationModel == .scriptlist {
            switch validateScriptList() {
            case .failure(let message):
                errorMessage = message
                return
            case .success(let scriptList):
                createScriptListWorld(scriptList: scriptList)
                return
            }
        }

        isCreating = true
        errorMessage = nil

        Task {
            defer { isCreating = false }
            do {
                let isWander = mode == .wander

                // scenario_role 模式：用 scenePromptText 兜底，其次 rolePromptText，都空时传 null。
                // 其余模式：用户未填写时传 null（服务端接受字段缺失，但不接受空字符串）。
                let prompt: String? = {
                    if isWander && wanderUploadMode == .scenarioRole {
                        let scene = scenePromptText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let role  = rolePromptText.trimmingCharacters(in: .whitespacesAndNewlines)
                        return scene.isEmpty ? (role.isEmpty ? nil : role) : scene
                    }
                    return (isWander ? wanderPrompt : storyPrompt)
                        .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                }()

                let body = CreateWorldRequest(
                    mode: mode.rawValue,
                    async_: true,
                    prompt: prompt,
                    eventStyle: nil,
                    refWorldId: nil,
                    perspective: isWander ? wanderPerspective.apiValue : nil,
                    uploadMode: isWander ? wanderUploadMode.apiValue : nil,
                    firstFrameImage: {
                        let wanderUrl = firstFrameImageUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                        let storyUrl  = storyImageUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                        if isWander && wanderUploadMode == .firstFrame && !wanderUrl.isEmpty {
                            return ImageRef(url: wanderUrl)
                        } else if !isWander && !storyUrl.isEmpty {
                            return ImageRef(url: storyUrl)
                        }
                        return nil
                    }(),
                    sceneImage: (isWander && wanderUploadMode == .scenarioRole && !sceneImageUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        ? ImageRef(url: sceneImageUrl.trimmingCharacters(in: .whitespacesAndNewlines))
                        : nil,
                    scenePrompt: (isWander && wanderUploadMode == .scenarioRole)
                        ? scenePromptText.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                        : nil,
                    roleImage: (isWander && wanderUploadMode == .scenarioRole && !roleImageUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        ? ImageRef(url: roleImageUrl.trimmingCharacters(in: .whitespacesAndNewlines))
                        : nil,
                    rolePrompt: (isWander && wanderUploadMode == .scenarioRole)
                        ? rolePromptText.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                        : nil,
                    resolution: isWander ? nil : storyResolution.apiValue,
                    layout: isWander ? nil : "Stable",
                    narrative: isWander ? nil : storyNarrative.apiValue
                )
                if let bodyData = try? JSONEncoder().encode(body),
                   let bodyStr = String(data: bodyData, encoding: .utf8) {
                    appLog("[Create] → request body: \(bodyStr)")
                }
                let response = try await env.apiClient.createWorld(body)
                appLog("[Create] ✅ createWorld ok — id: \(response.encryptedWorldId)")
                startPolling(worldId: response.encryptedWorldId, mode: mode)
            } catch let err as APIError {
                appLog("[Create] ❌ createWorld failed: \(err)")
                errorMessage = errorDescription(err)
            } catch {
                appLog("[Create] ❌ createWorld unexpected error: \(error)")
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - creationModel=scriptlist 提交与校验

    private func createScriptListWorld(scriptList: JSONValue) {
        isCreating = true
        errorMessage = nil

        Task {
            defer { isCreating = false }
            do {
                let body = ScriptListWorldRequest(
                    mode: ServerWorldMode.story.rawValue,
                    asyncFlag: true,
                    creationModel: "scriptlist",
                    resolution: storyResolution.apiValue,
                    firstFrameImage: ImageRef(url: scriptFirstFrameUrl.trimmingCharacters(in: .whitespacesAndNewlines)),
                    scriptList: scriptList
                )
                if let bodyData = try? JSONEncoder().encode(body),
                   let bodyStr = String(data: bodyData, encoding: .utf8) {
                    appLog("[Create] → request body: \(bodyStr)")
                }
                let response = try await env.apiClient.createScriptListWorld(body)
                appLog("[Create] ✅ createScriptListWorld ok — id: \(response.encryptedWorldId)")
                startPolling(worldId: response.encryptedWorldId, mode: .story)
            } catch let err as APIError {
                appLog("[Create] ❌ createScriptListWorld failed: \(err)")
                errorMessage = errorDescription(err)
            } catch {
                appLog("[Create] ❌ createScriptListWorld unexpected error: \(error)")
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 提交前本地预校验，对齐服务端强校验（创建独有的首帧图校验 + 共用的 scriptList 结构校验，
    /// 见 `ScriptListJSONValidator`）；校验通过时把已解析的 `JSONValue` 一并带出，提交时直接复用。
    private func validateScriptList() -> ScriptListJSONValidation {
        let firstFrameUrl = scriptFirstFrameUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: firstFrameUrl),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .failure(message: "首帧图需为合法 http(s) URL")
        }
        return ScriptListJSONValidator.validate(text: scriptListText)
    }

    // MARK: - 轮询逻辑

    private func startPolling(worldId: String, mode: ServerWorldMode) {
        switch mode {
        case .wander:
            wanderPollTask?.cancel()
            wanderPollingId  = worldId
            wanderPollStatus = nil
            wanderPollTask   = Task { await pollUntilReady(worldId: worldId, mode: .wander) }
        case .story:
            storyPollTask?.cancel()
            storyPollingId  = worldId
            storyPollStatus = nil
            storyPollTask   = Task { await pollUntilReady(worldId: worldId, mode: .story) }
        }
    }

    @MainActor
    private func pollUntilReady(worldId: String, mode: ServerWorldMode) async {
        while !Task.isCancelled {
            do {
                let s = try await env.apiClient.worldBuildStatus(encryptedWorldId: worldId)
                appLog("[Poll] \(mode == .wander ? "wander" : "story") status=\(s.status)")
                switch mode {
                case .wander: wanderPollStatus = s
                case .story:  storyPollStatus  = s
                }
                switch s.status {
                case .ready:
                    showToast("世界已就绪！")
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    clearPolling(mode: mode)
                    navigation.switchTo(.play)
                    return
                case .failed:
                    clearPolling(mode: mode)
                    errorMessage = "世界生成失败，请重试"
                    return
                case .generating:
                    break
                }
            } catch {
                appLog("[Poll] error: \(error)")
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func clearPolling(mode: ServerWorldMode) {
        switch mode {
        case .wander:
            wanderPollTask?.cancel(); wanderPollTask = nil
            wanderPollingId  = nil
            wanderPollStatus = nil
        case .story:
            storyPollTask?.cancel(); storyPollTask = nil
            storyPollingId  = nil
            storyPollStatus = nil
        }
    }

    private func showToast(_ message: String) {
        withAnimation(.easeInOut(duration: 0.3)) { toast = message }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation(.easeInOut(duration: 0.3)) { toast = nil }
        }
    }

    private func errorDescription(_ error: APIError) -> String {
        switch error {
        case .business(let code, let msg, let rid):
            if code == 403003 { return "该操作需要主 API Key，临时 Key 无权限（403003）" }
            if code == 403004 { return "内容审核未通过：涉及违规内容（403004）" }
            if code == 403005 { return "内容审核未通过：涉及版权/IP 违规（403005）" }
            let ridSuffix = rid.map { " [req:\($0)]" } ?? ""
            return (msg ?? "业务错误 \(code)") + ridSuffix
        case .gateway(let code, let msg, let rid):
            let ridSuffix = rid.map { " [req:\($0)]" } ?? ""
            return "网关错误 \(code)：\(msg ?? "")\(ridSuffix)"
        default:
            return error.localizedDescription
        }
    }
}

// MARK: - 参数枚举

enum WorldPerspective: String, CaseIterable, Identifiable {
    case firstPerson
    case thirdPerson

    var id: String { rawValue }

    var label: String {
        switch self {
        case .firstPerson: return "第一人称"
        case .thirdPerson: return "第三人称"
        }
    }

    /// 服务端要求 snake_case（与 `OysterWorldSpec.Perspective` 对齐）。
    var apiValue: String {
        switch self {
        case .firstPerson: return "first_person"
        case .thirdPerson: return "third_person"
        }
    }
}

enum StoryResolution: String, CaseIterable, Identifiable {
    case r480p = "480p"
    case r720p = "720p"

    var id: String { rawValue }
    var label: String { rawValue }
    var apiValue: String { rawValue }
}

/// Wander 图片子模式（`uploadMode` 字段）。
enum WanderUploadMode: String, CaseIterable, Identifiable {
    /// 首帧图模式（`uploadMode=first_frame`）：可选传一张参考图作为视觉锚点。
    case firstFrame
    /// 场景角色模式（`uploadMode=scenario_role`）：分别提供场景与角色图。
    case scenarioRole

    var id: String { rawValue }

    var label: String {
        switch self {
        case .firstFrame:   return "首帧图"
        case .scenarioRole: return "场景角色"
        }
    }

    /// 传给服务端的 `uploadMode` 值。
    var apiValue: String? {
        switch self {
        case .firstFrame:   return "first_frame"
        case .scenarioRole: return "scenario_role"
        }
    }
}

// MARK: - String helper

private extension String {
    /// 空字符串返回 nil，用于可选字段的空值裁剪。
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Story 创建方式（本地 UI 概念，不直接对应服务端字段；scriptlist 提交时才带
/// `creationModel="scriptlist"`，simple 不发该字段，服务端默认视为 simple）。
enum StoryCreationModel: String, CaseIterable, Identifiable {
    case simple = "simple"
    case scriptlist = "scriptlist"
    var id: String { rawValue }
    var label: String { self == .simple ? "简单" : "剧本" }
}

/// Story 叙事风格（`narrative` 字段）。
enum StoryNarrative: String, CaseIterable, Identifiable {
    case calm     = "Calm"
    case dramatic = "Dramatic"
    case normal   = "Normal"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .calm:     return "平静"
        case .dramatic: return "戏剧性"
        case .normal:   return "标准"
        }
    }

    var apiValue: String { rawValue }
}
