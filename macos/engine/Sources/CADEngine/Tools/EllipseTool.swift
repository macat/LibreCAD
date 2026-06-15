//
//  EllipseTool.swift
//  CADEngine
//
//  The center + major-axis-endpoint + minor-point Ellipse draw tool — a concrete
//  `Tool` built to the same template as `CircleTool` / `ArcTool` (private `enum
//  State`, pure value type, no CADDrawing/Quadtree/GUI access). Ported in spirit
//  from LibreCAD's `RS_ActionDrawEllipseAxis`
//  (librecad/src/lib/actions/drawing/draw/ellipse/), with the magic `int
//  m_status` replaced by an exhaustive private `enum State` carrying the picks
//  made so far, and the post-commit re-arm behavior preserved.
//
//  This file also fans out LibreCAD's OTHER ellipse construction variants behind a
//  `Mode` selector (see `EllipseTool.Mode`), each ported in spirit from its
//  `RS_ActionDrawEllipse*` sibling:
//    - `.axis`         → `RS_ActionDrawEllipseAxis` (the ORIGINAL/default — UNCHANGED)
//    - `.fociPoint`    → `RS_ActionDrawEllipseFociPoint`
//    - `.fourPoint`    → `RS_ActionDrawEllipse4Points` (`RS_Ellipse::createFrom4P`)
//    - `.inscribeQuad` → `RS_ActionDrawEllipseInscribe` (`createInscribeQuadrilateral`)
//    - `.arc`          → axis-defined ellipse + start/end angles (elliptic ARC)
//  The variants are built UNWIRED: there is NO new `ToolKind` case; a later
//  wire-wave surfaces them (the app constructs `EllipseTool(mode:)` directly).
//
//  Behavior (`.axis`, center → first axis endpoint → minor-axis distance, FULL
//  ellipse):
//    - click #1 → fix the CENTER (State.settingCenter → .settingMajor).
//                 status: "Specify first axis endpoint".
//    - click #2 → fix the MAJOR-axis endpoint relative to the center:
//                 majorP = (p − center) (State.settingMajor → .settingRatio).
//                 status: "Specify minor axis distance".
//    - `.move` (in .settingRatio) → rubber-band a FULL tessellated ellipse whose
//                 minor/major ratio is the cursor's perpendicular distance to the
//                 major-axis LINE divided by |majorP|, clamped to (0, 1], drawn as
//                 a CLOSED `ResolvedPolyline` (reuses `Tessellation.ellipsePoints`).
//    - click #3 → ratio from that click's perpendicular distance; commit ONE
//                 `.ellipse(EllipseData(center, majorP, ratio, startAngle: 0,
//                 endAngle: 0, reversed: false))` — a WHOLE ellipse (the
//                 `startAngle == endAngle == 0` LibreCAD convention, see
//                 `EllipseData.isArc`) — then RESET to await a new center.
//    - `.backspace` → step back one pick (ratio-pick state → major-pick state →
//                 initial), no commit.
//    - `.cancel` (Esc) → discard the run, reset to the initial state, `.finished`.
//    - `.commit` (Ret) when idle → end the tool; `.finished` (each ellipse was
//                 already committed on its third click).
//    - A degenerate pick (zero major axis, or ratio ≈ 0 i.e. the minor point on
//                 the major-axis line) is IGNORED.
//
//  FULL-ELLIPSE CONVENTION: a committed FULL `EllipseData` carries
//  `startAngle == endAngle == 0`, which `EllipseData.isArc` (and therefore
//  `Tessellation.ellipsePoints`) treats as a WHOLE ellipse — a closed ring of
//  points. The preview tessellates the same way (closed), so what you see while
//  dragging is exactly what gets committed. The `.arc` mode instead emits a
//  non-zero start/end pair (an elliptic arc).
//
//  PURE: it never touches CADDrawing/Quadtree/GUI. It receives already-snapped
//  world points and returns outcomes/preview; the app re-mints ids on commit and
//  IGNORES `context` (a draw tool needs only the snapped points).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionDrawEllipseAxis).
//  Copyright (C) 2011-2016 Dongxu Li (original ellipse construction math).
//

import Foundation

/// The interactive Ellipse tool. By default (`.axis`) it draws the LibreCAD
/// axis-defined full ellipse (center → major-axis endpoint → minor distance);
/// `EllipseTool(mode:)` selects one of the other LibreCAD construction variants
/// (`.fociPoint` / `.fourPoint` / `.inscribeQuad` / `.arc`). All variants commit a
/// single `.ellipse` and re-arm for the next (LibreCAD behavior).
public struct EllipseTool: Tool {

    // MARK: - Construction mode (the UNWIRED variant selector)

    /// Which LibreCAD ellipse construction this tool runs. The default `.axis`
    /// preserves the original `RS_ActionDrawEllipseAxis` behavior unchanged; the
    /// other cases mirror the sibling `RS_ActionDrawEllipse*` actions. There is
    /// deliberately NO `ToolKind` case per mode — a later wire-wave decides how to
    /// surface them; for now the app constructs `EllipseTool(mode:)` directly.
    public enum Mode: Sendable, Equatable {
        /// `RS_ActionDrawEllipseAxis` — center → major-axis endpoint → minor
        /// distance, FULL ellipse. The ORIGINAL, default, unchanged behavior.
        case axis
        /// `RS_ActionDrawEllipseFociPoint` — two FOCUS points + a point ON the
        /// ellipse. center = midpoint of the foci; major radius
        /// a = ½(|F1−P| + |F2−P|); ratio b/a with b = √(a²−c²), c = ½|F1−F2|.
        case fociPoint
        /// `RS_ActionDrawEllipse4Points` — four points the ellipse passes through,
        /// fit by the axis-aligned conic least-squares (`RS_Ellipse::createFrom4P`).
        case fourPoint
        /// `RS_ActionDrawEllipseInscribe` — an ellipse inscribed in a
        /// parallelogram-ish 4-corner box (the midpoint / Steiner inellipse).
        case inscribeQuad
        /// Axis-defined ellipse PLUS start/end angles → an elliptic ARC.
        case arc
    }

    /// The construction mode for this tool instance (fixed for the instance's
    /// life). Defaults to `.axis` — the original behavior.
    public let mode: Mode

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle, ported from `RS_ActionDrawEllipse*`'s status integers
    /// to an exhaustive `enum`. One unified enum spans every mode; each mode walks
    /// only the cases it uses (the `handle` arms switch on `mode` first).
    private enum State: Equatable {
        // --- .axis / .arc shared spine ---
        /// Waiting for the center (no pick yet).
        case settingCenter
        /// Center fixed; waiting for the first axis endpoint (`majorP = pick −
        /// center`). `center` is the fixed center.
        case settingMajor(center: Vector)
        /// Center + major fixed; waiting for the minor-axis distance (ratio =
        /// perpendicular distance to the major line / |majorP|).
        case settingRatio(center: Vector, majorP: Vector)
        /// (`.arc` only) center+major+ratio fixed; waiting for the START angle.
        case settingArcStart(center: Vector, majorP: Vector, ratio: Double)
        /// (`.arc` only) START angle fixed; waiting for the END angle.
        case settingArcEnd(center: Vector, majorP: Vector, ratio: Double, startAngle: Double)

        // --- .fociPoint ---
        /// Waiting for the first focus.
        case settingFocus1
        /// First focus fixed; waiting for the second focus.
        case settingFocus2(focus1: Vector)
        /// Both foci fixed; waiting for a point ON the ellipse.
        case settingFociPoint(focus1: Vector, focus2: Vector)

        // --- .fourPoint / .inscribeQuad (collect N points / corners) ---
        /// Collecting points (4-point fit) or corners (inscribe). `points` holds
        /// the picks so far (0...3); the 4th pick commits.
        case collecting(points: [Vector])
    }

    /// The current state. The initial case depends on the mode.
    private var state: State

    /// The last cursor point seen via `.move`, used to draw the rubber-band even
    /// between clicks. Invalid until the first move.
    private var cursor: Vector = .invalid

    /// Creates an ellipse tool in the given construction `mode` (default `.axis`).
    public init(mode: Mode = .axis) {
        self.mode = mode
        switch mode {
        case .axis, .arc:               self.state = .settingCenter
        case .fociPoint:                self.state = .settingFocus1
        case .fourPoint, .inscribeQuad: self.state = .collecting(points: [])
        }
    }

    // MARK: - Tool

    public var title: String {
        switch mode {
        case .axis:         return "Ellipse"
        case .fociPoint:    return "Ellipse (Foci + Point)"
        case .fourPoint:    return "Ellipse (4 Points)"
        case .inscribeQuad: return "Ellipse (Inscribed)"
        case .arc:          return "Elliptical Arc"
        }
    }

    public var status: String {
        switch state {
        case .settingCenter:    return "Specify center point"
        case .settingMajor:     return "Specify first axis endpoint"
        case .settingRatio:     return "Specify minor axis distance"
        case .settingArcStart:  return "Specify start angle"
        case .settingArcEnd:    return "Specify end angle"
        case .settingFocus1:    return "Specify first focus of ellipse"
        case .settingFocus2:    return "Specify second focus of ellipse"
        case .settingFociPoint: return "Specify a point on the ellipse"
        case .collecting(let pts):
            let n = pts.count + 1
            let noun = (mode == .inscribeQuad) ? "corner" : "point"
            return "Specify \(noun) \(n) of 4"
        }
    }

    /// The live rubber-band. For `.axis` it is a FULL tessellated ellipse driven by
    /// the cursor's perpendicular distance to the major-axis line; for `.arc` it
    /// additionally previews the partial sweep once the start angle is fixed; for
    /// the point-collecting modes it previews the fitted ellipse once enough picks
    /// (plus the cursor) are available. Empty when there is nothing to preview yet.
    public var preview: [ResolvedPolyline] {
        guard let data = previewData() else { return [] }
        let (pts, closed) = Tessellation.ellipsePoints(
            data, tolerance: ResolveContext.default.tessellationTolerance
        )
        guard pts.count >= 2 else { return [] }
        return [ResolvedPolyline(points: pts, closed: closed, pen: .toolPreview)]
    }

    /// The `EllipseData` the current state + cursor would preview, or `nil` when
    /// there is nothing valid to draw yet.
    private func previewData() -> EllipseData? {
        switch state {
        case .settingRatio(let center, let majorP):
            guard cursor.valid, center.valid, majorP.valid,
                  let ratio = Self.ratio(center: center, majorP: majorP, point: cursor) else {
                return nil
            }
            return EllipseData(center: center, majorP: majorP, ratio: ratio)

        case .settingArcStart(let center, let majorP, let ratio):
            // Picking the start angle; preview the whole ellipse as a guide.
            return EllipseData(center: center, majorP: majorP, ratio: ratio)

        case .settingArcEnd(let center, let majorP, let ratio, let startAngle):
            guard cursor.valid else { return nil }
            let endAngle = Self.ellipseAngle(center: center, majorP: majorP, ratio: ratio, point: cursor)
            return EllipseData(center: center, majorP: majorP, ratio: ratio,
                               startAngle: startAngle, endAngle: endAngle, reversed: false)

        case .settingFociPoint(let focus1, let focus2):
            guard cursor.valid else { return nil }
            return Self.fromFociPoint(focus1: focus1, focus2: focus2, point: cursor)

        case .collecting(let pts):
            guard cursor.valid else { return nil }
            let all = pts + [cursor]
            switch mode {
            case .fourPoint:    return all.count == 4 ? Self.fromFourPoints(all) : nil
            case .inscribeQuad: return all.count == 4 ? Self.fromInscribedQuad(all) : nil
            default:            return nil
            }

        default:
            return nil
        }
    }

    /// A draw tool: it IGNORES `context` (it needs only the snapped world points)
    /// and emits new geometry as `.add` edits.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            return preview.isEmpty ? .none : .preview

        case .click(let p), .value(let p):
            // A typed coordinate (U1) places the next point exactly like a click.
            return handleClick(p)

        case .backspace:
            return handleBackspace()

        case .cancel:
            // Esc — discard the run and return to the initial state.
            reset()
            return .finished

        case .commit:
            // Return — end the tool. Each ellipse was already committed on its
            // final click, so there is nothing pending to add here.
            reset()
            return .finished
        }
    }

    // MARK: - Click handling (dispatch by mode)

    private mutating func handleClick(_ p: Vector) -> ToolOutcome {
        switch mode {
        case .axis:         return handleAxisClick(p, commitArc: false)
        case .arc:          return handleAxisClick(p, commitArc: true)
        case .fociPoint:    return handleFociClick(p)
        case .fourPoint:    return handleCollectClick(p, fit: Self.fromFourPoints)
        case .inscribeQuad: return handleCollectClick(p, fit: Self.fromInscribedQuad)
        }
    }

    /// Shared `.axis`/`.arc` click handler. In `.axis` the 3rd click commits the
    /// full ellipse; in `.arc` the 3rd click instead advances to picking the
    /// start/end angles, and the 5th click commits the elliptic arc.
    private mutating func handleAxisClick(_ p: Vector, commitArc: Bool) -> ToolOutcome {
        switch state {
        case .settingCenter:
            state = .settingMajor(center: p)
            cursor = p
            return .none

        case .settingMajor(let center):
            // Second point fixes the major axis: majorP = (p − center). Ignore a
            // degenerate (zero-length) major axis.
            guard center.valid, p.valid else { return .none }
            let majorP = p - center
            guard majorP.magnitude > Tolerance.distance else { return .none }
            state = .settingRatio(center: center, majorP: majorP)
            cursor = p
            return .none

        case .settingRatio(let center, let majorP):
            // Third point fixes the minor/major ratio. Ignore a degenerate
            // (ratio ≈ 0) pick — the minor point on the major-axis line.
            guard center.valid, p.valid,
                  let ratio = Self.ratio(center: center, majorP: majorP, point: p) else {
                return .none
            }
            if commitArc {
                // `.arc`: keep going to pick the start/end angles.
                state = .settingArcStart(center: center, majorP: majorP, ratio: ratio)
                cursor = p
                return .none
            }
            return commitEllipse(EllipseData(center: center, majorP: majorP, ratio: ratio))

        case .settingArcStart(let center, let majorP, let ratio):
            // Fourth point fixes the START ellipse-angle (the parametric angle of
            // the point projected onto the ellipse).
            guard p.valid else { return .none }
            let startAngle = Self.ellipseAngle(center: center, majorP: majorP, ratio: ratio, point: p)
            state = .settingArcEnd(center: center, majorP: majorP, ratio: ratio, startAngle: startAngle)
            cursor = p
            return .none

        case .settingArcEnd(let center, let majorP, let ratio, let startAngle):
            // Fifth point fixes the END ellipse-angle; commit the elliptic ARC.
            guard p.valid else { return .none }
            let endAngle = Self.ellipseAngle(center: center, majorP: majorP, ratio: ratio, point: p)
            // A zero sweep (start ≈ end, i.e. the two angles coincide modulo 2π)
            // would degenerate to a whole ellipse via the `isArc` convention; reject
            // it so an arc stays an arc. `coincident` is true when the raw separation
            // is within tolerance of 0 or 2π (a full turn).
            guard !Self.anglesCoincide(startAngle, endAngle) else { return .none }
            return commitEllipse(EllipseData(
                center: center, majorP: majorP, ratio: ratio,
                startAngle: startAngle, endAngle: endAngle, reversed: false
            ))

        default:
            return .none
        }
    }

    /// `.fociPoint` click handler: focus1 → focus2 → point-on-ellipse → commit.
    private mutating func handleFociClick(_ p: Vector) -> ToolOutcome {
        switch state {
        case .settingFocus1:
            state = .settingFocus2(focus1: p)
            cursor = p
            return .none

        case .settingFocus2(let focus1):
            // The second focus must be distinct from the first.
            guard p.distance(to: focus1) > Tolerance.distance else { return .none }
            state = .settingFociPoint(focus1: focus1, focus2: p)
            cursor = p
            return .none

        case .settingFociPoint(let focus1, let focus2):
            guard let data = Self.fromFociPoint(focus1: focus1, focus2: focus2, point: p) else {
                return .none
            }
            return commitEllipse(data)

        default:
            return .none
        }
    }

    /// Shared 4-pick collector (`.fourPoint` / `.inscribeQuad`): accumulate four
    /// picks, then commit the ellipse `fit` produces (ignoring it if the fit fails
    /// — e.g. four collinear points, or a non-parallelogram box).
    private mutating func handleCollectClick(_ p: Vector, fit: ([Vector]) -> EllipseData?) -> ToolOutcome {
        guard case .collecting(var pts) = state else { return .none }
        guard p.valid else { return .none }
        pts.append(p)
        cursor = p
        if pts.count < 4 {
            state = .collecting(points: pts)
            return .none
        }
        // Fourth pick: try to fit. On failure, drop back to 3 picks (let the user
        // re-pick the last point) rather than committing garbage.
        guard let data = fit(pts) else {
            state = .collecting(points: Array(pts.prefix(3)))
            return .none
        }
        return commitEllipse(data)
    }

    /// Commits one full/arc ellipse and re-arms for the next.
    private mutating func commitEllipse(_ data: EllipseData) -> ToolOutcome {
        let record = EntityRecord(id: .placeholder, kind: .ellipse(data))
        reset()
        return .commit([.add(record)])
    }

    // MARK: - Backspace handling

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .settingCenter, .settingFocus1:
            return .none

        case .settingMajor:
            reset()
            return .preview

        case .settingRatio(let center, _):
            state = .settingMajor(center: center)
            cursor = center
            return .preview

        case .settingArcStart(let center, let majorP, _):
            state = .settingRatio(center: center, majorP: majorP)
            cursor = center
            return .preview

        case .settingArcEnd(let center, let majorP, let ratio, _):
            state = .settingArcStart(center: center, majorP: majorP, ratio: ratio)
            cursor = center
            return .preview

        case .settingFocus2:
            reset()
            return .preview

        case .settingFociPoint(let focus1, _):
            state = .settingFocus2(focus1: focus1)
            cursor = focus1
            return .preview

        case .collecting(let pts):
            guard let last = pts.last else { return .none }
            state = .collecting(points: Array(pts.dropLast()))
            cursor = last
            return .preview
        }
    }

    /// Returns to this mode's initial waiting state.
    private mutating func reset() {
        switch mode {
        case .axis, .arc:               state = .settingCenter
        case .fociPoint:                state = .settingFocus1
        case .fourPoint, .inscribeQuad: state = .collecting(points: [])
        }
        cursor = .invalid
    }

    // MARK: - Ratio from the minor point (.axis / .arc)

    /// The minor/major ratio implied by `point`: its perpendicular distance to the
    /// major-axis LINE (through `center`, direction `majorP`) divided by the major
    /// radius |majorP|, clamped to (0, 1]. Returns `nil` when the major axis is
    /// degenerate or the resulting ratio is ≈ 0 (point on the major-axis line).
    private static func ratio(center: Vector, majorP: Vector, point: Vector) -> Double? {
        let majorLen = majorP.magnitude
        guard majorLen > Tolerance.distance else { return nil }
        let d = point - center
        let cross = abs(d.x * majorP.y - d.y * majorP.x)
        let perp = cross / majorLen
        let raw = perp / majorLen
        guard raw > Tolerance.distance else { return nil }
        return Swift.min(raw, 1.0)
    }

    // MARK: - Elliptic-arc angle from a world point (.arc)

    /// The *ellipse angle* (the parametric angle `a` fed to
    /// `EllipseData.ellipsePoint(a)`) that corresponds to `point`. Mirrors
    /// `RS_Ellipse::getEllipseAngle`: transform the point into the ellipse's local
    /// frame (undo the major-axis rotation, then unscale the minor axis by
    /// `1/ratio`) and take that direction's angle. This is exactly the angle whose
    /// `ellipsePoint` lies on the ray from the center through `point`.
    static func ellipseAngle(center: Vector, majorP: Vector, ratio: Double, point: Vector) -> Double {
        let rot = majorP.angle
        // Into local (unrotated) frame, then unscale Y by the ratio so the ellipse
        // becomes a circle and the angle reads directly.
        let local = (point - center).rotated(by: -rot)
        let unscaledY = (ratio > Tolerance.distance) ? local.y / ratio : local.y
        return Vector.correctAngle(atan2(unscaledY, local.x))
    }

    /// Whether two ellipse angles coincide modulo 2π (their CCW separation is within
    /// the angular tolerance of either 0 or a full turn). Used to reject a
    /// zero-sweep elliptic arc, which would collapse to a whole ellipse under the
    /// `startAngle == endAngle == 0` / `isArc` convention.
    static func anglesCoincide(_ a: Double, _ b: Double) -> Bool {
        let twoPi = 2 * Double.pi
        var diff = (b - a).truncatingRemainder(dividingBy: twoPi)
        if diff < 0 { diff += twoPi }                 // → [0, 2π)
        return diff < Tolerance.angle || (twoPi - diff) < Tolerance.angle
    }

    // MARK: - Foci + point construction (.fociPoint)

    /// Builds an ellipse from two FOCI and a point ON the ellipse, mirroring
    /// `RS_ActionDrawEllipseFociPoint`:
    ///   - center = midpoint of the foci,
    ///   - c      = ½·|F1 − F2|              (focal half-distance),
    ///   - a      = ½·(|F1 − P| + |F2 − P|)  (major radius; the ellipse's defining
    ///              "sum of distances to the foci" is 2a),
    ///   - majorP = unit(F1 − center) · a    (major axis toward F1, length a),
    ///   - ratio  = √(a² − c²) / a = b / a.
    /// Returns `nil` if the foci coincide (c == 0 ⇒ a circle is ambiguous here) or
    /// the point makes a degenerate ellipse (a ≤ c, i.e. on/inside the focal axis).
    static func fromFociPoint(focus1: Vector, focus2: Vector, point: Vector) -> EllipseData? {
        guard focus1.valid, focus2.valid, point.valid else { return nil }
        let center = (focus1 + focus2) * 0.5
        let c = 0.5 * focus1.distance(to: focus2)
        guard c > Tolerance.distance else { return nil }
        let a = 0.5 * (focus1.distance(to: point) + focus2.distance(to: point))
        // A valid ellipse needs a > c (the point must be off the focal segment).
        guard a > c + Tolerance.distance else { return nil }
        let majorDir = (focus1 - center) / c            // unit vector toward F1
        let majorP = majorDir * a
        let b = (a * a - c * c).squareRoot()
        let ratio = b / a
        return EllipseData(center: center, majorP: majorP, ratio: ratio)
    }

    // MARK: - 4-point construction (.fourPoint)

    /// Fits an ellipse through four points, ported from `RS_Ellipse::createFrom4P`.
    ///
    /// METHOD: solve the AXIS-ALIGNED conic (exactly determined by four points)
    /// `c0·x² + c1·x + c2·y² + c3·y = 1` — i.e. an ellipse with NO `xy` cross term,
    /// so its axes are parallel to the world X/Y axes (this is the standard
    /// LibreCAD 4-point interpretation; a full 5-DOF rotated conic needs a fifth
    /// point, so the rotation is fixed to axis-aligned here). Completing the square:
    ///   center  = (−c1/2c0, −c3/2c2),
    ///   d       = 1 + ¼·(c1²/c0 + c3²/c2),   (the centered RHS, so the centered
    ///             conic is c0·x² + c2·y² = d),
    ///   xSemi   = √(d/c0)  (semi-axis along X),  ySemi = √(d/c2)  (along Y).
    /// The LARGER of `xSemi`/`ySemi` is the major axis, so `majorP` points along
    /// whichever axis is longer and `ratio = minor/major ≤ 1` (the engine's
    /// invariant). Returns `nil` when the points are collinear / don't define a
    /// real ellipse (singular solve, or the coefficients aren't both positive).
    static func fromFourPoints(_ p: [Vector]) -> EllipseData? {
        guard p.count == 4, p.allSatisfy({ $0.valid }) else { return nil }
        // Augmented 4×5 matrix for [c0 c1 c2 c3 | 1].
        var m: [[Double]] = []
        for v in p {
            m.append([v.x * v.x, v.x, v.y * v.y, v.y, 1.0])
        }
        guard let dn = linearSolve(m) else { return nil }
        let c0 = dn[0], c1 = dn[1], c2 = dn[2], c3 = dn[3]
        let tol = 1.0e-12
        guard abs(c0) > tol, abs(c2) > tol else { return nil }
        let d = 1.0 + 0.25 * (c1 * c1 / c0 + c3 * c3 / c2)
        guard d / c0 > tol, d / c2 > tol else { return nil }
        let center = Vector(-0.5 * c1 / c0, -0.5 * c3 / c2)
        let xSemi = (d / c0).squareRoot()   // semi-axis along X
        let ySemi = (d / c2).squareRoot()   // semi-axis along Y
        guard xSemi > Tolerance.distance, ySemi > Tolerance.distance else { return nil }
        if ySemi > xSemi {
            // Y is the MAJOR axis.
            return EllipseData(center: center, majorP: Vector(0, ySemi), ratio: xSemi / ySemi)
        }
        return EllipseData(center: center, majorP: Vector(xSemi, 0), ratio: ySemi / xSemi)
    }

    // MARK: - Inscribe-in-quadrilateral construction (.inscribeQuad)

    /// Builds the ellipse inscribed in the PARALLELOGRAM with the four ordered
    /// corners `c` (`[c0, c1, c2, c3]` walking the perimeter), the standard CAD
    /// interpretation of "inscribe in a 4-corner box" for a parallelogram-ish box.
    ///
    /// METHOD (midpoint / Steiner inellipse): the ellipse inscribed in a
    /// parallelogram is the affine image of the incircle of a square, so it TOUCHES
    /// the midpoints of the four sides and is centered at the parallelogram's
    /// center. Its two CONJUGATE semi-diameters are the vectors from the center to
    /// two ADJACENT side-midpoints:
    ///   center = ¼·Σ corners (== diagonal midpoint for a true parallelogram),
    ///   u = midpoint(c0,c1) − center,   v = midpoint(c1,c2) − center.
    /// `u` and `v` are conjugate semi-diameters; `axesFromConjugate` recovers the
    /// true major/minor axes (`majorP`, `ratio`) from them (see that helper). We
    /// REQUIRE a genuine parallelogram (the diagonals must bisect each other) — the
    /// brief scopes this to a "parallelogram-ish" box, and the general
    /// (trapezoid / arbitrary quad) tangent-fit is out of scope; a
    /// non-parallelogram returns `nil`.
    static func fromInscribedQuad(_ c: [Vector]) -> EllipseData? {
        guard c.count == 4, c.allSatisfy({ $0.valid }) else { return nil }
        // Require a parallelogram: the diagonals bisect ⇔ c0 + c2 == c1 + c3.
        let diagA = c[0] + c[2]
        let diagB = c[1] + c[3]
        guard diagA.distance(to: diagB) < 1.0e-6 * (1 + diagA.magnitude) else { return nil }
        let center = (c[0] + c[1] + c[2] + c[3]) * 0.25
        let u = (c[0] + c[1]) * 0.5 - center   // → midpoint of side c0-c1
        let v = (c[1] + c[2]) * 0.5 - center   // → midpoint of side c1-c2
        guard u.magnitude > Tolerance.distance, v.magnitude > Tolerance.distance else { return nil }
        return axesFromConjugate(center: center, u: u, v: v)
    }

    /// Recovers an ellipse's true axes from a pair of CONJUGATE semi-diameters
    /// `u`, `v` (relative to `center`). The map `M = [u v]` sends the unit circle
    /// to the ellipse, so the ellipse's quadratic form is governed by `S = M·Mᵀ`
    /// (a 2×2 symmetric PSD matrix). The eigenvalues of `S` are the SQUARED
    /// semi-axis lengths and its eigenvectors are the axis directions — a robust
    /// closed form that handles non-perpendicular (skewed) conjugate diameters,
    /// unlike a naive Rytz line construction. Returns `nil` for a degenerate pair.
    static func axesFromConjugate(center: Vector, u: Vector, v: Vector) -> EllipseData? {
        // S = M Mᵀ = [[a, b], [b, d]].
        let a = u.x * u.x + v.x * v.x
        let b = u.x * u.y + v.x * v.y
        let dd = u.y * u.y + v.y * v.y
        let trace = a + dd
        let det = a * dd - b * b
        let disc = trace * trace * 0.25 - det
        guard disc >= -Tolerance.distance else { return nil }
        let root = Swift.max(0, disc).squareRoot()
        let lambdaMajor = trace * 0.5 + root   // larger eigenvalue → major²
        let lambdaMinor = trace * 0.5 - root   // smaller eigenvalue → minor²
        guard lambdaMajor > Tolerance.distanceSquared else { return nil }
        let semiMajor = lambdaMajor.squareRoot()
        let semiMinor = Swift.max(0, lambdaMinor).squareRoot()
        // Eigenvector for the major eigenvalue: (b, λ−a), with a fallback.
        var ev = Vector(b, lambdaMajor - a)
        if ev.magnitude < Tolerance.distance { ev = Vector(lambdaMajor - dd, b) }
        if ev.magnitude < Tolerance.distance { ev = Vector(1, 0) }
        let majorDir = ev / ev.magnitude
        let majorP = majorDir * semiMajor
        let ratio = semiMinor / semiMajor
        return EllipseData(center: center, majorP: majorP, ratio: ratio)
    }

    // MARK: - Tiny Gaussian-elimination linear solver (RS_Math::linearSolver)

    /// Solves the square linear system carried in an augmented matrix `m` (each row
    /// is `[a0 … a_{n-1} | b]`), returning the solution vector or `nil` if the
    /// system is singular. Partial-pivoting Gaussian elimination — the value-type
    /// port of LibreCAD's `RS_Math::linearSolver`, kept local so the tool stays
    /// self-contained.
    static func linearSolve(_ matrix: [[Double]]) -> [Double]? {
        var m = matrix
        let n = m.count
        guard n > 0, m.allSatisfy({ $0.count == n + 1 }) else { return nil }
        for col in 0..<n {
            // Partial pivot: find the row with the largest |value| in this column.
            var pivot = col
            var best = abs(m[col][col])
            for r in (col + 1)..<n where abs(m[r][col]) > best {
                best = abs(m[r][col]); pivot = r
            }
            guard best > 1.0e-15 else { return nil }   // singular
            m.swapAt(col, pivot)
            // Eliminate below.
            for r in (col + 1)..<n {
                let f = m[r][col] / m[col][col]
                guard f != 0 else { continue }
                for k in col...n { m[r][k] -= f * m[col][k] }
            }
        }
        // Back-substitution.
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = m[row][n]
            for k in (row + 1)..<n { sum -= m[row][k] * x[k] }
            x[row] = sum / m[row][row]
        }
        return x
    }
}
