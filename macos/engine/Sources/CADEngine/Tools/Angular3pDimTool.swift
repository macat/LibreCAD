//
//  Angular3pDimTool.swift
//  CADEngine
//
//  The interactive 3-POINT ANGULAR dimension creation tool — places a
//  `DimKind.angular3p` dimension measuring the angle at a vertex between two rays
//  defined by three picked points (vertex, point-on-ray-1, point-on-ray-2).
//
//  Ported in spirit from LibreCAD's 3-point angular path in `RS_ActionDimAngular`
//  (librecad/src/actions/drawing/draw/dimensions/rs_actiondimangular.*) +
//  `RS_DimAngular` (the angular3p constructor), with the magic `int m_status`
//  replaced by an exhaustive private `enum State`. Built against the FROZEN `Tool`
//  contract: a PURE value type that takes already-snapped WORLD points and authors
//  one `.dimension` entity whose graphic is computed in `resolve()` (ADR-001).
//
//  Click sequence:
//    1. angle vertex          (.settingVertex → .settingPoint1)
//    2. point on first ray    (.settingPoint1 → .settingPoint2)
//    3. point on second ray   (.settingPoint2 → .settingArc)
//    4. dimension arc location → `DimData.definitionPoint`; the arc-location click
//       SELECTS which of the two sectors the dimension spans (the resolve's
//       `dimAngularGeometry` spans the sector the def point sits in). Commit
//       `.angular3p`, then RESET.
//
//  PURE: never touches CADDrawing/Quadtree/GUI; ignores `context` (it needs only
//  the snapped points). UNWIRED at creation (registered in a later wire-wave).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionDim* family).
//

import Foundation

/// The interactive 3-point Angular dimension tool. See the file header for the
/// click sequence. The arc-location click chooses the measured sector.
public struct Angular3pDimTool: Tool {

    private enum State: Equatable {
        case settingVertex
        case settingPoint1(vertex: Vector)
        case settingPoint2(vertex: Vector, point1: Vector)
        case settingArc(vertex: Vector, point1: Vector, point2: Vector)
    }

    private var state: State = .settingVertex
    private var cursor: Vector = .invalid

    public init() {}

    public var title: String { "Angular Dimension (3-point)" }

    public var status: String {
        switch state {
        case .settingVertex: return "Specify angle vertex"
        case .settingPoint1: return "Specify first angle endpoint"
        case .settingPoint2: return "Specify second angle endpoint"
        case .settingArc:    return "Specify dimension arc location"
        }
    }

    public var preview: [ResolvedPolyline] {
        guard case .settingArc(let v, let p1, let p2) = state, cursor.valid,
              v.valid, p1.valid, p2.valid else { return [] }
        let data = DimData(
            kind: .angular3p(vertex: v, point1: p1, point2: p2),
            definitionPoint: cursor
        )
        return DimToolSupport.previewLines(data)
    }

    /// A draw tool: it IGNORES `context` and emits the new dimension as `.add`.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            return preview.isEmpty ? .none : .preview
        case .click(let p), .value(let p):
            return handleClick(p)
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

    private mutating func handleClick(_ p: Vector) -> ToolOutcome {
        guard p.valid else { return .none }
        switch state {
        case .settingVertex:
            state = .settingPoint1(vertex: p)
            cursor = p
            return .none
        case .settingPoint1(let vertex):
            // Ignore a ray-1 point coincident with the vertex (no ray direction).
            guard p.distance(to: vertex) > Tolerance.distance else { return .none }
            state = .settingPoint2(vertex: vertex, point1: p)
            cursor = p
            return .none
        case .settingPoint2(let vertex, let point1):
            guard p.distance(to: vertex) > Tolerance.distance else { return .none }
            state = .settingArc(vertex: vertex, point1: point1, point2: p)
            cursor = p
            return .none
        case .settingArc(let vertex, let point1, let point2):
            let record = EntityRecord(
                id: .placeholder,
                kind: .dimension(DimData(
                    kind: .angular3p(vertex: vertex, point1: point1, point2: point2),
                    definitionPoint: p
                ))
            )
            reset()
            return .commit([.add(record)])
        }
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .settingVertex:
            return .none
        case .settingPoint1:
            reset()
            return .preview
        case .settingPoint2(let vertex, _):
            state = .settingPoint1(vertex: vertex)
            cursor = vertex
            return .preview
        case .settingArc(let vertex, let point1, _):
            state = .settingPoint2(vertex: vertex, point1: point1)
            cursor = point1
            return .preview
        }
    }

    private mutating func reset() {
        state = .settingVertex
        cursor = .invalid
    }
}
