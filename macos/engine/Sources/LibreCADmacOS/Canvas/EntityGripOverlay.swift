//
//  EntityGripOverlay.swift
//  LibreCADmacOS
//
//  The on-canvas PER-ENTITY GRIP-EDITING overlay — a screen-space AppKit overlay
//  floated OVER the Metal canvas that, when grip-editable entities are selected,
//  draws the small blue square GRIP handles at each entity's characteristic points
//  (a line's endpoints/mid, a circle's center+quadrants, a polyline's vertices, …)
//  and lets the user RESHAPE one entity by DRAGGING a grip — the classic CAD
//  direct-edit gesture. Where the GIZMO (`GizmoOverlayView`) moves/scales/rotates a
//  whole selection by an affine transform, GRIPS edit ONE entity's defining geometry
//  in place: a dragged line endpoint follows the cursor while the other end stays
//  put, a circle quadrant sets a new radius about the fixed center, a polyline vertex
//  moves while neighbours + bulges are preserved.
//
//  ## All the geometry math lives in CADEngine (`EntityGrips`)
//  This view carries NO geometry math. It only:
//    1. calls `EntityGrips.grips(for:ctx:)` to know WHERE to draw the handles (and
//       each handle's `role`, for the affordance), and
//    2. on a grip drag, calls `EntityGrips.moveGrip(_:of:to:ctx:)` to get a NEW
//       `EntityRecord`, drawn as a live green preview, then COMMITTED on mouse-up.
//  So a grip edit produces exactly the engine-defined geometry (unit-tested in
//  `EntityGripsTests`), and the overlay's only logic is screen↔world projection +
//  nearest-grip hit-testing (both pure + unit-tested in `EntityGripOverlayTests`).
//
//  ## Why a screen-space AppKit overlay (mirrors GizmoOverlayView / DynamicGripOverlay)
//  The grip squares must stay a CONSTANT on-screen size across zoom, and the overlay
//  must be transparent to clicks that are NOT on a grip (so clicking empty space or
//  another entity behaves exactly as today). A transparent flipped `NSView` subview
//  whose `hitTest` returns itself ONLY over a grip gives both for free and keeps grip
//  chrome out of the GPU buffer-build path. The grip positions come from
//  `worldToScreen` of `EntityGrips.grips(...)` and are recomputed on every pan/zoom
//  via `refresh()`. This is the SAME contract as the two sibling overlays —
//  `isFlipped = true`, a `hitTest`-claims-only-over-a-handle gate, and a
//  `refresh()` / `isHidden` / `isActive` / `isDragging` lifecycle the mount drives.
//
//  ## INJECTED, not CanvasModel-coupled (the Wave-3 mount wires it)
//  Unlike the two sibling overlays (which hold a `CanvasModel` directly), this
//  overlay is SELF-CONTAINED + INJECTED: it owns NO model and performs NO document
//  mutation. The Wave-3 mount (`CADCanvasView`/its controller) supplies, as closures:
//    • `selectionProvider`  — the currently-selected grip-editable `EntityRecord`s,
//    • `contextProvider`    — the `ResolveContext` for `EntityGrips` queries,
//    • `viewportProvider`   — the `Viewport` for world↔screen projection,
//    • `onGripCommit`       — called once on mouse-up with the moved `EntityRecord`
//                             (the mount routes it through the undoable commit path),
//    • `requestRedraw`      — repaint the Metal canvas (during a live drag preview).
//  The mount also toggles `isEnabled` to SUPPRESS this overlay while the gizmo or
//  another overlay owns the gesture, so two transparent overlays never fight over an
//  ambiguous hit-test (the same dual-overlay arbitration the dynamic grip uses).
//
//  ## Multi-select
//  Single-entity selection is the primary case (grips for that one entity). For a
//  MULTI-entity selection this overlay draws the grips of EVERY selected
//  grip-editable entity and a drag edits the one entity the grabbed grip belongs to
//  (each grip carries its owning record). Kept deliberately simple: there is no
//  cross-entity coupled grip editing here (that is the gizmo's job).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (RS_* grip/handle semantics reused).
//
//  This program is free software; you can redistribute it and/or modify it under the
//  terms of the GNU General Public License version 2 or (at your option) any later
//  version.
//

import AppKit
import CADEngine

// MARK: - The per-entity grip-editing overlay

/// A transparent `NSView` drawn over the canvas that renders + hit-tests the
/// per-entity grip handles and drives a single-grip drag → `EntityGrips.moveGrip`
/// → injected `onGripCommit`. Added as a subview of the `FlippedMTKView`, kept
/// covering the canvas bounds, and shown ONLY when its injected selection has at
/// least one grip-editable entity AND it is enabled (the mount toggles `isEnabled`
/// / calls `refresh()` on selection / pan / zoom change).
@MainActor
final class EntityGripOverlayView: NSView {

    // MARK: Injected inputs (the Wave-3 mount supplies these — no CanvasModel here)

    /// The currently-selected entities to draw grips for. The mount returns ONLY the
    /// records it wants grip-edited (typically the live selection); this overlay
    /// further filters to those that actually expose grips (`grips(for:)` non-empty).
    private let selectionProvider: () -> [EntityRecord]

    /// The `ResolveContext` for `EntityGrips.grips`/`moveGrip` queries.
    private let contextProvider: () -> ResolveContext

    /// The current `Viewport`, for world↔screen projection (drawing + hit-test +
    /// mapping the cursor to a world point for `moveGrip`).
    private let viewportProvider: () -> Viewport

    /// Commit funnel: called ONCE on mouse-up with the moved `EntityRecord` (the
    /// result of `EntityGrips.moveGrip`). The mount routes it through the existing
    /// undoable commit path (e.g. `applyInspectorEdits`), so one ⌘Z reverts the drag.
    private let onGripCommit: (EntityRecord) -> Void

    /// Repaint the underlying Metal canvas (the mount's `requestRedraw`), so the live
    /// grip-drag preview is reflected while dragging.
    private let requestRedraw: () -> Void

    // MARK: State

    /// The grip handles currently drawn, each tagged with its owning record + the
    /// grip's stable engine index. Recomputed from the injected selection in
    /// `refresh()` (and held stable across a drag).
    private var handles: [EntityGripHandle] = []

    /// The in-progress grip drag, or `nil` when idle.
    private var activeDrag: Drag?

    /// One live grip drag: the grabbed handle (its owning record + stable engine grip
    /// index, captured at mouse-down so the projection math is relative to grab time)
    /// and the latest previewed moved record (drawn green; committed on mouse-up).
    private struct Drag {
        /// The grabbed handle (owning record + stable grip index), captured at mouse-down.
        let handle: EntityGripHandle
        /// The latest `EntityGrips.moveGrip` result (the live preview), or `nil` when
        /// the cursor has produced no valid edit yet (a degenerate `moveGrip`).
        var preview: EntityRecord?
    }

    // MARK: Geometry constants (screen points)

    /// Half-size of a grip square (points). The full square is 2×.
    static let gripHalf: CGFloat = 4
    /// Click slop added around a grip's drawn size for easier grabbing (points).
    static let hitSlop: CGFloat = 4

    // MARK: Colors

    /// Grip square fill — the classic CAD blue grip.
    private static let gripFill   = NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.95, alpha: 1.0)
    private static let gripStroke = NSColor.white
    /// Live drag preview line color (matches the gizmo/tool preview green).
    private static let previewColor = NSColor(calibratedRed: 0.45, green: 1.0, blue: 0.55, alpha: 0.95)

    // MARK: Init

    init(selectionProvider: @escaping () -> [EntityRecord],
         contextProvider: @escaping () -> ResolveContext,
         viewportProvider: @escaping () -> Viewport,
         onGripCommit: @escaping (EntityRecord) -> Void,
         requestRedraw: @escaping () -> Void) {
        self.selectionProvider = selectionProvider
        self.contextProvider = contextProvider
        self.viewportProvider = viewportProvider
        self.onGripCommit = onGripCommit
        self.requestRedraw = requestRedraw
        super.init(frame: .zero)
        wantsLayer = true
        // The overlay paints nothing opaque; only the grip squares + drag preview.
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Same flipped (top-left, Y-down) space as the host `FlippedMTKView`, so
    /// `worldToScreen` points land directly without a Y flip (matches the siblings).
    override var isFlipped: Bool { true }

    // MARK: Enable / visibility / refresh

    /// Whether the mount currently lets this overlay participate. The mount sets this
    /// `false` to SUPPRESS grips while the gizmo (or another overlay) owns the gesture;
    /// when `false` the overlay hides + ignores all hits. Default `true`.
    var isEnabled: Bool = true {
        didSet { if oldValue != isEnabled { refresh() } }
    }

    /// Recomputes the drawn grip handles from the injected selection and repaints.
    /// Hides the overlay when disabled or when no selected entity exposes grips (so it
    /// never blocks clicks). Called by the mount on selection / pan / zoom change.
    /// A drag in progress keeps its captured handles stable until mouse-up.
    func refresh() {
        guard activeDrag == nil else { needsDisplay = true; return }
        if isEnabled {
            handles = Self.makeHandles(for: selectionProvider(), ctx: contextProvider())
        } else {
            handles = []
        }
        isHidden = handles.isEmpty
        needsDisplay = true
    }

    /// Whether the overlay currently has grips to show (enabled + a grip-editable
    /// selection). The mount can read this to coordinate with the gizmo.
    var isActive: Bool { isEnabled && !handles.isEmpty }

    /// Whether a grip drag is in progress (so the mount lets this overlay own the
    /// gesture and suppresses its own click/pan handling, mirroring the gizmo).
    var isDragging: Bool { activeDrag != nil }

    // MARK: Screen mapping

    private func screen(_ world: Vector) -> CGPoint { viewportProvider().worldToScreen(world) }
    private func world(_ screen: CGPoint) -> Vector { viewportProvider().screenToWorld(screen) }

    // MARK: Hit-testing (transparent except over a grip)

    /// `hitTest` returns this view ONLY when the point is over a grip (so it can own
    /// the drag); otherwise `nil`, letting the click fall through to the canvas
    /// (selection / drawing) unchanged — the sibling overlays' contract. A drag in
    /// progress keeps the gesture; a disabled/empty overlay never claims a hit.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, isEnabled else { return nil }
        if activeDrag != nil { return self }
        // `point` is in the SUPERVIEW's coordinate space; convert to ours.
        let local = convert(point, from: superview)
        return handleIndex(at: local) != nil ? self : nil
    }

    /// The index into `handles` of the grip nearest a LOCAL screen point within the
    /// grip square + slop, or `nil` if none. Delegates to the pure, unit-tested
    /// `EntityGripHitTest.nearestHandle`.
    private func handleIndex(at p: CGPoint) -> Int? {
        EntityGripHitTest.nearestHandle(
            to: p,
            handles: handles,
            viewport: viewportProvider(),
            slop: Self.gripHalf + Self.hitSlop)
    }

    // MARK: Mouse handling (the drag lifecycle)

    override func mouseDown(with event: NSEvent) {
        guard !isHidden, isEnabled else { super.mouseDown(with: event); return }
        let p = convert(event.locationInWindow, from: nil)
        guard let i = handleIndex(at: p) else { super.mouseDown(with: event); return }
        activeDrag = Drag(handle: handles[i], preview: nil)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var drag = activeDrag else { super.mouseDragged(with: event); return }
        let cursorWorld = world(convert(event.locationInWindow, from: nil))
        // Pure engine math: the moved record (or nil for a degenerate edit, e.g. a
        // circle quadrant dragged onto the center). A nil keeps the last good preview.
        if let moved = EntityGrips.moveGrip(drag.handle.gripIndex,
                                            of: drag.handle.record,
                                            to: cursorWorld,
                                            ctx: contextProvider()) {
            drag.preview = moved
        }
        activeDrag = drag
        needsDisplay = true
        requestRedraw()
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag = activeDrag else { super.mouseUp(with: event); return }
        let cursorWorld = world(convert(event.locationInWindow, from: nil))
        activeDrag = nil
        // Commit the FINAL moved record (recompute from the up-point so the commit
        // matches the cursor exactly, falling back to the last live preview).
        let committed = EntityGrips.moveGrip(drag.handle.gripIndex,
                                             of: drag.handle.record,
                                             to: cursorWorld,
                                             ctx: contextProvider()) ?? drag.preview
        if let committed { onGripCommit(committed) }
        // The geometry moved → re-query grips, repaint chrome + canvas.
        refresh()
        requestRedraw()
    }

    /// Cancels an in-progress grip drag → drop the preview WITHOUT committing, and
    /// re-anchor the grips. The mount's Escape handler calls this (the controller's
    /// key handler always has focus, so this is the reliable cancel path — the overlay
    /// does not depend on becoming first responder). No-op when no drag is in progress.
    /// Mirrors `DynamicGripOverlayView.cancelActiveDrag`.
    func cancelActiveDrag() {
        guard activeDrag != nil else { return }
        activeDrag = nil
        refresh()
        requestRedraw()
    }

    /// AppKit's responder-chain Escape entry point, forwarded to `cancelActiveDrag`
    /// (belt-and-suspenders; the primary cancel path is the mount's Escape handler).
    override func cancelOperation(_ sender: Any?) { cancelActiveDrag() }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // During a drag, draw the moved entity (the live `moveGrip` preview) as green
        // polylines — the same look as the gizmo/tool rubber-band.
        if let preview = activeDrag?.preview { drawPreview(preview, in: ctx) }

        // The grip squares at every drawn handle's screen position.
        for h in handles { drawGrip(at: screen(h.world), in: ctx) }
    }

    /// Draws one grip square at a screen point (filled blue, white stroke).
    private func drawGrip(at p: CGPoint, in ctx: CGContext) {
        let r = CGRect(x: p.x - Self.gripHalf, y: p.y - Self.gripHalf,
                       width: Self.gripHalf * 2, height: Self.gripHalf * 2)
        ctx.setFillColor(Self.gripFill.cgColor)
        ctx.fill(r)
        ctx.setStrokeColor(Self.gripStroke.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(r)
    }

    /// Draws the live drag preview: the moved record resolved to polylines, in green.
    /// Resolves through the injected `ResolveContext` so the preview matches what the
    /// committed geometry will render to.
    private func drawPreview(_ record: EntityRecord, in ctx: CGContext) {
        let resolved = record.resolve(contextProvider())
        ctx.saveGState()
        ctx.setStrokeColor(Self.previewColor.cgColor)
        ctx.setLineWidth(1.5)
        for poly in resolved.polylines {
            let pts = poly.points
            guard pts.count >= 2 else { continue }
            ctx.move(to: screen(pts[0]))
            for i in 1..<pts.count { ctx.addLine(to: screen(pts[i])) }
            if poly.closed, pts.count >= 3 { ctx.addLine(to: screen(pts[0])) }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    // MARK: Pure handle construction (headlessly testable)

    /// Builds the flat list of grip handles for a selection: for each grip-editable
    /// record, one `EntityGripHandle` per `EntityGrips.grips(for:)` entry, tagged with
    /// the owning record + the grip's stable engine index. Pure (no view state), so it
    /// is unit-tested directly. Records that expose no grips contribute nothing.
    static func makeHandles(for records: [EntityRecord], ctx: ResolveContext) -> [EntityGripHandle] {
        var out: [EntityGripHandle] = []
        for record in records {
            for gp in EntityGrips.grips(for: record, ctx: ctx) {
                out.append(EntityGripHandle(record: record, gripIndex: gp.index,
                                            world: gp.world, role: gp.role))
            }
        }
        return out
    }
}

// MARK: - EntityGripHandle (one drawn grip, tagged with its owning entity)

/// One drawn grip handle: the owning `EntityRecord`, the grip's STABLE engine index
/// (for `EntityGrips.moveGrip`), and a cached world position + role from
/// `EntityGrips.grips(for:)`. Carrying the owning record makes a multi-entity
/// selection's drag route to the right entity. A plain value type so the
/// projection/hit-test logic is pure + headlessly testable.
struct EntityGripHandle: Equatable {
    /// The entity this grip belongs to (the `moveGrip` target; preserves id/layer/pen).
    var record: EntityRecord
    /// The grip's stable engine index for `EntityGrips.moveGrip(_:of:to:ctx:)`.
    var gripIndex: Int
    /// The grip's world position (cached from `EntityGrips.grips(for:)`).
    var world: Vector
    /// The grip's semantic role (for the affordance; not used by the drag math).
    var role: GripRole
}

// MARK: - EntityGripHitTest (pure nearest-grip hit-testing)

/// Pure, headlessly-testable nearest-grip hit-testing for the overlay — the only
/// non-trivial geometry the view itself owns (projection is `Viewport`; reshaping is
/// `EntityGrips`). Static members of a namespaced `enum` so there are no module-scope
/// free functions (CONVENTIONS.md).
enum EntityGripHitTest {

    /// The index into `handles` of the grip whose SCREEN position is nearest a local
    /// screen point `p` AND within `slop` points (Chebyshev / square test, matching
    /// the drawn square grip), or `nil` if none is within slop. When several grips are
    /// within slop the geometrically NEAREST (Euclidean) wins, so overlapping grips
    /// (e.g. a line endpoint sitting under a polyline vertex) resolve deterministically.
    static func nearestHandle(to p: CGPoint,
                              handles: [EntityGripHandle],
                              viewport: Viewport,
                              slop: CGFloat) -> Int? {
        var best: Int?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (i, h) in handles.enumerated() {
            let s = viewport.worldToScreen(h.world)
            let dx = p.x - s.x
            let dy = p.y - s.y
            // Square (Chebyshev) containment within the grip square + slop.
            guard abs(dx) <= slop, abs(dy) <= slop else { continue }
            let d = dx * dx + dy * dy           // squared Euclidean for the tie-break
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }
}
