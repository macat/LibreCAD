//
//  ArrayPathTool.swift
//  CADEngine
//
//  The ARRAY-ALONG-PATH modify tool — distribute `N` copies of the current
//  selection along a picked PATH entity (line / arc / polyline) at EQUAL
//  arc-length spacing. Ported in spirit from LibreCAD's "measure / divide along
//  path" array mode (the path-array variant of `lc_actionmodifyarray.cpp`, which
//  walks the path's cumulative arc length and stamps the item at each station):
//  the array PARAMETERS (`count`, `alignToTangent`) come from a dialog (modeled
//  here as the tool's `config`), the selection is the set to replicate, and the
//  ORIGINALS stay in place — only the `N` distributed copies are committed.
//
//  This tool is a sibling of `ArrayTool` (rectangular / polar) and shares its
//  contract conventions, but the spacing math is path-driven rather than grid /
//  ring driven:
//
//  Behavior:
//    - empty selection → status nudges "Select objects to array along a path
//                        first"; every input is a no-op (nothing to array).
//    - PATH supplied in the config (`config.path != nil`): the tool is `.ready`
//                        and `.commit`/`.click` fires immediately.
//    - PATH NOT in the config: the tool is `.pickingPath`; the FIRST `.click`
//                        supplies the path (the nearest line/arc/polyline under
//                        the pick, via `context.nearbyEntities`) and fires.
//    - SPACING: the path is tessellated to its resolve polyline points, the
//                        cumulative chord length is walked, and `count` STATIONS
//                        are placed at equal arc-length. For an OPEN path the
//                        stations span both endpoints inclusive (station `i` at
//                        arc-length `i/(count−1) · L`, so the first sits at the
//                        path start and the last at the path end). For a CLOSED
//                        path they wrap evenly (station `i` at `i/count · L`, so
//                        no copy lands on top of the first).
//    - PLACEMENT: each copy is the selection TRANSLATED so the selection's anchor
//                        (its combined bounding-box center) moves from its current
//                        position to the station. When `alignToTangent == true`
//                        each copy is additionally ROTATED about that station to
//                        the local path direction (the tangent of the segment the
//                        station lies on); otherwise copies stay axis-aligned.
//    - COUNT: `count` copies are committed (one per station). A `count ≤ 0` or a
//                        degenerate / zero-length path yields no copies; the fire
//                        finishes the run. (Unlike the rectangular / polar arrays,
//                        the path array does NOT treat a station as "the original"
//                        — the original is not on the path, so all `count` stations
//                        are real distributed copies, matching the common
//                        measure-along-path semantic.)
//    - `.move`         → updates the cursor for the live preview while picking the
//                        path (path-in-config arrays preview immediately).
//    - `.cancel` (Esc) → discard captured selection / pending path, reset,
//                        `.finished`.
//
//  PURE (ADR-001 / Tool contract): never touches CADDrawing / Quadtree / GUI. It
//  reads only `ToolContext.selected` / `nearbyEntities`, receives already-snapped
//  world points, and builds every copy through the shared
//  `EntityKind.transformed(by:)` / `Affine2D` — the single source of truth for
//  "transform an entity". The path is tessellated via the same `resolve()` /
//  `Tessellation` the renderer uses, so the spacing matches what the user sees.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionModify* array semantics).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive Array-along-path tool. With a selection active, replicate it
/// at `count` equal-arc-length stations along a picked path entity (configured
/// via `config`), committing the `count` distributed copies and leaving the
/// originals untouched.
public struct ArrayPathTool: Tool {

    // MARK: - Configuration (the "array-along-path dialog" modeled as a value)

    /// The path-array parameters. In LibreCAD these come from the array dialog;
    /// here they are a value the app constructs (or a test injects), so the tool
    /// stays pure and deterministic.
    public struct Config: Sendable, Equatable {
        /// How many copies to distribute along the path (each at one station).
        public var count: Int
        /// When `true`, each copy is rotated to the local path tangent at its
        /// station; when `false`, copies keep their original (axis-aligned)
        /// orientation and are only translated to the station.
        public var alignToTangent: Bool
        /// The path entity to array along. When `nil`, the first click supplies it
        /// (the nearest line / arc / polyline under the pick).
        public var path: EntityRecord?

        public init(count: Int, alignToTangent: Bool, path: EntityRecord? = nil) {
            self.count = count
            self.alignToTangent = alignToTangent
            self.path = path
        }

        /// A sensible default (5 copies, tangent-aligned, path picked on click) so
        /// the no-arg `ArrayPathTool()` is usable; the app overrides it from the
        /// dialog.
        public static let `default` = Config(count: 5, alignToTangent: true, path: nil)
    }

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle.
    private enum State: Equatable {
        /// A path is already in the config: ready to fire on `.commit`/`.click`.
        case ready
        /// No config path: waiting for the user to pick the path with a click.
        case pickingPath
    }

    /// The array parameters. Public so the app can set them from the dialog.
    public var config: Config

    private var state: State

    /// The selection captured the first time a non-empty `context.selected` is
    /// seen, so preview/commit operate on a stable set. Empty until then.
    private var captured: [EntityRecord] = []

    /// The last cursor point (drives the path-preview hover before the pick).
    private var cursor: Vector = .invalid

    public init(config: Config = .default) {
        self.config = config
        self.state = config.path == nil ? .pickingPath : .ready
    }

    // MARK: - Tool

    public var title: String { "Array Along Path" }

    public var status: String {
        if captured.isEmpty { return "Select objects to array along a path first" }
        switch state {
        case .ready:        return "Press Return to array along the path"
        case .pickingPath:  return "Pick the path to array along"
        }
    }

    /// The live rubber-band: every committed copy resolved with the preview pen.
    /// Shown as soon as a selection is captured AND a path is available (from the
    /// config, or — while picking — none yet, so nothing previews until the click).
    public var preview: [ResolvedPolyline] {
        guard !captured.isEmpty, let path = config.path else { return [] }
        let transforms = Self.copyTransforms(
            captured: captured, path: path, config: config
        )
        guard !transforms.isEmpty else { return [] }
        return captured.flatMap { record -> [ResolvedPolyline] in
            transforms.flatMap { t -> [ResolvedPolyline] in
                record.kind.transformed(by: t)
                    .resolve(pen: .toolPreview, ctx: .default)
                    .polylines
            }
        }
    }

    /// A MODIFY tool: it reads `context.selected` to capture the set to array,
    /// then emits one `.add` per station (originals stay).
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        // Capture the selection the first time a non-empty one is seen.
        if captured.isEmpty, !context.selected.isEmpty {
            captured = context.selected
        }

        switch input {
        case .value:
            // A typed coordinate doesn't apply to this selection-based MODIFY tool.
            return .none

        case .move(let p):
            cursor = p
            return (state == .ready && !preview.isEmpty) ? .preview : .none

        case .click(let p):
            return handleClick(p, context: context)

        case .commit:
            return handleFire(pathOverride: nil)

        case .backspace:
            return .none

        case .cancel:
            reset()
            return .finished
        }
    }

    // MARK: - Click / fire handling

    private mutating func handleClick(_ p: Vector, context: ToolContext) -> ToolOutcome {
        guard !captured.isEmpty, p.valid else { return .none }
        switch state {
        case .ready:
            // Path already in the config: a click fires the array.
            return handleFire(pathOverride: nil)
        case .pickingPath:
            // Pick the nearest path entity under the click; if found, fire.
            guard let path = Self.pickPath(at: p, context: context) else {
                return .none   // nothing pickable here — keep waiting
            }
            return handleFire(pathOverride: path)
        }
    }

    /// Builds and commits the copy edits if the array is fully specified, else a
    /// no-op (e.g. a path-array still missing its path). A fully-specified array
    /// that produces ZERO copies (e.g. a count ≤ 0 or a zero-length path) finishes
    /// the run rather than committing nothing-and-waiting.
    private mutating func handleFire(pathOverride: EntityRecord?) -> ToolOutcome {
        guard !captured.isEmpty else {
            reset(); return .finished
        }
        guard let path = pathOverride ?? config.path else {
            // A path-array still missing its path is NOT fireable — keep waiting.
            return .none
        }
        let transforms = Self.copyTransforms(
            captured: captured, path: path, config: config
        )
        let edits: [ToolEdit] = captured.flatMap { record in
            transforms.map { t in
                ToolEdit.add(EntityRecord(
                    id: .placeholder,
                    layer: record.layer,
                    pen: record.pen,
                    flags: record.flags.subtracting(.selected),
                    kind: record.kind.transformed(by: t)
                ))
            }
        }
        reset()
        return edits.isEmpty ? .finished : .commit(edits)
    }

    // MARK: - Path picking

    /// The picked tolerance aperture in world units (mirrors `TrimTool`): a
    /// fraction of the grid when present, else a small fixed default.
    static func pickTolerance(_ context: ToolContext) -> Double {
        if let g = context.gridSpacing, g > Tolerance.distance {
            return g * 0.5
        }
        return 0.5
    }

    /// The nearest path entity (line / arc / polyline) within the pick aperture of
    /// `p`, or `nil`. Other kinds are skipped (a path must have a walkable arc
    /// length).
    static func pickPath(at p: Vector, context: ToolContext) -> EntityRecord? {
        let tol = pickTolerance(context)
        var best: EntityRecord?
        var bestDist = Double.greatestFiniteMagnitude
        for e in context.nearbyEntities(p, tol) {
            switch e.kind {
            case .line, .arc, .polyline:
                let d = HitTesting.worldDistance(from: p, to: e)
                if d < bestDist {
                    bestDist = d
                    best = e
                }
            default:
                continue
            }
        }
        return best
    }

    // MARK: - Path walking (cumulative arc length → equal-spaced stations)

    /// A station along the path: the world position to place a copy's anchor at,
    /// plus the local tangent ANGLE (radians) of the path there (for the
    /// align-to-tangent option).
    struct Station: Equatable {
        var position: Vector
        var tangent: Double
    }

    /// Resolves the path entity to the ordered polyline points that approximate it
    /// (the same tessellation the renderer uses), plus whether the polyline is
    /// closed. Lines → 2 points; arcs → arc tessellation; polylines → bulge
    /// expansion. Returns `nil` for a non-path / degenerate (< 2 point) kind.
    static func pathPolyline(_ path: EntityRecord) -> (points: [Vector], closed: Bool)? {
        // Resolve through the shared geometry pipeline so the walked polyline is
        // exactly what the user sees. A path entity resolves to a single polyline.
        let resolved = path.kind.resolve(pen: .toolPreview, ctx: .default)
        guard let first = resolved.polylines.first else { return nil }
        let pts = first.points.filter { $0.valid }
        guard pts.count >= 2 else { return nil }
        return (pts, first.closed)
    }

    /// Walks `points` (optionally closing the loop) and returns `count` stations
    /// at EQUAL arc-length spacing. Open paths span both endpoints inclusive
    /// (`i/(count−1)·L`); closed paths wrap evenly (`i/count·L`, so no copy lands
    /// on the first). Empty when `count ≤ 0`, fewer than 2 points, or a
    /// zero-length path.
    static func stations(points raw: [Vector], closed: Bool, count: Int) -> [Station] {
        guard count > 0 else { return [] }
        // Build the walked vertex list — append the wrap point for a closed path so
        // the closing edge is part of the arc length.
        var pts = raw
        if closed, let first = pts.first { pts.append(first) }
        guard pts.count >= 2 else { return [] }

        // Cumulative chord length at each vertex.
        var cum: [Double] = [0]
        cum.reserveCapacity(pts.count)
        for i in 1..<pts.count {
            cum.append(cum[i - 1] + pts[i].distance(to: pts[i - 1]))
        }
        let total = cum.last ?? 0
        guard total > Tolerance.distance else { return [] }

        // Equal-arc-length target distances. Open: i/(count−1) for endpoints
        // inclusive (a single copy lands at the start). Closed: i/count so the
        // last copy doesn't coincide with the first.
        var stations: [Station] = []
        stations.reserveCapacity(count)
        let divisor = closed ? Double(count) : Double(Swift.max(1, count - 1))
        for i in 0..<count {
            let target = total * (Double(i) / divisor)
            stations.append(stationAt(arcLength: target, points: pts, cumulative: cum))
        }
        return stations
    }

    /// The station at cumulative arc-length `target` along `points` (with the
    /// matching `cumulative` prefix sums): linearly interpolates the position
    /// within the containing segment and reports that segment's direction as the
    /// tangent angle. Clamps `target` to `[0, total]`.
    static func stationAt(arcLength target: Double, points pts: [Vector], cumulative cum: [Double]) -> Station {
        let total = cum.last ?? 0
        let t = Swift.min(Swift.max(target, 0), total)
        // Find the segment [i, i+1] whose cumulative range contains `t`.
        var seg = pts.count - 2   // default to the last segment (handles t == total)
        for i in 1..<cum.count where cum[i] >= t {
            seg = i - 1
            break
        }
        seg = Swift.min(Swift.max(seg, 0), pts.count - 2)
        let a = pts[seg]
        let b = pts[seg + 1]
        let segLen = cum[seg + 1] - cum[seg]
        let local = segLen > Tolerance.distance ? (t - cum[seg]) / segLen : 0
        let position = a + (b - a) * local
        let tangent = a.angleTo(b)
        return Station(position: position, tangent: tangent)
    }

    // MARK: - Transform generation (the path-array math, pure)

    /// The reference anchor of a captured selection: the center of its combined
    /// bounding box. Each copy is built by mapping this anchor onto a station.
    static func anchor(of captured: [EntityRecord]) -> Vector {
        var box = AABB.empty
        for r in captured { box = box.union(r.kind.boundingBox()) }
        let c = box.center
        return c.valid ? c : Vector(0, 0)
    }

    /// The transforms for the distributed copies — one per station. Each maps the
    /// selection's anchor onto the station (a translation), and — when
    /// `alignToTangent` — additionally rotates about the station to the local path
    /// tangent. Empty when the path is degenerate or `count ≤ 0`.
    static func copyTransforms(captured: [EntityRecord], path: EntityRecord, config: Config) -> [Affine2D] {
        guard config.count > 0, !captured.isEmpty else { return [] }
        guard let (pts, closed) = pathPolyline(path) else { return [] }
        let stops = stations(points: pts, closed: closed, count: config.count)
        guard !stops.isEmpty else { return [] }

        let anchor = anchor(of: captured)
        return stops.map { station -> Affine2D in
            let move = Affine2D.translation(station.position - anchor)
            guard config.alignToTangent else { return move }
            // Rotate about the station to the path tangent, then translate the
            // anchor onto the station (rotate-first composition order: B applied
            // before A in `A * B`).
            let rotate = Affine2D.rotation(angle: station.tangent, about: station.position)
            return rotate * move
        }
    }

    // MARK: - Reset

    private mutating func reset() {
        captured = []
        cursor = .invalid
        state = config.path == nil ? .pickingPath : .ready
    }
}
