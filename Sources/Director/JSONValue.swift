import Foundation

/// Minimal JSON tree for building request bodies and schemas deterministically.
public indirect enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), int(Int), bool(Bool), null
    case array([JSONValue]), object([(String, JSONValue)])

    public static func == (l: JSONValue, r: JSONValue) -> Bool {
        (try? JSONEncoder().encode(l)) == (try? JSONEncoder().encode(r))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let s): var c = encoder.singleValueContainer(); try c.encode(s)
        case .number(let n): var c = encoder.singleValueContainer(); try c.encode(n)
        case .int(let n): var c = encoder.singleValueContainer(); try c.encode(n)
        case .bool(let b): var c = encoder.singleValueContainer(); try c.encode(b)
        case .null: var c = encoder.singleValueContainer(); try c.encodeNil()
        case .array(let a): var c = encoder.unkeyedContainer(); for v in a { try c.encode(v) }
        case .object(let pairs):
            var c = encoder.container(keyedBy: Key.self)
            for (k, v) in pairs { try c.encode(v, forKey: Key(k)) }
        }
    }

    public init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: Key.self) {
            self = .object(try c.allKeys.map { ($0.stringValue, try c.decode(JSONValue.self, forKey: $0)) })
        } else if var c = try? decoder.unkeyedContainer() {
            var a: [JSONValue] = []
            while !c.isAtEnd { a.append(try c.decode(JSONValue.self)) }
            self = .array(a)
        } else {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let i = try? c.decode(Int.self) { self = .int(i) }
            else if let d = try? c.decode(Double.self) { self = .number(d) }
            else { self = .string(try c.decode(String.self)) }
        }
    }

    struct Key: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let pairs) = self { return pairs.first { $0.0 == key }?.1 }
        return nil
    }
    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var intValue: Int? {
        switch self { case .int(let i): i; case .number(let d): Int(d); default: nil }
    }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
}

// Schema helpers: strict objects (all properties required, no extras).
extension JSONValue {
    static func obj(_ props: [(String, JSONValue)]) -> JSONValue {
        .object([("type", .string("object")), ("additionalProperties", .bool(false)),
                 ("required", .array(props.map { .string($0.0) })), ("properties", .object(props))])
    }
    static func arr(_ items: JSONValue, min: Int? = nil, max: Int? = nil) -> JSONValue {
        var p: [(String, JSONValue)] = [("type", .string("array")), ("items", items)]
        if let min { p.append(("minItems", .int(min))) }
        if let max { p.append(("maxItems", .int(max))) }
        return .object(p)
    }
    static func str(_ values: [String]? = nil) -> JSONValue {
        var p: [(String, JSONValue)] = [("type", .string("string"))]
        if let values { p.append(("enum", .array(values.map { .string($0) }))) }
        return .object(p)
    }
    static func integer(_ min: Int, _ max: Int) -> JSONValue {
        .object([("type", .string("integer")), ("minimum", .int(min)), ("maximum", .int(max))])
    }
}
