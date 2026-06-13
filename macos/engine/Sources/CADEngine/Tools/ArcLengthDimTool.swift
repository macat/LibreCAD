//
//  ArcLengthDimTool.swift
//  CADEngine
//
//  The interactive ARC-LENGTH dimension creation tool — places a
//  `DimKind.arcLength` dimension measuring the length of a circular arc *along* the
//  arc, shown as a concentric dimension arc with an arc-length symbol (⌒).
//
//  Ported in spirit from LibreCAD's `LC_ActionDimArc`
//  (librecad/src/actions/drawing/draw/dimensions/lc_actiondimarc.*) + `LC_DimArc`
//  (librecad/src/lib/engine/document/entities/lc_dimarc.*), with the magic
//  `int m_status` replaced by an exhaustive private `enum State`. Built against the
//  FROZEN `Tool` contract: a PURE value type that takes already-snapped WORLD
//  points and authors one `.dimension` entity whose graphic is computed in
//  `resolve()` (ADR-001).
//
//  Click sequence:
//    1. an ARC (picked via `context.nearbyEntities`) — fixes the feature arc's
//       center / radius / sweep (.settingEntity → .settingLeader).
//    2. dimension-line location → `DimData.definitionPoint`; the dimension arc is
//       drawn concentric at that point's radius. Commit `.arcLength`, then RESET.
//
//  PURE: reads only the read-only `ToolContext.nearbyEntities` boundary hook to
//  pick the arc; no CADDrawing/Quadtree/GUI access. UNWIRED at creation (registered
//  in a later wire-wave).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionDim* family).
//  Copyright (C) LibreCAD contributors (LC_ActionDimArc / LC_DimArc).
//

import Foundation

/// The interactive Arc-length dimension tool. Click an arc, then a point for the
/// dimension-arc location. Commits one `.arcLength` dimension measuring the picked
/// arc's length, prefixed with the arc symbol (⌒).
public struct ArcLengthDimTool: Tool {

    /// The feature arc's defining data, captured on the pick.
    private struct Feature: Equatable {
        var center: Vector
        var radius: Double
        var startAngle: Double
        var endAngle: Double
        var reversed: Bool
    }

    private enum State: Equatable {
        case settingEntity
        case settingLeader(feature: Feature)
    }

    private var state: State = .settingEntity
    private var cursor: Vector = .invalid

    public init() {}

    public var title: String { "Arc Length Dimension" }

    public var status: String {
        switch state {
        case .settingEntity: return "Select an arc"
        case .settingLeader: return "Specify dimension arc location"
        }
    }

    public var preview: [ResolvedPolyline] {
        guard case .settingLeader(let f) = state, cursor.valid,
              let data = makeData(feature: f, leader: cursor) else { return [] }
        return DimToolSupport.previewLines(data)
    }

    /// Builds the `DimData` for the picked arc + leader point. `definitionPoint`
    /// (the leader point) sets the radius of the concentric dimension arc. Returns
    /// `nil` for a degenerate leader on the center.
    private func makeData(feature f: Feature, leader: Vector) -> DimData? {
        guard leader.distance(to: f.center) > Tolerance.distance else { return nil }
        return DimData(
            kind: .arcLength(center: f.center, radius: f.radius,
                             startAngle: f.startAngle, endAngle: f.endAngle,
                             reversed: f.reversed),
            definitionPoint: leader
        )
    }

    /// The nearest ARC within the pick aperture of `p`, returned as a `Feature`, or
    /// `nil`. Only `.arc` kinds are pickable (a full circle has no finite length).
    private func nearestArc(at p: Vector, context: ToolContext) -> Feature? {
        guard p.valid else { return nil }
        let tol = DimToolSupport.pickTolerance(context)
        var best: Feature?
        var bestDist = Double.greatestFiniteMagnitude
        for e in context.nearbyEntities(p, tol) {
            guard case .arc(let a) = e.kind, a.radius > Tolerance.distance else { continue }
            let d = HitTesting.worldDistance(from: p, to: e)
            if d < bestDist {
                bestDist = d
                best = Feature(center: a.center, radius: a.radius,
                               startAngle: a.startAngle, endAngle: a.endAngle,
                               reversed: a.reversed)
            }
        }
        return best
    }

    /// A draw-from-pick tool: reads `context.nearbyEntities` on the FIRST click to
    /// pick the arc, then emits the new dimension as `.add`.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            return preview.isEmpty ? .none : .preview
        case .click(let p), .value(let p):
            return handleClick(p, context: context)
        case .backspace:
            return handleBackspace()
        case .cancel:
            reset()
            return .finished
        case .commit:
            reset()
            return .finished
        }
    }

    private mutating func handleClick(_ p: Vector, context: ToolContext) -> ToolOutcome {
        guard p.valid else { return .none }
        switch state {
        case .settingEntity:
            guard let f = nearestArc(at: p, context: context) else { return .none }
            state = .settingLeader(feature: f)
            cursor = p
            return .none
        case .settingLeader(let f):
            guard let data = makeData(feature: f, leader: p) else {
                // Leader on the center — keep waiting for a usable leader point.
                return .none
            }
            let record = EntityRecord(id: .placeholder, kind: .dimension(data))
            reset()
            return .commit([.add(record)])
        }
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .settingEntity:
            return .none
        case .settingLeader:
            reset()
            return .preview
        }
    }

    private mutating func reset() {
        state = .settingEntity
        cursor = .invalid
    }
}
