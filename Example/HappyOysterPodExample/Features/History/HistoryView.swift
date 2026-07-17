import SwiftUI
import AVKit
import Photos

// MARK: - 历史主页（旅途列表）

struct HistoryView: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var items: [TravelListItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    /// nil = 全部；有值时只展示对应状态
    @State private var filterStatus: TravelStatus? = nil
    @State private var travelToShowDetail: TravelListItem? = nil

    // MARK: 分页
    private let pageSize = 20
    @State private var currentPage = 1
    @State private var hasMore = false
    @State private var isLoadingMore = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationView {
            Group {
                if isLoading && items.isEmpty {
                    loadingView
                } else if let err = errorMessage, items.isEmpty {
                    errorView(err)
                } else if items.isEmpty && hasLoaded {
                    emptyView
                } else {
                    gridView
                }
            }
            .navigationTitle("历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    filterPicker
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isLoading {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button { Task { await load() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .task { await load() }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Filter picker

    private var filterPicker: some View {
        Menu {
            Button {
                guard filterStatus != nil else { return }
                filterStatus = nil
                Task { await load() }
            } label: {
                HStack {
                    Text("全部")
                    if filterStatus == nil { Image(systemName: "checkmark") }
                }
            }
            Divider()
            ForEach([TravelStatus.running, .completed, .failed, .paused], id: \.self) { status in
                Button {
                    guard filterStatus != status else { return }
                    filterStatus = status
                    Task { await load() }
                } label: {
                    HStack {
                        Text(statusLabel(status))
                        if filterStatus == status { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text(filterStatus.map { statusLabel($0) } ?? "全部")
                    .font(.subheadline)
            }
            .foregroundStyle(filterStatus == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
        }
    }

    private func statusLabel(_ status: TravelStatus) -> String {
        switch status {
        case .`init`:    return "初始化"
        case .pending:   return "等待中"
        case .running:   return "进行中"
        case .completed: return "已完成"
        case .failed:    return "失败"
        case .paused:    return "已暂停"
        }
    }

    // MARK: Grid

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(items, id: \.encryptedTravelId) { item in
                    NavigationLink {
                        TravelArtifactsView(travel: item, client: env.apiClient)
                    } label: {
                        TravelCard(item: item)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            travelToShowDetail = item
                        } label: {
                            Label("查看详情", systemImage: "info.circle")
                        }
                    }
                    .onAppear {
                        if item.encryptedTravelId == items.last?.encryptedTravelId {
                            Task { await loadMore() }
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
        .refreshable { await load() }
        .sheet(item: $travelToShowDetail) { travel in
            TravelDetailSheet(travel: travel)
        }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("加载中…").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "map").font(.system(size: 48)).foregroundStyle(.tertiary)
            Text("暂无旅途记录").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundStyle(.orange)
            Text(msg).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("重试") { Task { await load() } }.buttonStyle(.bordered)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Load

    /// 重置到第一页（下拉刷新、切换筛选时调用）
    @MainActor private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false; hasLoaded = true }
        do {
            let result = try await env.apiClient.listTravels(
                page: 1, pageSize: pageSize, status: filterStatus
            )
            items = result.items
            currentPage = 1
            hasMore = result.pagination.hasMore
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 加载下一页（滚动到底部时调用）
    @MainActor private func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let nextPage = currentPage + 1
            let result = try await env.apiClient.listTravels(
                page: nextPage, pageSize: pageSize, status: filterStatus
            )
            let existingIds = Set(items.map(\.encryptedTravelId))
            let newItems = result.items.filter { !existingIds.contains($0.encryptedTravelId) }
            items.append(contentsOf: newItems)
            currentPage = nextPage
            hasMore = result.pagination.hasMore
        } catch {
            // 加载更多失败不覆盖已有列表，保留 hasMore 以便下次重试
        }
    }
}

// MARK: - 旅途卡片

private struct TravelCard: View {
    let item: TravelListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                placeholderGradient.frame(height: 100).clipped()
                modeBadge.padding(7)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(statusLabel).font(.system(size: 11)).foregroundStyle(statusColor)
                    Spacer(minLength: 0)
                    if let dur = item.durationSec {
                        Text(formatDuration(dur)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if let date = formattedDate {
                    Text(date).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Divider().padding(.vertical, 2)
                // Travel ID（截断中间）
                HStack(spacing: 4) {
                    Text("ID")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
                    Text(item.encryptedTravelId)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // Mode
                if let mode = item.mode {
                    Text(mode == .wander ? "Wander" : "Story")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 5, x: 0, y: 2)
    }

    private var placeholderGradient: some View {
        LinearGradient(
            colors: item.mode == .some(.wander)
                ? [Color(hue: 0.55, saturation: 0.5, brightness: 0.65),
                   Color(hue: 0.65, saturation: 0.4, brightness: 0.45)]
                : [Color(hue: 0.08, saturation: 0.5, brightness: 0.7),
                   Color(hue: 0.03, saturation: 0.4, brightness: 0.5)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: item.mode == .some(.wander) ? "wind" : "book.pages")
                .font(.system(size: 24)).foregroundStyle(.white.opacity(0.45))
        }
    }

    private var modeBadge: some View {
        Text(item.mode == .some(.wander) ? "Wander" : item.mode == .some(.story) ? "Story" : "—")
            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private var statusColor: Color {
        switch item.status {
        case .completed: return .green
        case .running:   return .blue
        case .paused:    return .orange
        case .failed:    return .red
        default:         return .secondary
        }
    }

    private var statusLabel: String {
        switch item.status {
        case .`init`:    return "初始化"
        case .pending:   return "等待中"
        case .running:   return "进行中"
        case .completed: return "已完成"
        case .failed:    return "失败"
        case .paused:    return "已暂停"
        }
    }

    private var formattedDate: String? {
        guard let raw = item.createdAt else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = iso.date(from: raw) else { return nil }
        let fmt = DateFormatter(); fmt.dateFormat = "MM/dd HH:mm"
        return fmt.string(from: date)
    }

    private func formatDuration(_ s: Int) -> String {
        let m = s / 60; let sec = s % 60
        return m > 0 ? "\(m)m\(sec)s" : "\(sec)s"
    }
}

// MARK: - 产物子页面

struct TravelArtifactsView: View {
    let travel: TravelListItem
    let client: APIClient

    @State private var artifact: TravelArtifactsResponse?
    /// 拆包/解码前的完整响应 JSON，随产物一起往下传，供详情页底部展示。
    @State private var artifactRawJSON: String?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("加载产物…").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40)).foregroundStyle(.orange)
                    Text(err).font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("重试") { Task { await load() } }.buttonStyle(.bordered)
                }
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let videos = artifact?.video, !videos.isEmpty {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(videos.sorted(by: { $0.key < $1.key }), id: \.key) { key, video in
                            ArtifactVideoCard(key: key, video: video, travel: travel, artifactRawJSON: artifactRawJSON)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 48)).foregroundStyle(.tertiary)
                    Text("暂无产物").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("旅途产物")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @MainActor private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await client.travelArtifactsWithRaw(encryptedTravelId: travel.encryptedTravelId)
            artifact = result.value
            artifactRawJSON = result.rawJSON
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 产物视频卡片

private struct ArtifactVideoCard: View {
    let key: String
    let video: TravelArtifactVideo
    let travel: TravelListItem
    let artifactRawJSON: String?

    @State private var showDetail = false

    private var canPlay: Bool { (video.status == nil || video.status == "ready") && video.url != nil }

    var body: some View {
        Button {
            guard canPlay else { return }
            showDetail = true
        } label: {
            cardContent
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showDetail) {
            ArtifactVideoDetailView(key: key, video: video, travel: travel, artifactRawJSON: artifactRawJSON)
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                placeholder
                if canPlay {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 4)
                } else if video.url == nil {
                    Image(systemName: "clock")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(height: 110)
            .clipped()

            VStack(alignment: .leading, spacing: 4) {
                Text(videoKeyLabel(key))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                HStack {
                    if let res = video.resolution {
                        Text(res).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if let dur = video.durationSec {
                        Text(formatDuration(dur)).font(.system(size: 10)).foregroundStyle(.tertiary)
                    } else if let st = video.status, st != "ready" {
                        Text(st).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 5, x: 0, y: 2)
        .opacity(canPlay ? 1 : 0.55)
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [Color(hue: 0.75, saturation: 0.3, brightness: 0.55),
                     Color(hue: 0.8, saturation: 0.25, brightness: 0.4)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    private func videoKeyLabel(_ k: String) -> String {
        switch k {
        case "original":                   return "原始"
        case "withWatermark":              return "含水印"
        case "withInstruction":            return "含指令"
        case "withInstructionAndWatermark": return "含指令+水印"
        default: return k
        }
    }

    private func formatDuration(_ s: Int) -> String {
        let m = s / 60; let sec = s % 60
        return m > 0 ? "\(m)m\(sec)s" : "\(sec)s"
    }
}

// MARK: - 产物视频详情（竖屏，上半播放器 + 下半信息 + 下载）

private struct ArtifactVideoDetailView: View {
    let key: String
    let video: TravelArtifactVideo
    let travel: TravelListItem
    /// 拆包/解码前的产物接口完整响应 JSON；nil 表示上一层没能带下来（理论上不会发生）。
    let artifactRawJSON: String?

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var isDownloading = false
    @State private var downloadError: String?
    @State private var downloadDone = false

    private var keyLabel: String {
        switch key {
        case "original":                    return "原始"
        case "withWatermark":               return "含水印"
        case "withInstruction":             return "含指令"
        case "withInstructionAndWatermark": return "含指令+水印"
        default: return key
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部导航栏
            HStack {
                Text(keyLabel).font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            // 视频播放器（上半部分，16:9 比例）
            if let p = player {
                VideoPlayerEmbedded(player: p)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
            }

            // 下半部分：产物信息 + 下载
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 基本信息
                    infoSection

                    Divider()

                    // 下载区域
                    downloadSection

                    Divider()

                    // 调试信息：完整 travel 信息 + 产物接口原始响应，排查问题不用再翻控制台日志
                    debugSection
                }
                .padding(20)
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .onAppear {
            if let urlStr = video.url, let url = URL(string: urlStr) {
                player = AVPlayer(url: url)
                player?.play()
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("产物信息")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            infoRow(label: "类型", value: keyLabel)
            if let res = video.resolution {
                infoRow(label: "分辨率", value: res)
            }
            if let dur = video.durationSec {
                let m = dur / 60; let s = dur % 60
                infoRow(label: "时长", value: m > 0 ? "\(m)m \(s)s" : "\(s)s")
            }
            infoRow(label: "状态", value: video.status ?? "ready")
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
        }
    }

    private var downloadSection: some View {
        VStack(spacing: 12) {
            if let errMsg = downloadError {
                Text(errMsg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            if isDownloading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("下载中…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            } else if downloadDone {
                Label("已保存到相册", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            } else {
                Button(action: downloadVideo) {
                    Label("下载视频", systemImage: "arrow.down.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(video.url == nil)
            }
        }
    }

    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("调试信息")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            debugSubsection(title: "Travel") {
                debugRow("encryptedTravelId", travel.encryptedTravelId)
                debugRow("encryptedWorldId", travel.encryptedWorldId)
                debugRow("status", travel.status.rawValue)
                debugRow("mode", travel.mode.map { String($0.rawValue) } ?? "—")
                debugRow("durationSec", travel.durationSec.map(String.init) ?? "—")
                debugRow("createdAt", travel.createdAt ?? "—")
                debugRow("endedAt", travel.endedAt ?? "—")
            }

            debugSubsection(title: "产物接口原始响应") {
                Text(artifactRawJSON ?? "<无>")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func debugSubsection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.tertiary)
            content()
        }
    }

    private func debugRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func downloadVideo() {
        guard let urlStr = video.url, let url = URL(string: urlStr) else { return }
        isDownloading = true
        downloadError = nil

        Task {
            do {
                // 下载到临时文件
                let (localURL, _) = try await URLSession.shared.download(from: url)
                let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("artifact_\(key)_\(Int(Date().timeIntervalSince1970)).\(ext)")
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: localURL, to: dest)

                // 请求相册权限并保存
                let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                guard status == .authorized || status == .limited else {
                    throw NSError(domain: "Photos", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "未获得相册写入权限，请在「设置」中开启"])
                }
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: dest)
                }
                try? FileManager.default.removeItem(at: dest)

                await MainActor.run {
                    isDownloading = false
                    downloadDone = true
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    downloadError = "下载失败：\(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - 嵌入式视频播放器（不强制全屏）

private struct VideoPlayerEmbedded: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = true
        vc.videoGravity = .resizeAspect
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        vc.player = player
    }
}

// MARK: - 旅途详情 Sheet

private struct TravelDetailSheet: View {
    let travel: TravelListItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("Travel") {
                    detailRow("Travel ID", value: travel.encryptedTravelId)
                    detailRow("World ID",  value: travel.encryptedWorldId)
                }
                Section("状态") {
                    detailRow("Status",   value: travel.status.rawValue)
                    detailRow("Mode",     value: travel.mode.map { $0 == .wander ? "Wander (1)" : "Story (2)" } ?? "—")
                }
                Section("时间") {
                    detailRow("创建时间", value: travel.createdAt ?? "—")
                    detailRow("结束时间", value: travel.endedAt   ?? "—")
                    detailRow("时长",     value: travel.durationSec.map { formatDuration($0) } ?? "—")
                }
            }
            .navigationTitle("旅途详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
        }
    }

    private func formatDuration(_ s: Int) -> String {
        let m = s / 60; let sec = s % 60
        return m > 0 ? "\(m)m \(sec)s" : "\(sec)s"
    }
}

// TravelListItem 需要 Identifiable 供 .sheet(item:) 使用
extension TravelListItem: Identifiable {
    public var id: String { encryptedTravelId }
}
