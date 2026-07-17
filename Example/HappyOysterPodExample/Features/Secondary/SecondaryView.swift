import SwiftUI

struct SecondaryView: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var worlds: [WorldListItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    @State private var selectedWorld: WorldListItem?
    @State private var worldToDelete: WorldListItem?
    @State private var isDeleting = false
    @State private var worldToShowDetail: WorldListItem?
    /// nil = 全部；有值时只展示对应模式
    @State private var filterMode: ServerWorldMode? = nil

    // MARK: 分页
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
            .navigationTitle("游玩")
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
            .task { await loadWorlds() }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Filter picker

    private var filterPicker: some View {
        Menu {
            Button {
                guard filterMode != nil else { return }
                filterMode = nil
                Task { await loadWorlds() }
            } label: {
                HStack {
                    Text("全部")
                    if filterMode == nil { Image(systemName: "checkmark") }
                }
            }
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
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text(filterMode == nil ? "全部" : (filterMode == .wander ? "Wander" : "Story"))
                    .font(.subheadline)
            }
            .foregroundStyle(filterMode == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
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
                                Label("世界信息", systemImage: "info.circle")
                            }
                            Divider()
                            Button(role: .destructive) {
                                worldToDelete = world
                            } label: {
                                Label("删除世界", systemImage: "trash")
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
        .alert("删除世界", isPresented: Binding(
            get: { worldToDelete != nil },
            set: { if !$0 { worldToDelete = nil } }
        ), presenting: worldToDelete) { world in
            Button("删除", role: .destructive) {
                Task { await deleteWorld(world) }
            }
            Button("取消", role: .cancel) {}
        } message: { world in
            Text("确定要删除「\(world.name ?? world.encryptedWorldId.prefix(12).description)」吗？此操作不可撤销。")
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
            Text("加载中…")
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
            Text("暂无世界")
                .font(.title3)
                .fontWeight(.medium)
            Text("在「创建」页生成你的第一个世界")
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
            Button("重试") { Task { await loadWorlds() } }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Load

    /// 重置到第一页（下拉刷新、切换筛选时调用）
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

    /// 加载下一页（滚动到底部时调用）
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
            // 去重后追加，防止刷新与加载更多并发时重复
            let existingIds = Set(worlds.map(\.encryptedWorldId))
            let newItems = result.items.filter { !existingIds.contains($0.encryptedWorldId) }
            worlds.append(contentsOf: newItems)
            currentPage = nextPage
            hasMore = result.pagination.hasMore
        } catch {
            // 加载更多失败不覆盖已有列表，保留 hasMore 以便下次重试
        }
    }

    // MARK: - Delete

    @MainActor
    private func deleteWorld(_ world: WorldListItem) async {
        worldToDelete = nil
        do {
            _ = try await env.apiClient.deleteWorld(encryptedWorldId: world.encryptedWorldId)
            worlds.removeAll { $0.encryptedWorldId == world.encryptedWorldId }
        } catch {
            errorMessage = "删除失败：\(error.localizedDescription)"
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

    // MARK: Preview（previewUrl 当前通常为 null，展示占位渐变）

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
            colors: world.mode == .wander
                ? [Color(hue: 0.55, saturation: 0.6, brightness: 0.7),
                   Color(hue: 0.65, saturation: 0.5, brightness: 0.5)]
                : [Color(hue: 0.08, saturation: 0.6, brightness: 0.75),
                   Color(hue: 0.03, saturation: 0.5, brightness: 0.5)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: world.mode == .wander ? "wind" : "book.pages")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var modeBadge: some View {
        Text(world.mode == .wander ? "Wander" : "Story")
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
        case .ready:      return "就绪"
        case .generating: return "生成中"
        case .failed:     return "失败"
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
                    ProgressView("加载中…")
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
            .navigationTitle("世界信息")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
        .task { await loadDetail() }
    }

    private func detailContent(_ d: WorldDetailResponse) -> some View {
        List {
            Section("基本信息") {
                row(label: "名称",   value: d.name ?? "—")
                row(label: "ID",    value: d.encryptedWorldId)
                row(label: "模式",  value: d.mode == .wander ? "Wander" : "Story")
                row(label: "状态",  value: statusLabel(d.status))
            }
            if let prompt = d.prompt, !prompt.isEmpty {
                Section("创建描述") {
                    Text(prompt)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if d.previewUrl != nil || d.createdAt != nil || d.updatedAt != nil {
                Section("其他") {
                    if let url = d.previewUrl  { row(label: "预览图", value: url) }
                    if let at = d.createdAt    { row(label: "创建时间", value: at) }
                    if let at = d.updatedAt    { row(label: "更新时间", value: at) }
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
        case .ready:      return "就绪"
        case .generating: return "生成中"
        case .failed:     return "失败"
        }
    }

    @MainActor
    private func loadDetail() async {
        isLoading = true
        defer { isLoading = false }
        do {
            detail = try await env.apiClient.worldDetail(encryptedWorldId: world.encryptedWorldId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
