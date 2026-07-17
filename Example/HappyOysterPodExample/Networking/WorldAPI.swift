import Foundation

// MARK: - 枚举 / 公共类型

/// 世界模式（服务端数值类型码，1=wander，2=story）。
/// 注意：SDK 内部也有 WorldMode（adventure/directing），此处用 ServerWorldMode 避免命名冲突。
enum ServerWorldMode: Int, Codable {
    case wander = 1
    case story  = 2
}

/// 世界构建状态（服务端字符串值）。
enum ServerWorldStatus: String, Codable {
    case generating
    case ready
    case failed
}

// MARK: - 响应模型

struct WorldListItem: Decodable, Identifiable {
    var id: String { encryptedWorldId }
    let encryptedWorldId: String
    let name: String?
    let status: ServerWorldStatus
    let mode: ServerWorldMode
    let previewUrl: String?
    let createdAt: String?
}

struct CreateWorldResponse: Decodable {
    let encryptedWorldId: String
    let status: ServerWorldStatus
    let firstFrame: String?
}

struct BuildStatusResponse: Decodable {
    let encryptedWorldId: String
    let status: ServerWorldStatus
    let firstFrame: String?
    let name: String?
    let mode: ServerWorldMode?
    let previewUrl: String?
}

struct WorldDetailResponse: Decodable {
    let encryptedWorldId: String
    let name: String?
    let status: ServerWorldStatus
    let mode: ServerWorldMode
    let prompt: String?
    let previewUrl: String?
    let createdAt: String?
    let updatedAt: String?
    /// 世界创建方式：`simple`（默认）/ `scriptlist`；仅 `mode=2` 剧情下可能为 `scriptlist`。
    /// SDK 的 `enter-travel` 不带该字段，游玩中靠这里单独查一次决定体验页 UI
    /// （见 `TravelViewModel.fetchCreationModel`）。`scriptlist` 世界的 `prompt` 固定为 `null`。
    let creationModel: String?
}

struct DeleteWorldResponse: Decodable {
    let encryptedWorldId: String
    let deleted: Bool
}

// MARK: - 请求体

/// 图片引用（仅透传 URL，图片上传及获取逻辑由调用方自行实现）。
struct ImageRef: Encodable {
    let url: String
}

struct CreateWorldRequest: Encodable {
    let mode: Int
    let async_: Bool?
    let prompt: String?
    let eventStyle: String?
    let refWorldId: String?
    // Wander 通用
    let perspective: String?
    let uploadMode: String?
    // Wander first_frame
    let firstFrameImage: ImageRef?
    // Wander scenario_role
    let sceneImage: ImageRef?
    let scenePrompt: String?
    let roleImage: ImageRef?
    let rolePrompt: String?
    // Story 参数
    let resolution: String?
    let layout: String?
    let narrative: String?

    enum CodingKeys: String, CodingKey {
        case mode
        case async_ = "async"
        case prompt, eventStyle, refWorldId, perspective, uploadMode
        case firstFrameImage, sceneImage, scenePrompt, roleImage, rolePrompt
        case resolution, layout, narrative
    }
}

/// Story `creationModel=scriptlist` 独立请求体：结构化剧本创建，走独立结构而不复用
/// `CreateWorldRequest`——按接口文档，传 prompt/layout/narrative/inputImages/perspective/
/// uploadMode/scene*/role* 任一均 400000，故不含这些字段。
struct ScriptListWorldRequest: Encodable {
    let mode: Int
    /// 必须显式带 `async: true`，对齐 `CreateWorldRequest.async_` 的语义，后续走轮询。
    let asyncFlag: Bool
    let creationModel: String
    let resolution: String
    /// 仅 `{url}`，直接复用为世界首帧，跳过 AI 首帧生成。
    let firstFrameImage: ImageRef
    /// 用户编辑的原始剧本 JSON，原样透传（键名/大小写不做转换）。
    let scriptList: JSONValue

    enum CodingKeys: String, CodingKey {
        case mode
        case asyncFlag = "async"
        case creationModel, resolution, firstFrameImage, scriptList
    }
}

// MARK: - APIClient extension

extension APIClient {

    // MARK: 世界列表
    /// `GET /server-api/worlds`
    func listWorlds(
        page: Int = 1,
        pageSize: Int = 20,
        status: ServerWorldStatus? = nil,
        mode: ServerWorldMode? = nil
    ) async throws -> PaginatedResponse<WorldListItem> {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
        ]
        if let s = status { items.append(URLQueryItem(name: "status", value: s.rawValue)) }
        if let m = mode   { items.append(URLQueryItem(name: "mode", value: String(m.rawValue))) }
        let endpoint = APIEndpoint(target: .local, path: "/server-api/worlds", method: .get, queryItems: items)
        return try await requestBailian(endpoint)
    }

    // MARK: 创建世界
    /// `POST /server-api/worlds`
    func createWorld(_ body: CreateWorldRequest) async throws -> CreateWorldResponse {
        let endpoint = APIEndpoint(target: .local, path: "/server-api/worlds", method: .post, body: body)
        return try await requestBailian(endpoint)
    }

    // MARK: 创建世界（Story 结构化剧本 scriptlist 子模式）
    /// `POST /server-api/worlds`（`creationModel=scriptlist`，独立请求体，见 `ScriptListWorldRequest`）
    func createScriptListWorld(_ body: ScriptListWorldRequest) async throws -> CreateWorldResponse {
        let endpoint = APIEndpoint(target: .local, path: "/server-api/worlds", method: .post, body: body)
        return try await requestBailian(endpoint)
    }

    // MARK: 查构建状态
    /// `GET /server-api/worlds/build-status?encryptedWorldId=...`
    func worldBuildStatus(encryptedWorldId: String) async throws -> BuildStatusResponse {
        let endpoint = APIEndpoint(
            target: .local,
            path: "/server-api/worlds/build-status",
            method: .get,
            queryItems: [URLQueryItem(name: "encryptedWorldId", value: encryptedWorldId)]
        )
        return try await requestBailian(endpoint)
    }

    // MARK: 世界详情
    /// `GET /server-api/worlds/detail?encryptedWorldId=...`
    func worldDetail(encryptedWorldId: String) async throws -> WorldDetailResponse {
        let endpoint = APIEndpoint(
            target: .local,
            path: "/server-api/worlds/detail",
            method: .get,
            queryItems: [URLQueryItem(name: "encryptedWorldId", value: encryptedWorldId)]
        )
        return try await requestBailian(endpoint)
    }

    // MARK: 删除世界
    /// `POST /server-api/worlds/delete`
    func deleteWorld(encryptedWorldId: String) async throws -> DeleteWorldResponse {
        struct Body: Encodable { let encryptedWorldId: String }
        let endpoint = APIEndpoint(
            target: .local,
            path: "/server-api/worlds/delete",
            method: .post,
            body: Body(encryptedWorldId: encryptedWorldId)
        )
        return try await requestBailian(endpoint)
    }
}
