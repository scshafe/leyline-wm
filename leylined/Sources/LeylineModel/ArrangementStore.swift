// Validating typed view over the preserved arrangement JSON tree. Unknown variant
// fields retain their bytes; schema checks enforce segment and binding shape.
import Foundation

public struct StoreViolation: Sendable, CustomStringConvertible {
    public let path: String
    public let rule: String

    public var description: String { "\(path): \(rule)" }
}

public struct ArrangementStore: Sendable {
    public let root: JSONValue

    public init(root: JSONValue) throws {
        guard root.objectValue != nil else {
            throw DecodeFixtureError.malformed
        }
        self.root = root
    }

    public init(data: Data) throws {
        try self.init(root: JSONValue.parse(data))
    }

    public func dumpCanonical() -> String {
        root.canonical()
    }

    public var segments: [JSONValue] {
        root.at(path: "segments")?.arrayValue ?? []
    }

    public var bindings: JSONObject {
        root.at(path: "bindings")?.objectValue ?? [:]
    }

    /// Every bound window id: contents members where present, else the cell's
    /// bare window_id (matches the shadow recorder's read).
    public var boundWindowIds: Set<Int64> {
        Set(Arrangement.memberWindows(root).compactMap { $0.at(path: "window_id")?.intValue })
    }

    public func validate() -> [StoreViolation] {
        var v: [StoreViolation] = []

        for (i, seg) in segments.enumerated() {
            guard let s = seg.objectValue else {
                v.append(StoreViolation(path: "segments[\(i)]", rule: "not an object"))
                continue
            }
            if let axis = s["axis"]?.stringValue {
                if axis != "v" && axis != "h" {
                    v.append(StoreViolation(path: "segments[\(i)].axis", rule: "axis must be v|h, got \(axis)"))
                }
            } else {
                v.append(StoreViolation(path: "segments[\(i)].axis", rule: "missing axis"))
            }
            for key in ["coord", "lo", "hi"] where s[key]?.numberValue == nil {
                v.append(StoreViolation(path: "segments[\(i)].\(key)", rule: "missing or non-numeric"))
            }
        }

        for (anchor, cell) in bindings {
            guard let c = cell.objectValue else {
                v.append(StoreViolation(path: "bindings[\(anchor)]", rule: "not an object"))
                continue
            }
            if let presented = c["presented"], presented.boolValue == nil {
                v.append(StoreViolation(path: "bindings[\(anchor)].presented", rule: "not a bool"))
            }
            if let frame = c["frame"], frame.objectValue == nil, frame != .null {
                v.append(StoreViolation(path: "bindings[\(anchor)].frame", rule: "not an object or null"))
            }
            if let members = c["contents"]?.arrayValue, !members.isEmpty {
                let top = members[0].objectValue?["window_id"]?.intValue
                let bare = c["window_id"]?.intValue
                if top != bare {
                    v.append(StoreViolation(
                        path: "bindings[\(anchor)].contents[0]",
                        rule: "contents[0].window_id (\(top.map(String.init) ?? "nil")) != window_id (\(bare.map(String.init) ?? "nil"))"
                    ))
                }
            }
        }

        return v
    }
}
