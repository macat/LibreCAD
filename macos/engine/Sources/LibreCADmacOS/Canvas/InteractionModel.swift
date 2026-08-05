//
//  InteractionModel.swift
//  LibreCADmacOS
//
//  Wave 4 Phase 1 — extraction from the CanvasModel god object.
//  Owns interaction-owned state: Selection, SnapResult, cursor world point,
//  and the active tool routing. Depends on DocumentModel + ViewportModel via
//  init injection (the design's dependency rule).
//
//  Per perf-arch-review-plan Wave 4: InteractionModel is a focused
//  @Observable at @MainActor, so tool/snap/selection changes don't churn
//  document or viewport observers. CanvasModel holds this and forwards
//  canvasModel.selection -> interactionModel.selection etc.
//
//  GPLv2-or-later.
//

import Foundation
import CoreGraphics
import Observation
import CADEngine

/// The interaction-owned slice of canvas state: selection, snapping,
/// the cursor's world location, and the active tool's value.
///
/// Depends on the document and viewport models via init injection so
/// it can hit-test / snap against the live drawing + spatial index
/// without owning them.
@MainActor
@Observable
final class InteractionModel {

    // MARK: - Dependencies (injected, unowned for observation)

    private let document: DocumentModel
    private let viewport: ViewportModel

    // MARK: - Stored interaction state

    /// The current selection (toggled by click → hitTest).
    var selection = Selection()

    /// Whether anything is currently selected (thin accessor).
    var hasSelection: Bool { !selection.isEmpty }

    /// The latest snap result under the cursor (drives the snap marker).
    var snap: SnapResult?

    /// The cursor's world position (for the HUD). `nil` when outside.
    var cursorWorld: Vector?

    /// The active interaction mode: `.select` or a concrete draw tool.
    var activeToolKind: ToolKind = .select

    /// The live tool value for `activeToolKind`, or `nil` in `.select`.
    /// Value type the model owns; canvas events are forwarded to it.
    @ObservationIgnored
    var tool: (any Tool)?

    /// The tool's current prompt for the HUD.
    var toolStatus: String = ""

    /// The pick/snap aperture in GUI points.
    static let catchPoints: Double = 8
    var pickAperturePoints: Double = InteractionModel.catchPoints

    /// Snap tolerance in world units for the current zoom.
    var worldTolerance: Double { pickAperturePoints * viewport.viewport.worldPerPixel }

    // MARK: - Init (injection)

    init(document: DocumentModel, viewport: ViewportModel) {
        self.document = document
        self.viewport = viewport
    }

    // MARK: - Tool activation + routing (thin wrappers that stay interaction-owned)

    /// Activates `kind`, minting a fresh tool value (or clearing to select).
    func activateTool(_ kind: ToolKind) {
        activeToolKind = kind
        tool = kind.makeTool()
        toolStatus = tool?.status ?? ""
    }

    /// Whether a draw tool is active (vs select/pan).
    var isToolActive: Bool { activeToolKind != .select }

    /// Updates the tool status string (for HUD).
    func setToolStatus(_ s: String) { toolStatus = s }

    // MARK: - Selection helpers (pure selection state, view-agnostic)

    /// The entity currently under the cursor (hover highlight).
    @ObservationIgnored
    private(set) var hoverID: EntityID?

    /// Live marquee rect in world coords, or nil.
    @ObservationIgnored
    private(set) var marqueeRect: AABB?
    @ObservationIgnored
    private(set) var marqueeCrossing: Bool = false

    func setHover(_ id: EntityID?) { hoverID = id }
    func clearHover() { hoverID = nil }

    func beginMarquee(at world: Vector) {
        marqueeRect = AABB(point: world)
        marqueeCrossing = false
    }

    func updateMarquee(from anchor: Vector, to cursor: Vector) {
        marqueeRect = AABB(points: [anchor, cursor])
        marqueeCrossing = cursor.x < anchor.x
    }

    func clearMarquee() { marqueeRect = nil }

    var hoverTarget: EntityID? { hoverID }
    var marquee: AABB? { marqueeRect }
    var isMarqueeCrossing: Bool { marqueeCrossing }

    /// Hit-tests the nearest selectable entity at a world point.
    func hitTest(at world: Vector) -> EntityID? {
        selection.hitTest(
            worldPoint: world,
            worldTolerance: worldTolerance,
            in: document.drawing,
            using: viewport.quadtree
        )
    }

    /// Toggles selection at a screen point (thin wrapper over hitTest).
    @discardableResult
    func toggleSelection(atScreenPoint screen: CGPoint) -> Bool {
        let world = viewport.viewport.screenToWorld(screen)
        guard let id = hitTest(at: world) else { return false }
        selection.toggle(id)
        return true
    }

    /// Selects all selectable entities.
    @discardableResult
    func selectAll() -> Bool {
        let ids = Set(SelectionPolicy.selectableIDs(in: document.drawing))
        guard ids != selection.ids else { return false }
        selection = Selection(ids: ids)
        return true
    }

    /// Clears selection.
    @discardableResult
    func deselectAll() -> Bool {
        guard !selection.isEmpty else { return false }
        selection.clear()
        return true
    }

    // MARK: - Snap update

    /// Runs snapping for a cursor screen point, updating cursorWorld + snap.
    @discardableResult
    func updateSnap(atScreenPoint screen: CGPoint, gridSpacing: Double?, snapModes: SnapMode) -> Bool {
        let world = viewport.viewport.screenToWorld(screen)
        cursorWorld = world
        let result = Snapping.snap(
            worldPoint: world,
            modes: snapModes,
            worldTolerance: worldTolerance,
            gridSpacing: gridSpacing,
            in: document.drawing,
            using: viewport.quadtree,
            ctx: document.drawing.makeResolveContext()
        )
        let changed = result != snap
        snap = result
        return changed
    }

    func clearCursor() {
        cursorWorld = nil
        snap = nil
    }
}
