//
//  MLineTool.swift
//  CADEngine
//
//  A multi-vertex draw tool that accumulates clicks into ONE multiline (MLINE)
//  entity — the AutoCAD MLINE command: N parallel line elements drawn along one
//  shared, mitered vertex path. Ported in spirit from LibreCAD's polyline-style
//  multi-pick draw actions, on the SAME accumulate-then-commit-one-entity template
//  as `PolylineTool` / `RevisionCloudTool`.
//
//  ## How it differs from PolylineTool
//  `PolylineTool` accumulates clicks into ONE `.polyline`; `MLineTool` accumulates
//  the same way but commits ONE `.mline` carrying the clicked vertices as its path
//  plus the tool's element fan (parallel offset lines), justification, scale, and
//  closed flag. The drawn graphic (the N mitered offset element lines) is NOT stored
//  on the entity — `resolve()` derives it on demand (ADR-001), which is also how the
//  live `preview` is produced.
//
//  ## Default style (AutoCAD STANDARD-like)
//  With no MLSTYLE table yet (Wave 0 carries elements INLINE on the entity), the
//  tool seeds the AutoCAD STANDARD style: TWO elements at offsets `+0.5` and `-0.5`
//  (a unit-width double line), `justification = .top`, `scale = 1`, `closed = false`.
//  `justification` and `scale` are settable `var`s on the tool so a later wire-wave's
//  ToolOptionsBar can drive them through `CanvasModel.applyToolConfig`. (That UI
//  surfacing is NOT wired here — this tool is built UNWIRED.)
//
//  Behavior (mirrors PolylineTool):
//    - `.click`/`.value` → append the (snapped) vertex; clicking very near the FIRST
//                          vertex with ≥3 vertices CLOSES the path and commits.
//    - `.move`           → preview the in-progress `.mline` (its element fan resolved
//                          with the `.toolPreview` pen) plus a rubber-band to the cursor.
//    - `.commit`         → Return / double-click: if ≥2 vertices, emit ONE `.add(.mline)`;
//                          a single vertex (or none) commits nothing (a safe no-op).
//    - `.backspace`      → remove the last vertex.
//    - `.cancel`         → discard the run, reset.
//
//  PURE (the Tool contract): it never touches CADDrawing/Quadtree/GUI. It receives
//  already-snapped world points and returns outcomes/preview; the app re-mints ids on
//  commit and IGNORES `context` (a draw tool needs only the snapped points).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation

/// The interactive Multiline (MLINE) tool. Click to add path vertices; press Return
/// (or click back on the first vertex) to finish, committing all the vertices as ONE
/// `.mline` entity drawn with the tool's element fan / justification / scale. Unlike
/// `PolylineTool` (which commits a single-stroke `.polyline`), this commits a
/// multiline whose N parallel offset element lines are derived (mitered) at resolve.
public struct MLineTool: Tool {

    // MARK: - Default STANDARD-like style

    /// The default element fan — AutoCAD's STANDARD MLSTYLE: a unit-width double line,
    /// one element `+0.5` to the LEFT of the path and one `-0.5` to the right. (There
    /// is no MLSTYLE table yet — Wave 0 carries the elements inline on the entity.)
    public static let standardElements: [MLineElement] = [
        MLineElement(offset: 0.5),
        MLineElement(offset: -0.5),
    ]

    // MARK: - Settable style (driven by the later wire-wave's ToolOptionsBar)

    /// Which element rides the clicked vertex path (top / zero / bottom). Default
    /// `.top` (AutoCAD MLINE's default justification). A settable `var` so the later
    /// wire-wave can drive it via `CanvasModel.applyToolConfig` (NOT wired here).
    public var justification: MLineJustification = .top

    /// Overall offset scale (DXF code 40) applied to every element offset. Default `1`.
    /// A settable `var` for the later wire-wave's options bar (NOT wired here).
    public var scale: Double = 1

    /// The element fan committed on the `.mline`. Defaults to the STANDARD double line;
    /// exposed as a settable `var` so a future MLSTYLE picker (a later wave) can swap it.
    public var elements: [MLineElement] = MLineTool.standardElements

    // MARK: - Private state machine (mirrors PolylineTool)

    private enum State: Equatable {
        /// Waiting for the first point (no vertices yet).
        case empty
        /// One or more vertices fixed; waiting for the next point (or Return).
        case building(vertices: [Vector])
    }

    private var state: State = .empty

    /// The last cursor point seen via `.move`, used to draw the rubber-band from the
    /// last fixed vertex. Invalid until the first move.
    private var cursor: Vector = .invalid

    public init() {}

    // MARK: - Tool

    public var title: String { "Multiline" }

    public var status: String {
        switch state {
        case .empty:
            return "Specify start point"
        case .building(let vertices):
            return vertices.count >= 3
                ? "Specify next point (Return to finish, or click the start to close)"
                : "Specify next point (Return to finish)"
        }
    }

    /// The live preview while building: the in-progress `.mline` RESOLVED to its
    /// element fan (the N mitered offset lines) using the `.toolPreview` pen, exactly
    /// as it will draw on commit, plus a straight rubber-band from the last fixed
    /// vertex to the cursor so the next segment reads ahead of the click.
    ///
    /// Empty before the first point is set (and after commit/cancel, since `reset()`
    /// returns to `.empty`), so it never leaks into exports.
    public var preview: [ResolvedPolyline] {
        guard case .building(let vertices) = state, !vertices.isEmpty else {
            return []
        }
        // Path = committed vertices + the rubber-band point (the cursor), so the
        // preview shows the next, not-yet-clicked, segment of the multiline too.
        var path = vertices
        if cursor.valid, let last = vertices.last, last.valid,
           (cursor - last).magnitude > Tolerance.distance {
            path.append(cursor)
        }
        // Resolve the in-progress multiline to its element fan in the preview pen.
        // <2 valid path points or empty elements → resolve yields nothing (safe).
        let data = MLineData(
            vertices: path, elements: elements,
            justification: justification, scale: scale, closed: false
        )
        var lines = EntityKind.mline(data)
            .resolve(pen: .toolPreview, ctx: .default)
            .polylines
        // A bare single-vertex multiline resolves to nothing; show at least the path
        // rubber-band so the user sees their pick before the second click.
        if lines.isEmpty {
            lines = [ResolvedPolyline(points: path, closed: false, pen: .toolPreview)]
        }
        return lines
    }

    // MARK: - Mid-draw keyword options (Close / Undo — surfaced by a later wire-wave)

    /// The AutoCAD-style mid-draw keywords the multiline offers at its current step,
    /// derived PURELY from the committed-vertex count (mirrors `PolylineTool`):
    /// 0 vertices → none; 1 vertex → `Undo` only (nothing to close yet); ≥2 vertices →
    /// `Close` + `Undo`. The smart command line (a later wave) renders these; a chosen
    /// keyword routes back through the EXISTING `ToolInput` events (`Undo` ↔ `.backspace`,
    /// `Close` ↔ `.click(closeAnchor)`). Empty after commit/reset, so it never leaks.
    public var keywordOptions: [ToolKeyword] {
        guard case .building(let vertices) = state else { return [] }
        switch vertices.count {
        case 0:
            return []
        case 1:
            return [ToolKeyword(keyword: "Undo", label: "Undo")]
        default:
            return [
                ToolKeyword(keyword: "Close", label: "Close"),
                ToolKeyword(keyword: "Undo", label: "Undo"),
            ]
        }
    }

    /// The WORLD point a `Close` keyword re-feeds to close the path: the FIRST committed
    /// vertex, returned EXACTLY when `keywordOptions` offers `Close` (≥2 vertices), else
    /// `nil`. There is no standalone close input, so a later wave dispatches `Close` as
    /// `.click(closeAnchor)`; `handleClick`'s close-on-first-vertex path then commits the
    /// closed multiline. Reads the same private `state` `keywordOptions`/`preview` read.
    public var closeAnchor: Vector? {
        guard case .building(let vertices) = state, vertices.count >= 2 else { return nil }
        return vertices.first
    }

    /// A draw tool: it IGNORES `context` (it needs only the snapped world points) and
    /// emits new geometry as a single `.add` edit on commit.
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
            reset()
            return .finished

        case .commit:
            return handleCommit()
        }
    }

    // MARK: - Click / backspace / commit handling

    private mutating func handleClick(_ p: Vector) -> ToolOutcome {
        guard p.valid else { return .none }
        switch state {
        case .empty:
            state = .building(vertices: [p])
            cursor = p
            return .none

        case .building(var vertices):
            // Closing: clicking very near the FIRST vertex with ≥3 vertices closes the
            // path and commits immediately.
            if vertices.count >= 3, let first = vertices.first,
               first.valid, (p - first).magnitude <= Tolerance.distance {
                return commitMLine(vertices: vertices, closed: true)
            }
            // Ignore a degenerate (zero-length) repeat of the last vertex.
            if let last = vertices.last, last.valid,
               (p - last).magnitude <= Tolerance.distance {
                return .none
            }
            vertices.append(p)
            state = .building(vertices: vertices)
            cursor = p
            return .none
        }
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .empty:
            return .none
        case .building(var vertices):
            vertices.removeLast()
            if vertices.isEmpty {
                reset()
            } else {
                state = .building(vertices: vertices)
            }
            return .preview
        }
    }

    private mutating func handleCommit() -> ToolOutcome {
        switch state {
        case .empty:
            reset()
            return .finished
        case .building(let vertices):
            // A multiline needs at least two vertices (one segment); a single vertex
            // (or none) commits nothing — a safe no-op end-of-run.
            guard vertices.count >= 2 else {
                reset()
                return .finished
            }
            return commitMLine(vertices: vertices, closed: false)
        }
    }

    /// Builds the single `.add(.mline)` commit carrying the clicked `vertices` as the
    /// path plus the tool's element fan / justification / scale / `closed` flag, then
    /// resets the tool and returns `.commit`. The app re-mints the id and applies it as
    /// one undoable group (mirrors `PolylineTool.commitPolyline`).
    private mutating func commitMLine(vertices: [Vector], closed: Bool) -> ToolOutcome {
        let data = MLineData(
            vertices: vertices, elements: elements,
            justification: justification, scale: scale, closed: closed
        )
        let record = EntityRecord(id: .placeholder, kind: .mline(data))
        reset()
        return .commit([.add(record)])
    }

    /// Returns to the initial waiting-for-first-point state. The settable style
    /// (`justification`/`scale`/`elements`) is intentionally PRESERVED across a run so a
    /// configured tool keeps its style for the next multiline.
    private mutating func reset() {
        state = .empty
        cursor = .invalid
    }
}
