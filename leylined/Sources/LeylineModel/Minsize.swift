// Learned minimum-size identity, usable-display caps, authored tree/store stamps
// and cap-gated learn-up/learn-down with exact-target self-healing.
import Foundation

public enum Minsize {
    static let tol = 4.0

    public static func validStore(_ store: JSONValue) -> Bool {
        guard let table = store.objectValue else { return false }
        return table.allSatisfy { app, value in
            guard !app.isEmpty, let axes = value.objectValue else { return false }
            return axes.allSatisfy { axis, value in
                guard axis == "w" || axis == "h", let number = value.numberValue else { return false }
                return number.isFinite && number > 0
            }
        }
    }

    public static func minimumForWindow(_ window: JSONValue, store: JSONValue, topo: JSONValue?) -> JSONValue? {
        guard let app = winApp(window), !app.isEmpty else { return nil }
        return capped(store.objectValue?[app], usableCaps(topo))
    }

    public static func winApp(_ w: JSONValue) -> String? {
        let o = w.objectValue ?? [:]
        if let b = o["bundle_id"]?.stringValue { return b }
        return o["app"]?.stringValue
    }

    // _usable_caps — the largest display's usable w/h; nil = no cap.
    static func usableCaps(_ topo: JSONValue?) -> (w: Double, h: Double)? {
        var pairs: [(Double, Double)] = []
        for d in topo?.at(path: "displays")?.arrayValue ?? [] {
            let u = d.objectValue?["usable"] ?? d.objectValue?["frame"]
            if let a = u?.arrayValue, a.count >= 4,
               let w = a[2].numberValue, let h = a[3].numberValue {
                pairs.append((w, h))
            } else if let o = u?.objectValue,
                      let w = o["w"]?.numberValue, let h = o["h"]?.numberValue {
                pairs.append((w, h))
            }
        }
        guard !pairs.isEmpty else { return nil }
        return (pairs.map(\.0).max()!, pairs.map(\.1).max()!)
    }

    static func capped(_ m: JSONValue?, _ caps: (w: Double, h: Double)?) -> JSONValue? {
        guard let m, m != .null else { return nil }
        guard let caps, var o = m.objectValue else { return m }
        if let w = o["w"]?.numberValue, w > caps.w + tol { o.removeValue(forKey: "w") }
        if let h = o["h"]?.numberValue, h > caps.h + tol { o.removeValue(forKey: "h") }
        return o.isEmpty ? nil : .object(o)
    }

    // stamp_min_sizes — add-only tree stamp from the learned per-app table.
    public static func stampMinSizes(tree: JSONValue, store: JSONValue, observed: [JSONValue], topo: JSONValue?) -> JSONValue {
        let caps = usableCaps(topo)
        var appById: [String: String] = [:]
        for w in observed {
            guard let wid = w.objectValue?["window_id"]?.intValue else { continue }
            if let app = winApp(w) { appById[String(wid)] = app }
        }
        guard var t = tree.objectValue, var nodes = t["nodes"]?.objectValue else { return tree }
        for (id, node) in nodes {
            guard var n = node.objectValue,
                  let wid = n["window_id"], wid != .null, let w = wid.intValue,
                  n["min_size"] == nil || n["min_size"] == .null else { continue }
            guard let app = appById[String(w)],
                  let m = capped(store.objectValue?[app], caps) else { continue }
            n["min_size"] = m
            nodes[id] = .object(n)
        }
        t["nodes"] = .object(nodes)
        return .object(t)
    }

    // stamp_min_sizes_arr — refresh semantics onto binding + contents[0].
    public static func stampMinSizesArr(arr: JSONValue, store: JSONValue, observed: [JSONValue], topo: JSONValue?) -> JSONValue {
        guard arr.at(path: "segments") != nil, arr.at(path: "segments") != .null,
              !(store.objectValue ?? [:]).isEmpty else { return arr }
        let caps = usableCaps(topo)
        var appById: [String: String] = [:]
        for w in observed {
            guard let wid = w.objectValue?["window_id"]?.intValue else { continue }
            if let app = winApp(w) { appById[String(wid)] = app }
        }
        func stampMember(_ value: JSONValue) -> JSONValue {
            guard var member = value.objectValue, let id = member["window_id"]?.intValue,
                  let app = appById[String(id)] else { return value }
            if let minimum = capped(store.objectValue?[app], caps) { member["min_size"] = minimum }
            else { member.removeValue(forKey: "min_size") }
            return .object(member)
        }
        func stampBag(_ value: JSONValue) -> JSONValue {
            guard var bag = value.objectValue else { return value }
            bag["bindings"] = .object((bag["bindings"]?.objectValue ?? [:]).mapValues { value in
                var binding = stampMember(value).objectValue ?? [:]
                if let nested = binding["nested"] { binding["nested"] = stampBag(nested) }
                if let members = binding["contents"]?.arrayValue { binding["contents"] = .array(members.map(stampMember)) }
                return .object(binding)
            })
            return .object(bag)
        }
        return stampBag(arr)
    }

    // learn_min_sizes — the settled-observation fold.
    public static func learnMinSizes(targets: JSONValue, observed: [JSONValue], store: JSONValue, topo: JSONValue?) -> JSONValue {
        let caps = usableCaps(topo)
        var obs: JSONObject = [:]
        for w in observed {
            guard let wid = w.objectValue?["window_id"]?.intValue else { continue }
            obs[String(wid)] = w
        }
        var out = store.objectValue ?? [:]
        for (key, tv) in targets.objectValue ?? [:] {  // jq: to_entries — insertion order (last-wins folds)
            let t = tv.objectValue ?? [:]
            guard t["presented"]?.boolValue == true,
                  let tf = Frame.from(t["frame"]),
                  let o = obs[key],
                  let app = winApp(o),
                  let of = Frame.from(o.objectValue?["frame"]) else { continue }
            var cur = out[app]?.objectValue ?? [:]
            func axis(_ ofv: Double, _ tfv: Double, _ curv: Double?, _ cap: Double?) -> Double? {
                if ofv > tfv + tol {
                    if let curv, ofv < curv - tol { return ofv }
                    if cap == nil || ofv <= cap! + tol { return max(curv ?? 0, ofv) }
                    return curv
                }
                if let curv, ofv < curv - tol, abs(ofv - tfv) <= tol { return ofv }
                return curv
            }
            let nw = axis(of.w, tf.w, cur["w"]?.numberValue, caps?.w)
            let nh = axis(of.h, tf.h, cur["h"]?.numberValue, caps?.h)
            if nw == nil && nh == nil { continue }
            if let nw { cur["w"] = .number(nw) }
            if let nh { cur["h"] = .number(nh) }
            out[app] = .object(cur)
        }
        return .object(out)
    }
}
