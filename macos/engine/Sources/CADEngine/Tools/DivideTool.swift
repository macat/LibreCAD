//
//  DivideTool.swift
//  CADEngine
//
//  The DIVIDE modify tool — split a selected line / arc / circle / polyline into
//  `N` equal-length segments by placing POINT entities at the interior division
//  points. Ported in spirit from LibreCAD's "Divide" (the DIVIDE command, which
//  drops point nodes that snap targets can hook). The source entity is LEFT in
//  place (Divide only ADDS the division points — it does not break the geometry,
//  matching LibreCAD's point-node behavior; the destructive "break into pieces"
//  is a separate action).
//
//  Behavior:
//    - empty selection → status nudges "Select an object to divide first"; every
//                        input is a no-op.
//    - the tool divides the FIRST supported selected entity into `divisions`
//                        equal arc-length pieces and emits one `.add` POINT per
//                        INTERIOR division point.
//        * OPEN entity (line / arc / open polyline): `divisions` pieces have
//          `divisions − 1` interior points (the two endpoints are NOT duplicated).
//          So a line divided into 5 → 4 points.
//        * CLOSED entity (circle / closed polyline): `divisions` pieces have
//          `divisions` division points around the loop (the start point is one of
//          them; no duplicated wrap point), matching how a circle splits evenly.
//    - `.commit` (Return) / `.click` → fire the division (the point count is
//                        determined by `divisions` + the entity, no pick needed).
//    - `.cancel` (Esc) → discard the captured selection, reset, `.finished`.
//
//  The point positions are computed by EQUAL ARC LENGTH along the entity (so an
//  arc/circle divides by equal sweep, a polyline by equal cumulative length),
//  matching LibreCAD's equal-division semantics.
//
//  PURE (ADR-001 / Tool contract): never touches CADDrawing / Quadtree / GUI. It
//  reads only `ToolContext.selected`, and computes the division points from the
//  entity's DEFINING data (plus `Resolve.expandPolyline` for a polyline's flat
//  point chain). The app applies the `.add` points (re-minting ids) as one
//  undoable group.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original Divide action semantics).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive Divide tool. With a single supported entity selected, place
/// point nodes along it; the source entity stays. Two modes:
///   • `.count(n)`  — DIVIDE: `n − 1` (open) / `n` (closed) nodes at equal
///                    arc-length intervals (the historical default behavior).
///   • `.length(s)` — MEASURE: a node every `s` world units marched from the
///                    start endpoint (LibreCAD's MEASURE command).
public struct DivideTool: Tool {

    // MARK: - Configuration

    /// How the Divide tool places nodes along the entity.
    ///
    /// - `count(n)`:  DIVIDE — split into `n` equal arc-length pieces (the
    ///                division points are the interior boundaries for an open
    ///                entity, the loop boundaries for a closed one). `n` is
    ///                clamped to ≥ 2 when the division fires.
    /// - `length(s)`: MEASURE — drop a node every `s` world units of arc length
    ///                marched from the START endpoint. The start endpoint itself
    ///                (distance 0) is NOT emitted (it is already an endpoint
    ///                snap), and a trailing partial segment shorter than `s`
    ///                yields no node (the remainder is dropped) — matching
    ///                LibreCAD's MEASURE / equidistant "Snap distance" semantics.
    ///                `s` must be > 0; a non-positive spacing yields no nodes.
    public enum DivideMode: Equatable, Sendable {
        case count(Int)
        case length(Double)
    }

    /// The active mode/config. Defaults to `.count(2)` so the historical DIVIDE
    /// behavior is unchanged. It is read LIVE on every `status`/`preview`/`fire` —
    /// nothing is seeded from `mode` at construction (the only state is the captured
    /// selection). The app's options-bar (a later wave) doesn't mutate this in place:
    /// `applyToolConfig` RE-MINTS the tool via `init(mode:)` with the assembled mode
    /// (the ArcTool/LineConstructionTool re-mint pattern). `var` because the
    /// `init(mode:)` convenience and the `divisions` facade setter assign it.
    public var mode: DivideMode

    /// The number of equal pieces to divide into (LibreCAD's division count) — a
    /// convenience facade over `.count(…)` so existing call sites / command-line
    /// wiring that set `tool.divisions = n` keep working. Reading it returns the
    /// count for `.count`, and `0` when the tool is in `.length` mode. Writing it
    /// switches the tool into `.count(n)` mode.
    public var divisions: Int {
        get {
            if case .count(let n) = mode { return n }
            return 0
        }
        set { mode = .count(newValue) }
    }

    // MARK: - State

    private var captured: [EntityRecord] = []

    /// Construct in DIVIDE (count) mode — the historical initializer.
    public init(divisions: Int = 2) {
        self.mode = .count(divisions)
    }

    /// Construct with an explicit mode (DIVIDE-by-count or MEASURE-by-length).
    public init(mode: DivideMode) {
        self.mode = mode
    }

    // MARK: - Tool

    public var title: String { "Divide" }

    public var status: String {
        guard !captured.isEmpty else { return "Select an object to divide first" }
        switch mode {
        case .count(let n):
            return "Press Return to divide into \(Swift.max(2, n)) parts"
        case .length(let s):
            return "Press Return to measure nodes every \(s) units"
        }
    }

    /// The live preview: the division points rendered as degenerate single-point
    /// polylines (the renderer draws them as markers), with the preview pen.
    public var preview: [ResolvedPolyline] {
        divisionPoints().map {
            ResolvedPolyline(points: [$0], closed: false, pen: .toolPreview)
        }
    }

    /// A MODIFY tool: reads `context.selected`, then on fire emits one `.add`
    /// POINT per interior/loop division point. The source entity is untouched.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        if captured.isEmpty, !context.selected.isEmpty {
            captured = context.selected
        }

        switch input {
        case .move:
            return .none

        case .value:
            // A typed coordinate doesn't apply to this selection-based tool — ignore.
            return .none

        case .click, .commit:
            return fire()

        case .backspace:
            return .none

        case .cancel:
            reset()
            return .finished
        }
    }

    // MARK: - Fire

    private mutating func fire() -> ToolOutcome {
        let pts = divisionPoints()
        guard !pts.isEmpty else {
            // Nothing dividable (no/unsupported selection) → keep waiting.
            return captured.isEmpty ? .none : .none
        }
        // Inherit the divided entity's layer/pen so the nodes live with it.
        let source = firstDividable()
        let edits: [ToolEdit] = pts.map { p in
            .add(EntityRecord(
                id: .placeholder,
                layer: source?.layer ?? .zero,
                pen: source?.pen ?? .byLayer,
                flags: .default,
                kind: .point(PointData(position: p))
            ))
        }
        reset()
        return .commit(edits)
    }

    private mutating func reset() {
        captured = []
    }

    // MARK: - Division geometry (pure)

    /// The first selected entity the Divide tool supports (line / arc / circle /
    /// polyline). `nil` if none is selected or none is supported.
    private func firstDividable() -> EntityRecord? {
        captured.first { record in
            switch record.kind {
            case .line, .arc, .circle, .polyline: return true
            default: return false
            }
        }
    }

    /// The division points along the first supported selected entity. Empty when
    /// nothing dividable is selected or the mode/config is degenerate. Routes by
    /// `mode`: `.count` → equal-segment DIVIDE; `.length` → MEASURE-by-spacing.
    private func divisionPoints() -> [Vector] {
        guard let record = firstDividable() else { return [] }
        switch mode {
        case .count(let raw):
            let n = Swift.max(2, raw)
            switch record.kind {
            case .line(let d):
                return Self.divideLine(d, into: n)
            case .arc(let d):
                return Self.divideArc(d, into: n)
            case .circle(let d):
                return Self.divideCircle(d, into: n)
            case .polyline(let d):
                return Self.dividePolyline(d, into: n)
            default:
                return []
            }
        case .length(let spacing):
            return Self.measureNodes(record.kind, spacing: spacing)
        }
    }

    // MARK: - MEASURE (by fixed length, pure)

    /// Nodes placed every `spacing` world units of arc length along the entity,
    /// marched from the START endpoint. Reuses the equidistant `SnapGeometry`
    /// "Snap distance" helpers, so the convention is exactly LibreCAD's MEASURE:
    ///
    ///   • the START endpoint (distance 0) is NOT emitted (it is already an
    ///     endpoint snap);
    ///   • nodes are at `1·spacing, 2·spacing, …` strictly inside the entity;
    ///   • a trailing partial segment shorter than `spacing` produces no node —
    ///     the remainder is dropped (so a 10-unit line at spacing 3 → nodes at
    ///     3, 6, 9 and the final 1-unit stub is left empty);
    ///   • a non-positive `spacing` (or a degenerate entity) → no nodes.
    ///
    /// A CIRCLE has no canonical start endpoint; MEASURE marches from angle 0
    /// (the +X point, matching `divideCircle`'s reference) all the way around,
    /// emitting nodes at `1·spacing, 2·spacing, …` of arc length and dropping the
    /// trailing remainder before the full circumference.
    static func measureNodes(_ kind: EntityKind, spacing: Double) -> [Vector] {
        guard spacing > Tolerance.distance else { return [] }
        switch kind {
        case .line(let d):
            return SnapGeometry.pointsAlongLine(start: d.start, end: d.end,
                                                spacing: spacing, fromStart: true)
        case .arc(let d):
            return SnapGeometry.pointsAlongArc(center: d.center, radius: d.radius,
                                               startAngle: d.startAngle, endAngle: d.endAngle,
                                               reversed: d.reversed,
                                               spacing: spacing, fromStart: true)
        case .circle(let d):
            // A circle has no canonical endpoint: march the FULL circumference
            // (a 0 → 2π CCW arc) from the +X point — the same reference angle as
            // `divideCircle`. `pointsAlongArc` computes EXACT arc length (no
            // tessellation), so nodes land at 1·spacing, 2·spacing, … and the
            // trailing partial arc before 2π is dropped.
            return SnapGeometry.pointsAlongArc(center: d.center, radius: d.radius,
                                               startAngle: 0, endAngle: 2 * Double.pi,
                                               reversed: false,
                                               spacing: spacing, fromStart: true)
        case .polyline(let d):
            let pts = EntityKind.expandPolyline(d, ctx: .default)
            guard pts.count >= 2 else { return [] }
            return SnapGeometry.pointsAlongPolyline(points: pts, closed: d.closed,
                                                    spacing: spacing, fromStart: true)
        default:
            return []
        }
    }

    /// `n − 1` interior points evenly spaced between the line's endpoints.
    static func divideLine(_ d: LineData, into n: Int) -> [Vector] {
        guard n >= 2 else { return [] }
        let step = (d.end - d.start) / Double(n)
        return (1..<n).map { d.start + step * Double($0) }
    }

    /// `n − 1` interior points along the arc at equal sweep. The arc travels in
    /// its `reversed` direction over the normalized signed sweep (same convention
    /// as `Tessellation.arcPoints`), and the interior division angles are sampled
    /// at `startAngle + k · (sweep / n)` for k = 1 … n−1.
    static func divideArc(_ d: ArcData, into n: Int) -> [Vector] {
        guard n >= 2 else { return [] }
        let twoPi = 2 * Double.pi
        var sweep = d.reversed ? (d.startAngle - d.endAngle) : (d.endAngle - d.startAngle)
        sweep = sweep.truncatingRemainder(dividingBy: twoPi)
        if sweep <= Tolerance.angle { sweep += twoPi }
        let signed = d.reversed ? -sweep : sweep
        let step = signed / Double(n)
        return (1..<n).map { k in
            let a = d.startAngle + step * Double(k)
            return d.center + Vector.polar(radius: d.radius, angle: a)
        }
    }

    /// `n` points around the circle at equal sweep (a closed loop → the start
    /// point counts; no duplicated wrap point). Starts at angle 0 (the +X point)
    /// and steps CCW by `2π / n`.
    static func divideCircle(_ d: CircleData, into n: Int) -> [Vector] {
        guard n >= 2 else { return [] }
        let step = (2 * Double.pi) / Double(n)
        return (0..<n).map { k in
            d.center + Vector.polar(radius: d.radius, angle: step * Double(k))
        }
    }

    /// Division points along a polyline by equal CUMULATIVE arc length. Uses the
    /// shared `EntityKind.expandPolyline` flat-point chain (so bulged segments are
    /// followed along their arc, and the closed-loop convention matches the
    /// renderer). OPEN → `n − 1` interior points; CLOSED → `n` loop points (the
    /// start counts, the implicit closing edge is included in the total length).
    static func dividePolyline(_ d: PolylineData, into n: Int) -> [Vector] {
        guard n >= 2, d.vertices.count >= 2 else { return [] }
        var pts = EntityKind.expandPolyline(d, ctx: .default)
        guard pts.count >= 2 else { return [] }
        // For a closed polyline the flat chain omits the wrap point; append it so
        // the cumulative length includes the implicit closing edge.
        if d.closed, let first = pts.first {
            pts.append(first)
        }

        // Cumulative arc length at each sample point.
        var cum: [Double] = [0]
        cum.reserveCapacity(pts.count)
        for i in 1..<pts.count {
            cum.append(cum[i - 1] + pts[i].distance(to: pts[i - 1]))
        }
        let total = cum.last ?? 0
        guard total > Tolerance.distance else { return [] }

        // Targets: open → interior 1…n−1; closed → loop 0…n−1 (start counts).
        let targets: [Double]
        if d.closed {
            targets = (0..<n).map { total * Double($0) / Double(n) }
        } else {
            targets = (1..<n).map { total * Double($0) / Double(n) }
        }

        return targets.map { Self.pointAtLength($0, points: pts, cum: cum) }
    }

    /// Linearly interpolates the world point at cumulative arc length `s` along the
    /// flat sample chain `points` (with prefix-sum lengths `cum`). Clamps `s` to
    /// `[0, total]`.
    static func pointAtLength(_ s: Double, points: [Vector], cum: [Double]) -> Vector {
        guard let total = cum.last, total > 0 else { return points.first ?? .invalid }
        let target = Swift.min(Swift.max(0, s), total)
        // Find the segment [i-1, i] whose cumulative length brackets `target`.
        var i = 1
        while i < cum.count && cum[i] < target { i += 1 }
        if i >= cum.count { return points[points.count - 1] }
        let segLen = cum[i] - cum[i - 1]
        guard segLen > Tolerance.distance else { return points[i - 1] }
        let t = (target - cum[i - 1]) / segLen
        return points[i - 1] + (points[i] - points[i - 1]) * t
    }
}
