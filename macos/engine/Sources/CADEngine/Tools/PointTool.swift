//
//  PointTool.swift
//  CADEngine
//
//  A draw tool that places point entities — ported from LibreCAD's
//  `RS_ActionDrawPoint` (librecad/src/lib/actions/drawing/draw/rs_actiondrawpoint.cpp).
//  A point has no rubber-band, so this tool is essentially stateless: each
//  `.click` commits ONE `.point(PointData)` at the snapped location and the tool
//  stays active for the next point (matching LibreCAD, where the point action
//  keeps placing points until cancelled).
//
//  Behavior:
//    - `.click`     → commit ONE `.point(PointData(position:))` at the clicked
//                     point, then STAY active for the next point (like LineTool's
//                     chaining run — never `.finished` after a single click).
//    - `.move`      → a point has no rubber-band geometry to preview, so a move
//                     changes nothing: `.none`.
//    - `.backspace` → nothing in-progress to step back (each point committed on
//                     its click): no-op (`.none`).
//    - `.cancel` (Esc) → end the run, reset, `.finished`.
//    - `.commit` (Ret) → end the run; `.finished` (each point was already
//                        committed on its click, so nothing is pending to add).
//
//  PURE: it never touches CADDrawing/Quadtree/GUI. It receives already-snapped
//  world points and returns outcomes/preview; the app re-mints ids on commit.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionDrawPoint).
//

import Foundation

/// The interactive Point tool. Each click places a point entity; the tool stays
/// active so the user can keep placing points until `.commit`/`.cancel`
/// (LibreCAD behavior). A point has no rubber-band, so there is no preview.
public struct PointTool: Tool {

    public init() {}

    // MARK: - Tool

    public var title: String { "Point" }

    /// A point tool only ever has the one prompt — there is no multi-step state.
    public var status: String { "Specify point location" }

    /// A point has no rubber-band geometry to preview (it commits on each click),
    /// so the live preview is always empty.
    public var preview: [ResolvedPolyline] { [] }

    /// A draw tool: it IGNORES `context` (it needs only the snapped world point)
    /// and emits new geometry as `.add` edits.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move:
            // A point has no rubber-band — a move changes nothing.
            return .none

        case .click(let p):
            guard p.valid else {
                // Degenerate (invalid) pick — ignore it, keep waiting.
                return .none
            }
            // Commit one point at the clicked location, then STAY active for the
            // next point (no `.finished` — like LineTool's chaining run).
            let record = EntityRecord(
                id: .placeholder,
                kind: .point(PointData(position: p))
            )
            return .commit([.add(record)])

        case .backspace:
            // Each point was committed on its click, so there is nothing pending
            // to step back here (the app's undo removes a committed point).
            return .none

        case .cancel:
            // Esc — end the run and return to select mode.
            return .finished

        case .commit:
            // Return — end the run. Each point was already committed on its click,
            // so there is nothing pending to add here.
            return .finished
        }
    }
}
