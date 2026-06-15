//
//  DuplicateToolTests.swift
//  CADEngineTests
//
//  Exercises BOTH forms of Duplicate (AutoCAD-style ⌘D) PURELY (no GUI):
//
//    - the pure static API `Duplicate.duplicate(_:offset:)` — that a mixed
//      selection yields the same count of `.add` edits, each geometrically equal
//      to its source shifted by `offset`, with NEW (placeholder) ids and preserved
//      layer/pen/flags; that an empty selection yields no edits; and that an offset
//      of `Vector(0, 0)` produces exact in-place copies.
//
//    - the interactive `DuplicateTool` — that activation with a non-empty selection
//      duplicates immediately (one `.add` per entity, no base/destination pick) and
//      finishes, defaulting to a small visible nudge; that it is idempotent (a
//      single ⌘D = a single duplicate group); that an in-place offset duplicates
//      exactly; and that an empty selection / cancel is a clean no-op.
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("DuplicateTool (⌘D — duplicate selection in place)")
struct DuplicateToolTests {

    // MARK: - Fixtures (a mixed selection with distinctive, non-default attrs)

    /// A selected LINE with distinctive layer/pen/flags so attr-preservation is
    /// observable on the duplicate.
    private static let selectedLine = EntityRecord(
        id: EntityID(11),
        layer: LayerID("walls"),
        pen: Pen(lineColor: .explicit(RGBAColor(1, 0, 0, 1))),
        flags: [.visible, .selected],
        kind: .line(LineData(start: Vector(0, 0), end: Vector(4, 0)))
    )

    /// A selected CIRCLE with different attrs from the line.
    private static let selectedCircle = EntityRecord(
        id: EntityID(22),
        layer: LayerID("holes"),
        pen: Pen(lineColor: .explicit(RGBAColor(0, 0, 1, 1))),
        flags: [.visible, .selected, .construction],
        kind: .circle(CircleData(center: Vector(10, 10), radius: 3))
    )

    /// A selected ARC, so the mixed selection covers three different kinds.
    private static let selectedArc = EntityRecord(
        id: EntityID(33),
        layer: LayerID("trim"),
        pen: Pen(lineColor: .explicit(RGBAColor(0, 1, 0, 1))),
        flags: [.visible, .selected],
        kind: .arc(ArcData(center: Vector(-5, 2), radius: 2,
                           startAngle: 0, endAngle: .pi, reversed: false))
    )

    private static let mixedSelection: [EntityRecord] =
        [selectedLine, selectedCircle, selectedArc]

    /// A `ToolContext` whose `selected` is the mixed line/circle/arc selection.
    private func selectionContext() -> ToolContext {
        let sel = Self.mixedSelection
        return ToolContext(
            selected: sel,
            entity: { id in sel.first { $0.id == id } },
            gridSpacing: nil
        )
    }

    /// Pulls the ordered `.add` records out of a `.commit` outcome (returns nil —
    /// failing the caller's expectation — if the outcome isn't a pure-`.add`
    /// commit, i.e. if any edit is a `.replace`/`.remove`).
    private func addedRecords(_ outcome: ToolOutcome) -> [EntityRecord]? {
        guard case .commit(let edits) = outcome else { return nil }
        var records: [EntityRecord] = []
        for edit in edits {
            guard case .add(let r) = edit else { return nil }   // reject .replace/.remove
            records.append(r)
        }
        return records
    }

    /// Pulls the ordered `.add` records out of a raw `[ToolEdit]` (the static API's
    /// return), or nil if any edit isn't an `.add`.
    private func addedRecords(_ edits: [ToolEdit]) -> [EntityRecord]? {
        var records: [EntityRecord] = []
        for edit in edits {
            guard case .add(let r) = edit else { return nil }
            records.append(r)
        }
        return records
    }

    /// Asserts `copy` is `source` translated by `offset`, with new (placeholder)
    /// id and preserved layer/pen/flags. Covers line/circle/arc geometry.
    private func expectDuplicate(of source: EntityRecord,
                                 is copy: EntityRecord,
                                 offset: Vector) {
        // New id: never the source's; the placeholder the app re-mints.
        #expect(copy.id == .placeholder)
        #expect(copy.id == EntityID(0))
        #expect(copy.id != source.id)
        // Every property preserved.
        #expect(copy.layer == source.layer)
        #expect(copy.pen == source.pen)
        #expect(copy.flags == source.flags)
        // Geometry == source shifted by offset.
        let expected = source.kind.transformed(by: .translation(offset))
        #expect(copy.kind == expected)
    }

    // MARK: - Static API: count + geometry + ids + attrs

    @Test("static duplicate yields one .add per source, same count")
    func staticCountMatches() {
        let edits = Duplicate.duplicate(Self.mixedSelection, offset: Vector(2, 3))
        #expect(edits.count == Self.mixedSelection.count)   // 3 in, 3 .add out
        let records = addedRecords(edits)
        #expect(records?.count == 3)
    }

    @Test("each static duplicate equals its source shifted by offset, new id, attrs kept")
    func staticGeometryAndAttrs() {
        let offset = Vector(5, -7)
        let records = addedRecords(Duplicate.duplicate(Self.mixedSelection, offset: offset))
        #expect(records?.count == 3)
        guard let records, records.count == 3 else { return }
        expectDuplicate(of: Self.selectedLine,   is: records[0], offset: offset)
        expectDuplicate(of: Self.selectedCircle, is: records[1], offset: offset)
        expectDuplicate(of: Self.selectedArc,    is: records[2], offset: offset)
    }

    @Test("static duplicate translates line endpoints + circle center explicitly")
    func staticExplicitTranslation() {
        let offset = Vector(3, 5)
        let records = addedRecords(Duplicate.duplicate(Self.mixedSelection, offset: offset))
        #expect(records?.count == 3)

        guard case .line(let l)? = records?[0].kind else {
            Issue.record("expected first duplicate to be a line"); return
        }
        #expect(l.start == Vector(0, 0) + offset)
        #expect(l.end == Vector(4, 0) + offset)

        guard case .circle(let c)? = records?[1].kind else {
            Issue.record("expected second duplicate to be a circle"); return
        }
        #expect(c.center == Vector(10, 10) + offset)
        #expect(c.radius == 3)   // pure translation leaves radius unchanged
    }

    // MARK: - Static API: empty selection → no edits

    @Test("static duplicate of an empty selection yields no edits")
    func staticEmptyNoEdits() {
        #expect(Duplicate.duplicate([], offset: Vector(1, 1)).isEmpty)
        #expect(Duplicate.duplicate([]).isEmpty)   // default offset too
    }

    // MARK: - Static API: offset .zero → exact in-place copies

    @Test("static duplicate with zero offset produces exact in-place copies")
    func staticZeroOffsetInPlace() {
        let records = addedRecords(Duplicate.duplicate(Self.mixedSelection, offset: Vector(0, 0)))
        #expect(records?.count == 3)
        guard let records, records.count == 3 else { return }
        for (source, copy) in zip(Self.mixedSelection, records) {
            // Geometry identical to the source (no shift), new id, attrs preserved.
            #expect(copy.kind == source.kind)
            #expect(copy.id == .placeholder)
            #expect(copy.id != source.id)
            #expect(copy.layer == source.layer)
            #expect(copy.pen == source.pen)
            #expect(copy.flags == source.flags)
        }
    }

    @Test("default offset is a small nonzero nudge so copies are visible")
    func defaultOffsetIsNonzero() {
        #expect(Duplicate.defaultOffset != Vector(0, 0))
        #expect(Duplicate.defaultOffset.magnitude > Tolerance.distance)
    }

    // MARK: - Interactive tool: basics

    @Test("title is Duplicate")
    func title() {
        #expect(DuplicateTool().title == "Duplicate")
    }

    @Test("status nudges to select first before firing")
    func statusInitial() {
        #expect(DuplicateTool().status == "Select objects to duplicate first")
    }

    @Test("interactive tool has no preview (commits immediately)")
    func noPreview() {
        var tool = DuplicateTool()
        #expect(tool.preview.isEmpty)
        _ = tool.handle(.move(Vector(2, 2)), context: selectionContext())
        #expect(tool.preview.isEmpty)
    }

    // MARK: - Interactive tool: immediate duplicate on activation

    @Test("activation with a non-empty selection duplicates immediately and commits")
    func interactiveDuplicatesImmediately() {
        var tool = DuplicateTool()
        // The app feeds an event right after activating the tool; any non-cancel
        // event triggers the one-shot duplicate.
        let outcome = tool.handle(.commit, context: selectionContext())
        let records = addedRecords(outcome)
        #expect(records?.count == 3)   // one .add per selected entity
    }

    @Test("interactive default offset shifts each copy by the small nudge")
    func interactiveDefaultNudge() {
        var tool = DuplicateTool()
        let records = addedRecords(tool.handle(.click(Vector(0, 0)), context: selectionContext()))
        #expect(records?.count == 3)
        guard let records, records.count == 3 else { return }
        expectDuplicate(of: Self.selectedLine,   is: records[0], offset: Duplicate.defaultOffset)
        expectDuplicate(of: Self.selectedCircle, is: records[1], offset: Duplicate.defaultOffset)
        expectDuplicate(of: Self.selectedArc,    is: records[2], offset: Duplicate.defaultOffset)
    }

    @Test("interactive tool emits only .add edits — never .replace/.remove")
    func interactiveOnlyAdds() {
        var tool = DuplicateTool()
        let outcome = tool.handle(.click(Vector(0, 0)), context: selectionContext())
        guard case .commit(let edits) = outcome else {
            Issue.record("expected a commit outcome"); return
        }
        for edit in edits {
            switch edit {
            case .add: break
            case .replace, .remove:
                Issue.record("Duplicate must not replace/remove originals; got \(edit)")
            }
        }
    }

    @Test("interactive tool with a zero offset duplicates exactly in place")
    func interactiveZeroOffset() {
        var tool = DuplicateTool(offset: Vector(0, 0))
        let records = addedRecords(tool.handle(.commit, context: selectionContext()))
        #expect(records?.count == 3)
        guard let records, records.count == 3 else { return }
        for (source, copy) in zip(Self.mixedSelection, records) {
            #expect(copy.kind == source.kind)   // exact in-place copy
            #expect(copy.id == .placeholder)
            #expect(copy.id != source.id)
        }
    }

    // MARK: - Interactive tool: idempotence + empty + cancel

    @Test("a single ⌘D duplicates once — a second event is a no-op finish")
    func interactiveIdempotent() {
        var tool = DuplicateTool()
        let first = tool.handle(.commit, context: selectionContext())
        #expect(addedRecords(first)?.count == 3)
        // A second event must NOT duplicate again.
        let second = tool.handle(.commit, context: selectionContext())
        #expect(second == .finished)
        #expect(addedRecords(second) == nil)   // not a commit
    }

    @Test("empty selection → no commit, finishes quietly")
    func interactiveEmptySelection() {
        var tool = DuplicateTool()
        let outcome = tool.handle(.commit, context: .empty)
        #expect(outcome == .finished)
        #expect(addedRecords(outcome) == nil)
    }

    @Test("cancel finishes without duplicating")
    func interactiveCancel() {
        var tool = DuplicateTool()
        let outcome = tool.handle(.cancel, context: selectionContext())
        #expect(outcome == .finished)
        #expect(addedRecords(outcome) == nil)
        // Spent: a follow-up event does not duplicate either.
        let after = tool.handle(.commit, context: selectionContext())
        #expect(after == .finished)
        #expect(addedRecords(after) == nil)
    }
}
