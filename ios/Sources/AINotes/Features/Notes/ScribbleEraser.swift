import PencilKit
import UIKit

/// GoodNotes-style "scribble to erase": if the stroke you just drew looks like a
/// back-and-forth scribble *and* it crosses existing strokes, those crossed
/// strokes (and the scribble itself) are removed. Object-level erase — whole
/// strokes disappear, not pixels.
///
/// It only fires when the scribble actually overlaps ink, so scribbling on blank
/// space just leaves the scribble as normal ink.
enum ScribbleEraser {
    /// Tuning knobs.
    private static let minPoints = 8
    private static let minCompactness: CGFloat = 3.5   // path length / bbox diagonal
    private static let minReversals = 4                // sharp direction changes
    private static let hitDistance: CGFloat = 16       // points; how close counts as "crossing"
    private static let minHits = 2                     // near-points needed to erase a stroke

    /// Returns a new drawing with the scribble + crossed strokes removed, or nil
    /// if the newest stroke isn't an erase scribble (or crosses nothing).
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

        let searchBox = box.insetBy(dx: -hitDistance, dy: -hitDistance)
        var kept: [PKStroke] = []
        var erasedSomething = false

        for (i, stroke) in strokes.enumerated() {
            if i == idx { continue }   // always drop the scribble itself
            if stroke.renderBounds.intersects(searchBox),
               crosses(scribblePts, stroke) {
                erasedSomething = true
                continue               // drop the crossed stroke
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
        for point in stroke.path.interpolatedPoints(by: .distance(3)) {
            result.append(point.location.applying(transform))
        }
        return result
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

    /// True if enough scribble points land within `hitDistance` of the stroke.
    private static func crosses(_ scribblePts: [CGPoint], _ stroke: PKStroke) -> Bool {
        let target = points(of: stroke)
        guard !target.isEmpty else { return false }
        let threshold = hitDistance * hitDistance
        var hits = 0
        for p in scribblePts {
            for q in target where (p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y) <= threshold {
                hits += 1
                break
            }
            if hits >= minHits { return true }
        }
        return false
    }
}
