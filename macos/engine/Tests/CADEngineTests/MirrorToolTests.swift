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
}
