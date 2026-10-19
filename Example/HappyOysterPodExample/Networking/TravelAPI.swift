import Foundation

// MARK: - Enums / shared types

/// Travel status.
enum TravelStatus: String, Codable {
    case `init`
    case pending
    case running
    case completed
    case failed
    case paused
}

// MARK: - Response models

/// Response of POST /server-api/travel-credential.
struct TravelCredentialResponse: Decodable {
    let ticket: String
    /// Credential lifetime (seconds), default 1800.
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
    /// Failure reason error code (provided by the server when `status == .failed`).
    let errorCode: String?
    /// Failure reason message, shown to the user as-is.
    let errorMessage: String?

    /// Display string for the error code: an empty string is treated as absent.
    var errorCodeText: String? {
        guard let code = errorCode, !code.isEmpty else { return nil }
        return code
    }

    /// Whether there is displayable failure info (either a message or an error code exists).
    var hasFailureInfo: Bool {
        if let msg = errorMessage, !msg.isEmpty { return true }
        return errorCodeText != nil
    }

    /// Failure info display text: prefers `errorMessage`, falls back to the error code when missing.
    var failureText: String? {
        if let msg = errorMessage, !msg.isEmpty {
            return msg
        }
        return errorCodeText.map { String(localized: "Error code \($0)") }
    }
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
    /// Overall compose status: "ready" | "processing" | "failed" | nil
    let composeStatus: String?
    /// Artifact map, with keys such as "original" / "withWatermark" / "withInstruction" / "withInstructionAndWatermark"
    let video: [String: TravelArtifactVideo]?
}

/// Request body of `POST /server-api/travels/update-script`: while playing a `creationModel=scriptlist` world,
/// replaces the currently playing script wholesale with a new one. Mutually exclusive with text instructions (`sendInstruct`); only callable for scriptlist worlds.
struct UpdateScriptRequest: Encodable {
    let encryptedTravelId: String
    /// Structured script object, passed through verbatim (same as `ScriptListWorldRequest.scriptList` at creation).
    let scriptList: JSONValue
}

struct UpdateScriptResponse: Decodable {
    let encryptedTravelId: String
    let accepted: Bool
}

// MARK: - APIClient extension

extension APIClient {

    // MARK: Fetch travel credential
    /// `POST /server-api/travel-credential`
    /// Issues a one-time accessToken for a world that is ready.
    /// `mode` is required: the ticket is issued under the gateway route for that mode and must match the route
    /// referenced by the SDK's `OysterConfig.model`, otherwise `travel.start()` fails on the gateway side.
    func travelCredential(encryptedWorldId: String, mode: ServerWorldMode) async throws -> TravelCredentialResponse {
        struct Body: Encodable { let encryptedWorldId: String }
        let endpoint = APIEndpoint(
            target: .local,
            path: "/server-api/travel-credential",
            method: .post,
            body: Body(encryptedWorldId: encryptedWorldId),
            mode: mode
        )
        return try await requestBailian(endpoint)
    }

    // MARK: Travel list
    /// `GET /server-api/travels`
    /// `mode` is required: the server uses it to decide which gateway route to query. This demo passes it via the `X-Happy-Oyster-Mode` header;
    /// your own server can use any form (see `APIClient.modeHeaderField`).
    func listTravels(
        page: Int = 1,
        pageSize: Int = 20,
        status: TravelStatus? = nil,
        encryptedWorldId: String? = nil,
        mode: ServerWorldMode
    ) async throws -> PaginatedResponse<TravelListItem> {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
        ]
        if let s = status            { items.append(URLQueryItem(name: "status", value: s.rawValue)) }
        if let w = encryptedWorldId  { items.append(URLQueryItem(name: "encryptedWorldId", value: w)) }

        let endpoint = APIEndpoint(target: .local, path: "/server-api/travels", method: .get,
                                   queryItems: items, mode: mode)
        return try await requestBailian(endpoint)
    }

    // MARK: Query artifacts
    /// `GET /server-api/travels/artifacts?encryptedTravelId=...`
    /// Returns the decoded result + the raw response JSON (the full string before unwrapping/decoding), shown directly at the bottom of the artifact detail page,
    /// so diagnosing artifact structure issues doesn't require digging through console logs.
    func travelArtifactsWithRaw(encryptedTravelId: String, mode: ServerWorldMode) async throws -> (value: TravelArtifactsResponse, rawJSON: String) {
        let endpoint = APIEndpoint(
            target: .local,
            path: "/server-api/travels/artifacts",
            method: .get,
            queryItems: [URLQueryItem(name: "encryptedTravelId", value: encryptedTravelId)],
            mode: mode
        )
        return try await requestBailianWithRaw(endpoint)
    }

    // MARK: Update script (ScriptList mode)
    /// `POST /server-api/travels/update-script`: replaces the current script wholesale while playing a `creationModel=scriptlist` world.
    func updateScript(_ body: UpdateScriptRequest, mode: ServerWorldMode) async throws -> UpdateScriptResponse {
        let endpoint = APIEndpoint(
            target: .local,
            path: "/server-api/travels/update-script",
            method: .post,
            body: body,
            mode: mode
        )
        return try await requestBailian(endpoint)
    }
}
