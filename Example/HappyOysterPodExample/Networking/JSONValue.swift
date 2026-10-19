import Foundation

/// Codable representation of an arbitrary JSON value, used to pass through the user-edited `scriptList` JSON blob verbatim
/// (no conversion of key names / casing / structure), while also providing convenience accessors for client-side local pre-validation traversal.
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
            // Try bool before number: prevents true/false from being decoded as numbers.
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
                debugDescription: "Cannot be decoded as a known JSON type"
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

    // MARK: - Convenience accessors (for local validation traversal)

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

    /// For integer fields such as `turn`: JSON has no int/double distinction, so `number` always stores `Double`.
    /// Returns a value only when the number is integral and within `Int` range; otherwise it is treated as invalid (e.g. 1.5, "3").
    var intValue: Int? {
        guard let d = numberValue, d.rounded() == d,
              d >= Double(Int.min), d <= Double(Int.max) else { return nil }
        return Int(d)
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}
