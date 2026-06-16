//
//  ViewportTool.swift
//  CADEngine
//
//  Paper-space P3 — the interactive tool that PLACES a `LayoutViewport` on a
//  layout sheet (paperspace-plan §3 row P3). Two clicks on the sheet define the
//  viewport's `paperRect`; the tool then FRAMES the supplied model extents into
//  that rect (whole-model fit), producing a finished `LayoutViewport`.
//
//  ## Why this is a STANDALONE value type (NOT a `Tool` conformer) — option A
//  The `Tool` / `ToolEdit` contract is FROZEN: `ToolEdit` only expresses entity-
//  level `.add`/`.replace`/`.remove`, and viewports are NOT entities (they live in
//  `Layout.viewports`, off `EntityKind`). Wiring a viewport through `ToolEdit` would
//  need a new `ToolEdit.addViewport` case, which the brief forbids. So this is a
//  small SELF-CONTAINED state machine with its OWN click/move input and a
//  `LayoutViewport` result — the (later) wire-wave activates it and routes the
//  finished viewport to `CADDrawing.addViewport(_:toLayout:)` out of band.
//
//  PURE + headless-testable: it never touches `CADDrawing` / Quadtree / GUI / any
//  modal. It receives already-snapped PAPER-space points (the canvas converts the
//  cursor to paper coordinates) plus the model extents to frame, and returns the
//  produced `LayoutViewport`. No `ToolKind` case (built UNWIRED).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation

/// The interactive viewport-placement tool. Click two opposite corners on the
/// sheet to define the viewport frame; on the second click the tool frames the
/// model extents into the frame and yields a `LayoutViewport`.
///
/// Standalone (NOT a `Tool` conformer) — see the file header. Drive it with
/// `move`/`click`/`cancel`; the second `click` returns a `.placed(viewport)`.
public struct ViewportTool {

    // MARK: - Input + outcome (this tool's OWN minimal contract, not `ToolInput`)

    /// What the canvas feeds the tool. All points are in PAPER (sheet) coordinates —
    /// the canvas maps the cursor to paper space before calling (so the produced
    /// `paperRect` composes directly with the sheet rect).
    public enum Input: Sendable, Equatable {
        /// Cursor moved to a paper-space point (drives the rubber-band preview).
        case move(Vector)
        /// A click at a paper-space point (corner 1, then corner 2).
        case click(Vector)
        /// Cancel (Esc) — discard the in-progress placement.
        case cancel
    }

    /// The result of feeding one `Input`.
    public enum Outcome: Sendable, Equatable {
        /// Nothing user-visible changed (e.g. a move before the first click).
        case none
        /// The live rubber-band changed (the preview should repaint).
        case preview
        /// Both corners are placed — the finished viewport. The caller routes this to
        /// `CADDrawing.addViewport(_:toLayout:)`. The tool resets to its initial
        /// state afterward (ready to place another).
        case placed(LayoutViewport)
        /// The placement was cancelled / reset; clear any preview.
        case cancelled
    }

    // MARK: - State

    private enum State: Equatable {
        /// Waiting for the first corner.
        case settingFirst
        /// First corner fixed; waiting for the opposite corner. `first` is it.
        case settingSecond(first: Vector)
    }

    private var state: State = .settingFirst

    /// The last cursor point (paper space), for the rubber-band between clicks.
    private var cursor: Vector = .invalid

    /// The MODEL-space extents the placed viewport frames (the whole-model fit). The
    /// canvas sets this to the model's bounding box (or a chosen region). An empty
    /// extent still produces a valid viewport (a unit view at the model center).
    public var modelExtents: AABB

    /// Per-edge inset (fraction of the frame) the framing leaves around the model.
    public var marginFraction: Double

    public init(modelExtents: AABB = .empty, marginFraction: Double = 0.05) {
        self.modelExtents = modelExtents
        self.marginFraction = marginFraction
    }

    // MARK: - Description

    public var title: String { "Viewport" }

    public var status: String {
        switch state {
        case .settingFirst:  return "Specify first corner of viewport"
        case .settingSecond: return "Specify opposite corner of viewport"
        }
    }

    /// `true` once the first corner is placed (the canvas can show the rubber-band).
    public var isPlacing: Bool {
        if case .settingSecond = state { return true } else { return false }
    }

    /// The live rubber-band frame: the rectangle between the fixed first corner and
    /// the current cursor, as a closed 4-point polyline. Empty before the first
    /// click, or before the cursor has moved.
    public var preview: [ResolvedPolyline] {
        guard case .settingSecond(let first) = state, cursor.valid, first.valid else {
            return []
        }
        let rect = AABB(points: [first, cursor])
        guard !rect.isEmpty else { return [] }
        let ll = Vector(rect.min.x, rect.min.y)
        let lr = Vector(rect.max.x, rect.min.y)
        let ur = Vector(rect.max.x, rect.max.y)
        let ul = Vector(rect.min.x, rect.max.y)
        return [ResolvedPolyline(points: [ll, lr, ur, ul], closed: true, pen: .toolPreview)]
    }

    // MARK: - Drive

    /// Feeds one input, advancing the placement. The second `click` returns
    /// `.placed(viewport)` and resets the tool; `cancel` returns `.cancelled`.
    public mutating func handle(_ input: Input) -> Outcome {
        switch input {
        case .move(let p):
            cursor = p
            return preview.isEmpty ? .none : .preview

        case .click(let p):
            switch state {
            case .settingFirst:
                state = .settingSecond(first: p)
                cursor = p
                return .preview
            case .settingSecond(let first):
                // The two corners define the frame (order-independent: AABB(points:)
                // normalizes them). A degenerate (zero-area) box — a double-click or a
                // click on the same point — is rejected as a no-op so a stray click
                // can't make a zero-size viewport. Stay placing so the user can retry.
                let rect = AABB(points: [first, p])
                guard !rect.isEmpty, rect.size.x > 0, rect.size.y > 0 else {
                    return .none
                }
                let viewport = LayoutViewport.framing(
                    paperRect: rect,
                    modelExtents: modelExtents,
                    marginFraction: marginFraction
                )
                // Reset for the next placement.
                state = .settingFirst
                cursor = .invalid
                return .placed(viewport)
            }

        case .cancel:
            let wasPlacing = isPlacing
            state = .settingFirst
            cursor = .invalid
            return wasPlacing ? .cancelled : .none
        }
    }
}
