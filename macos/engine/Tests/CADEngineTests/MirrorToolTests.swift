//
//  MirrorToolTests.swift
//  CADEngineTests
//
//  Drives the interactive Mirror tool PURELY (no GUI): feeds `ToolInput` events +
//  a read-only `ToolContext` (with a known selection) to `MirrorTool` and asserts
//  the commit shape (one `.replace` per selected id, geometry reflected across the
//  two-point axis), that orientation-reversing flips land (polyline bulge SIGN
//  flips, arc `reversed` flips — both produced by `EntityTransform`, asserted here
//  only on the end result), the live preview (present + reflected), the
//  empty-selection no-op, the degenerate-axis no-op, and the cancel/backspace
//  resets.
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding test files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("MirrorTool interactive modify")
struct MirrorToolTests {

    // MARK: - Fixtures

    /// A line from (0,5) to (10,5), id 1. Mirroring across the X axis sends it to
    /// (0,-5)-(10,-5).
    private static let lineID = EntityID(1)
    private func lineRecord() -> EntityRecord {
        EntityRecord(id: Self.lineID, kind: .line(LineData(start: Vector(0, 5), end: Vector(10, 5))))
    }

    /// A two-vertex polyline with a nonzero bulge on its first segment, id 2.
    /// Mirroring flips the bulge SIGN (orientation reversal).
    private static let polylineID = EntityID(2)
    private static let polylineBulge = 0.5
    private func polylineRecord() -> EntityRecord {
        EntityRecord(
            id: Self.polylineID,
            kind: .polyline(PolylineData(vertices: [
                PolylineVertex(point: Vector(0, 5), bulge: Self.polylineBulge),
                PolylineVertex(point: Vector(10, 5), bulge: 0),
            ], closed: false))
        )
    }

    /// An arc (center (5,5), r 2, 0→π/2, not reversed), id 3. Mirroring flips
    /// `reversed`.
    private static let arcID = EntityID(3)
    private func arcRecord() -> EntityRecord {
        EntityRecord(
            id: Self.arcID,
            kind: .arc(ArcData(center: Vector(5, 5), radius: 2,
                               startAngle: 0, endAngle: .pi / 2, reversed: false))
        )
    }

    /// A line with FULLY non-default attributes (layer / pen / flags / space /
    /// layoutName), id 7. Used to prove the mirror-COPY `.add` record carries every
    /// source attribute verbatim — only id (→ placeholder) and geometry change.
    private static let decoratedID = EntityID(7)
    private static let decoratedLayer = LayerID("walls")
    private static let decoratedPen = Pen(lineColor: .byBlock, lineType: .dashed)
    private static let decoratedFlags: EntityFlags = [.visible, .locked]
    private func decoratedLineRecord() -> EntityRecord {
        EntityRecord(
            id: Self.decoratedID,
            layer: Self.decoratedLayer,
            pen: Self.decoratedPen,
            flags: Self.decoratedFlags,
            kind: .line(LineData(start: Vector(0, 5), end: Vector(10, 5))),
            space: .paper,
            layoutName: "Layout1"
        )
    }

    /// The X axis as a two-point mirror line: p1 = (0,0), p2 = (10,0).
    private static let axisP1 = Vector(0, 0)
    private static let axisP2 = Vector(10, 0)

    /// A `ToolContext` selecting the given records.
    private func context(_ records: [EntityRecord]) -> ToolContext {
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        return ToolContext(selected: records, entity: { byID[$0] }, gridSpacing: nil)
    }

    /// Pulls the `.replace`d kinds out of a `.commit`, keyed by id (returns nil if
    /// the outcome isn't a `.commit` of only `.replace` edits).
    private func replacedKinds(_ outcome: ToolOutcome) -> [EntityID: EntityKind]? {
        guard case .commit(let edits) = outcome else { return nil }
        var out: [EntityID: EntityKind] = [:]
        for edit in edits {
            guard case .replace(let id, let kind) = edit else { return nil }
            out[id] = kind
        }
        return out
    }

    /// Pulls the `.add`ed records out of a `.commit`, in order (returns nil if the
    /// outcome isn't a `.commit` of ONLY `.add` edits — so a `.replace`-only commit
    /// returns nil, which the regression guard relies on).
    private func addedRecords(_ outcome: ToolOutcome) -> [EntityRecord]? {
        guard case .commit(let edits) = outcome else { return nil }
        var out: [EntityRecord] = []
        for edit in edits {
            guard case .add(let record) = edit else { return nil }
            out.append(record)
        }
        return out
    }

    /// Approximate vector equality (mirror angles introduce tiny FP noise).
    private func approxEqual(_ a: Vector, _ b: Vector, _ eps: Double = 1e-9) -> Bool {
        abs(a.x - b.x) < eps && abs(a.y - b.y) < eps
    }

    // MARK: - Metadata / status

    @Test("title is Mirror")
    func title() {
        #expect(MirrorTool().title == "Mirror")
    }

    @Test("with a selection the status walks axis-1 → axis-2")
    func statusWithSelection() {
        var tool = MirrorTool()
        let ctx = context([lineRecord()])
        // Before any click the tool hasn't captured the selection yet, so the
        // first prompt is the select-first hint.
        #expect(tool.status == "Select objects to mirror first")
        _ = tool.handle(.click(Self.axisP1), context: ctx)
        #expect(tool.status == "Specify second point of mirror line")
    }

    @Test("empty selection keeps the select-first status")
    func statusEmptySelection() {
        let tool = MirrorTool()
        #expect(tool.status == "Select objects to mirror first")
    }

    // MARK: - Two-click commit (line reflected across the X axis)

    @Test("axis-1 + axis-2 commits one .replace per id; line reflects across the X axis")
    func twoClicksCommitReflectsLine() {
        var tool = MirrorTool()
        let ctx = context([lineRecord()])

        let first = tool.handle(.click(Self.axisP1), context: ctx)
        #expect(first == .none)   // first click only fixes the first axis point

        let outcome = tool.handle(.click(Self.axisP2), context: ctx)
        guard let kinds = replacedKinds(outcome) else {
            Issue.record("expected a .commit of only .replace edits"); return
        }
        #expect(kinds.count == 1)

        // Line (0,5)-(10,5) reflected across the X axis → (0,-5)-(10,-5).
        guard case .line(let mirroredLine)? = kinds[Self.lineID] else {
            Issue.record("line was not replaced with a line"); return
        }
        #expect(approxEqual(mirroredLine.start, Vector(0, -5)))
        #expect(approxEqual(mirroredLine.end, Vector(10, -5)))

        // The tool resets after the commit (ready for select-first again).
        #expect(tool.status == "Select objects to mirror first")
    }

    // MARK: - Orientation-reversing flips (from EntityTransform)

    @Test("polyline bulge SIGN flips under mirror")
    func polylineBulgeSignFlips() {
        var tool = MirrorTool()
        let ctx = context([polylineRecord()])

        _ = tool.handle(.click(Self.axisP1), context: ctx)
        let outcome = tool.handle(.click(Self.axisP2), context: ctx)
        guard let kinds = replacedKinds(outcome),
              case .polyline(let pl)? = kinds[Self.polylineID] else {
            Issue.record("polyline was not replaced with a polyline"); return
        }
        // Bulge sign flips (the magnitude is preserved by EntityTransform).
        #expect(pl.vertices.first?.bulge == -Self.polylineBulge)
    }

    @Test("arc reversed flag flips under mirror")
    func arcReversedFlips() {
        var tool = MirrorTool()
        let ctx = context([arcRecord()])

        _ = tool.handle(.click(Self.axisP1), context: ctx)
        let outcome = tool.handle(.click(Self.axisP2), context: ctx)
        guard let kinds = replacedKinds(outcome),
              case .arc(let arc)? = kinds[Self.arcID] else {
            Issue.record("arc was not replaced with an arc"); return
        }
        // The source arc is reversed:false → mirror flips it to true.
        #expect(arc.reversed == true)
        // Center reflects across the X axis (sanity), radius unchanged.
        #expect(approxEqual(arc.center, Vector(5, -5)))
        #expect(abs(arc.radius - 2) < 1e-9)
    }

    // MARK: - Live preview

    @Test("preview is present + reflected after the first axis point and a move")
    func previewPresentAfterMove() {
        var tool = MirrorTool()
        let ctx = context([lineRecord()])

        // No preview before the first axis point.
        #expect(tool.preview.isEmpty)

        _ = tool.handle(.click(Self.axisP1), context: ctx)
        // A move along the X axis drives the rubber-band.
        let moved = tool.handle(.move(Self.axisP2), context: ctx)
        #expect(moved == .preview)
        #expect(!tool.preview.isEmpty)

        // The previewed line is reflected across the X axis: (0,-5)-(10,-5).
        let pts = tool.preview.flatMap { $0.points }
        #expect(pts.contains { approxEqual($0, Vector(0, -5)) })
        #expect(pts.contains { approxEqual($0, Vector(10, -5)) })
    }

    // MARK: - Empty-selection no-op

    @Test("empty selection: every input is a no-op (no preview, no commit)")
    func emptySelectionNoOp() {
        var tool = MirrorTool()
        let ctx = ToolContext.empty

        #expect(tool.handle(.click(Self.axisP1), context: ctx) == .none)
        // Still waiting for the first axis point (selection never captured).
        #expect(tool.status == "Select objects to mirror first")
        #expect(tool.handle(.move(Self.axisP2), context: ctx) == .none)
        #expect(tool.preview.isEmpty)
        #expect(tool.handle(.click(Self.axisP2), context: ctx) == .none)
    }

    // MARK: - Degenerate axis ignored

    @Test("degenerate axis (p2 ≈ p1) is ignored — no commit")
    func degenerateAxisIgnored() {
        var tool = MirrorTool()
        let ctx = context([lineRecord()])

        _ = tool.handle(.click(Self.axisP1), context: ctx)
        // Second click coincides with the first → degenerate axis, ignored.
        let outcome = tool.handle(.click(Self.axisP1), context: ctx)
        #expect(outcome == .none)
        // Still in pickingAxis2 awaiting a valid second point.
        #expect(tool.status == "Specify second point of mirror line")
    }

    // MARK: - Cancel / backspace resets

    @Test("cancel resets to the initial state and reports .finished")
    func cancelResets() {
        var tool = MirrorTool()
        let ctx = context([lineRecord()])

        _ = tool.handle(.click(Self.axisP1), context: ctx)
        #expect(tool.status == "Specify second point of mirror line")

        #expect(tool.handle(.cancel, context: ctx) == .finished)
        // Reset: selection dropped, back to picking the first axis point.
        #expect(tool.status == "Select objects to mirror first")
        #expect(tool.preview.isEmpty)
    }

    @Test("backspace steps back from axis-2 to axis-1 (selection retained)")
    func backspaceStepsBack() {
        var tool = MirrorTool()
        let ctx = context([lineRecord()])

        _ = tool.handle(.click(Self.axisP1), context: ctx)
        #expect(tool.status == "Specify second point of mirror line")

        #expect(tool.handle(.backspace, context: ctx) == .preview)
        // Back to picking the first axis point, but the selection is retained, so
        // the prompt is the base hint (not the select-first hint).
        #expect(tool.status == "Specify first point of mirror line")
    }

    // MARK: - Mirror-COPY (W1-1C: keepOriginal == true → .add, originals kept)

    @Test("keepOriginal=true commits ONLY .add records (placeholder id, line reflected)")
    func keepCopyEmitsOnlyAddReflectedLine() {
        var tool = MirrorTool()
        tool.keepOriginal = true
        let ctx = context([lineRecord()])

        let first = tool.handle(.click(Self.axisP1), context: ctx)
        #expect(first == .none)   // first click only fixes the first axis point

        let outcome = tool.handle(.click(Self.axisP2), context: ctx)
        guard let added = addedRecords(outcome) else {
            Issue.record("expected a .commit of only .add edits"); return
        }
        #expect(added.count == 1)
        // New geometry carries the placeholder id — the app mints a real id on add.
        #expect(added.first?.id == .placeholder)

        // Line (0,5)-(10,5) reflected across the X axis → (0,-5)-(10,-5).
        guard case .line(let mirroredLine)? = added.first?.kind else {
            Issue.record("added record was not a line"); return
        }
        #expect(approxEqual(mirroredLine.start, Vector(0, -5)))
        #expect(approxEqual(mirroredLine.end, Vector(10, -5)))

        // The tool resets after the commit (ready for select-first again).
        #expect(tool.status == "Select objects to mirror first")
    }

    @Test("keepOriginal=true copies layer/pen/flags/space/layoutName onto the .add record")
    func keepCopyPreservesAllAttributes() {
        var tool = MirrorTool()
        tool.keepOriginal = true
        let source = decoratedLineRecord()
        let ctx = context([source])

        _ = tool.handle(.click(Self.axisP1), context: ctx)
        let outcome = tool.handle(.click(Self.axisP2), context: ctx)
        guard let added = addedRecords(outcome), let copy = added.first else {
            Issue.record("expected a .commit of only .add edits"); return
        }
        // id is the placeholder (the app mints a fresh id); EVERY other attribute is
        // copied verbatim from the source — only the geometry is reflected.
        #expect(copy.id == .placeholder)
        #expect(copy.id != source.id)
        #expect(copy.layer == source.layer)
        #expect(copy.pen == source.pen)
        #expect(copy.flags == source.flags)
        #expect(copy.space == source.space)
        #expect(copy.layoutName == source.layoutName)
    }

    @Test("keepOriginal=true: polyline bulge SIGN flips on the .add copy (same transform as .replace)")
    func keepCopyPolylineBulgeSignFlips() {
        var tool = MirrorTool()
        tool.keepOriginal = true
        let ctx = context([polylineRecord()])

        _ = tool.handle(.click(Self.axisP1), context: ctx)
        let outcome = tool.handle(.click(Self.axisP2), context: ctx)
        guard let added = addedRecords(outcome),
              case .polyline(let pl)? = added.first?.kind else {
            Issue.record("added record was not a polyline"); return
        }
        #expect(added.first?.id == .placeholder)
        // Bulge sign flips (magnitude preserved) — the orientation-reversing
        // transform is identical to the proven mirror-in-place `.replace` path.
        #expect(pl.vertices.first?.bulge == -Self.polylineBulge)
    }

    @Test("keepOriginal=true: arc reversed flag flips on the .add copy (same transform as .replace)")
    func keepCopyArcReversedFlips() {
        var tool = MirrorTool()
        tool.keepOriginal = true
        let ctx = context([arcRecord()])

        _ = tool.handle(.click(Self.axisP1), context: ctx)
        let outcome = tool.handle(.click(Self.axisP2), context: ctx)
        guard let added = addedRecords(outcome),
              case .arc(let arc)? = added.first?.kind else {
            Issue.record("added record was not an arc"); return
        }
        #expect(added.first?.id == .placeholder)
        // The source arc is reversed:false → mirror flips it to true (same flip the
        // `.replace` path proves), and the center reflects across the X axis.
        #expect(arc.reversed == true)
        #expect(approxEqual(arc.center, Vector(5, -5)))
        #expect(abs(arc.radius - 2) < 1e-9)
    }

    @Test("default (keepOriginal=false) still emits .replace, never .add (regression guard)")
    func defaultEmitsReplaceNotAdd() {
        var tool = MirrorTool()
        // keepOriginal defaults to false — deliberately do NOT set it.
        let ctx = context([lineRecord()])

        _ = tool.handle(.click(Self.axisP1), context: ctx)
        let outcome = tool.handle(.click(Self.axisP2), context: ctx)

        // Commit is ONLY `.replace` edits (helper is nil unless every edit replaces).
        #expect(replacedKinds(outcome) != nil)
        // And definitively contains no `.add` edits.
        #expect(addedRecords(outcome) == nil)
    }

    // MARK: - Typed coordinate (.value) parity with .click

    @Test(".value(p) is treated exactly like .click(p): typed axis points mirror the same")
    func typedValueMatchesClick() {
        var typed = MirrorTool()
        let ctxA = context([lineRecord()])
        let typedFirst = typed.handle(.value(Self.axisP1), context: ctxA)
        #expect(typedFirst == .none)   // a typed first axis point only fixes p1
        #expect(typed.status == "Specify second point of mirror line")
        let typedOutcome = typed.handle(.value(Self.axisP2), context: ctxA)

        var clicked = MirrorTool()
        let ctxB = context([lineRecord()])
        _ = clicked.handle(.click(Self.axisP1), context: ctxB)
        let clickedOutcome = clicked.handle(.click(Self.axisP2), context: ctxB)

        #expect(typedOutcome == clickedOutcome)
        #expect(replacedKinds(typedOutcome)?.count == 1)
    }

    @Test(".value with an empty selection is still a no-op (nothing to mirror)")
    func typedValueEmptySelectionNoOp() {
        var tool = MirrorTool()
        let outcome = tool.handle(.value(Vector(5, 5)), context: .empty)
        #expect(outcome == .none)
        #expect(tool.status == "Select objects to mirror first")
    }
}
