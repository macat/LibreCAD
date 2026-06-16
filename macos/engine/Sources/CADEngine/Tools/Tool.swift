//
//  Tool.swift
//  CADEngine
//
//  The interactive Tool framework — the shared contract every drawing/modify
//  tool implements. Ported in spirit from LibreCAD's RS_ActionInterface state
//  machine (librecad/src/lib/actions/rs_actioninterface.h), but with the design
//  improvements the engine-architecture note calls out:
//
//    - the magic `int m_status` becomes a per-tool *private* `enum State`
//      (exhaustive switch, no off-by-one);
//    - the tool is a PURE value type that takes already-snapped WORLD points and
//      returns outcomes/preview — it does NOT touch CADDrawing / Quadtree / GUI
//      (the app applies commits via the undoable `CADDrawing.add`);
//    - `RS_Snapper` is NOT a superclass: snapping is the caller's job (the app
//      snaps the cursor and feeds the snapped world point in), so a tool is fully
//      unit-testable WITHOUT the GUI or a snapper.
//
//  This file is the FROZEN contract the tool fan-out builds against. New tools
//  conform to `Tool` in their OWN file under Tools/; adding one does NOT require
//  editing this file (no central registry of conformers here — see ToolKind for
//  the only enumerated registration point, which the app owns).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionInterface state machine).
//

import Foundation

// MARK: - Tool input (the events the app feeds a tool)

/// A normalized interaction event handed to a `Tool`. All points are **WORLD**
/// coordinates (f64) already snapped by the caller (the app runs `Snapping.snap`
/// and passes the snapped point) — the tool never sees screen pixels and never
/// snaps. This keeps tools pure and GUI-free (testable without AppKit/Metal).
///
/// Ported from the relevant `RS_ActionInterface` events
/// (`mouseMoveEvent` / `mousePressEvent` / `coordinateEvent` / key handling),
/// collapsed to the device-agnostic set a tool actually reacts to.
public enum ToolInput: Sendable, Equatable {
    /// The cursor moved to a (snapped) world point — drives the rubber-band
    /// preview. Emits no geometry.
    case move(Vector)
    /// A primary click landed at a (snapped) world point — the tool's "pick a
    /// point" event.
    case click(Vector)
    /// A world point the user TYPED on the command/coordinate line (U1) — already
    /// resolved by `CommandParser` from `x,y` / `@dx,dy` / `dist<angle` / a bare
    /// distance, against the relative-zero + cursor. It is a "pick a point" event
    /// just like `.click`, but it lands at the *exact* typed coordinate (no snap
    /// drift): a DRAW or DIMENSION tool treats it like a `.click` at that point,
    /// placing the next point. MODIFY / SELECT tools ignore it (safe default —
    /// their pick semantics are entity-based, not coordinate-typed). Append-only
    /// extension of the frozen contract (decision D7); every tool's `handle`
    /// switch handles it (the build flags any that don't).
    case value(Vector)
    /// Finish the current operation (Return / double-click / Enter): commit any
    /// pending geometry and end the tool's current run.
    case commit
    /// Abort the current operation (Esc): discard the pending preview/state and
    /// reset the tool to its initial state.
    case cancel
    /// Undo the last picked point within the in-progress operation (Backspace),
    /// stepping the tool's state back one click without committing.
    case backspace
}

// MARK: - Tool edit (one undoable mutation a commit asks the app to apply)

/// A single drawing mutation a tool wants applied. A `.commit` carries an
/// ordered list of these; the app applies the whole list as ONE undoable group
/// (one undo reverts the entire tool action) and keeps the spatial index
/// consistent (see `CanvasModel.applyCommit`).
///
/// This is the seam that lets DRAW and MODIFY tools share one contract:
///   - draw tools emit only `.add` (new geometry, placeholder id → app mints);
///   - modify tools (move/rotate/scale/trim/offset) emit `.replace`/`.remove`
///     against the ids they read from `ToolContext.selected`.
///
/// ## Why `.replace(EntityID, EntityKind)` (not `.replace(EntityRecord)`)
/// The modify tools this contract is being widened for (move/rotate/scale/trim/
/// offset) all change ONLY an existing entity's geometry and keep its layer / pen
/// / flags. Carrying just the id + new `EntityKind` makes that the cheap, obvious
/// case: the app looks up the existing record, swaps its `kind`, and preserves
/// every other attribute (see `applyCommit`). If a future tool needs to change
/// the common attrs too (e.g. a "change layer" edit), add a sibling case
/// (e.g. `.replaceRecord(EntityRecord)` carrying the real id) rather than
/// overloading this one — this stays the minimal geometry-edit form.
public enum ToolEdit: Sendable, Equatable {
    /// Add new geometry. The record carries the placeholder id `EntityID(0)`; the
    /// app re-mints a real id when it applies the record via `CADDrawing.add`.
    case add(EntityRecord)
    /// Replace an existing entity's GEOMETRY in place (same id). The app looks the
    /// entity up, swaps only its `kind` to `EntityKind`, and keeps its layer/pen/
    /// flags. Undoable; the spatial index is updated to the new bounds.
    case replace(EntityID, EntityKind)
    /// Remove an existing entity by id. Undoable; the app also drops it from the
    /// spatial index and the selection.
    case remove(EntityID)
}

// MARK: - Tool outcome (what the app does after handling an input)

/// The result of feeding a `ToolInput` to a `Tool`. The app switches on this to
/// decide whether to redraw, apply edits, or tear the tool down.
///
/// `.commit(edits)` carries a list of `ToolEdit`s; the app applies them as one
/// undoable group via `CanvasModel.applyCommit` (ADR-002). For `.add` edits the
/// record's placeholder id (`EntityID(0)`) is re-minted by `CADDrawing.add`; a
/// tool NEVER mints ids itself.
public enum ToolOutcome: Sendable, Equatable {
    /// Nothing changed (e.g. a click that only advanced internal state). The app
    /// may still redraw if `preview` differs, but no commit and no teardown.
    case none
    /// Only the live preview changed (rubber-band moved): the app should redraw
    /// the overlay, nothing else.
    case preview
    /// The tool produced one or more edits to apply to the drawing. The app
    /// applies them as a single undoable group, updates the quadtree, then clears
    /// the preview. The tool stays active for the next operation (e.g. the Line
    /// tool chains a polyline-like run).
    case commit([ToolEdit])
    /// The tool's run is over (after a `.commit` or `.cancel`): the app may
    /// deactivate it / return to select mode, depending on the tool.
    case finished
}

// MARK: - Tool context (the read-only snapshot the app hands each call)

/// A READ-ONLY snapshot of the document state a `Tool` may need when it `handle`s
/// an input. The app rebuilds one per call so the tool always sees the current
/// selection / entities / grid WITHOUT being able to mutate them (mutation only
/// happens via the `ToolEdit`s a tool returns in `.commit`).
///
/// DRAW tools ignore the context entirely (they only need the snapped world
/// points in `ToolInput`). MODIFY tools read `selected` (the entities to act on)
/// and `entity(_:)` (to resolve any id they reference), and may read
/// `gridSpacing` for grid-aware snapping/stepping. The EDITING tools this contract
/// is widened for (Trim / Extend / Fillet) additionally need to see OTHER entities
/// as *boundaries* — the thing you trim against, extend to, or fillet between — so
/// they read `nearbyEntities(_:_:)` (boundaries near a picked point) and/or
/// `allEntities()` (a full scan).
///
/// Sendable: `selected` is a value array and the closures are `@Sendable`, so the
/// whole context crosses isolation boundaries with the tool value.
public struct ToolContext: Sendable {
    /// The entities currently selected, resolved to full records (the app resolves
    /// `Selection.ids` against the drawing). Empty when nothing is selected — the
    /// usual state while a draw tool runs. Modify tools operate on these.
    public let selected: [EntityRecord]

    /// Looks up any entity by id (e.g. an id a tool stashed across calls), or
    /// `nil` if it is no longer in the drawing. A `@Sendable` closure over the
    /// drawing's read-only lookup.
    public let entity: @Sendable (EntityID) -> EntityRecord?

    /// The current grid step in world units, or `nil` if the grid is off /
    /// unavailable. Tools that step by the grid (e.g. a grid-aware move) read this.
    public let gridSpacing: Double?

    /// The boundary-finding hook for the editing tools (Trim / Extend / Fillet):
    /// every entity whose geometry lies within the given WORLD `tolerance` of the
    /// given world `point`. The point is the user's pick (already snapped) and the
    /// tolerance is the pick aperture in world units (GUI px × worldPerPixel).
    ///
    /// The app implements this by prefiltering candidates with the shared quadtree
    /// (`query(point:tolerance:)`) and then keeping only those whose EXACT analytic
    /// distance to the point is within tolerance — the same prefilter→exact path
    /// `Selection.hitTest` uses, so a returned entity really is *under the pick*,
    /// not merely AABB-near it. Hidden entities (cleared `.visible` flag) are
    /// skipped — you can't pick a boundary you can't see. Order is unspecified; a
    /// tool that wants "the nearest boundary" sorts by its own exact distance.
    ///
    /// A `@Sendable` closure over an immutable value snapshot of the drawing (and a
    /// snapshot spatial query), so it carries across isolation boundaries with the
    /// tool value (no `self`, no actor state). Default returns `[]` (the empty
    /// context / draw-tool tests don't need boundaries).
    public let nearbyEntities: @Sendable (Vector, Double) -> [EntityRecord]

    /// A full snapshot of every entity in the drawing — for editing tools that scan
    /// ALL boundaries rather than just the ones near a pick (e.g. a Fillet that
    /// considers any pair, or an Extend whose target boundary is outside the pick
    /// aperture). Prefer `nearbyEntities(_:_:)` when a pick point is available; this
    /// is the brute-force fallback.
    ///
    /// A `@Sendable` closure returning the captured value snapshot. Default `[]`.
    public let allEntities: @Sendable () -> [EntityRecord]

    public init(
        selected: [EntityRecord],
        entity: @escaping @Sendable (EntityID) -> EntityRecord?,
        gridSpacing: Double?,
        nearbyEntities: @escaping @Sendable (Vector, Double) -> [EntityRecord] = { _, _ in [] },
        allEntities: @escaping @Sendable () -> [EntityRecord] = { [] }
    ) {
        self.selected = selected
        self.entity = entity
        self.gridSpacing = gridSpacing
        self.nearbyEntities = nearbyEntities
        self.allEntities = allEntities
    }

    /// An empty context (no selection, no lookup, no grid, no boundaries) — handy
    /// for unit tests of draw tools that ignore the context.
    public static let empty = ToolContext(
        selected: [],
        entity: { _ in nil },
        gridSpacing: nil
    )
}

// MARK: - The Tool protocol (the FROZEN contract)

/// An interactive drawing/modify tool: a small state machine driven by
/// `ToolInput`, producing a live `preview` and, on completion, committed
/// `EntityRecord`s. Tools are **value types** (`mutating func handle`) holding
/// their own private `enum State`; the app owns the active tool and feeds it
/// snapped world points.
///
/// ## How to add a new tool (the fan-out recipe)
/// 1. Add a file `Tools/<Name>Tool.swift` with `public struct <Name>Tool: Tool`.
/// 2. Give it a `private enum State` (NOT a magic Int) and the four protocol
///    members below. Keep it PURE: no `CADDrawing`/`Quadtree`/GUI access; react
///    only to the `ToolInput` points + the read-only `ToolContext` and return
///    `ToolOutcome`/`preview`.
/// 3. On completion emit `.commit([ToolEdit])`:
///      - a DRAW tool emits `.add(EntityRecord(id: .placeholder, kind: ...))` —
///        use the `.placeholder` id; the app re-mints on `CADDrawing.add`, and it
///        IGNORES the `context` (draw tools need only the snapped points).
///      - a MODIFY tool reads `context.selected` (and/or `context.entity(id)`),
///        then emits `.replace(id, newKind)` / `.remove(id)` against those ids
///        (and `.add` for any new geometry it produces, e.g. offset).
/// 4. Register it for activation by adding a `case` to `ToolKind` (the single
///    enumerated registration point) and an arm in `ToolKind.makeTool()`. That
///    enum is the ONE central file a new tool touches — see the collision note
///    on `ToolKind`.
/// 5. Add tests in `Tests/CADEngineTests/ToolTests.swift` (domain-prefixed
///    suite name, e.g. `@Suite("<Name>Tool")`), driving `.click`/`.move`/`.commit`
///    with NO GUI. Pass `.empty` (or a hand-built `ToolContext`) for the context.
public protocol Tool: Sendable {
    /// A human-readable tool name for the UI (e.g. "Line"). Stable per tool.
    var title: String { get }

    /// The current prompt for the status HUD (e.g. "Specify first point" /
    /// "Specify next point"). Reflects the tool's `State`, ported from
    /// `RS_ActionInterface::updateMouseButtonHints`.
    var status: String { get }

    /// The live rubber-band geometry to draw as an overlay (world coords). Empty
    /// when there is nothing to preview yet. Ported from the
    /// `RS_PreviewActionInterface` preview container.
    var preview: [ResolvedPolyline] { get }

    /// Feeds one interaction event to the tool, advancing its state and returning
    /// what the app should do. `context` is a read-only snapshot of the current
    /// selection / entities / grid; DRAW tools ignore it, MODIFY tools read
    /// `context.selected`. Mutating because the tool owns its state.
    mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome

    /// Optional dashed REFERENCE segments to draw in the overlay alongside the live
    /// `preview` — straight world-coord lines back to where an operation STARTED, so
    /// the user can see the original anchor while dragging (e.g. Move's base→cursor
    /// displacement vector, or Scale's center→reference original radius). Each tuple
    /// is `(from, to)` in WORLD coordinates; the app draws them DASHED (a dimmer
    /// guide color) so they read as a guide distinct from the solid ghost preview.
    ///
    /// Append-only extension of the frozen contract (the same additive-default
    /// pattern as `ToolContext`'s closures): a default implementation in the
    /// protocol extension below returns `[]`, so EVERY existing tool inherits "no
    /// reference line" with no per-tool change — only tools that opt in (Move /
    /// Scale) override it. It must be empty outside the active drag phase (before
    /// the anchor is fixed and after commit) so the line only shows mid-operation
    /// and never leaks into exports (exports never read a tool's overlay).
    var referenceSegments: [(Vector, Vector)] { get }
}

// MARK: - Default reference segments (additive: all tools inherit "none")

public extension Tool {
    /// Default: tools draw no dashed reference line. Only Move / Scale override this
    /// to expose their "where we started from" guide (the displacement vector / the
    /// original reference radius). Keeps the contract append-only — no existing tool
    /// file needs to change to gain a conforming (empty) `referenceSegments`.
    var referenceSegments: [(Vector, Vector)] { [] }
}

// MARK: - Placeholder id convention

public extension EntityID {
    /// The placeholder id a `Tool` stamps on records it emits in `.commit`. The
    /// app re-mints a real id when it applies the record via `CADDrawing.add`
    /// (which mints when the id is `0`). Tools never mint ids themselves.
    static let placeholder = EntityID(0)
}

// MARK: - Preview pen (shared by all tools' rubber-band geometry)

public extension ResolvedPen {
    /// The default pen tool previews resolve with — LibreCAD's signature green,
    /// solid, default width. The app's overlay path may recolor previews
    /// (distinct preview color) at draw time; this is just a concrete pen so a
    /// tool can build `ResolvedPolyline`s without a layer/resolve context.
    static let toolPreview = ResolvedPen(color: .librecadGreen, lineType: .solid, lineWidth: .default)
}
