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

    /// Optional LIVE DIMENSIONAL FEEDBACK to draw in the overlay while a draw/modify
    /// tool runs — the AutoCAD-style dotted dimension line plus a pre-formatted value
    /// label that tracks the cursor (e.g. a Line tool showing its running length, a
    /// Circle tool showing radius/diameter, a Rectangle tool showing W×H). Each
    /// `LiveDimension` carries the MEASURED quantity, the dotted dim-line endpoints,
    /// and a label string the tool already formatted IN-ENGINE from `ctx`.
    ///
    /// `ctx` is a tiny value snapshot of the document's display formatting variables
    /// (linear/angle format, precision, unit) so the tool can format the label with
    /// `CoordinateFormatter` WITHOUT reaching into `CADDrawing` — keeping the tool a
    /// pure value type. The engine never renders the label; it returns a plain
    /// `String` and the app's overlay (a LATER wave) draws it. No AppKit/SwiftUI.
    ///
    /// Append-only extension of the frozen contract (the SAME additive-default pattern
    /// as `referenceSegments`): a default implementation in the protocol extension
    /// below returns `[]`, so EVERY existing tool inherits "no live dimension" with no
    /// per-tool change — only tools that opt in (Line / Circle / Rectangle / …, in a
    /// later wave) override it. Like `referenceSegments`, it must be empty outside the
    /// active operation (before the first point is fixed and after commit) so the
    /// feedback only shows mid-operation and never leaks into exports (exports never
    /// read a tool's overlay).
    func liveDimensions(_ ctx: LiveDimensionContext) -> [LiveDimension]

    /// Resolves a set of TYPED dimension values (dynamic input — the user typed into a
    /// live dimension field, e.g. a Line's length / angle, a Rectangle's width / height,
    /// a Circle's radius) into the WORLD point the tool should commit to. The app feeds
    /// the returned point through the EXISTING coordinate-commit seam (`.value(point)`),
    /// reusing the proven typed-coordinate path — so a typed dimension lands EXACTLY
    /// where the same value clicked would (no new `ToolInput` case).
    ///
    /// - `values`: the parsed numeric value for each field the user typed (lengths in
    ///   world units, angles in RADIANS). A field absent from the map falls back to the
    ///   live value the cursor currently implies, so a single typed field (e.g. only the
    ///   length) constrains just that dimension while the cursor drives the rest.
    /// - `cursor`: the current (snapped) world cursor — the live source for any field the
    ///   user did NOT type.
    /// - `reference`: the operation's fixed anchor the dimensions are measured FROM (the
    ///   Line's running endpoint, the Rectangle's first corner, the Circle's center).
    ///
    /// Returns `nil` when the tool is not in a state where typed dimensions are
    /// meaningful (no anchor fixed yet, or a construction sub-mode without editable
    /// dimensions). The default implementation returns `nil`, so EVERY existing tool
    /// inherits "no dynamic input" with no per-tool change — exactly like
    /// `liveDimensions` / `referenceSegments`. GUI-free: a pure value-in / value-out map.
    func applyDynamicInput(_ values: [LiveDimensionField: Double],
                           cursor: Vector, reference: Vector) -> Vector?

    /// Optional per-tool COMMAND KEYWORDS to surface as tappable chips on the smart
    /// command line — the AutoCAD-style bracketed options a tool offers at its current
    /// step (e.g. a Line tool's "Close"/"Undo", an Arc tool's "Center"/"3 Points", a
    /// Circle tool's "2P"/"3P"/"Ttr"). Each `ToolKeyword` pairs the literal `keyword`
    /// the user types (or the chip text routed back in) with a human `label` for the
    /// chip. The list reflects the tool's current `State`, mirroring how `status`
    /// already reflects state — a tool returns only the options valid right now.
    ///
    /// Append-only extension of the frozen contract (the SAME additive-default pattern
    /// as `referenceSegments` / `liveDimensions`): a default implementation in the
    /// protocol extension below returns `[]`, so EVERY existing tool inherits "no
    /// keyword options" with no per-tool change — only tools that opt in (in a later
    /// wire-wave) override it. This is purely the data the UI (Wave 4) renders and the
    /// per-tool keyword overrides (Wave 2) populate; dispatching a chosen keyword reuses
    /// the EXISTING `ToolInput` events (no new `.keyword` case — that would force an
    /// exhaustive-switch edit across every tool's `handle`). GUI-free: a plain value list.
    var keywordOptions: [ToolKeyword] { get }

    /// Optional WORLD point a `Close` keyword should re-feed to the tool to close the
    /// in-progress loop. The multi-vertex draw tools (Polyline / Spline) close by clicking
    /// ON their FIRST placed vertex/point — there is NO standalone "close" input — so when
    /// such a tool currently offers a `Close` in `keywordOptions`, it exposes that first
    /// vertex/point here; the command-line dispatch (Wave 3) feeds it back as a
    /// `.click(closeAnchor)`, and the tool's existing close-on-coincidence path commits the
    /// closed entity. `nil` whenever closing is not currently offered (before there are
    /// enough vertices, or after commit/reset) — so it is `non-nil` EXACTLY when
    /// `keywordOptions` contains a `Close`.
    ///
    /// Append-only extension of the frozen contract (the SAME additive-default pattern as
    /// `referenceSegments` / `liveDimensions` / `keywordOptions`): a default implementation
    /// in the protocol extension below returns `nil`, so EVERY existing tool inherits "no
    /// close anchor" with no per-tool change — only the multi-vertex tools that offer
    /// `Close` (Polyline / Spline) override it. GUI-free: a plain engine `Vector?`.
    var closeAnchor: Vector? { get }
}

// MARK: - Default reference segments (additive: all tools inherit "none")

public extension Tool {
    /// Default: tools draw no dashed reference line. Only Move / Scale override this
    /// to expose their "where we started from" guide (the displacement vector / the
    /// original reference radius). Keeps the contract append-only — no existing tool
    /// file needs to change to gain a conforming (empty) `referenceSegments`.
    var referenceSegments: [(Vector, Vector)] { [] }

    /// Default: tools emit no live dimensional feedback. Only the draw/modify tools
    /// that opt in (Line / Circle / Rectangle / …, in a later wave) override this.
    /// Keeps the contract append-only — no existing tool file needs to change to gain
    /// a conforming (empty) `liveDimensions`, exactly like `referenceSegments`.
    func liveDimensions(_ ctx: LiveDimensionContext) -> [LiveDimension] { [] }

    /// Default: tools resolve no typed dimension input. Only the draw tools that expose
    /// editable live dimensions (Line / Rectangle / Circle / Polygon) override this to
    /// turn typed values into the world point to commit. Keeps the contract append-only —
    /// no existing tool file needs to change to gain a conforming (`nil`)
    /// `applyDynamicInput`, exactly like `liveDimensions` / `referenceSegments`.
    func applyDynamicInput(_ values: [LiveDimensionField: Double],
                           cursor: Vector, reference: Vector) -> Vector? { nil }

    /// Default: tools surface no command-line keyword chips. Only tools that opt in
    /// (in a later wire-wave) override this to expose their bracketed options. Keeps
    /// the contract append-only — no existing tool file needs to change to gain a
    /// conforming (empty) `keywordOptions`, exactly like `referenceSegments` /
    /// `liveDimensions`.
    var keywordOptions: [ToolKeyword] { [] }

    /// Default: tools have no close anchor. Only the multi-vertex draw tools that offer a
    /// `Close` keyword (Polyline / Spline) override this to expose the first vertex/point a
    /// `Close` should re-feed. Keeps the contract append-only — no existing tool file needs
    /// to change to gain a conforming (`nil`) `closeAnchor`, exactly like the others.
    var closeAnchor: Vector? { nil }
}

// MARK: - Command-line keyword (additive value type)

/// One AutoCAD-style command KEYWORD a tool offers on the smart command line at its
/// current step — the bracketed option text the user can type or tap (e.g. `[Close]`,
/// `[2 Points]`, `[Undo]`). A pure value type with NO UI dependency: the engine returns
/// the data and the app's command-line view (a later wave) renders the chips and routes
/// a chosen keyword back through the EXISTING `ToolInput` events. Mirrors the append-only,
/// value-only design of `LiveDimension` / `referenceSegments`.
public struct ToolKeyword: Sendable, Equatable {
    /// The literal keyword the user types (or the chip text routed back in) — e.g.
    /// `"Close"`, `"2P"`, `"Undo"`. This is the machine-facing token the tool matches on.
    public let keyword: String
    /// The human-readable label shown on the chip — e.g. `"Close"`, `"2 Points"`. May
    /// differ from `keyword` when the typed token is terse (`"2P"` → `"2 Points"`).
    public let label: String

    public init(keyword: String, label: String) {
        self.keyword = keyword
        self.label = label
    }
}

// MARK: - Live dimensional feedback (additive value types)

/// Which DIMENSION a live-dimension field stands for — the stable identity the app's
/// dynamic-input handler keys on to (a) order Tab traversal across a tool's editable
/// fields, (b) map a typed value back to the right `applyDynamicInput` slot, and (c)
/// label the active field in the overlay. A pure value enum (no UI dependency); mirrors
/// the append-only, value-only design of `LiveDimension`. Additive — every existing
/// `LiveDimension` defaults its `field` to `nil` (not editable), so no emit site changes.
public enum LiveDimensionField: String, Sendable, Equatable, Hashable {
    /// A linear length (a Line's running length).
    case length
    /// An angle (a Line's segment angle).
    case angle
    /// A rectangle's width (its bottom-edge extent).
    case width
    /// A rectangle's height (its right-edge extent).
    case height
    /// A circle / polygon radius.
    case radius
    /// A circle diameter.
    case diameter
}

/// The DISPLAY/EDIT state of one editable live-dimension field, set by the MODEL (not
/// the tool) while the user types into the dynamic-input overlay. The tool only stamps
/// `field` + `isEditable`; the model re-stamps this (via `LiveDimension.withEditing`) to
/// drive the overlay's chip styling. `.idle` is the default for a freshly tool-emitted
/// dim (nothing typed yet). A pure value enum, no UI dependency.
public enum LiveDimensionEditState: Sendable, Equatable {
    /// Not being edited — the overlay draws the tool's formatted `label` as usual.
    case idle
    /// The currently-focused field the user is typing into — the overlay draws the raw
    /// `typedString` plus a caret in an accent chip.
    case active
    /// A field whose typed value is locked in (Tab moved past it) — the overlay draws the
    /// raw `typedString` in a pinned tint; the synthetic cursor honors it live.
    case locked
}

/// A single piece of AutoCAD-style LIVE dimensional feedback a tool exposes while it
/// runs: a dotted dimension line (`from` → `to`, WORLD coords) plus a PRE-FORMATTED
/// value `label` placed at `labelAnchor`. The `kind` carries the raw measured
/// quantity (world units / radians) so the overlay (or a test) can reason about the
/// number independently of the display string.
///
/// A pure value type with NO UI dependency: `label` is a plain `String` the tool
/// formats in-engine (via `CoordinateFormatter`) from a `LiveDimensionContext`; the
/// app's overlay decides typeface/placement when it draws. The engine never touches
/// AppKit/SwiftUI. Mirrors the append-only, value-only design of `referenceSegments`.
public struct LiveDimension: Sendable, Equatable {
    /// The kind of quantity being shown, carrying the raw measured value(s) in WORLD
    /// units (lengths) or RADIANS (angles) — already in document units, NOT a display
    /// string (that's `label`). A `size(w:h:)` carries a rectangle's two extents.
    public enum Kind: Sendable, Equatable {
        /// A single linear distance (world units) — e.g. a Line's running length.
        case linear(Double)
        /// A circle/arc radius (world units).
        case radius(Double)
        /// A circle diameter (world units).
        case diameter(Double)
        /// An angle (RADIANS) — e.g. a rotation or an arc sweep.
        case angle(Double)
        /// A rectangle's width × height (world units).
        case size(w: Double, h: Double)
    }

    /// The measured quantity, in world units (lengths) / radians (angles).
    public let kind: Kind
    /// The dotted dim-line anchor (WORLD coords) — usually the operation's fixed point.
    public let from: Vector
    /// The dotted dim-line end (WORLD coords) — usually the cursor / the on-curve point.
    public let to: Vector
    /// The value text, PRE-FORMATTED in-engine (e.g. `"12.5"`, `"R8"`, `"45°"`). The
    /// app's overlay draws this verbatim — the engine does no UI-side formatting.
    public let label: String
    /// Where to place the `label` (WORLD coords) — usually the dim-line midpoint or a
    /// small offset from `to`. The overlay may nudge it for legibility.
    public let labelAnchor: Vector

    /// Which DIMENSION this readout represents, or `nil` when it is not an editable
    /// field (the default — every pre-existing emit site keeps `nil`). The dynamic-input
    /// handler keys on this to route a typed value into `applyDynamicInput` and to order
    /// Tab traversal.
    public let field: LiveDimensionField?

    /// Whether the user may TYPE a value into this dimension (dynamic input). Default
    /// `false` so existing dims stay read-only; only the tools that opt in (Line /
    /// Rectangle / Circle / Polygon, in their editable states) set it `true`.
    public let isEditable: Bool

    /// The DISPLAY/EDIT state, set by the MODEL while editing (the tool always emits
    /// `.idle`). Default `.idle`. Re-stamped via `withEditing(editState:typedString:)`.
    public let editState: LiveDimensionEditState

    /// The raw character buffer the user has typed for this field, echoed by the overlay
    /// when `editState` is `.active` / `.locked`. `nil` (the default) when nothing has
    /// been typed — the overlay then draws the formatted `label`. Set by the MODEL.
    public let typedString: String?

    public init(kind: Kind, from: Vector, to: Vector, label: String, labelAnchor: Vector,
                field: LiveDimensionField? = nil,
                isEditable: Bool = false,
                editState: LiveDimensionEditState = .idle,
                typedString: String? = nil) {
        self.kind = kind
        self.from = from
        self.to = to
        self.label = label
        self.labelAnchor = labelAnchor
        self.field = field
        self.isEditable = isEditable
        self.editState = editState
        self.typedString = typedString
    }

    /// Returns a copy with `editState` + `typedString` replaced and every other field
    /// preserved — the seam the MODEL uses to re-stamp a tool-emitted dim with the live
    /// editing display state (active field + caret buffer, or a locked typed value)
    /// without the tool knowing anything about the UI. The tool's `kind` / geometry /
    /// `field` / `isEditable` carry through unchanged.
    public func withEditing(editState: LiveDimensionEditState,
                            typedString: String?) -> LiveDimension {
        LiveDimension(kind: kind, from: from, to: to, label: label, labelAnchor: labelAnchor,
                      field: field, isEditable: isEditable,
                      editState: editState, typedString: typedString)
    }
}

/// A tiny value snapshot of the document's display-formatting variables, handed to
/// `Tool.liveDimensions(_:)` so a tool can format its live label IN-ENGINE (via
/// `CoordinateFormatter`) without reaching into `CADDrawing`. These mirror the
/// `CADDrawing.GraphicVariables` typed header accessors the formatter consumes:
/// `linearFormat`/`linearPrecision`/`unit` for lengths and `angleFormat`/
/// `anglePrecision` for angles — i.e. exactly the inputs of
/// `CoordinateFormatter.length(_:)` / `.angle(_:)` / `.polarPair(...)`.
///
/// A pure value type (no `CADDrawing`, no UI): the app builds one from its live
/// `GraphicVariables` and passes it down; defaults match the formatter's own defaults
/// (Decimal / 4 dp / unitless / decimal-degrees) so a test can use `.default`.
public struct LiveDimensionContext: Sendable, Equatable {
    /// Linear display format (`$LUNITS`) — drives length labels.
    public let linearFormat: LinearFormat
    /// Linear precision (`$LUPREC`, decimal places).
    public let linearPrecision: Int
    /// Drawing unit (`$INSUNITS`) — the unit length labels render in.
    public let unit: DrawingUnit
    /// Angle display format (`$AUNITS`) — drives angle labels.
    public let angleFormat: AngleFormat
    /// Angle precision (`$AUPREC`, decimal places).
    public let anglePrecision: Int

    public init(
        linearFormat: LinearFormat = .decimal,
        linearPrecision: Int = 4,
        unit: DrawingUnit = .none,
        angleFormat: AngleFormat = .degreesDecimal,
        anglePrecision: Int = 4
    ) {
        self.linearFormat = linearFormat
        self.linearPrecision = linearPrecision
        self.unit = unit
        self.angleFormat = angleFormat
        self.anglePrecision = anglePrecision
    }

    /// A default context matching `CoordinateFormatter`'s own defaults (Decimal,
    /// 4 dp, unitless, decimal degrees) — handy for tools/tests that ignore document
    /// formatting.
    public static let `default` = LiveDimensionContext()
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
