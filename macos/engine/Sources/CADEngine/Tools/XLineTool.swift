//
//  XLineTool.swift
//  CADEngine
//
//  The infinite construction-line (XLINE) draw tool. Ported in spirit from
//  LibreCAD's `RS_ActionDrawLineRelAngle` / the construction-line actions
//  (librecad/src/lib/actions/drawing/draw/), reduced to the engine's pure-value
//  `Tool` contract: pick a BASE point, then a SECOND point that fixes the
//  direction; the committed entity is an infinite `.xline` through the base in
//  that direction.
//
//  Constraint modes (cheap, common CAD affordances): the tool can lock the
//  direction to HORIZONTAL, VERTICAL, or a fixed ANGLE while picking the second
//  point — the second point then only selects which side / is otherwise ignored
//  for the angle, exactly like AutoCAD's XLINE H/V/A options.
//
//  PURE: it never touches CADDrawing/Quadtree/GUI. It receives already-snapped
//  world points and returns outcomes/preview; the app re-mints ids on commit.
//  WIRED: registered as `ToolKind.xline`; the direction-constraint `mode` (free /
//  horizontal / vertical / fixed-angle) is surfaced in the Tool Options bar and
//  RE-MINTED via `CanvasModel.applyToolConfig` (Lane M).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionDrawLine* construction).
//

import Foundation

/// The interactive infinite construction-line (XLINE) tool. Click a base point,
/// then a second point to fix the direction; it commits a `.xline` and continues
/// from the SAME base (LibreCAD's construction-line behavior — many lines share a
/// base) until `.commit`/`.cancel`. With a constraint `mode` set the direction is
/// locked (horizontal / vertical / a fixed angle) regardless of the second point.
public struct XLineTool: Tool {

    /// How the direction is determined while picking the second point.
    public enum Mode: Sendable, Equatable {
        /// The direction is base → second point (the free, two-point form).
        case free
        /// The line is locked HORIZONTAL (direction = (1, 0)).
        case horizontal
        /// The line is locked VERTICAL (direction = (0, 1)).
        case vertical
        /// The line is locked to a fixed `angle` (radians, CCW from +X).
        case angle(Double)
    }

    // MARK: - Private state machine

    private enum State: Equatable {
        /// Waiting for the base point.
        case settingBase
        /// Base fixed at `base`; waiting for the second point (the direction).
        case settingDirection(base: Vector)
    }

    private var state: State = .settingBase
    private var cursor: Vector = .invalid

    /// The active direction-constraint mode. `.free` (the default) is the
    /// two-point form; the others lock the direction. `CanvasModel.applyToolConfig`
    /// RE-MINTS the tool with the options-bar selection (`xlineModeValue`).
    public var mode: Mode

    public init(mode: Mode = .free) { self.mode = mode }

    // MARK: - Tool

    public var title: String { "Construction Line" }

    public var status: String {
        switch state {
        case .settingBase:      return "Specify base point"
        case .settingDirection: return modeStatus
        }
    }

    private var modeStatus: String {
        switch mode {
        case .free:       return "Specify direction point"
        case .horizontal: return "Horizontal — pick to place"
        case .vertical:   return "Vertical — pick to place"
        case .angle:      return "Fixed angle — pick to place"
        }
    }

    /// The live rubber-band: a LARGE finite segment through the base in the
    /// (constraint-resolved) cursor direction — the on-screen stand-in for the
    /// infinite line (the renderer / view-clip wiring is a documented follow-up).
    public var preview: [ResolvedPolyline] {
        guard case .settingDirection(let base) = state, base.valid, cursor.valid else {
            return []
        }
        guard let dir = direction(base: base, toward: cursor) else { return [] }
        let seg = Self.previewSegment(base: base, direction: dir)
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
            // Each line was committed on its second click; nothing pending.
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
            guard let dir = direction(base: base, toward: p) else {
                // Degenerate (no usable direction) — keep waiting.
                return .none
            }
            let record = EntityRecord(
                id: .placeholder,
                kind: .xline(XLineData(base: base, direction: dir))
            )
            // Continue from the SAME base (a common construction workflow is many
            // construction lines fanning from one point).
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

    // MARK: - Direction resolution (constraint modes)

    /// The (unit-ish) direction the line should take given the base and the
    /// toward-point, honoring the constraint `mode`. Returns `nil` only for the
    /// free mode when the two points coincide (no direction).
    func direction(base: Vector, toward: Vector) -> Vector? {
        switch mode {
        case .free:
            let d = toward - base
            return d.magnitude > Tolerance.distance ? d : nil
        case .horizontal:
            return Vector(1, 0)
        case .vertical:
            return Vector(0, 1)
        case .angle(let a):
            return Vector(angle: a)
        }
    }

    // MARK: - Preview geometry

    /// A large FINITE segment standing in for the infinite line in the preview,
    /// centered on the base (±`previewHalfLength` along the direction). Matches
    /// the engine's large-segment resolve fallback so the preview reads the same.
    static let previewHalfLength: Double = 1e6

    static func previewSegment(base: Vector, direction: Vector) -> (Vector, Vector) {
        let len = direction.magnitude
        let dir = len > Tolerance.distance ? direction / len : Vector(1, 0)
        return (base - dir * previewHalfLength, base + dir * previewHalfLength)
    }
}
