import Foundation

/// 任意 JSON 值的 Codable 表示，用于原样透传用户编辑的 `scriptList` JSON blob
/// （键名/大小写/结构完全不做转换），同时提供便捷访问器支撑客户端本地预校验遍历。
enum JSONValue: Codable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            // 先试 bool 再试 number：避免 true/false 被当成数值解码。
            self = .bool(v)
        } else if let v = try? container.decode(Double.self) {
            self = .number(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "无法解析为已知 JSON 类型"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let dict): try container.encode(dict)
        case .array(let arr):   try container.encode(arr)
        case .string(let s):    try container.encode(s)
        case .number(let d):    try container.encode(d)
        case .bool(let b):      try container.encode(b)
        case .null:             try container.encodeNil()
        }
    }

    // MARK: - 便捷访问器（本地校验遍历用）

    var objectValue: [String: JSONValue]? {
        if case .object(let dict) = self { return dict }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let arr) = self { return arr }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var numberValue: Double? {
        if case .number(let d) = self { return d }
        return nil
    }

    /// `turn` 等整数字段：JSON 无 int/double 之分，`number` 统一存 `Double`。
    /// 仅当数值为整值且落在 `Int` 范围内才返回，否则视为非法（如 1.5、"3"）。
    var intValue: Int? {
        guard let d = numberValue, d.rounded() == d,
              d >= Double(Int.min), d <= Double(Int.max) else { return nil }
        return Int(d)
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}
