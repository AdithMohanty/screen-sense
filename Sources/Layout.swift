import Foundation

enum Side: String {
    case left, right, above, below
}

/// Where the monitor sits. `frac` is where the laptop's center falls along the
/// monitor's adjoining edge: 0 = top (or left), 1 = bottom (or right).
struct Placement {
    let side: Side
    let frac: Double
    let spot: String?

    var label: String {
        let s = side == .above ? "Top" : side.rawValue.capitalized
        guard let spot = spot else { return "\(s), custom" }
        return spot.contains("aligned") ? "\(s), \(spot)" : "\(s)-\(spot)"
    }
}

struct ScreenSizes {
    let laptopW: Double, laptopH: Double
    let monitorW: Double, monitorH: Double
}

enum Layout {
    static let spotTolerance = 0.12
    static let edgeTolerance = 0.06
    static let minOverlap = 120.0

    struct Target {
        let frac: Double
        let name: String
        let tolerance: Double
        let isEdge: Bool
    }

    static func targets(_ side: Side, _ s: ScreenSizes) -> [Target] {
        let t: [Target]
        switch side {
        case .left, .right:
            let edge = s.laptopH / (2 * s.monitorH)
            t = [Target(frac: 1, name: "top", tolerance: spotTolerance, isEdge: false),
                 Target(frac: 0.5, name: "middle", tolerance: spotTolerance, isEdge: false),
                 Target(frac: 0, name: "bottom", tolerance: spotTolerance, isEdge: false),
                 Target(frac: edge, name: "top edges aligned", tolerance: edgeTolerance, isEdge: true),
                 Target(frac: 1 - edge, name: "bottom edges aligned", tolerance: edgeTolerance, isEdge: true)]
        case .above:
            let edge = s.laptopW / (2 * s.monitorW)
            t = [Target(frac: 1, name: "left", tolerance: spotTolerance, isEdge: false),
                 Target(frac: 0.5, name: "center", tolerance: spotTolerance, isEdge: false),
                 Target(frac: 0, name: "right", tolerance: spotTolerance, isEdge: false),
                 Target(frac: edge, name: "left edges aligned", tolerance: edgeTolerance, isEdge: true),
                 Target(frac: 1 - edge, name: "right edges aligned", tolerance: edgeTolerance, isEdge: true)]
        case .below:
            t = []
        }
        return t.filter { (0...1).contains($0.frac) }
    }

    /// Snaps to the nearest named spot when close enough. Edge alignment is only
    /// chosen when it's clearly the best match.
    static func snap(_ side: Side, _ raw: Double, _ s: ScreenSizes, edges: Bool) -> Placement {
        let f = min(max(raw, 0), 1)
        let all = targets(side, s).filter { edges || !$0.isEdge }
        let near = all.filter { abs(f - $0.frac) <= $0.tolerance }
            .sorted { abs(f - $0.frac) < abs(f - $1.frac) }
        guard let best = near.first else { return Placement(side: side, frac: f, spot: nil) }

        if best.isEdge {
            if let same = all.first(where: { !$0.isEdge && abs($0.frac - best.frac) <= 0.02 }) {
                return Placement(side: side, frac: same.frac, spot: same.name)
            }
            if let rival = near.dropFirst().first(where: { abs($0.frac - best.frac) > 0.02 }),
               abs(f - rival.frac) - abs(f - best.frac) < 0.03 {
                return rival.isEdge ? Placement(side: side, frac: f, spot: nil)
                                    : Placement(side: side, frac: rival.frac, spot: rival.name)
            }
        }
        return Placement(side: side, frac: best.frac, spot: best.name)
    }

    /// Turns the traced monitor box (relative to where you looked on the laptop)
    /// into a placement.
    static func placement(box: Gaze.Box, sizes: ScreenSizes, edges: Bool) -> Placement {
        let cu = (box.u0 + box.u1) / 2, cv = (box.v0 + box.v1) / 2
        // A side monitor leaves a clear horizontal gap from where you looked on the laptop.
        let gap = max(box.u0, -box.u1) / max(box.u1 - box.u0, 1e-6)
        let side: Side = gap < 0.12 ? (cv > 0 ? .below : .above) : (cu > 0 ? .right : .left)

        let vertical = side == .left || side == .right
        let start = vertical ? box.v0 : box.u0
        let extent = vertical ? box.v1 - box.v0 : box.u1 - box.u0
        let frac = extent > 1e-6 ? -start / extent : 0.5
        return snap(side, frac, sizes, edges: edges)
    }

    /// Monitor origin relative to the laptop's top-left corner, in points.
    static func origin(_ p: Placement, _ s: ScreenSizes) -> (x: Int, y: Int) {
        func along(_ laptopLen: Double, _ monitorLen: Double) -> Double {
            let pos = laptopLen / 2 - p.frac * monitorLen
            return min(max(pos, -monitorLen + minOverlap), laptopLen - minOverlap)
        }
        let x: Double, y: Double
        switch p.side {
        case .right: x = s.laptopW;   y = along(s.laptopH, s.monitorH)
        case .left:  x = -s.monitorW; y = along(s.laptopH, s.monitorH)
        case .above: y = -s.monitorH; x = along(s.laptopW, s.monitorW)
        case .below: y = s.laptopH;   x = along(s.laptopW, s.monitorW)
        }
        return (Int(x.rounded()), Int(y.rounded()))
    }
}
