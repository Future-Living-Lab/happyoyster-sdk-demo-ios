import Foundation

/// Preset model for structured scripts (scriptList). `scriptListJSON` is the JSON string of the full `scriptList`
/// object, used to prefill the editor and parsed on submit.
struct ScriptPreset: Identifiable {
    let id: String
    let name: String
    /// Business scenario tag (from the `scenario` field of `scriptlist_presets.json`, optional).
    let scenario: String?
    let scriptListJSON: String
    /// The preset's own first-frame image URL (optional; filled into the first-frame image field when the preset is selected).
    let firstFrameImageUrl: String?

    /// Dropdown display text: `name · scenario`.
    var label: String {
        if let scenario, !scenario.isEmpty { return "\(name) · \(scenario)" }
        return name
    }
}

// MARK: - scriptList structured models (fields per the official API docs, Codable)
//
// Templates are parsed with structs rather than JSONValue dictionaries:
// 1. Field names/types (`turn: Int?`, etc.) are strictly enforced at parse time, so bad template data fails
//    immediately instead of being rejected by the server on submit.
// 2. The synthesized `Encodable` writes JSON keys in property declaration order -- deterministic and controllable
//    here, unlike an unordered `[String: JSONValue]` dictionary that can only emulate order via alphabetical or manual priority.
// Free-form edits in the editor still go through `JSONValue` (see `WorldAPI.swift`/`MainView.validateScriptList`);
// these types only handle the "template with known structure" path.

/// `scriptList` object (world level + subjects + acts).
private struct ScriptListTemplate: Codable {
    var synopsis: String?
    var videoTitle: String?
    var scene: String?
    var style: String?
    var speed: String?
    var language: String?
    var setting: String?
    var soundtrack: String?
    var prologue: String?
    var videoTags: [String]?
    var subjects: [ScriptListSubject]?
    var acts: [ScriptListAct]
}

private struct ScriptListSubject: Codable {
    var label: String?
    var name: String?
    var type: String?
    var refImage: RefImage?
    var gender: String?
    var position: String?
    var ethnicity: String?
    var age: String?
    var appearance: String?
    var voice: String?

    struct RefImage: Codable {
        var url: String
    }
}

private struct ScriptListAct: Codable {
    var turn: Int?
    var content: String
    var cameraType: String?
    var shotSize: String?
    var cut: String?
}

/// A single record in `scriptlist_presets.json` (wire structure).
private struct ScriptListPresetFileEntry: Decodable {
    let id: String
    let name: String
    let scenario: String?
    let scriptList: ScriptListTemplate
    let firstFrameImageUrl: String?
}

// MARK: - scriptList JSON structure validation (same rules for creation and in-play script updates)

/// Result of scriptList JSON structure validation. On success, the parsed `JSONValue` is carried along
/// so it can be reused on submit without parsing a second time.
enum ScriptListJSONValidation {
    case success(scriptList: JSONValue)
    case failure(message: String)
}

/// Validates whether the user's scriptList JSON text meets the server's structural requirements (API docs §2.1 / §2.11).
/// World creation (`MainView`) and in-play script updates (`TravelView`) share the same rules, so the two validations don't drift apart.
enum ScriptListJSONValidator {
    static func validate(text: String) -> ScriptListJSONValidation {
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let root) = parsed else {
            return .failure(message: String(localized: "Invalid script JSON format"))
        }

        guard let synopsis = root["synopsis"]?.stringValue,
              !synopsis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(message: String(localized: "Please fill in the story synopsis (synopsis)"))
        }

        if let subjects = root["subjects"] {
            guard let subjectsArr = subjects.arrayValue else {
                return .failure(message: String(localized: "subjects must be an array"))
            }
            guard subjectsArr.count <= 6 else {
                return .failure(message: String(localized: "At most 6 characters are allowed"))
            }
        }

        guard let actsValue = root["acts"], let acts = actsValue.arrayValue else {
            return .failure(message: String(localized: "Missing acts"))
        }
        guard (1...45).contains(acts.count) else {
            return .failure(message: String(localized: "The number of acts must be between 1 and 45"))
        }

        var seenTurns = Set<Int>()
        for act in acts {
            guard let actObj = act.objectValue else {
                return .failure(message: String(localized: "Each act must be an object"))
            }
            guard let content = actObj["content"]?.stringValue,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(message: String(localized: "The content of each act cannot be empty"))
            }
            if let turnValue = actObj["turn"] {
                guard let turn = turnValue.intValue, (1...45).contains(turn) else {
                    return .failure(message: String(localized: "turn number is out of range or duplicated"))
                }
                guard seenTurns.insert(turn).inserted else {
                    return .failure(message: String(localized: "turn number is out of range or duplicated"))
                }
            }
        }

        return .success(scriptList: parsed)
    }
}

/// Preset script provider: reads `scriptlist_presets.json` from the app bundle first, falling back to the built-in default on failure.
struct ScriptPresetProvider {
    private static let bundleFileName = "scriptlist_presets"

    func loadPresets() async -> [ScriptPreset] {
        if let fromBundle = Self.loadFromBundle() { return fromBundle }
        return Self.builtIn
    }

    private static func loadFromBundle() -> [ScriptPreset]? {
        guard let url = Bundle.main.url(forResource: bundleFileName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([ScriptListPresetFileEntry].self, from: data),
              !entries.isEmpty else {
            return nil
        }
        return entries.map { entry in
            var scriptList = entry.scriptList
            if scriptList.synopsis == nil { scriptList.synopsis = entry.name }
            if scriptList.videoTitle == nil { scriptList.videoTitle = entry.name }
            return ScriptPreset(
                id: entry.id,
                name: entry.name,
                scenario: entry.scenario,
                scriptListJSON: Self.jsonString(scriptList),
                firstFrameImageUrl: entry.firstFrameImageUrl
            )
        }
    }

    /// Structs encode in declaration order (synopsis/videoTitle/... /subjects/acts), so `acts` naturally comes last;
    /// unlike a dictionary, no extra field priority is needed to keep users from seeing only acts and assuming the other fields weren't filled.
    private static func jsonString(_ template: ScriptListTemplate) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(template),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// Built-in fallback (used only if reading from the bundle fails). Its content is preset data sent to the backend and is intentionally not localized.
    static let builtIn: [ScriptPreset] = [
        ScriptPreset(
            id: "midnight-visitor",
            name: "午夜访客",
            scenario: nil,
            scriptListJSON: jsonString(
                ScriptListTemplate(
                    synopsis: "午夜访客",
                    videoTitle: "午夜访客",
                    subjects: [
                        ScriptListSubject(label: "[character_1]", name: "神秘访客", type: "character"),
                    ],
                    acts: [
                        ScriptListAct(
                            turn: 1,
                            content: "夜色笼罩下的老宅门前，[character_1] 缓步走近，敲响了门",
                            cameraType: "Static",
                            shotSize: "Wide",
                            cut: "long-take"
                        ),
                    ]
                )
            ),
            firstFrameImageUrl: nil
        ),
    ]
}
