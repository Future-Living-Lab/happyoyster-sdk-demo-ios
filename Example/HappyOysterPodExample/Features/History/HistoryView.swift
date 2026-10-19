import SwiftUI
import AVKit
import Photos

// MARK: - History home (travel list)

struct HistoryView: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var items: [TravelListItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    /// nil = all; when set, only travels with that status are shown
    @State private var filterStatus: TravelStatus? = nil
    /// The world mode currently shown. **There is no "All"**: since models are split by mode, the history
    /// list request must carry one concrete mode (the server uses it to pick the gateway route), so "All" can't be expressed.
    /// How it is passed is a convention of this demo's server; see `APIClient.modeHeaderField`.
    @State private var filterMode: ServerWorldMode = .wander
    @State private var travelToShowDetail: TravelListItem? = nil

    // MARK: Pagination
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
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    modePicker
                }
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

    // MARK: - Mode picker

    /// World mode picker. Sits next to the status filter but works differently: status is a pure display filter,
    /// while mode decides which gateway route the request hits, so there is no "All" option.
    private var modePicker: some View {
        Menu {
            ForEach(ServerWorldMode.allCases, id: \.self) { mode in
                Button {
                    guard filterMode != mode else { return }
                    filterMode = mode
                    Task { await load() }
                } label: {
                    HStack {
                        Text(mode.badgeLabel)
                        if filterMode == mode { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.up")
                Text(filterMode.badgeLabel)
                    .font(.subheadline)
            }
            .foregroundStyle(Color.accentColor)
        }
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
                    Text("All")
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
                Text(filterStatus.map { statusLabel($0) } ?? String(localized: "All"))
                    .font(.subheadline)
            }
            .foregroundStyle(filterStatus == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
        }
    }

    private func statusLabel(_ status: TravelStatus) -> String {
        switch status {
        case .`init`:    return String(localized: "Initializing")
        case .pending:   return String(localized: "Pending")
        case .running:   return String(localized: "Running")
        case .completed: return String(localized: "Completed")
        case .failed:    return String(localized: "Failed")
        case .paused:    return String(localized: "Paused")
        }
    }

    // MARK: Grid

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(items, id: \.encryptedTravelId) { item in
                    NavigationLink {
                        TravelArtifactsView(travel: item, client: env.apiClient, listMode: filterMode)
                    } label: {
                        TravelCard(item: item)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            travelToShowDetail = item
                        } label: {
                            Label("View Details", systemImage: "info.circle")
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
            Text("Loading…").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "map").font(.system(size: 48)).foregroundStyle(.tertiary)
            Text("No travel records yet").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundStyle(.orange)
            Text(msg).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Retry") { Task { await load() } }.buttonStyle(.bordered)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Load

    /// Reset to the first page (called on pull-to-refresh and filter changes)
    @MainActor private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false; hasLoaded = true }
        do {
            let result = try await env.apiClient.listTravels(
                page: 1, pageSize: pageSize, status: filterStatus, mode: filterMode
            )
            items = result.items
            currentPage = 1
            hasMore = result.pagination.hasMore
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Load the next page (called when scrolling to the bottom)
    @MainActor private func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let nextPage = currentPage + 1
            let result = try await env.apiClient.listTravels(
                page: nextPage, pageSize: pageSize, status: filterStatus, mode: filterMode
            )
            let existingIds = Set(items.map(\.encryptedTravelId))
            let newItems = result.items.filter { !existingIds.contains($0.encryptedTravelId) }
            items.append(contentsOf: newItems)
            currentPage = nextPage
            hasMore = result.pagination.hasMore
        } catch {
            // A failed load-more doesn't replace the existing list; keep hasMore so it can retry next time
        }
    }
}

// MARK: - Travel card

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
                // Travel ID (truncated in the middle)
                HStack(spacing: 4) {
                    Text(verbatim: "ID")
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
                    Text(mode.badgeLabel)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                // Failure info (API items[].errorCode / errorMessage)
                if let failure = item.failureText {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                        Text(failure)
                            .font(.system(size: 10))
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
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
            colors: item.mode?.cardGradientColors
                ?? [Color(hue: 0, saturation: 0, brightness: 0.6),
                    Color(hue: 0, saturation: 0, brightness: 0.4)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: item.mode?.cardIconName ?? "questionmark")
                .font(.system(size: 24)).foregroundStyle(.white.opacity(0.45))
        }
    }

    private var modeBadge: some View {
        Text(item.mode?.badgeLabel ?? "—")
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
        case .`init`:    return String(localized: "Initializing")
        case .pending:   return String(localized: "Pending")
        case .running:   return String(localized: "Running")
        case .completed: return String(localized: "Completed")
        case .failed:    return String(localized: "Failed")
        case .paused:    return String(localized: "Paused")
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

// MARK: - Artifacts subpage

struct TravelArtifactsView: View {
    let travel: TravelListItem
    let client: APIClient
    /// The world mode the list belongs to, used as a fallback when `travel.mode` is missing: the list itself
    /// was fetched with this mode, so every item in it belongs to it.
    let listMode: ServerWorldMode

    @State private var artifact: TravelArtifactsResponse?
    /// The full response JSON before unwrapping/decoding, passed down with the artifacts for display at the bottom of the detail page.
    @State private var artifactRawJSON: String?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading artifacts…").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40)).foregroundStyle(.orange)
                    Text(err).font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") { Task { await load() } }.buttonStyle(.bordered)
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
                    Text("No artifacts yet").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Travel Artifacts")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @MainActor private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await client.travelArtifactsWithRaw(
                encryptedTravelId: travel.encryptedTravelId,
                mode: travel.mode ?? listMode
            )
            artifact = result.value
            artifactRawJSON = result.rawJSON
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Artifact video card

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
        case "original":                   return String(localized: "Original")
        case "withWatermark":              return String(localized: "Watermarked")
        case "withInstruction":            return String(localized: "With Instructions")
        case "withInstructionAndWatermark": return String(localized: "With Instructions + Watermark")
        default: return k
        }
    }

    private func formatDuration(_ s: Int) -> String {
        let m = s / 60; let sec = s % 60
        return m > 0 ? "\(m)m\(sec)s" : "\(sec)s"
    }
}

// MARK: - Artifact video detail (portrait: player on top, info + download below)

private struct ArtifactVideoDetailView: View {
    let key: String
    let video: TravelArtifactVideo
    let travel: TravelListItem
    /// The full artifact API response JSON before unwrapping/decoding; nil means the parent couldn't pass it down (shouldn't happen in theory).
    let artifactRawJSON: String?

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var isDownloading = false
    @State private var downloadError: String?
    @State private var downloadDone = false

    private var keyLabel: String {
        switch key {
        case "original":                    return String(localized: "Original")
        case "withWatermark":               return String(localized: "Watermarked")
        case "withInstruction":             return String(localized: "With Instructions")
        case "withInstructionAndWatermark": return String(localized: "With Instructions + Watermark")
        default: return key
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top navigation bar
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

            // Video player (top half, 16:9)
            if let p = player {
                VideoPlayerEmbedded(player: p)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
            }

            // Bottom half: artifact info + download
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Basic info
                    infoSection

                    Divider()

                    // Download area
                    downloadSection

                    Divider()

                    // Debug info: full travel info + raw artifact API response, so debugging doesn't require digging through console logs
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
            Text("Artifact Info")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            infoRow(label: String(localized: "Type"), value: keyLabel)
            if let res = video.resolution {
                infoRow(label: String(localized: "Resolution"), value: res)
            }
            if let dur = video.durationSec {
                let m = dur / 60; let s = dur % 60
                infoRow(label: String(localized: "Duration"), value: m > 0 ? "\(m)m \(s)s" : "\(s)s")
            }
            infoRow(label: String(localized: "Status"), value: video.status ?? "ready")
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
                    Text("Downloading…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            } else if downloadDone {
                Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            } else {
                Button(action: downloadVideo) {
                    Label("Download Video", systemImage: "arrow.down.circle")
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
            Text("Debug Info")
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

            debugSubsection(title: String(localized: "Raw Artifact API Response")) {
                Text(artifactRawJSON ?? String(localized: "<none>"))
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
                // Download to a temporary file
                let (localURL, _) = try await URLSession.shared.download(from: url)
                let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("artifact_\(key)_\(Int(Date().timeIntervalSince1970)).\(ext)")
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: localURL, to: dest)

                // Request photo library permission and save
                let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                guard status == .authorized || status == .limited else {
                    throw NSError(domain: "Photos", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: String(localized: "Photo library write access was not granted. Please enable it in Settings.")])
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
                    downloadError = String(localized: "Download failed: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Embedded video player (doesn't force fullscreen)

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

// MARK: - Travel detail sheet

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
                Section("Status") {
                    detailRow("Status",   value: travel.status.rawValue)
                    detailRow("Mode",     value: travel.mode.map { "\($0.badgeLabel) (\($0.rawValue))" } ?? "—")
                }
                if travel.hasFailureInfo {
                    Section("Failure Info") {
                        detailRow("ErrorCode",    value: travel.errorCodeText ?? "—")
                        detailRow("ErrorMessage", value: travel.errorMessage ?? "—")
                    }
                }
                Section("Time") {
                    detailRow(String(localized: "Created At"), value: travel.createdAt ?? "—")
                    detailRow(String(localized: "Ended At"), value: travel.endedAt   ?? "—")
                    detailRow(String(localized: "Duration"),   value: travel.durationSec.map { formatDuration($0) } ?? "—")
                }
            }
            .navigationTitle("Travel Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
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

// TravelListItem needs Identifiable for .sheet(item:)
extension TravelListItem: Identifiable {
    public var id: String { encryptedTravelId }
}
