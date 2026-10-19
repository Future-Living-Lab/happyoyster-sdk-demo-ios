import Foundation
import SwiftUI

// MARK: - Enums / shared types

/// World mode (server-side numeric type code, 1=wander, 2=story, 3=acting).
/// Note: the SDK also has an internal WorldMode (adventure/directing/acting); ServerWorldMode is used here to avoid a naming conflict.
///
/// This type is the single authoritative representation of "world mode" in the demo: create-request encoding (it is itself the Int wire value),
/// list/history display, and parsing the SDK's raw mode string during play (see `init(sdkRawValue:)`) all go through it,
/// instead of ad-hoc strings or bare Int checks scattered around.
enum ServerWorldMode: Int, Codable, CaseIterable {
    case wander = 1
    case story  = 2
    case acting = 3

    /// Short English badge word used in lists / history.
    var badgeLabel: String {
        switch self {
        case .wander: return "Wander"
        case .story:  return "Story"
        case .acting: return "Acting"
        }
    }

    /// Placeholder icon for world cards (wander=wind, story=book, acting=person+sound waves).
    var cardIconName: String {
        switch self {
        case .wander: return "wind"
        case .story:  return "book.pages"
        case .acting: return "person.wave.2"
        }
    }

    /// Placeholder gradient for world cards: wander blue-purple, story warm orange, acting teal.
    var cardGradientColors: [Color] {
        switch self {
        case .wander:
            return [Color(hue: 0.55, saturation: 0.6, brightness: 0.7),
                    Color(hue: 0.65, saturation: 0.5, brightness: 0.5)]
        case .story:
            return [Color(hue: 0.08, saturation: 0.6, brightness: 0.75),
                    Color(hue: 0.03, saturation: 0.5, brightness: 0.5)]
        case .acting:
            return [Color(hue: 0.45, saturation: 0.55, brightness: 0.7),
                    Color(hue: 0.5, saturation: 0.45, brightness: 0.5)]
        }
    }

    /// Parses from the SDK's `OysterModeValue.rawValue` (returned by enter-travel, already mapped to a semantic string by the decoding layer).
    /// Covers every value that has historically appeared, plus `3` / `acting` for acting; returns nil when unrecognized,
    /// leaving the fallback display to the caller.
    init?(sdkRawValue raw: String) {
        switch raw.lowercased() {
        case "1", "wander", "adventure", "vendor": self = .wander
        case "2", "directing":                     self = .story
        case "3", "acting":                        self = .acting
        default:
            guard let value = Int(raw), let mode = ServerWorldMode(rawValue: value) else { return nil }
            self = mode
        }
    }
}

/// World build status (server-side string values).
enum ServerWorldStatus: String, Codable {
    case generating
    case ready
    case failed
}

// MARK: - Response models

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
    /// Aspect ratio (`9:16` / `16:9`). Only set for `mode=3` digital-human worlds; null for other modes.
    let aspectRatio: String?
    /// How the world was created: `simple` (default) / `scriptlist`; can only be `scriptlist` under `mode=2` story.
    /// The SDK's `enter-travel` does not include this field, so during play it is queried separately here to decide the experience page UI
    /// (see `TravelViewModel.fetchCreationModel`). `prompt` is always `null` for `scriptlist` worlds.
    let creationModel: String?
}

struct DeleteWorldResponse: Decodable {
    let encryptedWorldId: String
    let deleted: Bool
}

// MARK: - Request bodies

/// Image reference: either `url` (remote address, passed through) or `base64` (local image; the server decodes it, stores it temporarily and then re-uploads it,
/// so the client doesn't need to upload to OSS itself). Within one object the two must not both be non-empty, otherwise the server returns `400000` —
/// two named `init`s guarantee mutual exclusion at construction time, with no way to build one that has both `url` and `base64`.
/// Applicable fields: `firstFrameImage` / `sceneImage` / `roleImage` / `inputImages[]` /
/// `scriptList.subjects[].refImage`.
/// The API also supports an optional `referenceType`; this demo doesn't need to distinguish reference types, and omitting it lets the server
/// fill in `default` itself, so this struct does not include that field.
struct ImageRef: Encodable {
    let url: String?
    let base64: String?

    /// Remote URL reference.
    init(url: String) {
        self.url = url
        self.base64 = nil
    }

    /// Local image as base64: prepends the `data:image/png;base64,` prefix. **This prefix is not for the server
    /// to parse the image format** — it is a business marker recognized by the gateway, used to exempt such requests from the body size limit (related to
    /// the previously investigated 413 Request Entity Too Large: base64 encoding itself inflates size by ~33%, more noticeably with multiple images,
    /// easily hitting the gateway's default body size limit; this marker makes the gateway relax the limit). So the `image/png` in the prefix is
    /// fixed and does not reflect the original image's real format — local image picking allows any format natively supported by iOS (JPEG/PNG/HEIC/
    /// GIF/TIFF/BMP…), there's no need to distinguish the MIME type by actual format, and the server's parsing of the image content does not depend on this prefix.
    ///
    /// The `base64` argument is a raw base64 string already encoded by the caller (original file data, not transcoded or compressed);
    /// this only concatenates strings and does not re-encode. The 10MB decoded size limit is validated by the caller when picking images
    /// (see `LocalImageLimit`) and is not re-validated here.
    init(base64: String) {
        self.url = nil
        self.base64 = "data:image/png;base64,\(base64)"
    }
}

struct CreateWorldRequest: Encodable {
    let mode: Int
    let async_: Bool?
    let prompt: String?
    let eventStyle: String?
    let refWorldId: String?
    // Wander common
    let perspective: String?
    let uploadMode: String?
    // First-frame image: shared by wander first_frame / story simple mode (1 image) / acting first_frame
    let firstFrameImage: ImageRef?
    // Wander scenario_role
    let sceneImage: ImageRef?
    let scenePrompt: String?
    let roleImage: ImageRef?
    let rolePrompt: String?
    // Reference image list: shared by story simple mode (≥2 images) and acting multi_ref. Under story it is mutually exclusive with
    // `creationModel=scriptlist` (including this field in a scriptlist request body yields 400000;
    // `ScriptListWorldRequest` deliberately lacks this field), and it is either-or with `firstFrameImage` —
    // 1 selected image goes to `firstFrameImage`, ≥2 all go here; see `MainView.storyImageFields`.
    // Under acting, `uploadMode` decides which one takes effect (`multi_ref` submits here, `first_frame` submits
    // `firstFrameImage`; the other is ignored). Each array item has its own `url`/`base64`, and they can be mixed.
    let inputImages: [ImageRef]?
    // Story / Acting parameters (`resolution` used by both; `layout` Story only)
    let resolution: String?
    let layout: String?
    /// Aspect ratio: **only effective for `mode=3`**, `9:16` (default) / `16:9`. For mode=1/2 the server ignores it;
    /// the demo simply doesn't send it, keeping the request body consistent with each mode's whitelist.
    let aspectRatio: String?

    enum CodingKeys: String, CodingKey {
        case mode
        case async_ = "async"
        case prompt, eventStyle, refWorldId, perspective, uploadMode
        case firstFrameImage, sceneImage, scenePrompt, roleImage, rolePrompt
        case inputImages
        case resolution, layout
        case aspectRatio
    }
}

/// Standalone request body for Story `creationModel=scriptlist`: structured script creation uses its own struct instead of reusing
/// `CreateWorldRequest` — per the API docs, passing any of prompt/layout/narrative/inputImages/perspective/
/// uploadMode/scene*/role* yields 400000, so these fields are not included.
struct ScriptListWorldRequest: Encodable {
    let mode: Int
    /// Must explicitly carry `async: true`, matching the semantics of `CreateWorldRequest.async_`; polling follows.
    let asyncFlag: Bool
    let creationModel: String
    let resolution: String
    /// `{url}` only; reused directly as the world's first frame, skipping AI first-frame generation.
    let firstFrameImage: ImageRef
    /// The user-edited raw script JSON, passed through verbatim (no key name / casing conversion).
    let scriptList: JSONValue

    enum CodingKeys: String, CodingKey {
        case mode
        case asyncFlag = "async"
        case creationModel, resolution, firstFrameImage, scriptList
    }
}

// MARK: - APIClient extension

extension APIClient {

    // MARK: World list
    /// `GET /server-api/worlds`
    /// `mode` is required: it is both the list filter and what decides which gateway route the server queries, so "all" cannot be expressed.
    /// This demo passes it via the `X-Happy-Oyster-Mode` header; your own server can use any form
    /// (see `APIClient.modeHeaderField`).
    func listWorlds(
        page: Int = 1,
        pageSize: Int = 20,
        status: ServerWorldStatus? = nil,
        mode: ServerWorldMode
    ) async throws -> PaginatedResponse<WorldListItem> {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
        ]
        if let s = status { items.append(URLQueryItem(name: "status", value: s.rawValue)) }
        items.append(URLQueryItem(name: "mode", value: String(mode.rawValue)))
        let endpoint = APIEndpoint(target: .local, path: "/server-api/worlds", method: .get,
                                   queryItems: items, mode: mode)
        return try await requestBailian(endpoint)
    }

    // MARK: Create world
    /// `POST /server-api/worlds`
    func createWorld(_ body: CreateWorldRequest) async throws -> CreateWorldResponse {
        let endpoint = APIEndpoint(target: .local, path: "/server-api/worlds", method: .post,
                                   body: body, mode: ServerWorldMode(rawValue: body.mode))
        return try await requestBailian(endpoint)
    }

    // MARK: Create world (Story structured-script scriptlist sub-mode)
    /// `POST /server-api/worlds` (`creationModel=scriptlist`, standalone request body; see `ScriptListWorldRequest`)
    func createScriptListWorld(_ body: ScriptListWorldRequest) async throws -> CreateWorldResponse {
        let endpoint = APIEndpoint(target: .local, path: "/server-api/worlds", method: .post,
                                   body: body, mode: ServerWorldMode(rawValue: body.mode))
        return try await requestBailian(endpoint)
    }

    // MARK: Query build status
    /// `GET /server-api/worlds/build-status?encryptedWorldId=...`
    func worldBuildStatus(encryptedWorldId: String, mode: ServerWorldMode) async throws -> BuildStatusResponse {
        let endpoint = APIEndpoint(
            target: .local,
            path: "/server-api/worlds/build-status",
            method: .get,
            queryItems: [URLQueryItem(name: "encryptedWorldId", value: encryptedWorldId)],
            mode: mode
        )
        return try await requestBailian(endpoint)
    }

    // MARK: World detail
    /// `GET /server-api/worlds/detail?encryptedWorldId=...`
    func worldDetail(encryptedWorldId: String, mode: ServerWorldMode) async throws -> WorldDetailResponse {
        let endpoint = APIEndpoint(
            target: .local,
            path: "/server-api/worlds/detail",
            method: .get,
            queryItems: [URLQueryItem(name: "encryptedWorldId", value: encryptedWorldId)],
            mode: mode
        )
        return try await requestBailian(endpoint)
    }

    // MARK: Delete world
    /// `POST /server-api/worlds/delete`
    func deleteWorld(encryptedWorldId: String, mode: ServerWorldMode) async throws -> DeleteWorldResponse {
        struct Body: Encodable { let encryptedWorldId: String }
        let endpoint = APIEndpoint(
            target: .local,
            path: "/server-api/worlds/delete",
            method: .post,
            body: Body(encryptedWorldId: encryptedWorldId),
            mode: mode
        )
        return try await requestBailian(endpoint)
    }
}
