import SwiftUI

/// Create page: a segmented control at the top switches between Wander / Story / Acting modes.
/// Fill in the parameters on each sub-page and tap Create; on success, show a toast and jump to the Play tab.
struct MainView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var navigation: AppNavigation

    @State private var mode: ServerWorldMode = .wander
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var toast: String?

    // MARK: Wander parameters
    @State private var wanderPrompt = ""
    @State private var wanderPerspective: WorldPerspective = .thirdPerson
    /// First-frame image URL (passed through as-is; uploading is up to the caller). Wander only supports `uploadMode=first_frame`,
    /// and the first-frame image is required (either a URL or a locally picked image).
    @State private var firstFrameImageUrl = ""
    /// Local image pick state (mutually exclusive with the URL above; see `imageInputRow`)
    @State private var firstFrameImagePick = LocalImagePickState()

    // MARK: Story parameters
    @State private var storyPrompt = ""
    /// Reference images for Story simple mode: 0 → not sent; 1 → goes to `firstFrameImage`; ≥2 → all go to `inputImages`
    /// (mutually exclusive; see `storyImageFields()`). URL entries and local (base64) entries may be mixed in the list.
    @State private var storyImageEntries: [StoryImageEntry] = []
    @State private var storyImageUrlDraft = ""
    @State private var storyImageError: String?
    @State private var storyResolution: StoryResolution = .r720p

    // MARK: Acting (digital human, mode=3) parameters
    @State private var actingPrompt = ""
    /// First-frame image (URL and local pick are mutually exclusive; see `imageInputRow`). Acting only supports
    /// `uploadMode=first_frame`, and the first-frame image is required.
    @State private var actingFirstFrameUrl = ""
    @State private var actingFirstFramePick = LocalImagePickState()
    /// Server default is 480p (unlike Story, where it is required).
    @State private var actingResolution: StoryResolution = .r480p
    @State private var actingAspectRatio: ActingAspectRatio = .r9x16

    // MARK: Story - creationModel=scriptlist sub-mode
    @State private var storyCreationModel: StoryCreationModel = .simple
    @State private var scriptFirstFrameUrl = ""
    @State private var scriptFirstFramePick = LocalImagePickState()
    @State private var scriptListText = ""
    @State private var selectedPresetId: String?
    @State private var scriptPresets: [ScriptPreset] = []
    /// A local first-frame image is already picked and another template is tapped: don't overwrite the image yet; ask the user to choose,
    /// avoiding a UI/data mismatch where "the new template looks selected but the first frame is still the old local image".
    @State private var pendingPresetImageReplacement: ScriptPreset?

    // MARK: - Polling state (independent per mode: Wander / Story)
    @State private var wanderPollingId: String?
    @State private var wanderPollStatus: BuildStatusResponse?
    @State private var wanderPollTask: Task<Void, Never>?

    @State private var storyPollingId: String?
    @State private var storyPollStatus: BuildStatusResponse?
    @State private var storyPollTask: Task<Void, Never>?

    @State private var actingPollingId: String?
    @State private var actingPollStatus: BuildStatusResponse?
    @State private var actingPollTask: Task<Void, Never>?

    private var currentPollingId: String? {
        switch mode {
        case .wander: return wanderPollingId
        case .story:  return storyPollingId
        case .acting: return actingPollingId
        }
    }
    private var currentPollStatus: BuildStatusResponse? {
        switch mode {
        case .wander: return wanderPollStatus
        case .story:  return storyPollStatus
        case .acting: return actingPollStatus
        }
    }

    // MARK: - Character limits
    private let promptLimitFirstFrame = 4000
    /// Acting prompt limit (per API docs: natural language, max 2000).
    private let promptLimitActing     = 2000

    // MARK: - Focus state (for .focused() bindings; the keyboard is dismissed via the keyboard toolbar "Done" button)
    private enum Field: Hashable {
        case prompt, firstFrameImageUrl, storyImageUrl
        case scriptFirstFrameUrl, scriptListEditor
        case actingFirstFrameUrl
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
            .navigationTitle("Create")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .bottom) { toastBanner }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .task { await loadScriptPresetsIfNeeded() }
            // Use `.alert` rather than `.confirmationDialog`: the latter shows as a popover on iPad,
            // where the system treats the `.cancel`-role button as "tap outside to dismiss" and doesn't render it, so
            // only one button shows and users think there's no "keep" option. `.alert` reliably shows
            // both buttons on all devices.
            .alert(
                "This template includes a first-frame image",
                isPresented: Binding(
                    get: { pendingPresetImageReplacement != nil },
                    set: { if !$0 { pendingPresetImageReplacement = nil } }
                ),
                presenting: pendingPresetImageReplacement
            ) { preset in
                Button("Yes, Replace") { replaceFirstFrameWithPresetImage(preset) }
                Button("No, Keep Original", role: .cancel) { pendingPresetImageReplacement = nil }
            } message: { _ in
                Text("Replace the local image you selected?")
            }
        }
        .navigationViewStyle(.stack)
    }

    /// Prefetch the preset list before first entering the Story script sub-mode; skip if already loaded.
    private func loadScriptPresetsIfNeeded() async {
        guard scriptPresets.isEmpty else { return }
        let presets = await ScriptPresetProvider().loadPresets()
        scriptPresets = presets
        if selectedPresetId == nil, let first = presets.first {
            applyScriptPreset(first)
        }
    }

    // MARK: - Global toolbar (pinned below the picker; position doesn't change with form content)

    @ViewBuilder
    private var globalToolbar: some View {
        HStack(spacing: 8) {
            switch mode {
            case .wander:
                // Wander only supports uploadMode=first_frame; there's no sub-mode to switch, so no pill.
                perspectiveMenuButton(selection: $wanderPerspective)
            case .story:
                creationModelMenuButton
                resolutionMenuButton(selection: $storyResolution)
            case .acting:
                // Acting has no scriptlist sub-mode and no layout;
                // uploadMode is fixed to first_frame, so no pill either.
                resolutionMenuButton(selection: $actingResolution)
                actingAspectRatioMenuButton
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            Text("Wander").tag(ServerWorldMode.wander)
            Text("Story").tag(ServerWorldMode.story)
            Text("Acting").tag(ServerWorldMode.acting)
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
                } else if mode == .story && storyCreationModel == .scriptlist {
                    scriptListSection
                } else {
                    promptCard
                    if mode == .wander {
                        firstFrameImageCard
                    }
                    if mode == .story {
                        storyImageCard
                    }
                    if mode == .acting {
                        actingFirstFrameImageCard
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

    // MARK: - Building status view (replaces the input area while polling)

    @ViewBuilder
    private var buildingStatusView: some View {
        VStack(spacing: 16) {
            // Preview image / placeholder gradient
            buildingPreview
                .frame(height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)

            // Status info
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
                    Text("Fetching world info…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)

            // Cancel button
            Button {
                clearPolling(mode: mode)
            } label: {
                Text("Cancel and Go Back")
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
            colors: mode.cardGradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func buildingStatusBadge(_ status: ServerWorldStatus) -> some View {
        HStack(spacing: 6) {
            switch status {
            case .generating:
                ProgressView().scaleEffect(0.7)
                Text("Generating…")
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Ready")
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text("Generation Failed")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    // MARK: - Prompt card (shared by textOnly / firstFrame / Story / Acting)

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("World Description")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer()
                switch mode {
                case .wander:
                    charCountLabel(wanderPrompt.count, limit: promptLimitFirstFrame)
                case .story:
                    charCountLabel(storyPrompt.count, limit: promptLimitFirstFrame)
                case .acting:
                    charCountLabel(actingPrompt.count, limit: promptLimitActing)
                }
            }
            .padding(.horizontal)

            VStack(spacing: 0) {
                TextEditor(text: promptBinding)
                    .focused($focusedField, equals: .prompt)
                    .font(.body)
                    .frame(minHeight: 120, maxHeight: 200)
                    .padding(12)
                    .overlay(alignment: .topLeading) {
                        let prompt = promptBinding.wrappedValue
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
                        if mode == .wander && val.count > promptLimitFirstFrame {
                            wanderPrompt = String(val.prefix(promptLimitFirstFrame))
                        }
                    })
                    .onChange(of: storyPrompt, perform: { val in
                        if mode == .story && val.count > promptLimitFirstFrame {
                            storyPrompt = String(val.prefix(promptLimitFirstFrame))
                        }
                    })
                    .onChange(of: actingPrompt, perform: { val in
                        if mode == .acting && val.count > promptLimitActing {
                            actingPrompt = String(val.prefix(promptLimitActing))
                        }
                    })
            }
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator), lineWidth: 0.5))
            .padding(.horizontal)
        }
    }

    /// Prompt binding for the current mode.
    private var promptBinding: Binding<String> {
        switch mode {
        case .wander: return $wanderPrompt
        case .story:  return $storyPrompt
        case .acting: return $actingPrompt
        }
    }

    // MARK: - Reference image list card (shared by Story / Acting)

    /// Reference image list for Story simple mode: 1 → `firstFrameImage`, ≥2 → `inputImages` (mutually exclusive).
    private var storyImageCard: some View {
        imageListCard(
            title: "Reference Images (multiple allowed)",
            entries: $storyImageEntries,
            urlDraft: $storyImageUrlDraft,
            error: $storyImageError,
            field: .storyImageUrl,
            footnote: "Up to \(StoryImageLimit.maxCount) images (\(storyImageEntries.count)/\(StoryImageLimit.maxCount)), URLs and local images combined. A single image is used as the first frame; 2 or more all go to inputImages (mutually exclusive). URLs and local images (auto-encoded as base64) can be mixed in the list."
        )
    }

    private func imageListCard(
        title: LocalizedStringKey,
        entries: Binding<[StoryImageEntry]>,
        urlDraft: Binding<String>,
        error: Binding<String?>,
        field: Field,
        footnote: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            VStack(spacing: 0) {
                ForEach(entries.wrappedValue) { entry in
                    imageEntryRow(entry, entries: entries)
                    Divider()
                }

                if entries.wrappedValue.count < StoryImageLimit.maxCount {
                    imageListAddRow(entries: entries, urlDraft: urlDraft, error: error, field: field)
                }

                if let message = error.wrappedValue {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                }

                Divider()

                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(footnote)
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

    /// One added reference image: local images show a thumbnail, URL entries show the link text; both have a "Remove" button.
    private func imageEntryRow(_ entry: StoryImageEntry, entries: Binding<[StoryImageEntry]>) -> some View {
        HStack(spacing: 10) {
            if let preview = entry.preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text("Local image (converted to base64 on submit)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                Text(entry.url ?? "")
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Remove") {
                entries.wrappedValue.removeAll { $0.id == entry.id }
            }
            .font(.subheadline)
        }
        .padding(12)
    }

    /// Input row for adding a new entry: when the URL field loses focus (Return / switching fields / dismissing the keyboard) it's appended automatically,
    /// with no extra "Add" tap — `focusedField` changing from this row's `field` to anything else counts as losing focus; Return goes through
    /// `onSubmit` and adds immediately. Both paths call the same `addImageURL(...)`, which is idempotent for an empty draft.
    private func imageListAddRow(
        entries: Binding<[StoryImageEntry]>,
        urlDraft: Binding<String>,
        error: Binding<String?>,
        field: Field
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
                .font(.subheadline)
            TextField("Image URL (optional, added automatically when focus leaves)", text: urlDraft)
                .focused($focusedField, equals: field)
                .font(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { addImageURL(entries: entries, urlDraft: urlDraft, error: error) }
                .onChange(of: focusedField, perform: { newValue in
                    if newValue != field {
                        addImageURL(entries: entries, urlDraft: urlDraft, error: error)
                    }
                })
            MultiPhotoPickerButton(selectionLimit: StoryImageLimit.maxCount - entries.wrappedValue.count) { items in
                applyLocalImages(items, entries: entries, error: error)
            } onFailure: { failureCount, firstReason in
                showToast(failureCount > 1 ? String(localized: "Failed to read \(failureCount) images. One of them: \(firstReason)") : String(localized: "Failed to pick image: \(firstReason)"))
            }
        }
        .padding(12)
    }

    /// Append the URL in the draft field as a new reference image entry; reject if the count limit (URL and local images combined) is reached.
    private func addImageURL(
        entries: Binding<[StoryImageEntry]>,
        urlDraft: Binding<String>,
        error: Binding<String?>
    ) {
        let trimmed = urlDraft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard entries.wrappedValue.count < StoryImageLimit.maxCount else {
            error.wrappedValue = String(localized: "You can add up to \(StoryImageLimit.maxCount) reference images")
            return
        }
        error.wrappedValue = nil
        entries.wrappedValue.append(StoryImageEntry(url: trimmed))
        urlDraft.wrappedValue = ""
    }

    /// Validate each locally multi-picked image's size (≤10MB, no compression or transcoding) and append it as an entry, subject to the total limit
    /// (shares the same `StoryImageLimit.maxCount` with URL entries regardless of source); oversized images and those beyond the count limit
    /// are skipped with a notice, without affecting the other images that were added successfully.
    private func applyLocalImages(
        _ items: [(data: Data, preview: UIImage)],
        entries: Binding<[StoryImageEntry]>,
        error: Binding<String?>
    ) {
        appLog("[MainView] applyLocalImages items.count=\(items.count) existing=\(entries.wrappedValue.count)")
        error.wrappedValue = nil
        var oversized = 0
        var overLimit = 0
        for (index, item) in items.enumerated() {
            guard entries.wrappedValue.count < StoryImageLimit.maxCount else {
                appLog("[MainView] ⚠️ image #\(index + 1) exceeds the count limit, skipping")
                overLimit += 1
                continue
            }
            guard item.data.count <= LocalImageLimit.maxBytes else {
                appLog("[MainView] ⚠️ image #\(index + 1) exceeds 10MB (\(item.data.count) bytes), skipping")
                oversized += 1
                continue
            }
            entries.wrappedValue.append(StoryImageEntry(base64: item.data.base64EncodedString(), preview: item.preview))
            appLog("[MainView] ✅ image #\(index + 1) added to list data.count=\(item.data.count)")
        }
        var messages: [String] = []
        if oversized > 0 { messages.append(String(localized: "\(oversized) images exceed 10MB")) }
        if overLimit > 0 { messages.append(String(localized: "\(overLimit) images exceed the \(StoryImageLimit.maxCount)-image limit")) }
        if !messages.isEmpty {
            let joined = messages.joined(separator: String(localized: ", ", comment: "List separator between skipped-image reasons"))
            error.wrappedValue = String(localized: "\(joined), skipped")
        }
        appLog("[MainView] applyLocalImages done, total after adding=\(entries.wrappedValue.count)")
    }

    /// Map Story simple-mode reference images: 0 → not sent; 1 → `firstFrameImage`; ≥2 → all to `inputImages`
    /// (mutually exclusive; sending both conflicts at the API level). Wander / acting don't follow this rule — they only support
    /// `uploadMode=first_frame`, where the first-frame image is a separate required input card.
    private func storyImageFields() -> (firstFrameImage: ImageRef?, inputImages: [ImageRef]?) {
        let refs = storyImageEntries.map { $0.imageRef }
        if refs.count <= 1 {
            return (refs.first, nil)
        }
        return (nil, refs)
    }

    // MARK: - Story creationModel=scriptlist form

    private var scriptListSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            scriptPresetPickerCard
            scriptFirstFrameImageCard
            scriptListEditorCard
        }
    }

    /// Script template menu: selecting one fills its `scriptList` into the JSON editor below.
    private var scriptPresetPickerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Script Template")
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
                    Text(scriptPresets.first(where: { $0.id == selectedPresetId })?.label ?? String(localized: "Select Template"))
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
        errorMessage = nil

        guard let url = preset.firstFrameImageUrl, !url.isEmpty else { return }

        if scriptFirstFramePick.base64 != nil {
            // A local first-frame image is already picked: leave it alone until the user explicitly chooses "Replace" or "Keep" in the alert,
            // avoiding a mismatch where the template menu shows "selected" but the first frame is still the old image.
            pendingPresetImageReplacement = preset
        } else {
            scriptFirstFrameUrl = url
        }
    }

    /// The user chose "replace with the template's first frame" in the alert: clear the local image state and use the template's URL.
    private func replaceFirstFrameWithPresetImage(_ preset: ScriptPreset) {
        guard let url = preset.firstFrameImageUrl, !url.isEmpty else {
            pendingPresetImageReplacement = nil
            return
        }
        scriptFirstFramePick = LocalImagePickState()
        scriptFirstFrameUrl = url
        pendingPresetImageReplacement = nil
    }

    /// First-frame image URL card (required; only validates a well-formed http(s) URL); styled like `firstFrameImageCard`.
    private var scriptFirstFrameImageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("First-Frame Image (required)")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            VStack(spacing: 0) {
                imageInputRow(
                    placeholder: "First-frame image URL (http/https)",
                    urlText: $scriptFirstFrameUrl,
                    pick: $scriptFirstFramePick,
                    focusField: .scriptFirstFrameUrl
                )

                Divider()

                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Used directly as the world's first frame, skipping AI first-frame generation. You can also tap the icon on the right to pick from your photo library; the app encodes it as base64 and submits it.")
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

    /// Large text editor for scriptList JSON (prefilled from the preset), monospaced for readability.
    private var scriptListEditorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Script scriptList (JSON, required)")
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

    // MARK: - Image input (URL or local pick; shared by all `firstFrameImage` inputs)

    /// Image input row: a URL text field + a "pick local image" button on the right; once a local image is picked, the URL input is hidden
    /// and replaced with a thumbnail + Remove button. The UI state switch keeps `ImageRef.url`/`base64` mutually exclusive, with no extra
    /// two-way clearing logic.
    private func imageInputRow(
        placeholder: LocalizedStringKey,
        urlText: Binding<String>,
        pick: Binding<LocalImagePickState>,
        focusField: Field
    ) -> some View {
        Group {
            if let preview = pick.wrappedValue.preview {
                HStack(spacing: 10) {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Text("Local image selected (converted to base64 on submit)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Remove") { pick.wrappedValue = LocalImagePickState() }
                        .font(.subheadline)
                }
                .padding(12)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    TextField(placeholder, text: urlText)
                        .focused($focusedField, equals: focusField)
                        .font(.body)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    PhotoPickerButton(
                        onPick: { data, preview in applyLocalImage(data: data, preview: preview, urlText: urlText, to: pick) },
                        onFailure: { reason in showToast(String(localized: "Failed to pick image: \(reason)")) }
                    )
                }
                .padding(12)
            }
            if let err = pick.wrappedValue.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
        }
    }

    /// After picking a local image, convert it to base64 as-is (no transcoding or compression); only check the decoded (original file) size ≤10MB, otherwise ask for another image.
    /// Also clears the URL field — the two are mutually exclusive, so a hidden stale URL shouldn't linger once a local image is picked.
    private func applyLocalImage(data: Data, preview: UIImage, urlText: Binding<String>, to pick: Binding<LocalImagePickState>) {
        appLog("[MainView] applyLocalImage data.count=\(data.count)")
        guard data.count <= LocalImageLimit.maxBytes else {
            appLog("[MainView] ❌ applyLocalImage exceeds 10MB, not setting input state")
            pick.wrappedValue = LocalImagePickState(error: String(localized: "Image exceeds 10MB. Please choose another one."))
            return
        }
        urlText.wrappedValue = ""
        let base64 = data.base64EncodedString()
        pick.wrappedValue = LocalImagePickState(base64: base64, preview: preview)
        appLog("[MainView] ✅ applyLocalImage set input state base64.count=\(base64.count)")
    }

    /// Build an `ImageRef` from the URL text + local pick state: the local image wins (`imageInputRow` already keeps them mutually exclusive);
    /// returns nil if both are empty (for optional fields, meaning the field isn't sent).
    private func imageRef(url: String, pick: LocalImagePickState) -> ImageRef? {
        if let base64 = pick.base64 { return ImageRef(base64: base64) }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : ImageRef(url: trimmed)
    }

    /// Whether the required first-frame image is provided: either a URL or a local pick counts.
    private func hasImage(url: String, pick: LocalImagePickState) -> Bool {
        imageRef(url: url, pick: pick) != nil
    }

    // MARK: - First frame image card

    private var firstFrameImageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("First-Frame Image (required)")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            VStack(spacing: 0) {
                imageInputRow(
                    placeholder: "Image URL (required)",
                    urlText: $firstFrameImageUrl,
                    pick: $firstFrameImagePick,
                    focusField: .firstFrameImageUrl
                )

                Divider()

                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("First-frame image required: enter a URL to pass directly to the API, or tap the icon on the right to pick from your photo library; the app encodes it as base64 and submits it.")
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

    /// Acting first-frame image (required). The server validates its aspect ratio against the current frame format;
    /// for local picks the app checks first (see `validateActingFirstFrameAspectRatio()`) to avoid a wasted 400000 round trip.
    private var actingFirstFrameImageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("First-Frame Image firstFrameImage (required)")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            VStack(spacing: 0) {
                imageInputRow(
                    placeholder: "Image URL (required)",
                    urlText: $actingFirstFrameUrl,
                    pick: $actingFirstFramePick,
                    focusField: .actingFirstFrameUrl
                )

                Divider()

                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("First-frame image required; it is reused as the world's first frame. The server validates the aspect ratio against the current format \(actingAspectRatio.rawValue) (\(actingAspectRatio.ratioHint)) and returns 400000 if it doesn't match.")
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

    // MARK: - Toolbar buttons

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

    /// Resolution pill. Story and Acting each hold their own state (different defaults: Story 720p / Acting 480p),
    /// so it's passed in as a binding, following the same pattern as `perspectiveMenuButton(selection:)`.
    private func resolutionMenuButton(selection: Binding<StoryResolution>) -> some View {
        Menu {
            ForEach(StoryResolution.allCases) { r in
                Button {
                    selection.wrappedValue = r
                } label: {
                    HStack {
                        Text(r.label)
                        if selection.wrappedValue == r { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            toolbarPill(icon: "arrow.up.left.and.arrow.down.right", title: selection.wrappedValue.label)
        }
    }

    /// Acting frame-format pill (`aspectRatio`). The icon follows the current value's orientation; values come from the enum,
    /// so adding 3:4 / 4:3 later only requires extending the enum, not changing this.
    private var actingAspectRatioMenuButton: some View {
        Menu {
            ForEach(ActingAspectRatio.allCases) { r in
                Button {
                    actingAspectRatio = r
                } label: {
                    HStack {
                        Text(r.label)
                        if actingAspectRatio == r { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            toolbarPill(
                icon: actingAspectRatio.isPortrait ? "rectangle.portrait" : "rectangle",
                title: actingAspectRatio.label
            )
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
        // The transaction takes priority over a parent withAnimation (including animations triggered inside Menu),
        // so the Capsule background jumps immediately when the label width changes, without truncated transition frames.
        .transaction { $0.animation = nil }
    }

    // MARK: - Character counter

    private func charCountLabel(_ count: Int, limit: Int) -> some View {
        Text(verbatim: "\(count) / \(limit)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(count > limit ? Color.red : Color(.tertiaryLabel))
    }

    // MARK: - Create button

    private var createButton: some View {
        let disabled = isCreateDisabled
        return Button(action: createWorld) {
            HStack(spacing: 8) {
                if isCreating {
                    ProgressView().scaleEffect(0.85).tint(.white)
                }
                (isCreating ? Text("Creating…") : Text("Create World"))
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

    /// Enable condition per mode: Create is tappable once required fields are non-empty.
    private var isCreateDisabled: Bool {
        if isCreating { return true }
        switch mode {
        case .story:
            if storyCreationModel == .scriptlist {
                // Fine-grained errors come from validateScriptList() on tap; this is only a coarse non-empty check.
                // First-frame URL or local pick: either being non-empty counts as filled.
                let hasFirstFrame = !scriptFirstFrameUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || scriptFirstFramePick.base64 != nil
                return scriptListText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !hasFirstFrame
            }
            // Prompt is required; reference images are optional
            return storyPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .acting:
            // Acting only has the first_frame sub-mode: both prompt and first-frame image are required.
            return actingPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !hasImage(url: actingFirstFrameUrl, pick: actingFirstFramePick)
        case .wander:
            // Wander only has the first_frame sub-mode: both prompt and first-frame image are required.
            return wanderPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !hasImage(url: firstFrameImageUrl, pick: firstFrameImagePick)
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
        switch mode {
        case .wander: return String(localized: "Describe your world, e.g. an ancient city floating above the clouds…")
        case .story:  return String(localized: "Describe the story background, e.g. in the distant future, humanity has moved to Mars…")
        case .acting: return String(localized: "Describe the digital human's persona and scene, e.g. a late-night video call with a quiet girl…")
        }
    }

    // MARK: - Create request

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

        // Local aspect-ratio check for the acting first frame: local picks have real dimensions, so catch it early and save a guaranteed 400000 round trip.
        if let aspectRatioError = validateActingFirstFrameAspectRatio() {
            errorMessage = aspectRatioError
            return
        }

        isCreating = true
        errorMessage = nil

        Task {
            defer { isCreating = false }
            do {
                let body = makeCreateWorldRequest()
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

    /// Build the create request body per mode. **Every optional field is resolved via `switch mode`**, not a binary "not wander means story"
    /// check — the three modes have different field whitelists, and a binary check would make acting silently inherit Story's
    /// `layout`, which the server rejects with 400000.
    private func makeCreateWorldRequest() -> CreateWorldRequest {
        let isWander = mode == .wander

        // Send null when the user left it empty (the server accepts a missing field but not an empty string).
        let prompt: String? = promptBinding.wrappedValue
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        // Story's two reference image fields are mutually exclusive (1 → first frame / ≥2 → inputImages);
        // wander / acting only support first_frame, always submit firstFrameImage, and never send inputImages.
        let storyImages = mode == .story ? storyImageFields() : (firstFrameImage: nil, inputImages: nil)

        let firstFrameImage: ImageRef? = {
            switch mode {
            case .wander:
                return imageRef(url: firstFrameImageUrl, pick: firstFrameImagePick)
            case .story:
                return storyImages.firstFrameImage
            case .acting:
                return imageRef(url: actingFirstFrameUrl, pick: actingFirstFramePick)
            }
        }()

        // Wander / acting are fixed to the first_frame sub-mode; Story doesn't accept uploadMode.
        let uploadMode: String? = mode == .story ? nil : "first_frame"

        let resolution: String? = {
            switch mode {
            case .wander: return nil
            case .story:  return storyResolution.apiValue
            case .acting: return actingResolution.apiValue
            }
        }()

        return CreateWorldRequest(
            mode: mode.rawValue,
            async_: true,
            prompt: prompt,
            // Acting must not send eventStyle: it would block the server's uploadMode → eventStyle mapping.
            eventStyle: nil,
            refWorldId: nil,
            perspective: isWander ? wanderPerspective.apiValue : nil,
            uploadMode: uploadMode,
            firstFrameImage: firstFrameImage,
            // scenario_role fields are no longer supported by the demo (wander only uses first_frame).
            sceneImage: nil,
            scenePrompt: nil,
            roleImage: nil,
            rolePrompt: nil,
            inputImages: storyImages.inputImages,
            resolution: resolution,
            // layout is Story-only: sending it for acting is rejected as invalid parameters.
            layout: mode == .story ? "Stable" : nil,
            // aspectRatio only applies to acting; not sent for other modes.
            aspectRatio: mode == .acting ? actingAspectRatio.apiValue : nil
        )
    }

    /// When acting uses a **local image**, validate the first frame's aspect ratio against the current frame format
    /// (server rule: `16:9` → 1.5~2.0, `9:16` → 0.5~0.667, otherwise 400000).
    /// URL images have no known size, so the server decides; returning nil means pass.
    private func validateActingFirstFrameAspectRatio() -> String? {
        guard mode == .acting,
              let preview = actingFirstFramePick.preview else { return nil }
        let size = preview.size
        guard size.height > 0 else { return nil }
        let ratio = size.width / size.height
        let range = actingAspectRatio.allowedRatioRange
        guard !range.contains(ratio) else { return nil }
        return String(
            format: String(localized: "First-frame aspect ratio %.2f doesn't meet the %@ format requirement (%@). Please change the image or switch the format."),
            ratio, actingAspectRatio.rawValue, actingAspectRatio.ratioHint
        )
    }

    // MARK: - creationModel=scriptlist submission and validation

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
                    firstFrameImage: imageRef(url: scriptFirstFrameUrl, pick: scriptFirstFramePick)
                        ?? ImageRef(url: scriptFirstFrameUrl.trimmingCharacters(in: .whitespacesAndNewlines)),
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

    /// Local pre-validation before submitting, matching the server's strict checks (create-only first-frame check + shared scriptList structure check,
    /// see `ScriptListJSONValidator`); on success the parsed `JSONValue` is returned and reused for submission.
    private func validateScriptList() -> ScriptListJSONValidation {
        // Skip URL format validation when a local image (base64) is picked; they're mutually exclusive and `imageInputRow` ensures both aren't set.
        if scriptFirstFramePick.base64 == nil {
            let firstFrameUrl = scriptFirstFrameUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: firstFrameUrl),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return .failure(message: String(localized: "The first-frame image must be a valid http(s) URL, or pick one from your photo library instead."))
            }
        }
        return ScriptListJSONValidator.validate(text: scriptListText)
    }

    // MARK: - Polling logic

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
        case .acting:
            actingPollTask?.cancel()
            actingPollingId  = worldId
            actingPollStatus = nil
            actingPollTask   = Task { await pollUntilReady(worldId: worldId, mode: .acting) }
        }
    }

    @MainActor
    private func pollUntilReady(worldId: String, mode: ServerWorldMode) async {
        while !Task.isCancelled {
            do {
                let s = try await env.apiClient.worldBuildStatus(encryptedWorldId: worldId, mode: mode)
                appLog("[Poll] \(mode.badgeLabel) status=\(s.status)")
                switch mode {
                case .wander: wanderPollStatus = s
                case .story:  storyPollStatus  = s
                case .acting: actingPollStatus = s
                }
                switch s.status {
                case .ready:
                    showToast(String(localized: "World is ready!"))
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    clearPolling(mode: mode)
                    // Pass the new world's mode: the Play page filter has no "All", so without it the page stays on
                    // the last selected mode and the user wouldn't see the world just created.
                    navigation.switchToPlay(mode: mode)
                    return
                case .failed:
                    clearPolling(mode: mode)
                    errorMessage = String(localized: "World generation failed. Please try again.")
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
        case .acting:
            actingPollTask?.cancel(); actingPollTask = nil
            actingPollingId  = nil
            actingPollStatus = nil
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
            if code == 403003 { return String(localized: "This action requires the primary API key; temporary keys aren't permitted (403003)") }
            if code == 403004 { return String(localized: "Content moderation failed: prohibited content (403004)") }
            if code == 403005 { return String(localized: "Content moderation failed: copyright/IP violation (403005)") }
            if code == 403007 { return String(localized: "This tier isn't enabled: Acting mode is globally disabled or not enabled for this account (403007)") }
            let ridSuffix = rid.map { " [req:\($0)]" } ?? ""
            return (msg ?? String(localized: "Business error \(code)")) + ridSuffix
        case .gateway(let code, let msg, let rid):
            let ridSuffix = rid.map { " [req:\($0)]" } ?? ""
            let message = msg ?? ""
            return String(localized: "Gateway error \(code): \(message)\(ridSuffix)")
        default:
            return error.localizedDescription
        }
    }
}

// MARK: - Parameter enums

enum WorldPerspective: String, CaseIterable, Identifiable {
    case firstPerson
    case thirdPerson

    var id: String { rawValue }

    var label: String {
        switch self {
        case .firstPerson: return String(localized: "First Person")
        case .thirdPerson: return String(localized: "Third Person")
        }
    }

    /// The server requires snake_case (aligned with `OysterWorldSpec.Perspective`).
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

/// Acting frame aspect ratio (`aspectRatio` field, only effective for `mode=3`).
/// Named by the ratio itself rather than portrait/landscape: when the server adds `3:4` / `4:3`, just add a case —
/// orientation, icon, and validation range are all derived from the ratio, so UI and submission logic stay unchanged.
enum ActingAspectRatio: String, CaseIterable, Identifiable {
    case r9x16 = "9:16"
    case r16x9 = "16:9"

    var id: String { rawValue }
    var apiValue: String { rawValue }

    /// Width / height.
    private var ratio: Double {
        let parts = rawValue.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > 0 else { return 1 }
        return parts[0] / parts[1]
    }

    var isPortrait: Bool { ratio < 1 }

    var label: String { isPortrait ? String(localized: "\(rawValue) Portrait") : String(localized: "\(rawValue) Landscape") }

    /// Server-allowed range for the first frame's aspect ratio: `16:9` → 1.5~2.0, `9:16` → 0.5~0.667.
    /// Derived from the nominal ratio, so new ratios don't need entries here.
    var allowedRatioRange: ClosedRange<Double> {
        isPortrait ? 0.5...0.667 : 1.5...2.0
    }

    var ratioHint: String {
        String(format: String(localized: "W/H %.2f ~ %.2f"), allowedRatioRange.lowerBound, allowedRatioRange.upperBound)
    }
}

// MARK: - String helper

private extension String {
    /// Returns nil for an empty string; used to trim empty optional fields.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Story creation method (a local UI concept, not a direct server field; only scriptlist submissions include
/// `creationModel="scriptlist"`; simple omits the field and the server treats it as simple by default).
enum StoryCreationModel: String, CaseIterable, Identifiable {
    case simple = "simple"
    case scriptlist = "scriptlist"
    var id: String { rawValue }
    var label: String { self == .simple ? String(localized: "Simple") : String(localized: "Script") }
}

