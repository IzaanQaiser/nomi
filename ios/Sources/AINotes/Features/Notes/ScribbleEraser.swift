import PencilKit
import UIKit

/// GoodNotes-style "scribble to erase": if the stroke you just drew looks like a
/// back-and-forth scribble *and* it actually touches existing strokes, those
/// touched strokes (and the scribble itself) are removed. Object-level erase —
/// whole strokes disappear, not pixels.
///
/// Hit-testing uses polyline segment intersection (with a small stroke-width
/// tolerance), not a wide radius around the scribble.
enum ScribbleEraser {
    private static let minPoints = 8
    private static let minCompactness: CGFloat = 3.5   // path length / bbox diagonal
    private static let minReversals = 4                // sharp direction changes
    /// Extra slack beyond half the target stroke width so thin ink still counts
    /// as "touching" when the scribble crosses it.
    private static let minTouchTolerance: CGFloat = 2.0

    /// Returns a new drawing with the scribble + touched strokes removed, or nil
    /// if the newest stroke isn't an erase scribble (or touches nothing).
    static func apply(to drawing: PKDrawing, newStrokeIndex idx: Int) -> PKDrawing? {
        let strokes = drawing.strokes
        guard strokes.indices.contains(idx) else { return nil }

        let scribblePts = points(of: strokes[idx])
        guard scribblePts.count >= minPoints else { return nil }

        let box = bounds(of: scribblePts)
        let diagonal = hypot(box.width, box.height)
        guard diagonal > 4 else { return nil }

        let length = pathLength(scribblePts)
        guard length / diagonal >= minCompactness,
              directionReversals(scribblePts) >= minReversals else { return nil }

        // Cull with a tight AABB (tolerance-sized), not a large radius pad.
        let pad = minTouchTolerance + 4
        let searchBox = box.insetBy(dx: -pad, dy: -pad)
        var kept: [PKStroke] = []
        var erasedSomething = false

        for (i, stroke) in strokes.enumerated() {
            if i == idx { continue }   // always drop the scribble itself
            if stroke.renderBounds.intersects(searchBox),
               touches(scribblePts, stroke) {
                erasedSomething = true
                continue               // drop the touched stroke
            }
            kept.append(stroke)
        }

        guard erasedSomething else { return nil }
        return PKDrawing(strokes: kept)
    }

    // MARK: - Geometry helpers

    private static func points(of stroke: PKStroke) -> [CGPoint] {
        var result: [CGPoint] = []
        let transform = stroke.transform
        for point in stroke.path.interpolatedPoints(by: .distance(2.5)) {
            result.append(point.location.applying(transform))
        }
        return result
    }

    private static func averageWidth(of stroke: PKStroke) -> CGFloat {
        let path = stroke.path
        guard path.count > 0 else { return minTouchTolerance * 2 }
        var total: CGFloat = 0
        let step = max(1, path.count / 12)
        var samples = 0
        var i = 0
        while i < path.count {
            total += path[i].size.width
            samples += 1
            i += step
        }
        return samples > 0 ? total / CGFloat(samples) : minTouchTolerance * 2
    }

    private static func bounds(of pts: [CGPoint]) -> CGRect {
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for p in pts {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func pathLength(_ pts: [CGPoint]) -> CGFloat {
        guard pts.count > 1 else { return 0 }
        var total: CGFloat = 0
        for i in 1..<pts.count {
            total += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
        }
        return total
    }

    /// Number of sharp direction changes along the path (a scribble has several).
    private static func directionReversals(_ pts: [CGPoint]) -> Int {
        guard pts.count > 2 else { return 0 }
        var reversals = 0
        var prev = CGVector(dx: pts[1].x - pts[0].x, dy: pts[1].y - pts[0].y)
        for i in 2..<pts.count {
            let cur = CGVector(dx: pts[i].x - pts[i - 1].x, dy: pts[i].y - pts[i - 1].y)
            let mag = hypot(prev.dx, prev.dy) * hypot(cur.dx, cur.dy)
            if mag > 0 {
                let cosine = (prev.dx * cur.dx + prev.dy * cur.dy) / mag
                if cosine < -0.3 { reversals += 1 }   // > ~107° turn
            }
            if hypot(cur.dx, cur.dy) > 0.0001 { prev = cur }
        }
        return reversals
    }

    /// True if the scribble polyline actually touches the stroke polyline.
    private static func touches(_ scribblePts: [CGPoint], _ stroke: PKStroke) -> Bool {
        let target = points(of: stroke)
        guard scribblePts.count >= 2, target.count >= 2 else { return false }
        let tol = max(minTouchTolerance, averageWidth(of: stroke) * 0.55)

        for i in 0..<(scribblePts.count - 1) {
            let a = scribblePts[i]
            let b = scribblePts[i + 1]
            if hypot(b.x - a.x, b.y - a.y) < 0.01 { continue }
            for j in 0..<(target.count - 1) {
                let c = target[j]
                let d = target[j + 1]
                if hypot(d.x - c.x, d.y - c.y) < 0.01 { continue }
                if segmentsTouch(a, b, c, d, tolerance: tol) {
                    return true
                }
            }
        }
        return false
    }

    /// True if segments AB and CD intersect, or come within `tolerance` of each other.
    private static func segmentsTouch(
        _ a: CGPoint, _ b: CGPoint,
        _ c: CGPoint, _ d: CGPoint,
        tolerance: CGFloat
    ) -> Bool {
        if let _ = segmentIntersection(a, b, c, d) {
            return true
        }
        return segmentDistance(a, b, c, d) <= tolerance
    }

    private static func segmentIntersection(
        _ a: CGPoint, _ b: CGPoint,
        _ c: CGPoint, _ d: CGPoint
    ) -> CGPoint? {
        let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let cd = CGPoint(x: d.x - c.x, y: d.y - c.y)
        let ac = CGPoint(x: c.x - a.x, y: c.y - a.y)
        let denom = ab.x * cd.y - ab.y * cd.x
        guard abs(denom) > 1e-8 else { return nil } // parallel
        let t = (ac.x * cd.y - ac.y * cd.x) / denom
        let u = (ac.x * ab.y - ac.y * ab.x) / denom
        guard t >= 0, t <= 1, u >= 0, u <= 1 else { return nil }
        return CGPoint(x: a.x + t * ab.x, y: a.y + t * ab.y)
    }

    private static func segmentDistance(
        _ a: CGPoint, _ b: CGPoint,
        _ c: CGPoint, _ d: CGPoint
    ) -> CGFloat {
        min(
            pointSegmentDistance(a, c, d),
            pointSegmentDistance(b, c, d),
            pointSegmentDistance(c, a, b),
            pointSegmentDistance(d, a, b)
        )
    }

    private static func pointSegmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x
        let aby = b.y - a.y
        let len2 = abx * abx + aby * aby
        guard len2 > 1e-8 else { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2
        t = max(0, min(1, t))
        let qx = a.x + t * abx
        let qy = a.y + t * aby
        return hypot(p.x - qx, p.y - qy)
    }
}
