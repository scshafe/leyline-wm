// Spatial navigation — the canonical direction-ranking algorithm
// (docs/contracts/spatial-nav-algorithm-spec.md), ported from
// lib/swift/FocusNavigationModel.swift so the ranked orders agree to the last
// tie-break. One aggregate stitched surface, two phases (direct then wrap), one
// deterministic lexicographic score tuple ending in the window id. Pure: no
// CoreGraphics — geometry is Double-based NavRect (CGRect.union/intersects
// semantics reproduced exactly, including edge-touching NOT intersecting).

public struct NavRect: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let w: Double
    public let h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public var right: Double { x + w }
    public var bottom: Double { y + h }
    public var midX: Double { x + w / 2 }
    public var midY: Double { y + h / 2 }

    public func union(_ other: NavRect) -> NavRect {
        let nx = Swift.min(x, other.x)
        let ny = Swift.min(y, other.y)
        return NavRect(
            x: nx, y: ny,
            w: Swift.max(right, other.right) - nx,
            h: Swift.max(bottom, other.bottom) - ny
        )
    }

    /// CGRect.intersects semantics: an edge-touching pair (empty intersection)
    /// does NOT intersect.
    public func intersects(_ other: NavRect) -> Bool {
        Swift.max(x, other.x) < Swift.min(right, other.right)
            && Swift.max(y, other.y) < Swift.min(bottom, other.bottom)
    }
}

public enum NavDirection: String, CaseIterable, Sendable {
    case west, south, north, east
}

public enum NavOutcome: String, Sendable {
    case direct, wrap, noCandidate, noFocus
}

public struct NavWindow: Sendable {
    public let id: Int
    public let display: Int
    public let frame: NavRect

    public init(id: Int, display: Int, frame: NavRect) {
        self.id = id
        self.display = display
        self.frame = frame
    }
}

public struct NavExplanation: Sendable {
    public let direction: NavDirection
    public let outcome: NavOutcome
    public let winner: Int?
    public let ranked: [Int]

    public init(direction: NavDirection, outcome: NavOutcome, winner: Int?, ranked: [Int]) {
        self.direction = direction
        self.outcome = outcome
        self.winner = winner
        self.ranked = ranked
    }
}

public struct SpatialNav: Sendable {
    public let displayFrames: [NavRect]
    public let windows: [NavWindow]

    public init(displayFrames: [NavRect], windows: [NavWindow]) {
        self.displayFrames = displayFrames
        self.windows = windows
    }

    public func explain(sourceId: Int, direction: NavDirection) -> NavExplanation {
        guard let source = windows.first(where: { $0.id == sourceId }) else {
            return NavExplanation(direction: direction, outcome: .noFocus, winner: nil, ranked: [])
        }
        let pool = windows.filter { $0.id != source.id }

        let direct = ranked(pool: pool, source: source, direction: direction, wrap: false)
        if !direct.isEmpty {
            return NavExplanation(direction: direction, outcome: .direct, winner: direct.first, ranked: direct)
        }
        let wrapped = ranked(pool: pool, source: source, direction: direction, wrap: true)
        if !wrapped.isEmpty {
            return NavExplanation(direction: direction, outcome: .wrap, winner: wrapped.first, ranked: wrapped)
        }
        return NavExplanation(direction: direction, outcome: .noCandidate, winner: nil, ranked: [])
    }

    private func ranked(pool: [NavWindow], source: NavWindow, direction: NavDirection, wrap: Bool) -> [Int] {
        let band = wrap ? Self.oppositeEdgeBand(direction, union: unionFrame, displayFrames: displayFrames) : nil
        let scored: [(NavWindow, [Double])] = pool.compactMap { window in
            if wrap {
                guard let band,
                      band.intersects(window.frame), band.w > 0, band.h > 0,
                      Self.perpendicularOverlap(direction, source.frame, window.frame) > 0
                else { return nil }
                return (window, Self.scoreWrap(direction, source.frame, window.frame, union: unionFrame, id: window.id))
            } else {
                guard Self.viableDirect(direction, source.frame, window.frame) else { return nil }
                return (window, Self.scoreDirect(direction, source.frame, window.frame, id: window.id))
            }
        }
        return scored
            .sorted { Self.lexicographicLess($0.1, $1.1) }
            .map { $0.0.id }
    }

    // -- Aggregate surface --------------------------------------------------

    private var unionFrame: NavRect? {
        guard let first = displayFrames.first else { return nil }
        return displayFrames.dropFirst().reduce(first) { $0.union($1) }
    }

    static func oppositeEdgeBand(_ direction: NavDirection, union: NavRect?, displayFrames: [NavRect]) -> NavRect? {
        guard let union else { return nil }
        let maxW = displayFrames.map(\.w).max() ?? 0
        let maxH = displayFrames.map(\.h).max() ?? 0
        switch direction {
        case .west:
            return NavRect(x: union.right - maxW, y: union.y, w: maxW, h: union.h)
        case .east:
            return NavRect(x: union.x, y: union.y, w: maxW, h: union.h)
        case .north:
            return NavRect(x: union.x, y: union.bottom - maxH, w: union.w, h: maxH)
        case .south:
            return NavRect(x: union.x, y: union.y, w: union.w, h: maxH)
        }
    }

    // -- Predicates ---------------------------------------------------------

    static func signedGap(_ direction: NavDirection, _ source: NavRect, _ target: NavRect) -> Double {
        switch direction {
        case .east: return target.x - source.right
        case .west: return source.x - target.right
        case .south: return target.y - source.bottom
        case .north: return source.y - target.bottom
        }
    }

    /// Touching edges count as "beyond" (>= 0) — no dead zone between tiles.
    static func sideInDirection(_ direction: NavDirection, _ source: NavRect, _ target: NavRect) -> Bool {
        signedGap(direction, source, target) >= 0
    }

    /// Strictly positive — corner-only contact never counts.
    static func perpendicularOverlap(_ direction: NavDirection, _ source: NavRect, _ target: NavRect) -> Double {
        switch direction {
        case .east, .west:
            return overlap(source.y, source.bottom, target.y, target.bottom)
        case .north, .south:
            return overlap(source.x, source.right, target.x, target.right)
        }
    }

    static func viableDirect(_ direction: NavDirection, _ source: NavRect, _ target: NavRect) -> Bool {
        sideInDirection(direction, source, target)
            && perpendicularOverlap(direction, source, target) > 0
    }

    // -- Scoring ------------------------------------------------------------
    // The tuple: edge distance, -perpendicular overlap, border proportion,
    // centerline delta, window id. `id` is always the final word.

    static func scoreDirect(_ direction: NavDirection, _ source: NavRect, _ target: NavRect, id: Int) -> [Double] {
        let po = perpendicularOverlap(direction, source, target)
        return [
            signedGap(direction, source, target),
            -po,
            borderProportion(direction, target, po),
            centerlineDelta(direction, source, target),
            Double(id),
        ]
    }

    static func scoreWrap(_ direction: NavDirection, _ source: NavRect, _ target: NavRect, union: NavRect?, id: Int) -> [Double] {
        let po = perpendicularOverlap(direction, source, target)
        return [
            wrapEdgeDistance(direction, target, union: union),
            -po,
            borderProportion(direction, target, po),
            centerlineDelta(direction, source, target),
            Double(id),
        ]
    }

    private static func wrapEdgeDistance(_ direction: NavDirection, _ target: NavRect, union: NavRect?) -> Double {
        guard let union else { return 0 }
        switch direction {
        case .west: return union.right - target.right
        case .east: return target.x - union.x
        case .north: return union.bottom - target.bottom
        case .south: return target.y - union.y
        }
    }

    private static func borderProportion(_ direction: NavDirection, _ target: NavRect, _ perpendicularOverlap: Double) -> Double {
        let borderLength = (direction == .east || direction == .west) ? target.h : target.w
        guard borderLength > 0 else { return 0 }
        return 1 - (perpendicularOverlap / borderLength)
    }

    private static func centerlineDelta(_ direction: NavDirection, _ source: NavRect, _ target: NavRect) -> Double {
        switch direction {
        case .east, .west: return abs(source.midY - target.midY)
        case .north, .south: return abs(source.midX - target.midX)
        }
    }

    private static func overlap(_ a1: Double, _ a2: Double, _ b1: Double, _ b2: Double) -> Double {
        max(min(a2, b2) - max(a1, b1), 0)
    }

    static func lexicographicLess(_ a: [Double], _ b: [Double]) -> Bool {
        for (left, right) in zip(a, b) {
            if left < right { return true }
            if left > right { return false }
        }
        return a.count < b.count
    }
}
