// Learned minimum-size identity, usable-display caps, authored tree/store stamps
// and cap-gated learn-up/learn-down with exact-target self-healing.
import Foundation

public enum Minsize {
    /// Learning hysteresis: an observed size must differ from its target or its
    /// recorded floor by more than this to teach or shrink a minimum, and a floor
    /// may exceed the usable display cap by this much before it is dropped.
    static let learnHysteresis = 4.0

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
        if let w = o["w"]?.numberValue, w > caps.w + learnHysteresis { o.removeValue(forKey: "w") }
        if let h = o["h"]?.numberValue, h > caps.h + learnHysteresis { o.removeValue(forKey: "h") }
        return o.isEmpty ? nil : .object(o)
    }

    // stamp_min_sizes_arr — refresh known floors onto each binding and every stack member.
    public static func stampMinSizesArr(arr: JSONValue, store: JSONValue, observed: [JSONValue], topo: JSONValue?) -> JSONValue {
        guard arr.at(path: "segments") != nil, arr.at(path: "segments") != .null,
              !(store.objectValue ?? [:]).isEmpty else { return arr }
        let caps = usableCaps(topo)
        var appById: [String: String] = [:]
        for w in observed {
            guard let wid = w.objectValue?["window_id"]?.intValue else { continue }
            if let app = winApp(w) { appById[String(wid)] = app }
        }
        // An observed member takes the store's capped floor for its app, or loses a stale one.
        let stampMember: (inout JSONObject) -> Void = { record in
            guard let id = record["window_id"]?.intValue, let app = appById[String(id)] else { return }
            if let minimum = capped(store.objectValue?[app], caps) { record["min_size"] = minimum }
            else { record.removeValue(forKey: "min_size") }
        }
        return Arrangement.mapBindingTree(arr, binding: stampMember, member: stampMember)
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
                if ofv > tfv + learnHysteresis {
                    if let curv, ofv < curv - learnHysteresis { return ofv }
                    if cap == nil || ofv <= cap! + learnHysteresis { return max(curv ?? 0, ofv) }
                    return curv
                }
                if let curv, ofv < curv - learnHysteresis, abs(ofv - tfv) <= learnHysteresis { return ofv }
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
