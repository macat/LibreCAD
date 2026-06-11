//
//  ToolTests.swift
//  CADEngineTests
//
//  Drives the interactive Tool framework PURELY (no GUI): feeds `ToolInput`
//  events + a read-only `ToolContext` to `LineTool` and asserts the outcomes, the
//  live preview, the chaining behavior, cancel/backspace resets, and the status
//  prompt transitions.
//
//  Also proves the WIDENED contract (the modify-tool seam): a tiny inline modify
//  `Tool` reads `context.selected` and emits `.replace`/`.remove` edits, and the
//  apply path (the engine primitives `CanvasModel.applyCommit` is built on —
//  `CADDrawing.add/replace/remove` + `Quadtree.insert/update/remove` + `Selection`)
//  is exercised end-to-end with undo/redo. (The app's `CanvasModel.applyCommit`
//  lives in the executable target and isn't `@testable`-importable here, so the
//  apply logic is mirrored in `applyEdits` below — kept in lockstep with it.)
//
//  Domain-prefixed suite names (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding test files to the SAME target don't collide). The tool
//  fan-out adds `<Name>ToolTests` suites here following this template.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("LineTool interactive draw")
struct LineToolTests {

    // MARK: - Helpers

    /// Pulls the single LineData out of a `.commit` outcome (fails the test if the
    /// outcome isn't a one-edit `.add` line commit).
    private func committedLine(_ outcome: ToolOutcome) -> LineData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .line(let d) = record.kind else { return nil }
        return d
    }

    // MARK: - Status transitions

    @Test("status starts at 'Specify first point' and advances after the first click")
    func statusTransitions() {
        var tool = LineTool()
        #expect(tool.status == "Specify first point")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.status == "Specify next point")
    }

    @Test("title is Line")
    func title() {
        #expect(LineTool().title == "Line")
    }

    // MARK: - Two-click commit

    @Test("two clicks commit a line with the exact endpoints")
    func twoClicksCommit() {
        var tool = LineTool()
        let start = Vector(1, 2)
        let end = Vector(7, 9)

        let first = tool.handle(.click(start), context: .empty)
        #expect(first == .none)   // first click only fixes the start

        let second = tool.handle(.click(end), context: .empty)
        let line = committedLine(second)
        #expect(line != nil)
        #expect(line?.start == start)
        #expect(line?.end == end)
    }

    @Test("committed record carries the placeholder id (app re-mints on add)")
    func commitUsesPlaceholderID() {
        var tool = LineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let outcome = tool.handle(.click(Vector(5, 0)), context: .empty)
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0] else {
            Issue.record("expected a single-add commit outcome")
            return
        }
        #expect(record.id == .placeholder)
        #expect(record.id == EntityID(0))
    }

    // MARK: - Preview (rubber-band)

    @Test("preview is empty before the first click")
    func previewEmptyInitially() {
        var tool = LineTool()
        #expect(tool.preview.isEmpty)
        // A move with no fixed point still shows nothing.
        let outcome = tool.handle(.move(Vector(3, 3)), context: .empty)
        #expect(outcome == .none)
        #expect(tool.preview.isEmpty)
    }

    @Test("after the first click a move produces a 1-segment preview start→cursor")
    func previewAfterFirstClick() {
        var tool = LineTool()
        let start = Vector(2, 2)
        _ = tool.handle(.click(start), context: .empty)

        let cursor = Vector(10, 4)
        let outcome = tool.handle(.move(cursor), context: .empty)
        #expect(outcome == .preview)

        #expect(tool.preview.count == 1)
        let poly = tool.preview[0]
        #expect(poly.points.count == 2)
        #expect(poly.closed == false)
        #expect(poly.points[0] == start)
        #expect(poly.points[1] == cursor)
    }

    @Test("preview updates to the new cursor on a subsequent move")
    func previewFollowsCursor() {
        var tool = LineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.move(Vector(1, 1)), context: .empty)
        _ = tool.handle(.move(Vector(8, 3)), context: .empty)
        #expect(tool.preview[0].points[1] == Vector(8, 3))
    }

    // MARK: - Chaining (polyline-like run)

    @Test("chaining: the next segment continues from the last endpoint")
    func chainingContinuesFromEndpoint() {
        var tool = LineTool()
        let p0 = Vector(0, 0)
        let p1 = Vector(5, 0)
        let p2 = Vector(5, 5)

        _ = tool.handle(.click(p0), context: .empty)
        let seg1 = committedLine(tool.handle(.click(p1), context: .empty))
        #expect(seg1?.start == p0)
        #expect(seg1?.end == p1)

        // A move now rubber-bands from p1, not p0.
        _ = tool.handle(.move(Vector(5, 3)), context: .empty)
        #expect(tool.preview[0].points[0] == p1)

        // The next click commits p1→p2 (continues the chain).
        let seg2 = committedLine(tool.handle(.click(p2), context: .empty))
        #expect(seg2?.start == p1)
        #expect(seg2?.end == p2)

        // Still active (chaining), prompt unchanged.
        #expect(tool.status == "Specify next point")
    }

    @Test("a degenerate (zero-length) second click does not commit")
    func degenerateClickIgnored() {
        var tool = LineTool()
        let p = Vector(3, 3)
        _ = tool.handle(.click(p), context: .empty)
        let outcome = tool.handle(.click(p), context: .empty)   // same point
        #expect(outcome == .none)
    }

    // MARK: - Cancel / commit / backspace

    @Test("cancel resets to an empty preview and finishes")
    func cancelResets() {
        var tool = LineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.move(Vector(5, 5)), context: .empty)
        #expect(!tool.preview.isEmpty)

        let outcome = tool.handle(.cancel, context: .empty)
        #expect(outcome == .finished)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Specify first point")
    }

    @Test("commit ends the run and finishes (segments already committed per click)")
    func commitFinishes() {
        var tool = LineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(4, 0)), context: .empty)   // already committed seg1
        let outcome = tool.handle(.commit, context: .empty)       // Return → end the run
        #expect(outcome == .finished)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Specify first point")
    }

    @Test("backspace from a single fixed point returns to the initial state")
    func backspaceRewinds() {
        var tool = LineTool()
        _ = tool.handle(.click(Vector(2, 2)), context: .empty)
        #expect(tool.status == "Specify next point")
        let outcome = tool.handle(.backspace, context: .empty)
        #expect(outcome == .preview)
        #expect(tool.status == "Specify first point")
        #expect(tool.preview.isEmpty)
    }

    @Test("backspace with nothing fixed is a no-op")
    func backspaceNoop() {
        var tool = LineTool()
        let outcome = tool.handle(.backspace, context: .empty)
        #expect(outcome == .none)
        #expect(tool.status == "Specify first point")
    }

    @Test("draw tool ignores a populated context (behavior unchanged with selection)")
    func drawToolIgnoresContext() {
        // A non-empty context (as if entities were selected) must NOT change a
        // draw tool's outcome — LineTool reads only the snapped points.
        let selected = EntityRecord(id: EntityID(42), kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0))))
        let ctx = ToolContext(
            selected: [selected],
            entity: { id in id == EntityID(42) ? selected : nil },
            gridSpacing: 0.5
        )
        var tool = LineTool()
        _ = tool.handle(.click(Vector(1, 2)), context: ctx)
        let line = committedLine(tool.handle(.click(Vector(7, 9)), context: ctx))
        #expect(line?.start == Vector(1, 2))
        #expect(line?.end == Vector(7, 9))
    }
}

@Suite("ToolKind registration")
struct ToolKindTests {

    @Test("select makes no tool; line makes a LineTool")
    func makeTool() {
        #expect(ToolKind.select.makeTool() == nil)
        let tool = ToolKind.line.makeTool()
        #expect(tool != nil)
        #expect(tool?.title == "Line")
    }

    @Test("titles are present for every kind")
    func titles() {
        #expect(ToolKind.select.title == "Select")
        #expect(ToolKind.line.title == "Line")
    }

    @Test("kinds round-trip through their raw value")
    func rawValueRoundTrip() {
        for kind in ToolKind.allCases {
            #expect(ToolKind(rawValue: kind.rawValue) == kind)
        }
    }
}

// MARK: - Widened contract: ToolEdit / ToolContext support modify semantics

/// A minimal MODIFY tool used to prove the widened `Tool` contract end-to-end:
/// on `.commit` it reads `context.selected` and, for each selected line, either
/// translates its geometry by `delta` (`.replace`, even indices) or deletes it
/// (`.remove`, odd indices). It is NOT a production Move tool — it exists only to
/// show the contract expresses replace/remove generically off the selection.
private struct StubModifyTool: Tool {
    var delta: Vector
    var title: String { "StubModify" }
    var status: String { "Select then commit" }
    var preview: [ResolvedPolyline] { [] }

    mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        guard case .commit = input else { return .none }
        var edits: [ToolEdit] = []
        for (i, e) in context.selected.enumerated() {
            if i.isMultiple(of: 2) {
                // Translate the line's geometry (replace its kind, same id).
                guard case .line(let d) = e.kind else { continue }
                let moved = LineData(start: d.start + delta, end: d.end + delta)
                edits.append(.replace(e.id, .line(moved)))
            } else {
                edits.append(.remove(e.id))
            }
        }
        return edits.isEmpty ? .finished : .commit(edits)
    }
}

@MainActor
@Suite("Tool contract — modify edits (replace/remove) + undo")
struct ToolModifyContractTests {

    /// A test UndoManager: manual grouping (no run loop closes event groups).
    private func testUndoManager() -> UndoManager {
        let um = UndoManager()
        um.groupsByEvent = false
        return um
    }

    private func makeLine(from a: Vector, to b: Vector) -> EntityRecord {
        EntityRecord(id: EntityID(0), kind: .line(LineData(start: a, end: b)))
    }

    /// Mirrors `CanvasModel.applyCommit`: applies a tool's edits to the drawing +
    /// quadtree + selection as ONE undo group. Kept in lockstep with that method.
    private func applyEdits(_ edits: [ToolEdit],
                            drawing: CADDrawing,
                            quadtree: Quadtree,
                            selection: inout Selection,
                            undoManager: UndoManager) {
        guard !edits.isEmpty else { return }
        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }

        for edit in edits {
            switch edit {
            case .add(let record):
                let id = drawing.add(record)
                let box = drawing.entity(id)?.boundingBox() ?? record.boundingBox()
                if !box.isEmpty { quadtree.insert(id, bounds: box) }
            case .replace(let id, let newKind):
                guard var record = drawing.entity(id) else { continue }
                record.kind = newKind
                drawing.replace(record)
                let box = record.boundingBox()
                if box.isEmpty { quadtree.remove(id) } else { quadtree.update(id, bounds: box) }
            case .remove(let id):
                drawing.remove(id)
                quadtree.remove(id)
                selection.remove(id)
            }
        }
    }

    /// Rebuilds the quadtree from the drawing (what `CanvasModel.undo/redo` do, so
    /// the value-snapshot undo — which doesn't touch the index — stays consistent).
    private func rebuildIndex(_ drawing: CADDrawing, into quadtree: Quadtree) {
        quadtree.removeAll()
        for e in drawing.entities {
            let b = e.boundingBox()
            if !b.isEmpty { quadtree.insert(e.id, bounds: b) }
        }
    }

    @Test(".replace edit translates geometry; quadtree + undo/redo stay consistent")
    func replaceEditWithUndo() {
        let um = testUndoManager()
        let drawing = CADDrawing()
        let quadtree = Quadtree()
        var selection = Selection()

        // Seed one line WITHOUT undo (set up state), index it, select it.
        let id = drawing.add(makeLine(from: Vector(0, 0), to: Vector(10, 0)))
        quadtree.insert(id, bounds: drawing.entity(id)!.boundingBox())
        selection.add(id)
        drawing.undoManager = um

        // A modify tool moves the (single) selected line by (0, 5). The lookup
        // closure is fed a value snapshot (same Sendable approach as CanvasModel).
        var tool = StubModifyTool(delta: Vector(0, 5))
        let byID = Dictionary(uniqueKeysWithValues: drawing.entities.map { ($0.id, $0) })
        let ctx = ToolContext(
            selected: selection.ids.compactMap { byID[$0] },
            entity: { byID[$0] },
            gridSpacing: nil
        )
        let outcome = tool.handle(.commit, context: ctx)
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .replace = edits[0] else {
            Issue.record("expected a single .replace edit")
            return
        }
        applyEdits(edits, drawing: drawing, quadtree: quadtree, selection: &selection, undoManager: um)

        // Geometry replaced in place (same id, new endpoints), drawing count same.
        #expect(drawing.count == 1)
        guard case .line(let moved) = drawing.entity(id)!.kind else {
            Issue.record("entity is no longer a line"); return
        }
        #expect(moved.start == Vector(0, 5))
        #expect(moved.end == Vector(10, 5))
        // Quadtree updated to the new bounds (the moved line is found at y≈5, and
        // the old footprint at y≈0 no longer hits).
        #expect(quadtree.query(point: Vector(5, 5), tolerance: 0.1).contains(id))
        #expect(!quadtree.query(point: Vector(5, 0), tolerance: 0.1).contains(id))

        // Undo restores the original geometry; redo re-applies the move.
        um.undo()
        rebuildIndex(drawing, into: quadtree)
        guard case .line(let restored) = drawing.entity(id)!.kind else {
            Issue.record("entity is no longer a line after undo"); return
        }
        #expect(restored.start == Vector(0, 0))
        #expect(restored.end == Vector(10, 0))
        #expect(quadtree.query(point: Vector(5, 0), tolerance: 0.1).contains(id))

        um.redo()
        rebuildIndex(drawing, into: quadtree)
        guard case .line(let redone) = drawing.entity(id)!.kind else {
            Issue.record("entity is no longer a line after redo"); return
        }
        #expect(redone.start == Vector(0, 5))
        #expect(quadtree.query(point: Vector(5, 5), tolerance: 0.1).contains(id))
    }

    @Test(".remove edit drops the entity from drawing + quadtree + selection; one undo restores the whole commit")
    func removeEditWithUndo() {
        let um = testUndoManager()
        let drawing = CADDrawing()
        let quadtree = Quadtree()
        var selection = Selection()

        // Two selected lines so the stub takes both branches: index 0 → replace,
        // index 1 → remove. Set up state without undo, then attach the manager.
        let id = drawing.add(makeLine(from: Vector(0, 0), to: Vector(4, 0)))
        let id2 = drawing.add(makeLine(from: Vector(0, 1), to: Vector(4, 1)))
        quadtree.insert(id, bounds: drawing.entity(id)!.boundingBox())
        quadtree.insert(id2, bounds: drawing.entity(id2)!.boundingBox())
        selection.add(id)
        selection.add(id2)
        drawing.undoManager = um

        var tool = StubModifyTool(delta: Vector(0, 0))
        // Order the selection deterministically: id (replace), id2 (remove).
        let byID = Dictionary(uniqueKeysWithValues: drawing.entities.map { ($0.id, $0) })
        let ctx = ToolContext(
            selected: [byID[id]!, byID[id2]!],
            entity: { byID[$0] },
            gridSpacing: nil
        )
        let outcome = tool.handle(.commit, context: ctx)
        guard case .commit(let edits) = outcome, edits.count == 2 else {
            Issue.record("expected two edits (replace + remove)"); return
        }
        applyEdits(edits, drawing: drawing, quadtree: quadtree, selection: &selection, undoManager: um)

        // id2 removed everywhere; id survives.
        #expect(drawing.count == 1)
        #expect(!drawing.contains(id2))
        #expect(drawing.contains(id))
        #expect(quadtree.query(point: Vector(2, 1), tolerance: 0.1).isEmpty)
        #expect(!selection.contains(id2))

        // ONE undo reverts the WHOLE commit (both the replace and the remove).
        um.undo()
        rebuildIndex(drawing, into: quadtree)
        #expect(drawing.count == 2)
        #expect(drawing.contains(id2))
        #expect(quadtree.query(point: Vector(2, 1), tolerance: 0.1).contains(id2))

        um.redo()
        rebuildIndex(drawing, into: quadtree)
        #expect(drawing.count == 1)
        #expect(!drawing.contains(id2))
    }

    @Test("an .add edit through the same path mints an id and indexes it (draw seam)")
    func addEditThroughApply() {
        let um = testUndoManager()
        let drawing = CADDrawing()
        let quadtree = Quadtree()
        var selection = Selection()
        drawing.undoManager = um

        let rec = EntityRecord(id: .placeholder, kind: .line(LineData(start: Vector(0, 0), end: Vector(3, 4))))
        applyEdits([.add(rec)], drawing: drawing, quadtree: quadtree, selection: &selection, undoManager: um)

        #expect(drawing.count == 1)
        let id = drawing.entities[0].id
        #expect(id.rawValue != 0)   // placeholder re-minted
        #expect(quadtree.query(point: Vector(1.5, 2), tolerance: 0.5).contains(id))

        um.undo()
        rebuildIndex(drawing, into: quadtree)
        #expect(drawing.isEmpty)
        #expect(quadtree.isEmpty)
    }
}
