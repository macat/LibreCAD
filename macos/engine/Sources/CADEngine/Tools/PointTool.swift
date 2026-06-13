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

/// The on-screen display style for placed points — a subset of AutoCAD's `$PDMODE`
/// point-marker glyphs, surfaced by the tool-options bar (UX-plan U2). It selects
/// HOW a point is drawn (a dot, a plus/cross, an X, …).
///
/// NOTE: rendering each style is gated on a `style` field being added to the
/// engine's `PointData` (Entity.swift) + the point resolve arm honoring it — both
/// owned by the engine agent. Until then this enum lets the options bar expose the
/// choice; the committed `PointData` carries only its position, so every point
/// currently renders with the default marker regardless of this selection. The
/// `rawValue` matches the DXF `$PDMODE` code so it round-trips once wired.
public enum PointStyle: Int, Sendable, Hashable, CaseIterable {
    /// A single dot (DXF `$PDMODE` 0 — the default).
    case dot = 0
    /// A plus sign / cross (`$PDMODE` 2).
    case plus = 2
    /// An X (`$PDMODE` 3).
    case cross = 3
    /// A vertical tick (`$PDMODE` 4).
    case tick = 4
    /// A dot inside a circle (`$PDMODE` 33).
    case circle = 33
    /// A dot inside a square (`$PDMODE` 65).
    case square = 65

    /// A short human label for the options-bar picker.
    public var label: String {
        switch self {
        case .dot:    return "Dot"
        case .plus:   return "Plus"
        case .cross:  return "Cross (X)"
        case .tick:   return "Tick"
        case .circle: return "Circle"
        case .square: return "Square"
        }
    }
}

/// The interactive Point tool. Each click places a point entity; the tool stays
/// active so the user can keep placing points until `.commit`/`.cancel`
/// (LibreCAD behavior). A point has no rubber-band, so there is no preview.
public struct PointTool: Tool {

    /// The display style new points are placed with (UX-plan U2). Defaulted +
    /// back-compatible; honored at render time once `PointData.style` lands (see
    /// `PointStyle`).
    public var style: PointStyle = .dot

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

        case .click(let p), .value(let p):
            // A typed coordinate (U1) places a point exactly like a click.
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
