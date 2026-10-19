import SwiftUI

struct SecondaryView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var navigation: AppNavigation

    @State private var worlds: [WorldListItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    @State private var selectedWorld: WorldListItem?
    @State private var worldToDelete: WorldListItem?
    @State private var isDeleting = false
    @State private var worldToShowDetail: WorldListItem?
    /// The world mode currently shown. **There is no "All"**: since models are split by mode, the world
    /// list request must carry one concrete mode (the server uses it to pick the gateway route), so "All" can't be expressed.
    /// How it is passed is a convention of this demo's server; see `APIClient.modeHeaderField`.
    @State private var filterMode: ServerWorldMode = .wander

    // MARK: Pagination
    private let pageSize = 20
    @State private var currentPage = 1
    @State private var hasMore = false
    @State private var isLoadingMore = false

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        NavigationView {
            Group {
                if isLoading && worlds.isEmpty {
                    loadingView
                } else if let error = errorMessage, worlds.isEmpty {
                    errorView(error)
                } else if worlds.isEmpty && hasLoaded {
                    emptyView
                } else {
                    gridView
                }
            }
            .navigationTitle("Play")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    filterPicker
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isLoading {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button { Task { await loadWorlds() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            // First appearance: consume the mode requested by the create flow before fetching, to avoid a wasted fetch with the old mode.
            .task {
                consumePendingPlayMode()
                await loadWorlds()
            }
            // When this page is already alive (TabView keeps pages it has built) and we jump here from the create page, this path runs.
            .onChange(of: navigation.pendingPlayMode) { _ in
                guard consumePendingPlayMode() else { return }
                Task { await loadWorlds() }
            }
        }
        .navigationViewStyle(.stack)
    }

    /// Takes the display mode requested by the create flow and resets it to nil (one-shot; see `AppNavigation.pendingPlayMode`).
    /// Returns whether the filter actually changed; if not, the list doesn't need to be refetched.
    @discardableResult
    private func consumePendingPlayMode() -> Bool {
        guard let pending = navigation.pendingPlayMode else { return false }
        navigation.pendingPlayMode = nil
        guard pending != filterMode else { return false }
        filterMode = pending
        return true
    }

    // MARK: - Filter picker

    private var filterPicker: some View {
        Menu {
            Button {
                guard filterMode != .wander else { return }
                filterMode = .wander
                Task { await loadWorlds() }
            } label: {
                HStack {
                    Text("Wander")
                    if filterMode == .wander { Image(systemName: "checkmark") }
                }
            }
            Button {
                guard filterMode != .story else { return }
                filterMode = .story
                Task { await loadWorlds() }
            } label: {
                HStack {
                    Text("Story")
                    if filterMode == .story { Image(systemName: "checkmark") }
                }
            }
            Button {
                guard filterMode != .acting else { return }
                filterMode = .acting
                Task { await loadWorlds() }
            } label: {
                HStack {
                    Text("Acting")
                    if filterMode == .acting { Image(systemName: "checkmark") }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text(filterMode.badgeLabel)
                    .font(.subheadline)
            }
            .foregroundStyle(Color.accentColor)
        }
    }

    // MARK: - Grid

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(worlds) { world in
                    WorldCard(world: world)
                        .onTapGesture {
                            if world.status == .ready {
                                selectedWorld = world
                            }
                        }
                        .opacity(world.status == .ready ? 1 : 0.55)
                        .onAppear {
                            if world.id == worlds.last?.id {
                                Task { await loadMoreWorlds() }
                            }
                        }
                        .contextMenu {
                            Button {
                                worldToShowDetail = world
                            } label: {
                                Label("World Info", systemImage: "info.circle")
                            }
                            Divider()
                            Button(role: .destructive) {
                                worldToDelete = world
                            } label: {
                                Label("Delete World", systemImage: "trash")
                            }
                        }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if isLoadingMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        }
        .refreshable { await loadWorlds() }
        .fullScreenCover(item: $selectedWorld) { world in
            TravelView(world: world)
                .environmentObject(env)
        }
        .alert("Delete World", isPresented: Binding(
            get: { worldToDelete != nil },
            set: { if !$0 { worldToDelete = nil } }
        ), presenting: worldToDelete) { world in
            Button("Delete", role: .destructive) {
                Task { await deleteWorld(world) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { world in
            Text("Are you sure you want to delete “\(world.name ?? world.encryptedWorldId.prefix(12).description)”? This action cannot be undone.")
        }
        .sheet(item: $worldToShowDetail) { world in
            WorldDetailSheet(world: world)
                .environmentObject(env)
        }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "globe.desk")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text("No worlds yet")
                .font(.title3)
                .fontWeight(.medium)
            Text("Generate your first world on the Create tab")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") { Task { await loadWorlds() } }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Load

    /// Reset to the first page (called on pull-to-refresh and filter changes)
    @MainActor
    private func loadWorlds() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false; hasLoaded = true }
        do {
            let result = try await env.apiClient.listWorlds(
                page: 1, pageSize: pageSize, mode: filterMode
            )
            worlds = result.items
            currentPage = 1
            hasMore = result.pagination.hasMore
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Load the next page (called when scrolling to the bottom)
    @MainActor
    private func loadMoreWorlds() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let nextPage = currentPage + 1
            let result = try await env.apiClient.listWorlds(
                page: nextPage, pageSize: pageSize, mode: filterMode
            )
            // Deduplicate before appending, to avoid duplicates when refresh and load-more run concurrently
            let existingIds = Set(worlds.map(\.encryptedWorldId))
            let newItems = result.items.filter { !existingIds.contains($0.encryptedWorldId) }
            worlds.append(contentsOf: newItems)
            currentPage = nextPage
            hasMore = result.pagination.hasMore
        } catch {
            // A failed load-more doesn't replace the existing list; keep hasMore so it can retry next time
        }
    }

    // MARK: - Delete

    @MainActor
    private func deleteWorld(_ world: WorldListItem) async {
        worldToDelete = nil
        do {
            _ = try await env.apiClient.deleteWorld(encryptedWorldId: world.encryptedWorldId, mode: world.mode)
            worlds.removeAll { $0.encryptedWorldId == world.encryptedWorldId }
        } catch {
            errorMessage = String(localized: "Delete failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - World Card

private struct WorldCard: View {
    let world: WorldListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            previewArea
            infoArea
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
    }

    // MARK: Preview (previewUrl is usually null for now; show a placeholder gradient)

    private var previewArea: some View {
        ZStack(alignment: .topTrailing) {
            if let urlStr = world.previewUrl, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholderGradient
                    }
                }
            } else {
                placeholderGradient
            }
            modeBadge
                .padding(8)
        }
        .frame(height: 120)
        .clipped()
    }

    private var placeholderGradient: some View {
        LinearGradient(
            colors: world.mode.cardGradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: world.mode.cardIconName)
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var modeBadge: some View {
        Text(world.mode.badgeLabel)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: Info

    private var infoArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(world.name ?? String(world.encryptedWorldId.prefix(12)))
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(2)
                .foregroundStyle(.primary)

            HStack(spacing: 6) {
                statusBadge
                Spacer(minLength: 0)
                if let date = formattedDate {
                    Text(date)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusLabel)
                .font(.system(size: 11))
                .foregroundStyle(statusColor)
        }
    }

    private var statusColor: Color {
        switch world.status {
        case .ready:      return .green
        case .generating: return .orange
        case .failed:     return .red
        }
    }

    private var statusLabel: String {
        switch world.status {
        case .ready:      return String(localized: "Ready")
        case .generating: return String(localized: "Generating")
        case .failed:     return String(localized: "Failed")
        }
    }

    private var formattedDate: String? {
        guard let raw = world.createdAt else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = iso.date(from: raw) else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM/dd"
        return fmt.string(from: date)
    }
}

// MARK: - World Detail Sheet

private struct WorldDetailSheet: View {
    @EnvironmentObject private var env: AppEnvironment
    let world: WorldListItem

    @State private var detail: WorldDetailResponse?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let msg = errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 36))
                            .foregroundStyle(.orange)
                        Text(msg)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let d = detail {
                    detailContent(d)
                }
            }
            .navigationTitle("World Info")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
        .task { await loadDetail() }
    }

    private func detailContent(_ d: WorldDetailResponse) -> some View {
        List {
            Section("Basic Info") {
                row(label: String(localized: "Name"), value: d.name ?? "—")
                row(label: "ID",    value: d.encryptedWorldId)
                row(label: String(localized: "Mode"), value: d.mode.badgeLabel)
                if let aspectRatio = d.aspectRatio {
                    row(label: String(localized: "Aspect Ratio"), value: aspectRatio)
                }
                row(label: String(localized: "Status"), value: statusLabel(d.status))
            }
            if let prompt = d.prompt, !prompt.isEmpty {
                Section("Creation Prompt") {
                    Text(prompt)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if d.previewUrl != nil || d.createdAt != nil || d.updatedAt != nil {
                Section("Other") {
                    if let url = d.previewUrl  { row(label: String(localized: "Preview Image"), value: url) }
                    if let at = d.createdAt    { row(label: String(localized: "Created At"), value: at) }
                    if let at = d.updatedAt    { row(label: String(localized: "Updated At"), value: at) }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private func statusLabel(_ status: ServerWorldStatus) -> String {
        switch status {
        case .ready:      return String(localized: "Ready")
        case .generating: return String(localized: "Generating")
        case .failed:     return String(localized: "Failed")
        }
    }

    @MainActor
    private func loadDetail() async {
        isLoading = true
        defer { isLoading = false }
        do {
            detail = try await env.apiClient.worldDetail(encryptedWorldId: world.encryptedWorldId, mode: world.mode)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
