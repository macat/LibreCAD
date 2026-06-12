//
//  OffsetToolTests.swift
//  CADEngineTests
//
//  Drives the OFFSET modify tool PURELY (no GUI): feeds `ToolInput` events + a
//  read-only `ToolContext` carrying a known selection and asserts the OFFSET
//  contract — that clicking a "through point" emits one `.add` per SUPPORTED
//  selected entity (a parallel COPY, NOT a `.replace` of the original), each
//  carrying the placeholder id and preserving the original's layer/pen/flags,
//  with the geometry offset so it passes through the clicked point. Covers the
//  per-kind offset geometry (line / circle / arc), the live preview, the
//  empty-selection no-op, the unsupported-kind skip, the zero-distance rejection,
//  and attribute preservation.
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("OffsetTool modify (parallel copy through a point)")
struct OffsetToolTests {

    // MARK: - Fixtures

    /// A selected horizontal LINE (0,0)→(10,0) with distinctive, non-default
    /// attrs so attr-preservation is observable on the offset copy.
    private static let selectedLine = EntityRecord(
        id: EntityID(11),
        layer: LayerID("walls"),
        pen: Pen(lineColor: .explicit(RGBAColor(1, 0, 0, 1))),
        flags: [.visible, .selected],
        kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0)))
    )

    /// A selected CIRCLE center (0,0) r=5 with different attrs from the line.
    private static let selectedCircle = EntityRecord(
        id: EntityID(22),
        layer: LayerID("holes"),
        pen: Pen(lineColor: .explicit(RGBAColor(0, 0, 1, 1))),
        flags: [.visible, .selected, .construction],
        kind: .circle(CircleData(center: Vector(0, 0), radius: 5))
    )

    /// A selected ARC center (0,0) r=5, quarter sweep 0→π/2.
    private static let selectedArc = EntityRecord(
        id: EntityID(33),
        layer: LayerID("arcs"),
        pen: Pen(lineColor: .explicit(RGBAColor(0, 1, 0, 1))),
        flags: [.visible, .selected],
        kind: .arc(ArcData(center: Vector(0, 0), radius: 5,
                           startAngle: 0, endAngle: .pi / 2, reversed: false))
    )

    /// A selected POINT — an UNSUPPORTED kind for offset (must be skipped).
    private static let selectedPoint = EntityRecord(
        id: EntityID(44),
        layer: LayerID("pts"),
        pen: .byLayer,
        flags: [.visible, .selected],
        kind: .point(PointData(position: Vector(7, 7)))
    )

    /// Builds a `ToolContext` whose `selected` is the given records.
    private func context(_ records: [EntityRecord]) -> ToolContext {
        ToolContext(
            selected: records,
            entity: { id in records.first { $0.id == id } },
            gridSpacing: nil
        )
    }

    /// Pulls the ordered `.add` records out of a `.commit` outcome (returns nil if
    /// the outcome isn't a pure-`.add` commit — i.e. rejects `.replace`/`.remove`).
    private func addedRecords(_ outcome: ToolOutcome) -> [EntityRecord]? {
        guard case .commit(let edits) = outcome else { return nil }
        var records: [EntityRecord] = []
        for edit in edits {
            guard case .add(let r) = edit else { return nil }
            records.append(r)
        }
        return records
    }

    // MARK: - Basics

    @Test("title is Offset")
    func title() {
        #expect(OffsetTool().title == "Offset")
    }

    @Test("status nudges to select first when nothing is selected")
    func statusEmptySelection() {
        let tool = OffsetTool()
        #expect(tool.status == "Select objects to offset first")
    }

    @Test("after a non-empty selection is seen the status advances to the through-point prompt")
    func statusTransitions() {
        var tool = OffsetTool()
        _ = tool.handle(.move(Vector(0, 3)), context: context([Self.selectedLine]))
        #expect(tool.status == "Specify through point")
    }

    // MARK: - Empty-selection no-op

    @Test("a through-point click with an empty selection is a no-op")
    func emptySelectionNoop() {
        var tool = OffsetTool()
        let outcome = tool.handle(.click(Vector(1, 1)), context: .empty)
        #expect(outcome == .none)
        #expect(tool.status == "Select objects to offset first")
    }

    // MARK: - Line offset

    @Test("line (0,0)-(10,0) through (0,3) → offset line (0,3)-(10,3)")
    func lineOffsetPositiveSide() {
        var tool = OffsetTool()
        let ctx = context([Self.selectedLine])
        let records = addedRecords(tool.handle(.click(Vector(0, 3)), context: ctx))
        #expect(records?.count == 1)
        guard case .line(let l)? = records?.first?.kind else {
            Issue.record("expected a line offset copy"); return
        }
        #expect(l.start == Vector(0, 3))
        #expect(l.end == Vector(10, 3))
    }

    @Test("line (0,0)-(10,0) through (0,-3) → offset line (0,-3)-(10,-3)")
    func lineOffsetNegativeSide() {
        var tool = OffsetTool()
        let ctx = context([Self.selectedLine])
        let records = addedRecords(tool.handle(.click(Vector(0, -3)), context: ctx))
        #expect(records?.count == 1)
        guard case .line(let l)? = records?.first?.kind else {
            Issue.record("expected a line offset copy"); return
        }
        #expect(l.start == Vector(0, -3))
        #expect(l.end == Vector(10, -3))
    }

    @Test("line offset uses the PERPENDICULAR distance (through point off the ends still shifts in Y only)")
    func lineOffsetPerpendicular() {
        var tool = OffsetTool()
        let ctx = context([Self.selectedLine])
        // Through point well past the right end, at y = 4: perpendicular distance
        // to the infinite line is 4, so the copy is the line shifted to y = 4.
        let records = addedRecords(tool.handle(.click(Vector(99, 4)), context: ctx))
        guard case .line(let l)? = records?.first?.kind else {
            Issue.record("expected a line offset copy"); return
        }
        #expect(l.start == Vector(0, 4))
        #expect(l.end == Vector(10, 4))
    }

    // MARK: - Circle offset

    @Test("circle center (0,0) r=5 through (0,8) → concentric r=8 (.add)")
    func circleOffsetOutside() {
        var tool = OffsetTool()
        let ctx = context([Self.selectedCircle])
        let records = addedRecords(tool.handle(.click(Vector(0, 8)), context: ctx))
        #expect(records?.count == 1)
        guard case .circle(let c)? = records?.first?.kind else {
            Issue.record("expected a circle offset copy"); return
        }
        #expect(c.center == Vector(0, 0))
        #expect(abs(c.radius - 8) < 1e-9)
    }

    @Test("circle center (0,0) r=5 through (0,3) → concentric r=3 (inside → smaller)")
    func circleOffsetInside() {
        var tool = OffsetTool()
        let ctx = context([Self.selectedCircle])
        let records = addedRecords(tool.handle(.click(Vector(0, 3)), context: ctx))
        guard case .circle(let c)? = records?.first?.kind else {
            Issue.record("expected a circle offset copy"); return
        }
        #expect(c.center == Vector(0, 0))
        #expect(abs(c.radius - 3) < 1e-9)
    }

    @Test("circle offset radius uses the radial distance regardless of through-point angle")
    func circleOffsetRadialAngleIndependent() {
        var tool = OffsetTool()
        let ctx = context([Self.selectedCircle])
        // (3,4) is distance 5 from center == the original radius → d ≈ 0 → no edit.
        let outcome = tool.handle(.click(Vector(3, 4)), context: ctx)
        #expect(outcome == .none)
    }

    // MARK: - Arc offset

    @Test("arc concentric offset shifts radius and PRESERVES angles + reversed flag")
    func arcOffsetPreservesAngles() {
        var tool = OffsetTool()
        let ctx = context([Self.selectedArc])
        // Through (0,8): radial distance 8 → concentric arc r=8.
        let records = addedRecords(tool.handle(.click(Vector(0, 8)), context: ctx))
        #expect(records?.count == 1)
        guard case .arc(let a)? = records?.first?.kind else {
            Issue.record("expected an arc offset copy"); return
        }
        #expect(a.center == Vector(0, 0))
        #expect(abs(a.radius - 8) < 1e-9)
        #expect(a.startAngle == 0)
        #expect(abs(a.endAngle - .pi / 2) < 1e-12)
        #expect(a.reversed == false)
    }

    @Test("arc offset can shrink the radius (inside through point)")
    func arcOffsetShrinks() {
        var tool = OffsetTool()
        let ctx = context([Self.selectedArc])
        let records = addedRecords(tool.handle(.click(Vector(0, 2)), context: ctx))
        guard case .arc(let a)? = records?.first?.kind else {
            Issue.record("expected an arc offset copy"); return
        }
        #expect(abs(a.radius - 2) < 1e-9)
    }

    // MARK: - Unsupported kind is skipped

    @Test("an unsupported kind (point) is skipped — no edit emitted for it")
    func unsupportedKindSkipped() {
        var tool = OffsetTool()
        // Selection = a point (unsupported) only → nothing to offset → no-op.
        let ctx = context([Self.selectedPoint])
        let outcome = tool.handle(.click(Vector(0, 3)), context: ctx)
        #expect(outcome == .none)
    }

    @Test("mixed selection: supported entities offset, unsupported point dropped")
    func mixedSelectionSkipsUnsupported() {
        var tool = OffsetTool()
        // line + point: only the line yields an .add.
        let ctx = context([Self.selectedLine, Self.selectedPoint])
        let records = addedRecords(tool.handle(.click(Vector(0, 3)), context: ctx))
        #expect(records?.count == 1)
        guard case .line? = records?.first?.kind else {
            Issue.record("expected the lone offset to be the line copy"); return
        }
    }

    // MARK: - Zero-distance rejection

    @Test("a through point on the line (d ≈ 0) emits no edit")
    func zeroDistanceLineIgnored() {
        var tool = OffsetTool()
        let ctx = context([Self.selectedLine])
        // (5,0) lies on the line → d ≈ 0 → no offset.
        let outcome = tool.handle(.click(Vector(5, 0)), context: ctx)
        #expect(outcome == .none)
    }

    // MARK: - Commit shape: only .add, attrs preserved

    @Test("offsets emit ONLY .add edits — never .replace/.remove (originals untouched)")
    func onlyAddEdits() {
        var tool = OffsetTool()
        let ctx = context([Self.selectedLine, Self.selectedCircle, Self.selectedArc])
        let outcome = tool.handle(.click(Vector(0, 9)), context: ctx)
        guard case .commit(let edits) = outcome else {
            Issue.record("expected a commit outcome"); return
        }
        #expect(edits.count == 3)
        for edit in edits {
            switch edit {
            case .add: break
            case .replace, .remove:
                Issue.record("Offset must not replace/remove originals; got \(edit)")
            }
        }
    }

    @Test("offset copies carry the placeholder id (app re-mints on add)")
    func copiesUsePlaceholderID() {
        var tool = OffsetTool()
        let ctx = context([Self.selectedLine, Self.selectedCircle])
        let records = addedRecords(tool.handle(.click(Vector(0, 9)), context: ctx))
        #expect(records?.count == 2)
        for r in records ?? [] {
            #expect(r.id == .placeholder)
            #expect(r.id == EntityID(0))
        }
    }

    @Test("each offset copy preserves the original's layer, pen, and flags")
    func attributesPreserved() {
        var tool = OffsetTool()
        let ctx = context([Self.selectedLine, Self.selectedCircle])
        let records = addedRecords(tool.handle(.click(Vector(0, 9)), context: ctx))
        #expect(records?.count == 2)
        // Line offset mirrors the line original's attrs.
        #expect(records?[0].layer == Self.selectedLine.layer)
        #expect(records?[0].pen == Self.selectedLine.pen)
        #expect(records?[0].flags == Self.selectedLine.flags)
        // Circle offset mirrors the circle original's attrs (distinct from line's).
        #expect(records?[1].layer == Self.selectedCircle.layer)
        #expect(records?[1].pen == Self.selectedCircle.pen)
        #expect(records?[1].flags == Self.selectedCircle.flags)
    }

    // MARK: - Preview

    @Test("preview is empty before a selection is captured")
    func previewEmptyInitially() {
        let tool = OffsetTool()
        #expect(tool.preview.isEmpty)
    }

    @Test("after a selection a move produces a preview for each supported entity")
    func previewAfterSelection() {
        var tool = OffsetTool()
        let ctx = context([Self.selectedLine, Self.selectedCircle])
        let outcome = tool.handle(.move(Vector(0, 9)), context: ctx)
        #expect(outcome == .preview)
        // Two supported entities → at least two resolved preview polylines.
        #expect(tool.preview.count >= 2)
    }

    @Test("preview reflects the cursor: the line offset copy sits at the cursor's Y")
    func previewFollowsCursor() {
        var tool = OffsetTool()
        let ctx = context([Self.selectedLine])
        _ = tool.handle(.move(Vector(2, 3)), context: ctx)
        #expect(tool.preview.count == 1)
        let poly = tool.preview[0]
        // Original (0,0)→(10,0); offset through y=3 → (0,3)→(10,3).
        #expect(poly.points.first == Vector(0, 3))
        #expect(poly.points.last == Vector(10, 3))
        #expect(poly.pen == .toolPreview)
    }

    @Test("preview skips an unsupported kind (point alone yields no preview)")
    func previewSkipsUnsupported() {
        var tool = OffsetTool()
        let ctx = context([Self.selectedPoint])
        _ = tool.handle(.move(Vector(0, 3)), context: ctx)
        #expect(tool.preview.isEmpty)
    }

    // MARK: - Cancel reset

    @Test("cancel discards the captured selection and finishes")
    func cancelResets() {
        var tool = OffsetTool()
        let ctx = context([Self.selectedLine])
        _ = tool.handle(.move(Vector(0, 3)), context: ctx)
        #expect(!tool.preview.isEmpty)
        let outcome = tool.handle(.cancel, context: ctx)
        #expect(outcome == .finished)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Select objects to offset first")
    }

    @Test("backspace is a no-op for the single-pick offset")
    func backspaceNoop() {
        var tool = OffsetTool()
        let ctx = context([Self.selectedLine])
        _ = tool.handle(.move(Vector(0, 3)), context: ctx)
        #expect(tool.handle(.backspace, context: ctx) == .none)
    }
}
