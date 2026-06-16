//
//  QuickSelectUIWiringTests.swift
//  CADEngineTests
//
//  Exercises the CanvasModel WIRING for the Quick Select panel — the model funnel the
//  `QuickSelectSectionContent` "Apply" button calls — over a real fixture drawing:
//
//   • `applyQuickSelect(_:mode:)` installs `selection.ids` correctly for each apply mode
//     (replace / add / remove / intersect), built on the engine-pure `QuickSelect`.
//   • The match set is SCOPED to the active space and EXCLUDES block-DEFINITION members
//     (they are owned by a block, never loose top-level entities) and locked/frozen-layer
//     geometry (the same selectability gate Select All uses).
//   • `selectSimilar(to:)` / `similarFilter(to:)` build the kind + layer + color filter
//     for a reference entity and replace the selection with its peers.
//   • The selection-version (`modelVersion`) bumps on a real change and a no-op returns
//     `false` without bumping (so the caller can skip a redraw).
//
//  `CanvasModel` lives in the (un-importable) app target — reached here via the existing
//  `_SharedCanvasModel.swift` symlink. The suite is `@MainActor` (mirrors the other
//  CanvasModel suites). No modal is reachable from any path under test.
//
//  Uniquely namespaced so it does not collide with the other suites in the shared target.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
import CoreGraphics
@testable import CADEngine

@MainActor
@Suite("QuickSelect UI wiring (CanvasModel.applyQuickSelect / selectSimilar)")
struct QuickSelectUIWiringTests {

    // MARK: - Fixtures

    private static let red = RGBAColor(1, 0, 0)
    private static let blue = RGBAColor(0, 0, 1)

    private func makeModel(_ drawing: CADDrawing) -> CanvasModel {
        let model = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        model.undoManager.groupsByEvent = false
        return model
    }

    private func line(_ id: UInt64, layer: String = "0",
                      color: PenColor = .byLayer) -> EntityRecord {
        EntityRecord(id: EntityID(id),
                     layer: LayerID(layer),
                     pen: Pen(lineColor: color, lineType: .byLayer, lineWidth: .byLayer),
                     flags: .default,
                     kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0))))
    }

    private func circle(_ id: UInt64, layer: String = "0",
                        color: PenColor = .byLayer) -> EntityRecord {
        EntityRecord(id: EntityID(id),
                     layer: LayerID(layer),
                     pen: Pen(lineColor: color, lineType: .byLayer, lineWidth: .byLayer),
                     flags: .default,
                     kind: .circle(CircleData(center: Vector(0, 0), radius: 5)))
    }

    /// A drawing with two layers ("walls", "doors") + a mixed set of lines / circles.
    /// Returns the model and a name→id map (the minted ids the drawing assigns on `add`).
    private func mixedModel() -> (model: CanvasModel, ids: [String: EntityID]) {
        let d = CADDrawing()
        _ = d.addLayer(Layer(name: "walls"))
        _ = d.addLayer(Layer(name: "doors"))
        var ids: [String: EntityID] = [:]
        ids["lineWallsRed"]  = d.add(line(0, layer: "walls", color: .explicit(Self.red)))
        ids["lineWallsBlue"] = d.add(line(0, layer: "walls", color: .explicit(Self.blue)))
        ids["circWalls"]     = d.add(circle(0, layer: "walls", color: .explicit(Self.red)))
        ids["circDoors"]     = d.add(circle(0, layer: "doors", color: .byLayer))
        ids["lineDoors"]     = d.add(line(0, layer: "doors", color: .byLayer))
        return (makeModel(d), ids)
    }

    // MARK: - applyQuickSelect — modes

    @Test("replace: installs exactly the matching ids, discarding the prior selection")
    func replaceMode() {
        let (model, ids) = mixedModel()
        model.selection = Selection(ids: [ids["lineDoors"]!])   // prior selection
        let changed = model.applyQuickSelect(QuickSelectFilter(layer: "walls"), mode: .replace)
        #expect(changed)
        #expect(model.selection.ids == [ids["lineWallsRed"]!, ids["lineWallsBlue"]!, ids["circWalls"]!])
    }

    @Test("add: unions the matches into the prior selection")
    func addMode() {
        let (model, ids) = mixedModel()
        model.selection = Selection(ids: [ids["lineDoors"]!])
        _ = model.applyQuickSelect(QuickSelectFilter(kinds: [.circle]), mode: .add)
        #expect(model.selection.ids == [ids["lineDoors"]!, ids["circWalls"]!, ids["circDoors"]!])
    }

    @Test("remove: subtracts the matches from the prior selection")
    func removeMode() {
        let (model, ids) = mixedModel()
        // Select everything on walls, then remove the circles.
        model.selection = Selection(ids: [ids["lineWallsRed"]!, ids["lineWallsBlue"]!, ids["circWalls"]!])
        _ = model.applyQuickSelect(QuickSelectFilter(kinds: [.circle]), mode: .remove)
        #expect(model.selection.ids == [ids["lineWallsRed"]!, ids["lineWallsBlue"]!])
    }

    @Test("intersect: keeps only ids in both the prior selection and the matches")
    func intersectMode() {
        let (model, ids) = mixedModel()
        // Prior: everything on walls. Match: every circle. Intersect → the walls circle.
        model.selection = Selection(ids: [ids["lineWallsRed"]!, ids["lineWallsBlue"]!, ids["circWalls"]!])
        _ = model.applyQuickSelect(QuickSelectFilter(kinds: [.circle]), mode: .intersect)
        #expect(model.selection.ids == [ids["circWalls"]!])
    }

    @Test("combined kind + color filter (AND of criteria)")
    func combinedFilter() {
        let (model, ids) = mixedModel()
        let filter = QuickSelectFilter(kinds: [.line], color: .explicit(Self.red))
        _ = model.applyQuickSelect(filter, mode: .replace)
        #expect(model.selection.ids == [ids["lineWallsRed"]!])
    }

    // MARK: - applyQuickSelect — change detection / version bump

    @Test("a real change bumps modelVersion and returns true; a no-op returns false without bumping")
    func changeDetection() {
        let (model, ids) = mixedModel()
        let v0 = model.modelVersion
        let changed = model.applyQuickSelect(QuickSelectFilter(layer: "doors"), mode: .replace)
        #expect(changed)
        #expect(model.modelVersion == v0 &+ 1)
        #expect(model.selection.ids == [ids["circDoors"]!, ids["lineDoors"]!])

        // Re-applying the SAME filter+mode produces the same set → no-op.
        let v1 = model.modelVersion
        let again = model.applyQuickSelect(QuickSelectFilter(layer: "doors"), mode: .replace)
        #expect(!again)
        #expect(model.modelVersion == v1)
    }

    @Test("an empty-kinds filter matches nothing; replace clears the selection")
    func emptyKindsMatchesNothing() {
        let (model, ids) = mixedModel()
        model.selection = Selection(ids: [ids["circDoors"]!])
        _ = model.applyQuickSelect(QuickSelectFilter(kinds: []), mode: .replace)
        #expect(model.selection.isEmpty)
    }

    // MARK: - Scoping: excludes block-definition members + locked layers

    @Test("a Quick Select never picks block-DEFINITION members (model space)")
    func excludesBlockMembers() {
        let d = CADDrawing()
        // A block whose member is a line on layer "0"; plus a loose top-level line.
        let memberID = d.add(line(0))
        d.mutateBlocks { _ = $0.add(Block(name: "WIDGET", entityIDs: [memberID])) }
        let looseID = d.add(line(0))
        let model = makeModel(d)

        // Sanity: the member is registered as a block member.
        #expect(d.blockMemberIDs.contains(memberID))

        // Select all lines: only the LOOSE line — the block member is excluded.
        _ = model.applyQuickSelect(QuickSelectFilter(kinds: [.line]), mode: .replace)
        #expect(model.selection.ids == [looseID])
        #expect(!model.selection.ids.contains(memberID))
    }

    @Test("a Quick Select skips geometry on a LOCKED layer (Select-All selectability gate)")
    func excludesLockedLayer() {
        let d = CADDrawing()
        _ = d.addLayer(Layer(name: "locked"))
        let openID = d.add(line(0, layer: "0"))
        let lockedID = d.add(line(0, layer: "locked"))
        d.setLayerLocked("locked", true)
        let model = makeModel(d)

        _ = model.applyQuickSelect(QuickSelectFilter(kinds: [.line]), mode: .replace)
        #expect(model.selection.ids == [openID])
        #expect(!model.selection.ids.contains(lockedID))
    }

    @Test("quickSelectMatchIDs is a pure preview: it returns matches without mutating the selection")
    func matchIDsIsPurePreview() {
        let (model, ids) = mixedModel()
        let before = model.selection.ids
        let v0 = model.modelVersion
        let matches = model.quickSelectMatchIDs(QuickSelectFilter(kinds: [.circle]))
        #expect(matches == [ids["circWalls"]!, ids["circDoors"]!])
        #expect(model.selection.ids == before)   // unchanged
        #expect(model.modelVersion == v0)         // no bump
    }

    // MARK: - selectSimilar / similarFilter

    @Test("similarFilter builds a kind + layer + color filter from a reference entity")
    func similarFilterShape() {
        let (model, ids) = mixedModel()
        let filter = model.similarFilter(to: ids["lineWallsRed"]!)
        #expect(filter != nil)
        #expect(filter?.kinds == [.line])
        #expect(filter?.layer == "walls")
        #expect(filter?.color == .explicit(Self.red))
        // Line width is intentionally NOT constrained (Select Similar groups by look).
        #expect(filter?.lineWidth == nil)
    }

    @Test("similarFilter returns nil for an id that no longer resolves")
    func similarFilterMissing() {
        let (model, _) = mixedModel()
        #expect(model.similarFilter(to: EntityID(999_999)) == nil)
    }

    @Test("selectSimilar replaces the selection with the reference entity's peers (same kind/layer/color)")
    func selectSimilarPeers() {
        let (model, ids) = mixedModel()
        // The walls red line: its only same-kind+layer+color peer is itself (the other
        // walls line is blue, the walls circle is a different kind).
        let changed = model.selectSimilar(to: ids["lineWallsRed"]!)
        #expect(changed)
        #expect(model.selection.ids == [ids["lineWallsRed"]!])

        // The walls red CIRCLE: same kind+layer+color group is just itself here.
        _ = model.selectSimilar(to: ids["circWalls"]!)
        #expect(model.selection.ids == [ids["circWalls"]!])
    }

    @Test("selectSimilar groups byLayer-colored peers of the same kind on the same layer")
    func selectSimilarByLayerGroup() {
        let d = CADDrawing()
        _ = d.addLayer(Layer(name: "doors"))
        let a = d.add(line(0, layer: "doors", color: .byLayer))
        let b = d.add(line(0, layer: "doors", color: .byLayer))
        _ = d.add(circle(0, layer: "doors", color: .byLayer))   // different kind
        _ = d.add(line(0, layer: "0", color: .byLayer))         // different layer
        let model = makeModel(d)
        _ = model.selectSimilar(to: a)
        #expect(model.selection.ids == [a, b])
    }

    @Test("selectSimilar returns false (no change) for a missing reference id")
    func selectSimilarMissingIsNoOp() {
        let (model, ids) = mixedModel()
        model.selection = Selection(ids: [ids["circDoors"]!])
        let v0 = model.modelVersion
        let changed = model.selectSimilar(to: EntityID(999_999))
        #expect(!changed)
        #expect(model.selection.ids == [ids["circDoors"]!])   // untouched
        #expect(model.modelVersion == v0)
    }
}
