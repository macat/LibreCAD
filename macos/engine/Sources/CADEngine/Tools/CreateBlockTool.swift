//
//  CreateBlockTool.swift
//  CADEngine
//
//  The CREATE-BLOCK-FROM-SELECTION tool (feature-catalog F9, tool half) — group
//  the current selection into a NAMED block and replace the originals with one
//  INSERT that references it. Ported in spirit from LibreCAD's
//  `RS_ActionBlocksCreate` (librecad/src/actions/blocks/rs_actionblockscreate.cpp):
//  the user names the block + picks a base point, the selected entities become the
//  block's members (re-authored relative to the base point), and a single block
//  reference (INSERT) re-draws them where they were.
//
//  ## Why this tool is NOT a plain `ToolEdit`-emitting tool (decision)
//  A `ToolEdit` only expresses entity-level `.add` / `.replace` / `.remove`; it
//  cannot register a `Block` in the drawing's `BlockTable`. Creating a block must
//  ALSO touch the block table (and re-author the member records). So unlike the
//  other modify tools, `CreateBlockTool` does NOT emit its result as `.commit`
//  edits — it captures the selection ids + the picked base point + the chosen name
//  into a `pendingCreation` REQUEST, and the app applies it through the NEW
//  undoable model op `CADDrawing.makeBlockFromEntities(name:basePoint:ids:)` (which
//  the block-from-selection wave owns on `CADDrawing`). The static helper
//  `CreateBlockTool.apply(_:to:)` performs exactly that, so the whole flow is
//  unit-testable against a real `CADDrawing` WITHOUT the GUI.
//
//  Behavior:
//    - empty selection → status nudges "Select entities to make into a block first";
//                        every input is a no-op (nothing to block).
//    - `.move`         → drives the base-point preview (a small crosshair at the
//                        cursor) once a selection is captured; otherwise no preview.
//    - `.click` / `.value` (the base point) → capture the base point, build the
//                        `pendingCreation` request, and return `.finished`. The app
//                        reads `pendingCreation` and calls `makeBlockFromEntities`.
//    - `.commit` (Ret) → same as a click using the LAST cursor point as the base
//                        point (or the selection's bbox lower-left if no move yet).
//    - `.cancel` (Esc) → discard the captured selection + request, `.finished`.
//
//  PURE (ADR-001 / Tool contract): it never touches CADDrawing / Quadtree / GUI. It
//  reads only `context.selected` (the entities to block) and the snapped world point
//  in `ToolInput`, and records a value request the app applies via the undoable
//  model op. It is intentionally UNWIRED until the wire-wave registers a ToolKind
//  case + the block-picker name UI.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionBlocksCreate).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// A value request to create a block from a selection — the captured intent a
/// `CreateBlockTool` produces, applied by the app via the undoable model op
/// `CADDrawing.makeBlockFromEntities(name:basePoint:ids:)`. Pure value type so it
/// crosses isolation boundaries with the tool and is trivially testable.
public struct CreateBlockRequest: Sendable, Hashable {
    /// The requested block name (de-duplicated by the model op on a clash).
    public var name: String
    /// The base point: the block's local origin in WORLD coords. The placing INSERT
    /// lands here so the geometry re-draws exactly where it was.
    public var basePoint: Vector
    /// The ids of the entities to fold into the block (in selection order).
    public var ids: [EntityID]

    public init(name: String, basePoint: Vector, ids: [EntityID]) {
        self.name = name
        self.basePoint = basePoint
        self.ids = ids
    }
}

/// The interactive Create-Block-from-selection tool. With one or more entities
/// selected, the user names the block (supplied at construction by the future
/// block-name UI) and picks a base point; the tool records a `CreateBlockRequest`
/// the app applies via the undoable `makeBlockFromEntities` model op. UNWIRED for
/// now (no `ToolKind` case yet); fully usable + testable as a value type.
public struct CreateBlockTool: Tool {

    // MARK: - Configuration

    /// The name to give the new block. Supplied by the picker UI at construction;
    /// defaults to "Block" (the model op de-duplicates on a clash, so a default is
    /// always safe).
    private let blockName: String

    // MARK: - State

    /// The selection captured on the first `handle` (snapshotted so a later
    /// selection change cannot alter the in-progress block). Empty until captured.
    private var captured: [EntityRecord] = []

    /// The last cursor point seen via `.move`, used both for the base-point preview
    /// and as the `.commit` fallback base point. Invalid until the first move.
    private var cursor: Vector = .invalid

    /// The request the most recent commit produced — the app reads this after a
    /// `.finished` outcome and applies it via `makeBlockFromEntities`. `nil` until a
    /// base point is committed (or after a cancel).
    public private(set) var pendingCreation: CreateBlockRequest?

    /// Creates a Create-Block tool that names the new block `blockName`.
    public init(blockName: String = "Block") {
        let trimmed = blockName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.blockName = trimmed.isEmpty ? "Block" : trimmed
    }

    // MARK: - Tool

    public var title: String { "Create Block" }

    public var status: String {
        captured.isEmpty
            ? "Select entities to make into a block first"
            : "Specify the block base point"
    }

    /// A tiny base-point crosshair preview at the cursor once a selection is
    /// captured (so the user sees where the block's origin will land). Empty before
    /// a selection is captured or before the cursor has moved.
    public var preview: [ResolvedPolyline] {
        guard !captured.isEmpty, cursor.valid else { return [] }
        return Self.crosshair(at: cursor)
    }

    /// A MODIFY-style tool: it reads `context.selected` (the entities to block) and,
    /// on a base-point pick, records a `CreateBlockRequest` and ends its run. It does
    /// NOT emit `.commit` edits (block creation is a model op, not a `ToolEdit`).
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        if captured.isEmpty, !context.selected.isEmpty {
            captured = context.selected
        }
        guard !captured.isEmpty else {
            // Nothing selected — inert (the picker should require a selection first).
            return .none
        }

        switch input {
        case .move(let p):
            cursor = p
            return .preview

        case .click(let p), .value(let p):
            // A typed coordinate (U1) picks the base point exactly like a click.
            guard p.valid else { return .none }
            return finish(basePoint: p)

        case .commit:
            // Return — use the last cursor, else the selection's bbox lower-left.
            return finish(basePoint: commitBasePoint())

        case .backspace:
            // Single-pick placement — nothing to step back.
            return .none

        case .cancel:
            reset()
            return .finished
        }
    }

    // MARK: - Finish

    /// Records the creation request at `basePoint` and ends the run. The app reads
    /// `pendingCreation` after the `.finished` and applies it via the model op.
    private mutating func finish(basePoint: Vector) -> ToolOutcome {
        pendingCreation = CreateBlockRequest(
            name: blockName,
            basePoint: basePoint,
            ids: captured.map(\.id)
        )
        captured = []
        cursor = .invalid
        return .finished
    }

    private mutating func reset() {
        captured = []
        cursor = .invalid
        pendingCreation = nil
    }

    /// The base point a `.commit` (Return) uses: the last cursor if it has moved,
    /// else the lower-left of the captured selection's bounding box (a sensible
    /// default — LibreCAD prompts for the point, but Return shouldn't fail).
    private func commitBasePoint() -> Vector {
        if cursor.valid { return cursor }
        var box = AABB.empty
        for r in captured { box = box.union(r.boundingBox()) }
        return box.isEmpty ? Vector(0, 0) : box.min
    }

    // MARK: - Apply (the model-op bridge — exercised in tests + by the app)

    /// Applies a `CreateBlockRequest` to a drawing via the undoable model op
    /// `CADDrawing.makeBlockFromEntities`. The single seam the app calls after the
    /// tool finishes; returns the creation result (name + new insert id) or `nil` if
    /// the request was empty / the ids vanished.
    @MainActor
    @discardableResult
    public static func apply(_ request: CreateBlockRequest,
                             to drawing: CADDrawing) -> CADDrawing.BlockCreation? {
        drawing.makeBlockFromEntities(
            name: request.name, basePoint: request.basePoint, ids: request.ids)
    }

    // MARK: - Preview geometry (pure)

    /// A small "+" crosshair (two short segments) centered at `p`, in the preview
    /// pen — the base-point marker. Size is fixed in world units (the app's overlay
    /// may rescale at draw time).
    static func crosshair(at p: Vector, halfSize: Double = 1.0) -> [ResolvedPolyline] {
        let h = ResolvedPolyline(
            points: [Vector(p.x - halfSize, p.y), Vector(p.x + halfSize, p.y)],
            closed: false, pen: .toolPreview)
        let v = ResolvedPolyline(
            points: [Vector(p.x, p.y - halfSize), Vector(p.x, p.y + halfSize)],
            closed: false, pen: .toolPreview)
        return [h, v]
    }
}
