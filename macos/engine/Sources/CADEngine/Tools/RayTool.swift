//
//  RayTool.swift
//  CADEngine
//
//  The semi-infinite construction-line (RAY) draw tool. Ported in spirit from
//  LibreCAD's construction-line actions (librecad/src/lib/actions/drawing/draw/),
//  reduced to the engine's pure-value `Tool` contract: pick a BASE (start) point,
//  then a SECOND point that fixes the direction; the committed entity is a
//  `.ray` from the base toward that direction (one way only).
//
//  PURE: it never touches CADDrawing/Quadtree/GUI. It receives already-snapped
//  world points and returns outcomes/preview; the app re-mints ids on commit.
//  UNWIRED — registered into `ToolKind` + the toolbar/menu in wire-wave-3.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionDrawLine* construction).
//

import Foundation

/// The interactive ray (semi-infinite construction line) tool. Click a base
/// (start) point, then a second point to fix the direction; it commits a `.ray`
/// running from the base toward that point and continues from the SAME base until
/// `.commit`/`.cancel` (a common construction workflow is several rays fanning
/// from one origin).
public struct RayTool: Tool {

    // MARK: - Private state machine

    private enum State: Equatable {
        /// Waiting for the base (start) point.
        case settingBase
        /// Base fixed at `base`; waiting for the direction point.
        case settingDirection(base: Vector)
    }

    private var state: State = .settingBase
    private var cursor: Vector = .invalid

    public init() {}

    // MARK: - Tool

    public var title: String { "Ray" }

    public var status: String {
        switch state {
        case .settingBase:      return "Specify start point"
        case .settingDirection: return "Specify direction point"
        }
    }

    /// The live rubber-band: a large finite segment from the base toward the
    /// cursor (the on-screen stand-in for the semi-infinite ray; the renderer /
    /// view-clip wiring is a documented follow-up).
    public var preview: [ResolvedPolyline] {
        guard case .settingDirection(let base) = state, base.valid, cursor.valid else {
            return []
        }
        let d = cursor - base
        guard d.magnitude > Tolerance.distance else { return [] }
        let seg = Self.previewSegment(base: base, direction: d)
        return [ResolvedPolyline(points: [seg.0, seg.1], closed: false, pen: .toolPreview)]
    }

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
            // Each ray was committed on its second click; nothing pending.
            reset()
            return .finished
        }
    }

    // MARK: - Click / backspace

    private mutating func handleClick(_ p: Vector) -> ToolOutcome {
        switch state {
        case .settingBase:
            state = .settingDirection(base: p)
            cursor = p
            return .none

        case .settingDirection(let base):
            let dir = p - base
            guard dir.magnitude > Tolerance.distance else {
                // Degenerate (zero-length) pick — keep waiting.
                return .none
            }
            let record = EntityRecord(
                id: .placeholder,
                kind: .ray(RayData(base: base, direction: dir))
            )
            cursor = p
            return .commit([.add(record)])
        }
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .settingBase:
            return .none
        case .settingDirection:
            reset()
            return .preview
        }
    }

    private mutating func reset() {
        state = .settingBase
        cursor = .invalid
    }

    // MARK: - Preview geometry

    /// How far the preview segment runs from the base toward the direction (the
    /// large-finite stand-in for the semi-infinite ray; matches the engine's
    /// large-segment resolve fallback).
    static let previewLength: Double = 1e6

    static func previewSegment(base: Vector, direction: Vector) -> (Vector, Vector) {
        let len = direction.magnitude
        let dir = len > Tolerance.distance ? direction / len : Vector(1, 0)
        return (base, base + dir * previewLength)
    }
}
