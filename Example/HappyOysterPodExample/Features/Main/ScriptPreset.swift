import Foundation

/// 结构化剧本（scriptList）预置模型。`scriptListJSON` 为完整 `scriptList` 对象的
/// JSON 字符串，供编辑器预填与提交时解析。
struct ScriptPreset: Identifiable {
    let id: String
    let name: String
    /// 业务场景标签（来自 `scriptlist_presets.json` 的 `scenario` 字段，可选）。
    let scenario: String?
    let scriptListJSON: String
    /// 预置自带的首帧图 URL（可选，选中预置时同步灌入首帧图输入框）。
    let firstFrameImageUrl: String?

    /// 下拉展示文案：`名称 · 场景`。
    var label: String {
        if let scenario, !scenario.isEmpty { return "\(name) · \(scenario)" }
        return name
    }
}

// MARK: - scriptList 结构化模型（按官方接口文档字段定义，Codable）
//
// 用结构体而非 JSONValue 字典解析模板：
// 1. 字段名/类型（`turn: Int?` 等）在解析期就有强约束，模板数据本身有误时能立刻报错，
//    不必等到提交时才被服务端拒绝。
// 2. `Encodable` 合成实现按属性声明顺序写出 JSON 键——顺序在此处是确定的、可控的，
//    不像 `[String: JSONValue]` 字典本身无序、只能靠字母序或手工指定优先级顺序模拟。
// 用户在编辑器里的自由编辑仍走 `JSONValue`（见 `WorldAPI.swift`/`MainView.validateScriptList`），
// 该类型只负责“已知结构的模板”这一路径。

/// `scriptList` 对象（World 级 + subjects + acts）。
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

/// `scriptlist_presets.json` 单条记录（wire 结构）。
private struct ScriptListPresetFileEntry: Decodable {
    let id: String
    let name: String
    let scenario: String?
    let scriptList: ScriptListTemplate
    let firstFrameImageUrl: String?
}

// MARK: - scriptList JSON 结构校验（创建 / 游玩中更新剧本共用同一套规则）

/// scriptList JSON 结构校验结果。校验通过时把已解析的 `JSONValue` 一并带出，
/// 提交时直接复用，不再 parse 第二次。
enum ScriptListJSONValidation {
    case success(scriptList: JSONValue)
    case failure(message: String)
}

/// 校验用户输入的 scriptList JSON 文本是否满足服务端结构要求（接口文档 §2.1 / §2.11）。
/// 创建世界（`MainView`）与游玩中更新剧本（`TravelView`）共用同一份规则，避免两处校验逻辑各自维护、逐渐漂移。
enum ScriptListJSONValidator {
    static func validate(text: String) -> ScriptListJSONValidation {
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let root) = parsed else {
            return .failure(message: "剧本 JSON 格式有误")
        }

        guard let synopsis = root["synopsis"]?.stringValue,
              !synopsis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(message: "请填写故事梗概 synopsis")
        }

        if let subjects = root["subjects"] {
            guard let subjectsArr = subjects.arrayValue else {
                return .failure(message: "subjects 需为数组")
            }
            guard subjectsArr.count <= 6 else {
                return .failure(message: "角色最多 6 个")
            }
        }

        guard let actsValue = root["acts"], let acts = actsValue.arrayValue else {
            return .failure(message: "缺少 acts")
        }
        guard (1...45).contains(acts.count) else {
            return .failure(message: "acts 数量需在 1–45 之间")
        }

        var seenTurns = Set<Int>()
        for act in acts {
            guard let actObj = act.objectValue else {
                return .failure(message: "每一拍 act 需为对象")
            }
            guard let content = actObj["content"]?.stringValue,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(message: "每一拍 act 的 content 不能为空")
            }
            if let turnValue = actObj["turn"] {
                guard let turn = turnValue.intValue, (1...45).contains(turn) else {
                    return .failure(message: "turn 序号越界或重复")
                }
                guard seenTurns.insert(turn).inserted else {
                    return .failure(message: "turn 序号越界或重复")
                }
            }
        }

        return .success(scriptList: parsed)
    }
}

/// 预置剧本提供方：优先读 App Bundle 内 `scriptlist_presets.json`，失败回落内置兜底。
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

    /// 结构体按声明顺序编码（synopsis/videoTitle/... /subjects/acts），`acts` 天然排最后，
    /// 不需要像字典那样额外指定字段优先级来避免用户只看到 acts 就以为其余字段没填入。
    private static func jsonString(_ template: ScriptListTemplate) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(template),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// 内置兜底（仅 bundle 读取失败时使用）。
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
