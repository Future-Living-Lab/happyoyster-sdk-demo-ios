import Foundation

// MARK: - 枚举 / 公共类型

/// 漫游状态。
enum TravelStatus: String, Codable {
    case `init`
    case pending
    case running
    case completed
    case failed
    case paused
}

// MARK: - 响应模型

/// POST /server-api/travel-credential 响应。
struct TravelCredentialResponse: Decodable {
    let ticket: String
    /// 凭证有效期（秒），默认 1800。
    let expiresIn: Int
    let encryptedWorldId: String
}

struct TravelListItem: Decodable {
    let encryptedTravelId: String
    let status: TravelStatus
    let mode: ServerWorldMode?
    let encryptedWorldId: String
    let durationSec: Int?
    let createdAt: String?
    let endedAt: String?
}

struct TravelArtifactVideo: Decodable {
    let url: String?
    /// "ready" | "processing" | "failed" | nil
    let status: String?
    let resolution: String?
    let durationSec: Int?
}

struct TravelArtifactsResponse: Decodable {
    let encryptedTravelId: String
    /// 整体合成状态："ready" | "processing" | "failed" | nil
    let composeStatus: String?
    /// 产物 map，键如 "original" / "withWatermark" / "withInstruction" / "withInstructionAndWatermark"
    let video: [String: TravelArtifactVideo]?
}

/// `POST /server-api/travels/update-script` 请求体：`creationModel=scriptlist` 世界游玩中，
/// 用一份新剧本整体替换当前播放的剧本，与文本指令（`sendInstruct`）互斥，仅 scriptlist 世界可调用。
struct UpdateScriptRequest: Encodable {
    let encryptedTravelId: String
    /// 结构化剧本对象，原样透传（同创建时 `ScriptListWorldRequest.scriptList`）。
    let scriptList: JSONValue
}

struct UpdateScriptResponse: Decodable {
    let encryptedTravelId: String
    let accepted: Bool
}

// MARK: - APIClient extension

extension APIClient {

    // MARK: 获取漫游凭证
    /// `POST /server-api/travel-credential`
    /// 为已 ready 的世界签发一次性 accessToken。
    func travelCredential(encryptedWorldId: String) async throws -> TravelCredentialResponse {
        struct Body: Encodable { let encryptedWorldId: String }
        let endpoint = APIEndpoint(
            target: .local,
            path: "/server-api/travel-credential",
            method: .post,
            body: Body(encryptedWorldId: encryptedWorldId)
        )
        return try await requestBailian(endpoint)
    }

    // MARK: 漫游列表
    /// `GET /server-api/travels`
    func listTravels(
        page: Int = 1,
        pageSize: Int = 20,
        status: TravelStatus? = nil,
        encryptedWorldId: String? = nil
    ) async throws -> PaginatedResponse<TravelListItem> {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
        ]
        if let s = status            { items.append(URLQueryItem(name: "status", value: s.rawValue)) }
        if let w = encryptedWorldId  { items.append(URLQueryItem(name: "encryptedWorldId", value: w)) }

        let endpoint = APIEndpoint(target: .local, path: "/server-api/travels", method: .get, queryItems: items)
        return try await requestBailian(endpoint)
    }

    // MARK: 查产物
    /// `GET /server-api/travels/artifacts?encryptedTravelId=...`
    /// 返回解码结果 + 原始响应 JSON（拆包/解码前的完整字符串），供产物详情页底部直接展示，
    /// 排查产物结构问题不用再翻控制台日志。
    func travelArtifactsWithRaw(encryptedTravelId: String) async throws -> (value: TravelArtifactsResponse, rawJSON: String) {
        let endpoint = APIEndpoint(
            target: .local,
            path: "/server-api/travels/artifacts",
            method: .get,
            queryItems: [URLQueryItem(name: "encryptedTravelId", value: encryptedTravelId)]
        )
        return try await requestBailianWithRaw(endpoint)
    }

    // MARK: 更新剧本（ScriptList 模式）
    /// `POST /server-api/travels/update-script`：`creationModel=scriptlist` 世界游玩中整体替换当前剧本。
    func updateScript(_ body: UpdateScriptRequest) async throws -> UpdateScriptResponse {
        let endpoint = APIEndpoint(
            target: .local,
            path: "/server-api/travels/update-script",
            method: .post,
            body: body
        )
        return try await requestBailian(endpoint)
    }
}
