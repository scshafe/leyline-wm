// Pure double-precision frame arithmetic. Oracle rounding uses half away from
// zero; native window targets round shared edges before requesting physical frames.
import Foundation

public struct Frame: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public var maxX: Double { x + w }
    public var maxY: Double { y + h }

    public func rounded() -> Frame {
        Frame(x: x.rounded(), y: y.rounded(), w: w.rounded(), h: h.rounded())
    }

    /// Round shared edges together: independently rounding origin and size can
    /// extend the last tile/border past the display by one point.
    public func roundedEdges() -> Frame {
        // A translated half-point rounds the same way on negative monitors.
        let left = floor(x + 0.5), top = floor(y + 0.5)
        return Frame(x: left, y: top, w: floor(maxX + 0.5) - left, h: floor(maxY + 0.5) - top)
    }

    public var json: JSONValue {
        .object(["x": .number(x), "y": .number(y), "w": .number(w), "h": .number(h)])
    }

    /// F::as_frame — array or object form, {w,h} or {width,height}; null → nil.
    public static func from(_ v: JSONValue?) -> Frame? {
        guard let v, v != .null else { return nil }
        if let a = v.arrayValue {
            return Frame(
                x: a.count > 0 ? (a[0].numberValue ?? 0) : 0,
                y: a.count > 1 ? (a[1].numberValue ?? 0) : 0,
                w: a.count > 2 ? (a[2].numberValue ?? 0) : 0,
                h: a.count > 3 ? (a[3].numberValue ?? 0) : 0
            )
        }
        guard let o = v.objectValue else { return nil }
        return Frame(
            x: o["x"]?.numberValue ?? 0,
            y: o["y"]?.numberValue ?? 0,
            w: o["w"]?.numberValue ?? o["width"]?.numberValue ?? 0,
            h: o["h"]?.numberValue ?? o["height"]?.numberValue ?? 0
        )
    }
}

public enum Geometry {
    /// G::frame_overlap_x / _y — clamped at 0.
    public static func overlapX(_ a: Frame, _ b: Frame) -> Double {
        max(min(a.maxX, b.maxX) - max(a.x, b.x), 0)
    }

    public static func overlapY(_ a: Frame, _ b: Frame) -> Double {
        max(min(a.maxY, b.maxY) - max(a.y, b.y), 0)
    }

    /// The area two frames share; 0 when they only touch or are apart.
    public static func intersectionArea(_ a: Frame, _ b: Frame) -> Double {
        overlapX(a, b) * overlapY(a, b)
    }

    /// G::frame_eq at tolerance (default: the model's coordinate tolerance).
    public static func frameEq(_ a: Frame, _ b: Frame, tol: Double = Arrangement.coordinateTolerance) -> Bool {
        abs(a.x - b.x) <= tol && abs(a.y - b.y) <= tol
            && abs(a.w - b.w) <= tol && abs(a.h - b.h) <= tol
    }

    /// G::frames_union — bounding union; nil on empty.
    public static func union(_ frames: [Frame]) -> Frame? {
        guard var acc = frames.first else { return nil }
        for f in frames.dropFirst() {
            let nx = min(acc.x, f.x)
            let ny = min(acc.y, f.y)
            let nr = max(acc.maxX, f.maxX)
            let nb = max(acc.maxY, f.maxY)
            acc = Frame(x: nx, y: ny, w: nr - nx, h: nb - ny)
        }
        return acc
    }

    /// G::inset_frame — uniform inset, w/h clamped ≥ 0; nil passes through.
    public static func inset(_ f: Frame?, by g: Double) -> Frame? {
        guard let f else { return nil }
        return Frame(x: f.x + g, y: f.y + g, w: max(f.w - 2 * g, 0), h: max(f.h - 2 * g, 0))
    }

    /// G::assign_display — max usable-area overlap, falling back to display
    /// FRAMES when nothing overlaps a usable rect; ties (incl. all-zero) break
    /// to the LOWEST id. Nil only on an empty display list.
    public static func assignDisplay(_ win: Frame, _ displays: [NormDisplay]) -> Int64? {
        guard !displays.isEmpty else { return nil }
        let byUsable = displays.map { (id: $0.id, ov: intersectionArea(win, $0.usable)) }
        let cands = byUsable.contains(where: { $0.ov > 0 })
            ? byUsable
            : displays.map { (id: $0.id, ov: intersectionArea(win, $0.frame)) }
        return cands
            .sortedStableBy { .array([.double(-$0.ov), $0.id.map { JSONValue.int($0) } ?? .null]) }
            .first?.id
    }

}
