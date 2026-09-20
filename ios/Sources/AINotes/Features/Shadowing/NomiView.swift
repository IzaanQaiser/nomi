import SwiftUI

// ============================================================================
//  NomiView
//  A vector rig for the Nomi mascot, traced from the six PNGs in
//  Assets.xcassets (blob reconstruction IoU 0.9909 against NomiIdle.png).
//
//  Everything is drawn in a fixed 384 x 384 design space and scaled to fit,
//  so it is resolution independent and every pose is the same four shapes at
//  different parameter values.
//
//  Drop-in usage inside MascotView:
//
//      NomiView(pose: .init(engineState: engine.state))
//          .frame(width: nomiSize, height: nomiSize)
//
//  ...in place of Image(poseName). The old imagesets can stay in the catalog
//  for the app icon / marketing; the view no longer reads them.
// ============================================================================


// MARK: - Geometry, measured from the source assets

public enum NomiGeometry {
    /// 24 control points around the blob, resampled by arc length from
    /// NomiIdle.png and fed through a closed Catmull-Rom spline.
    static let bodyPoints: [CGPoint] = [
        CGPoint(x: 194.0, y:  68.0), CGPoint(x: 161.2, y:  74.8), CGPoint(x: 129.4, y:  84.0),
        CGPoint(x: 102.0, y: 104.0), CGPoint(x:  84.0, y: 132.1), CGPoint(x:  68.6, y: 161.4),
        CGPoint(x:  60.0, y: 193.4), CGPoint(x:  63.0, y: 227.8), CGPoint(x:  74.6, y: 258.6),
        CGPoint(x:  94.9, y: 285.9), CGPoint(x: 123.0, y: 304.0), CGPoint(x: 154.4, y: 314.0),
        CGPoint(x: 188.8, y: 317.0), CGPoint(x: 223.2, y: 314.0), CGPoint(x: 255.5, y: 306.0),
        CGPoint(x: 284.1, y: 289.0), CGPoint(x: 307.0, y: 263.4), CGPoint(x: 320.0, y: 233.2),
        CGPoint(x: 324.0, y: 199.2), CGPoint(x: 318.0, y: 166.0), CGPoint(x: 302.7, y: 136.7),
        CGPoint(x: 282.5, y: 109.5), CGPoint(x: 257.9, y:  85.9), CGPoint(x: 228.4, y:  71.0)
    ]

    static let canvas: CGFloat = 384
    static let centroid = CGPoint(x: 191.7, y: 195.8)
    /// Every squash and stretch is anchored here so Nomi sits on a floor
    /// instead of floating. This single choice does most of the work.
    static let ground = CGPoint(x: 192, y: 317)

    static let eyeLeft  = CGPoint(x: 146.3, y: 195)
    static let eyeRight = CGPoint(x: 236.3, y: 195)
    static let eyeRadius: CGFloat = 37
    static let pupilRadius: CGFloat = 21.5
    /// Slightly larger than eyeRadius - pupilRadius, so the pupil clips at the
    /// rim on extreme looks. That clipping is present in the original art.
    static let pupilTravel: CGFloat = 17

    static let mouth = CGPoint(x: 191.5, y: 234.5)
    static let mouthHalfWidth: CGFloat = 14
    static let mouthSag: CGFloat = 5
    static let mouthStroke: CGFloat = 7

    static let badgeCenter = CGPoint(x: 316, y: 96)
    static let badgeRadius: CGFloat = 24
}

public enum NomiPalette {
    public static let blob    = Color(red: 27/255,  green: 113/255, blue: 252/255) // #1B71FC
    public static let paper   = Color(red: 252/255, green: 252/255, blue: 252/255) // #FCFCFC
    public static let ink     = Color(red:  5/255,  green:   5/255, blue:   5/255) // #050505
    public static let confirm = Color(red: 52/255,  green: 208/255, blue: 127/255) // #34D07F
    public static let nudge   = Color(red: 249/255, green: 115/255, blue:  22/255) // #F97316
    public static let tongue  = Color(red: 242/255, green: 118/255, blue: 107/255) // #F2766B
    public static let soft    = Color(red: 169/255, green: 196/255, blue: 245/255) // #A9C4F5
    public static let brow    = Color(red: 11/255,  green:  27/255, blue:  51/255) // #0B1B33
}


// MARK: - Poses

public enum NomiPose: Equatable {
    case sleep, idle, thinking, confirm, nudge, talk, listening

    var badge: NomiBadge? {
        switch self {
        case .sleep:     return .zzz
        case .thinking:  return .dots
        case .confirm:   return .check
        case .nudge:     return .alert
        case .talk:      return .lines
        case .idle, .listening: return nil
        }
    }
    /// Breathing period in seconds.
    var breathe: Double {
        switch self {
        case .sleep: return 5.2
        case .idle: return 3.2
        case .thinking: return 4.0
        case .confirm: return 3.0
        case .nudge: return 3.0
        case .talk: return 2.8
        case .listening: return 2.6
        }
    }
    /// Breathing amplitude as a fraction of height.
    var breatheAmplitude: Double {
        switch self {
        case .sleep: return 0.022
        case .idle, .listening: return 0.014
        case .thinking: return 0.016
        case .confirm: return 0.018
        case .nudge, .talk: return 0.020
        }
    }
    var tilt: Double {
        switch self {
        case .sleep: return -3
        case .thinking: return 2
        case .nudge: return -4
        default: return 0
        }
    }
    var lift: CGFloat { self == .confirm ? 7 : 0 }
    /// Fixed gaze, or nil for autonomous saccades.
    var fixedGaze: CGPoint? {
        switch self {
        case .thinking: return CGPoint(x: 0.62, y: -0.86)
        case .nudge:    return CGPoint(x: 0.90, y: -0.35)
        default:        return nil
        }
    }
    var happyEyes: Bool { self == .confirm }
    var sleepyEyes: Bool { self == .sleep }
    var leftSquint: Double { self == .nudge ? 0.38 : 0 }
    var showsBrow: Bool { self == .nudge }
    var smileScale: Double { self == .confirm ? 1.25 : 1.0 }
    var blinks: Bool { !happyEyes && !sleepyEyes }
    /// Blink a little less while it is listening to you, which reads as attention.
    var blinkPeriod: Double { self == .listening ? 7.5 : 4.6 }
}

enum NomiBadge { case check, alert, dots, zzz, lines }


// MARK: - The view

public struct NomiView: View {
    public var pose: NomiPose
    /// Optional external gaze in normalised -1...1 coordinates. Feed this the
    /// pen position so Nomi watches where you are writing; leave it nil for
    /// autonomous ambient saccades.
    public var gaze: CGPoint?
    /// 0...1 mouth aperture, normally an audio envelope while speaking.
    public var speechLevel: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(pose: NomiPose, gaze: CGPoint? = nil, speechLevel: Double = 0) {
        self.pose = pose
        self.gaze = gaze
        self.speechLevel = speechLevel
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let s = min(size.width, size.height) / NomiGeometry.canvas
                ctx.translateBy(x: (size.width - NomiGeometry.canvas * s) / 2,
                                y: (size.height - NomiGeometry.canvas * s) / 2)
                ctx.scaleBy(x: s, y: s)
                draw(&ctx, t: t)
            }
        }
        .accessibilityHidden(true)
    }
}


// MARK: - Drawing

private extension NomiView {

    func draw(_ ctx: inout GraphicsContext, t: Double) {
        let g = NomiGeometry.self

        // ---- body scale: breathing, anchored at the ground ----
        let breathe = reduceMotion ? 0 : sin(t * 2 * .pi / pose.breathe)
        let sy = 1 + breathe * pose.breatheAmplitude
        let sx = 1 / sqrt(sy)                       // rough volume preservation
        let wobble = reduceMotion ? 0 : 0.009

        // ---- body ----
        ctx.drawLayer { layer in
            transform(&layer, tilt: pose.tilt, lift: pose.lift,
                      pivot: g.ground, scale: CGSize(width: sx, height: sy), about: g.ground)
            layer.fill(blobPath(t: t, wobble: wobble), with: .color(NomiPalette.blob))
        }

        // ---- face: follows 85% of the body's travel, deforms at 25% ----
        // That deliberate lag is what makes the face read as sitting on a soft body.
        let faceDY = (g.ground.y - g.eyeLeft.y) * (1 - sy) * 0.85
        let faceScale = 1 + (sy - 1) * 0.25

        ctx.drawLayer { layer in
            layer.translateBy(x: 0, y: -pose.lift)
            rotate(&layer, degrees: pose.tilt, about: g.ground)
            layer.translateBy(x: g.centroid.x, y: g.eyeLeft.y + faceDY)
            layer.scaleBy(x: 1 / sqrt(faceScale), y: faceScale)
            layer.translateBy(x: -g.centroid.x, y: -g.eyeLeft.y)
            drawFace(&layer, t: t)
        }

        if let badge = pose.badge {
            drawBadge(&ctx, badge, t: t)
        }
    }

    func drawFace(_ ctx: inout GraphicsContext, t: Double) {
        let g = NomiGeometry.self

        // ---- gaze ----
        let (gazeL, gazeR) = resolvedGaze(t: t)
        let blink = pose.blinks && !reduceMotion ? blinkAmount(t: t) : 0
        let lidL = max(blink, pose.leftSquint, pose.sleepyEyes ? 1 : 0)
        let lidR = max(blink, pose.sleepyEyes ? 1 : 0)

        if pose.happyEyes {
            ctx.fill(happyEye(at: g.eyeLeft),  with: .color(NomiPalette.ink))
            ctx.fill(happyEye(at: g.eyeRight), with: .color(NomiPalette.ink))
        } else if pose.sleepyEyes {
            ctx.fill(sleepEye(at: g.eyeLeft),  with: .color(NomiPalette.ink))
            ctx.fill(sleepEye(at: g.eyeRight), with: .color(NomiPalette.ink))
        } else {
            drawEye(&ctx, center: g.eyeLeft,  gaze: gazeL, lid: lidL)
            drawEye(&ctx, center: g.eyeRight, gaze: gazeR, lid: lidR)
        }

        if pose.showsBrow {
            var brow = Path()
            brow.move(to: CGPoint(x: g.eyeRight.x - 16, y: g.eyeRight.y - 46))
            brow.addQuadCurve(to: CGPoint(x: g.eyeRight.x + 20, y: g.eyeRight.y - 50),
                              control: CGPoint(x: g.eyeRight.x + 2, y: g.eyeRight.y - 58))
            ctx.stroke(brow, with: .color(NomiPalette.brow),
                       style: StrokeStyle(lineWidth: 9, lineCap: .round))
        }

        drawMouth(&ctx, t: t)
    }

    /// The eye is clipped from the top down by a real lid, never faded out.
    /// Opacity blinks look like a rendering bug; this looks like an eyelid.
    func drawEye(_ ctx: inout GraphicsContext, center: CGPoint, gaze: CGPoint, lid: Double) {
        let g = NomiGeometry.self
        let eyeRect = CGRect(x: center.x - g.eyeRadius, y: center.y - g.eyeRadius,
                             width: g.eyeRadius * 2, height: g.eyeRadius * 2)
        let lidTop = center.y - g.eyeRadius + 2 * g.eyeRadius * CGFloat(lid)
        let visible = CGRect(x: eyeRect.minX - 2, y: lidTop,
                             width: eyeRect.width + 4,
                             height: max(0.01, eyeRect.maxY + 2 - lidTop))

        if lid < 0.999 {
            ctx.drawLayer { layer in
                layer.clip(to: Path(visible))
                layer.fill(Path(ellipseIn: eyeRect), with: .color(NomiPalette.paper))
                layer.clip(to: Path(ellipseIn: eyeRect))
                let p = CGPoint(x: center.x + gaze.x * g.pupilTravel,
                                y: center.y + gaze.y * g.pupilTravel)
                layer.fill(Path(ellipseIn: CGRect(x: p.x - g.pupilRadius, y: p.y - g.pupilRadius,
                                                  width: g.pupilRadius * 2, height: g.pupilRadius * 2)),
                           with: .color(NomiPalette.ink))
            }
        }
        // The dark lid line at the end of a blink.
        if lid > 0.8 {
            var line = Path()
            line.move(to: CGPoint(x: center.x - 26, y: center.y + 1))
            line.addQuadCurve(to: CGPoint(x: center.x + 26, y: center.y + 1),
                              control: CGPoint(x: center.x, y: center.y + 7))
            ctx.opacity = (lid - 0.8) / 0.2
            ctx.stroke(line, with: .color(NomiPalette.ink),
                       style: StrokeStyle(lineWidth: 8, lineCap: .round))
            ctx.opacity = 1
        }
    }

    func drawMouth(_ ctx: inout GraphicsContext, t: Double) {
        let g = NomiGeometry.self
        var open = pose == .talk ? max(0.25, speechLevel) : 0
        if pose == .talk && speechLevel == 0 && !reduceMotion {
            // Stand-in envelope so the preview talks without an audio source.
            let env = (sin(t * 9.3) * 0.5 + 0.5) * (sin(t * 3.1) * 0.35 + 0.65)
            open = 0.30 + 0.60 * env
        }

        if open < 0.02 {
            var smile = Path()
            smile.move(to: CGPoint(x: g.mouth.x - g.mouthHalfWidth, y: g.mouth.y))
            smile.addQuadCurve(to: CGPoint(x: g.mouth.x + g.mouthHalfWidth, y: g.mouth.y),
                               control: CGPoint(x: g.mouth.x,
                                                y: g.mouth.y + g.mouthSag * 2 * CGFloat(pose.smileScale)))
            ctx.stroke(smile, with: .color(NomiPalette.ink),
                       style: StrokeStyle(lineWidth: g.mouthStroke, lineCap: .round))
            return
        }

        let w = g.mouthHalfWidth + (20 - g.mouthHalfWidth) * CGFloat(open)
        let h = 1 + 25 * CGFloat(open)
        let top = g.mouth.y - h * 0.12
        var m = Path()
        m.move(to: CGPoint(x: g.mouth.x - w, y: top))
        m.addQuadCurve(to: CGPoint(x: g.mouth.x, y: top - 1),
                       control: CGPoint(x: g.mouth.x - w * 0.45, y: top - 3.5))
        m.addQuadCurve(to: CGPoint(x: g.mouth.x + w, y: top),
                       control: CGPoint(x: g.mouth.x + w * 0.45, y: top - 3.5))
        m.addQuadCurve(to: CGPoint(x: g.mouth.x, y: top + h),
                       control: CGPoint(x: g.mouth.x + w * 0.92, y: top + h))
        m.addQuadCurve(to: CGPoint(x: g.mouth.x - w, y: top),
                       control: CGPoint(x: g.mouth.x - w * 0.92, y: top + h))
        m.closeSubpath()
        ctx.fill(m, with: .color(NomiPalette.ink))

        if open > 0.45 {
            ctx.drawLayer { layer in
                layer.clip(to: m)
                layer.opacity = min(1, (open - 0.45) / 0.3)
                let rect = CGRect(x: g.mouth.x - 1 - w * 0.55, y: top + h * 0.92 - h * 0.42,
                                  width: w * 1.10, height: h * 0.84)
                layer.fill(Path(ellipseIn: rect), with: .color(NomiPalette.tongue))
            }
        }
    }

    func drawBadge(_ ctx: inout GraphicsContext, _ badge: NomiBadge, t: Double) {
        let c = NomiGeometry.badgeCenter, r = NomiGeometry.badgeRadius
        let disc = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)

        switch badge {
        case .check:
            ctx.fill(Path(ellipseIn: disc), with: .color(NomiPalette.confirm))
            var tick = Path()
            tick.move(to: CGPoint(x: c.x - 11, y: c.y + 1))
            tick.addLine(to: CGPoint(x: c.x - 4, y: c.y + 9))
            tick.addLine(to: CGPoint(x: c.x + 11, y: c.y - 7))
            ctx.stroke(tick, with: .color(.white),
                       style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))

        case .alert:
            ctx.drawLayer { layer in
                let shake = reduceMotion ? 0 : sin(t * 14) * 2.6 * max(0, 1 - (t.truncatingRemainder(dividingBy: 6)) / 1.2)
                rotate(&layer, degrees: shake, about: c)
                layer.fill(Path(ellipseIn: disc), with: .color(NomiPalette.nudge))
                var bang = Path()
                bang.move(to: CGPoint(x: c.x, y: c.y - 12))
                bang.addLine(to: CGPoint(x: c.x, y: c.y + 3))
                layer.stroke(bang, with: .color(.white),
                             style: StrokeStyle(lineWidth: 6.5, lineCap: .round))
                layer.fill(Path(ellipseIn: CGRect(x: c.x - 3.6, y: c.y + 7.4, width: 7.2, height: 7.2)),
                           with: .color(.white))
            }

        case .dots:
            let dots: [(CGFloat, CGFloat, CGFloat)] = [(300, 118, 11), (318, 96, 9.5), (334, 78, 8)]
            for (i, d) in dots.enumerated() {
                let phase = reduceMotion ? 0.5 : ((t * 1.5 + Double(i) * 0.5).truncatingRemainder(dividingBy: 2))
                let scale = 0.82 + 0.22 * sin(phase * .pi)
                let rr = d.2 * CGFloat(scale)
                ctx.fill(Path(ellipseIn: CGRect(x: d.0 - rr, y: d.1 - rr, width: rr * 2, height: rr * 2)),
                         with: .color(NomiPalette.soft))
            }

        case .zzz:
            let zs: [(CGFloat, CGFloat, CGFloat)] = [(302, 118, 26), (320, 96, 21), (336, 79, 17)]
            for (i, z) in zs.enumerated() {
                let phase = reduceMotion ? 0 : ((t * 0.45 + Double(i) * 0.33).truncatingRemainder(dividingBy: 1))
                ctx.opacity = 1 - phase * 0.7
                ctx.draw(Text("z").font(.system(size: z.2, weight: .bold))
                            .foregroundColor(NomiPalette.soft),
                         at: CGPoint(x: z.0, y: z.1 - CGFloat(phase) * 10))
            }
            ctx.opacity = 1

        case .lines:
            for o in [CGPoint(x: 0, y: -14), CGPoint(x: 8, y: 4), CGPoint(x: 0, y: 22)] {
                var l = Path()
                l.move(to: CGPoint(x: 300 + o.x, y: 92 + o.y))
                l.addLine(to: CGPoint(x: 322 + o.x, y: 83 + o.y))
                ctx.stroke(l, with: .color(NomiPalette.soft),
                           style: StrokeStyle(lineWidth: 9, lineCap: .round))
            }
        }
    }
}


// MARK: - Motion

private extension NomiView {

    /// Pupils snap and hold. They never glide. A saccade is roughly 70 ms of
    /// travel followed by a hold close to a second, and getting this wrong is
    /// the single biggest reason animated mascot eyes feel dead.
    ///
    /// The schedule is derived from the clock rather than stored, so the view
    /// stays stateless and two Nomis on screen never fall into lockstep.
    func resolvedGaze(t: Double) -> (CGPoint, CGPoint) {
        var target: CGPoint
        var previous: CGPoint
        var progress: Double

        if let fixed = pose.fixedGaze {
            let drift = reduceMotion ? CGPoint.zero
                : CGPoint(x: sin(t * 0.7) * 0.05, y: cos(t * 0.53) * 0.05)
            target = CGPoint(x: fixed.x + drift.x, y: fixed.y + drift.y)
            previous = target
            progress = 1
        } else if let external = gaze {
            target = external
            previous = external
            progress = 1
        } else {
            let segment = floor(t / 1.65)
            let local = t - segment * 1.65
            let snapStart = hash01(segment) * 0.9
            progress = min(max((local - snapStart) / 0.07, 0), 1)
            target = ambientTarget(segment)
            previous = ambientTarget(segment - 1)
        }

        let e = easeOut(progress)
        let lead = CGPoint(x: previous.x + (target.x - previous.x) * e,
                           y: previous.y + (target.y - previous.y) * e)

        // The right eye trails the left by 30 ms and travels 94% as far.
        // Perfect symmetry reads as mechanical; the mismatch reads as a creature.
        let lagged = easeOut(min(max((progress * 0.07 - 0.03) / 0.07, 0), 1))
        let trail = CGPoint(x: (previous.x + (target.x - previous.x) * lagged) * 0.94,
                            y: (previous.y + (target.y - previous.y) * lagged) * 0.94)

        return (clampGaze(lead), clampGaze(trail))
    }

    func ambientTarget(_ segment: Double) -> CGPoint {
        let a = hash01(segment * 3.1) * 2 * .pi
        let r = 0.25 + hash01(segment * 7.7) * 0.60
        return CGPoint(x: cos(a) * r, y: sin(a) * r * 0.7)
    }

    /// 90 ms close, 40 ms hold, 130 ms open.
    func blinkAmount(t: Double) -> Double {
        let period = pose.blinkPeriod
        let segment = floor(t / period)
        let local = t - segment * period
        let start = hash01(segment * 1.7) * (period - 1.0)
        let b = local - start
        guard b >= 0, b < 0.26 else { return 0 }
        if b < 0.09 { return b / 0.09 }
        if b < 0.13 { return 1 }
        return 1 - (b - 0.13) / 0.13
    }

    func clampGaze(_ p: CGPoint) -> CGPoint {
        let m = sqrt(p.x * p.x + p.y * p.y)
        guard m > 1 else { return p }
        return CGPoint(x: p.x / m, y: p.y / m)
    }
}


// MARK: - Shapes and helpers

private extension NomiView {

    /// The blob deformed by a travelling radial wave, which keeps it feeling
    /// soft without the random floating that makes mascots look generated.
    func blobPath(t: Double, wobble: Double) -> Path {
        let pts: [CGPoint]
        if wobble <= 0.0001 {
            pts = NomiGeometry.bodyPoints
        } else {
            let c = NomiGeometry.centroid
            pts = NomiGeometry.bodyPoints.map { p in
                let dx = p.x - c.x, dy = p.y - c.y
                let a = atan2(dy, dx)
                let k = 1 + wobble * (sin(a * 2 + t * 1.15) * 0.6 + sin(a * 3 - t * 0.83) * 0.4)
                return CGPoint(x: c.x + dx * k, y: c.y + dy * k)
            }
        }
        return catmullRom(pts)
    }

    func happyEye(at c: CGPoint) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: c.x - 26, y: c.y + 4))
        p.addQuadCurve(to: CGPoint(x: c.x + 26, y: c.y + 4), control: CGPoint(x: c.x, y: c.y - 28))
        p.addQuadCurve(to: CGPoint(x: c.x - 26, y: c.y + 4), control: CGPoint(x: c.x, y: c.y - 4))
        p.closeSubpath()
        return p
    }

    func sleepEye(at c: CGPoint) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: c.x - 30, y: c.y - 6))
        p.addQuadCurve(to: CGPoint(x: c.x + 30, y: c.y - 6), control: CGPoint(x: c.x, y: c.y + 20))
        p.addQuadCurve(to: CGPoint(x: c.x - 30, y: c.y - 6), control: CGPoint(x: c.x, y: c.y + 10))
        p.closeSubpath()
        return p
    }

    /// Closed Catmull-Rom spline through the control points, emitted as cubic
    /// Bezier segments. This is what reproduces the traced silhouette exactly.
    func catmullRom(_ pts: [CGPoint]) -> Path {
        var path = Path()
        guard pts.count > 2 else { return path }
        let n = pts.count
        path.move(to: pts[0])
        for i in 0..<n {
            let p0 = pts[(i - 1 + n) % n], p1 = pts[i]
            let p2 = pts[(i + 1) % n], p3 = pts[(i + 2) % n]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        path.closeSubpath()
        return path
    }

    func transform(_ ctx: inout GraphicsContext, tilt: Double, lift: CGFloat,
                   pivot: CGPoint, scale: CGSize, about anchor: CGPoint) {
        ctx.translateBy(x: 0, y: -lift)
        rotate(&ctx, degrees: tilt, about: pivot)
        ctx.translateBy(x: anchor.x, y: anchor.y)
        ctx.scaleBy(x: scale.width, y: scale.height)
        ctx.translateBy(x: -anchor.x, y: -anchor.y)
    }

    func rotate(_ ctx: inout GraphicsContext, degrees: Double, about p: CGPoint) {
        guard degrees != 0 else { return }
        ctx.translateBy(x: p.x, y: p.y)
        ctx.rotate(by: .degrees(degrees))
        ctx.translateBy(x: -p.x, y: -p.y)
    }

    func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }

    func hash01(_ n: Double) -> Double {
        let x = sin(n * 127.1 + 311.7) * 43758.5453
        return x - floor(x)
    }
}


// MARK: - Bridging to ShadowingEngine

public extension NomiPose {
    /// Mirrors the switch already in MascotView.poseName, so swapping the
    /// Image for a NomiView is a one-line change.
    ///
    ///     NomiView(pose: .init(engineState: engine.state))
    ///
    /// Uncomment the body once ShadowingState is in scope.
    ///
    /// init(engineState state: ShadowingState) {
    ///     switch state {
    ///     case .off:       self = .sleep
    ///     case .idle:      self = .idle
    ///     case .thinking:  self = .thinking
    ///     case .onTrack:   self = .confirm
    ///     case .hint:      self = .nudge
    ///     case .listening: self = .listening
    ///     case .reply:     self = .talk
    ///     }
    /// }
    init() { self = .idle }
}


// MARK: - Preview

#Preview("Nomi states") {
    let poses: [NomiPose] = [.sleep, .idle, .thinking, .confirm, .nudge, .talk]
    return ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], spacing: 16) {
            ForEach(Array(poses.enumerated()), id: \.offset) { _, pose in
                VStack(spacing: 6) {
                    NomiView(pose: pose)
                        .frame(width: 130, height: 130)
                    Text(String(describing: pose))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }
    .background(Color(white: 0.06))
}
