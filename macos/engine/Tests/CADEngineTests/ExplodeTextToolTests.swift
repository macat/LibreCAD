//
//  ExplodeTextToolTests.swift
//  CADEngineTests
//
//  Drives the EXPLODE-TEXT modify tool PURELY (no GUI): feeds `ToolInput` events +
//  a read-only `ToolContext` carrying a known text selection and asserts the
//  explode-text contract — a `.text`/`.mtext` is REMOVED and its RENDERED glyph
//  geometry is ADDED as free `.polyline` entities. Covers:
//    - empty / non-text selection → no-op;
//    - a native-outline `.text` ("AB") → N closed `.polyline`s whose combined
//      geometry matches the text's own resolved glyph outlines (same resolve path);
//    - an `.mtext` likewise explodes to polylines;
//    - the added polylines inherit the text's layer / pen / flags and the original
//      is removed;
//    - the stroke-vs-fill flattening of the static `explodePolylines` helper
//      (stroke fonts → OPEN polylines; outline fonts → CLOSED contours).
//
//  Glyph geometry is obtained the SAME way the renderer does — the tool resolves
//  through `CADFonts.provider` (the shared font registry), so these tests exercise
//  the real Core Text outline path (Helvetica Neue resolves headless, per the
//  existing TextSystem tests).
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("ExplodeTextTool modify (text → polyline geometry)")
struct ExplodeTextToolTests {

    // MARK: - Helpers

    private func context(_ records: [EntityRecord]) -> ToolContext {
        ToolContext(
            selected: records,
            entity: { id in records.first { $0.id == id } },
            gridSpacing: nil
        )
    }

    /// Splits a `.commit` into its single `.remove` id and the ordered `.add`
    /// records (fails — returns nil — if the shape isn't remove-then-adds).
    private func removeThenAdds(_ outcome: ToolOutcome) -> (removed: EntityID, added: [EntityRecord])? {
        guard case .commit(let edits) = outcome, let first = edits.first,
              case .remove(let id) = first else { return nil }
        var added: [EntityRecord] = []
        for edit in edits.dropFirst() {
            guard case .add(let r) = edit else { return nil }
            added.append(r)
        }
        return (id, added)
    }

    /// All vertices of all `.polyline` records, flattened (for combined-geometry
    /// comparison against the text's own resolve).
    private func allPolylinePoints(_ records: [EntityRecord]) -> [Vector] {
        records.flatMap { r -> [Vector] in
            if case .polyline(let d) = r.kind { return d.vertices.map(\.point) }
            return []
        }
    }

    /// All points of a resolved geometry's polylines + fills (the reference set the
    /// explode should reproduce).
    private func allResolvedPoints(_ geo: ResolvedGeometry) -> [Vector] {
        var pts: [Vector] = []
        for line in geo.polylines where line.points.count >= 2 { pts.append(contentsOf: line.points) }
        for fill in geo.fills { for loop in fill.loops where loop.count >= 3 { pts.append(contentsOf: loop) } }
        return pts
    }

    private func textRecord(
        _ string: String,
        id: EntityID = EntityID(7),
        styleName: String? = nil
    ) -> EntityRecord {
        EntityRecord(
            id: id,
            layer: LayerID("notes"),
            pen: Pen(lineColor: .explicit(RGBAColor(0, 0, 1, 1))),
            flags: [.visible, .selected],
            kind: .text(TextData(position: Vector(0, 0), height: 10, text: string, styleName: styleName))
        )
    }

    // MARK: - Basics

    @Test("title is Explode Text")
    func title() {
        #expect(ExplodeTextTool().title == "Explode Text")
    }

    @Test("status nudges to select text when nothing explodable is selected")
    func statusEmpty() {
        #expect(ExplodeTextTool().status == "Select text to explode into geometry first")
    }

    @Test("a fire with an empty selection is a no-op")
    func emptyNoop() {
        var tool = ExplodeTextTool()
        #expect(tool.handle(.commit, context: .empty) == .none)
    }

    @Test("a non-text selection (a line) is a no-op")
    func nonTextNoop() {
        let line = EntityRecord(
            id: EntityID(1), layer: .zero, pen: .byLayer, flags: [.visible, .selected],
            kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 1)))
        )
        var tool = ExplodeTextTool()
        #expect(tool.handle(.commit, context: context([line])) == .none)
    }

    @Test("an empty-string text is not explodable (no-op)")
    func emptyStringNoop() {
        var tool = ExplodeTextTool()
        #expect(tool.handle(.commit, context: context([textRecord("")])) == .none)
    }

    // MARK: - Native outline text → closed polylines

    @Test("a native '.text' explodes into closed polylines; the text is removed")
    func explodeNativeText() {
        let text = textRecord("AB", id: EntityID(42))
        var tool = ExplodeTextTool()
        let outcome = tool.handle(.commit, context: context([text]))

        let split = removeThenAdds(outcome)
        #expect(split != nil)
        guard let (removed, added) = split else { return }

        // The original text is removed.
        #expect(removed == text.id)
        // It explodes into at least one polyline (A + B glyph outlines).
        #expect(!added.isEmpty)
        // Every added entity is a CLOSED polyline (outline-font contours are closed).
        for r in added {
            guard case .polyline(let d) = r.kind else {
                Issue.record("added entity is not a polyline: \(r.kind)")
                continue
            }
            #expect(d.closed)
            #expect(d.vertices.count >= 3)   // a real outline loop, not degenerate
        }
    }

    @Test("exploded polylines inherit the text's layer / pen / flags")
    func inheritsAttributes() {
        let text = textRecord("X", id: EntityID(9))
        var tool = ExplodeTextTool()
        guard let (_, added) = removeThenAdds(tool.handle(.commit, context: context([text]))) else {
            Issue.record("expected a remove-then-adds commit")
            return
        }
        #expect(!added.isEmpty)
        for r in added {
            #expect(r.layer == text.layer)
            #expect(r.pen == text.pen)
            #expect(r.flags == text.flags)
            #expect(r.id == .placeholder)    // app re-mints
        }
    }

    @Test("the combined exploded geometry matches the text's own resolved glyph outlines")
    func combinedGeometryMatchesResolve() {
        let text = textRecord("AB", id: EntityID(11))
        var tool = ExplodeTextTool()
        guard let (_, added) = removeThenAdds(tool.handle(.commit, context: context([text]))) else {
            Issue.record("expected a remove-then-adds commit")
            return
        }

        // The reference: the text resolved through the SAME font registry the tool
        // uses. The explode's points must equal the resolve's points (same path).
        let ctx = ExplodeTextTool.resolveContext()
        let resolved = text.kind.resolve(pen: .toolPreview, ctx: ctx)
        let refPoints = allResolvedPoints(resolved)
        let gotPoints = allPolylinePoints(added)

        #expect(!refPoints.isEmpty)
        #expect(gotPoints.count == refPoints.count)
        // Point-for-point identity (the explode flattens the resolve's loops in order).
        if gotPoints.count == refPoints.count {
            for (a, b) in zip(gotPoints, refPoints) {
                #expect(a.distance(to: b) < 1e-9)
            }
        }
    }

    // MARK: - MText

    @Test("an '.mtext' explodes into polylines; the mtext is removed")
    func explodeMText() {
        let mtext = EntityRecord(
            id: EntityID(55),
            layer: LayerID("notes"),
            pen: .byLayer,
            flags: [.visible, .selected],
            kind: .mtext(MTextParser.makeData(coded: "Hi", position: Vector(0, 0), height: 8))
        )
        var tool = ExplodeTextTool()
        guard let (removed, added) = removeThenAdds(tool.handle(.commit, context: context([mtext]))) else {
            Issue.record("expected a remove-then-adds commit for mtext")
            return
        }
        #expect(removed == mtext.id)
        #expect(!added.isEmpty)
        for r in added {
            guard case .polyline = r.kind else {
                Issue.record("mtext explode produced a non-polyline: \(r.kind)")
                continue
            }
        }
    }

    // MARK: - Multiple selections

    @Test("two selected texts both explode in one commit (two removes)")
    func multipleTexts() {
        let t1 = textRecord("A", id: EntityID(1))
        let t2 = textRecord("B", id: EntityID(2))
        var tool = ExplodeTextTool()
        let outcome = tool.handle(.commit, context: context([t1, t2]))
        guard case .commit(let edits) = outcome else {
            Issue.record("expected a commit")
            return
        }
        let removes = edits.compactMap { edit -> EntityID? in
            if case .remove(let id) = edit { return id }
            return nil
        }
        #expect(Set(removes) == Set([t1.id, t2.id]))
        // And at least one polyline add per text.
        let adds = edits.filter { if case .add = $0 { return true }; return false }
        #expect(adds.count >= 2)
    }

    // MARK: - Lifecycle

    @Test("cancel discards the captured selection and finishes")
    func cancelResets() {
        let text = textRecord("A")
        var tool = ExplodeTextTool()
        // Capture by handling a move first (captures the selection).
        _ = tool.handle(.move(Vector(0, 0)), context: context([text]))
        #expect(tool.handle(.cancel, context: .empty) == .finished)
        // After cancel, a fire with no selection is a no-op.
        #expect(tool.handle(.commit, context: .empty) == .none)
    }

    @Test("a typed coordinate is ignored (selection-based tool)")
    func valueIgnored() {
        let text = textRecord("A")
        var tool = ExplodeTextTool()
        #expect(tool.handle(.value(Vector(5, 5)), context: context([text])) == .none)
    }

    @Test("preview reflects the resolved contours when text is selected")
    func previewPopulated() {
        let text = textRecord("A")
        var tool = ExplodeTextTool()
        _ = tool.handle(.move(Vector(0, 0)), context: context([text]))
        #expect(!tool.preview.isEmpty)
    }

    // MARK: - Static helper: stroke vs fill flattening

    @Test("explodePolylines flattens native fills into closed contours")
    func staticHelperFills() {
        let text = textRecord("O", id: EntityID(3))   // 'O' has a counter (a hole)
        let contours = ExplodeTextTool.explodePolylines(text)
        #expect(!contours.isEmpty)
        // 'O' is a native outline glyph → every contour is closed.
        for c in contours {
            #expect(c.closed)
            #expect(c.points.count >= 3)
        }
        // The counter means at least two contours (outer ring + hole).
        #expect(contours.count >= 2)
    }

    @Test("explodePolylines of a non-text record is empty")
    func staticHelperNonText() {
        let circle = EntityRecord(
            id: EntityID(4), kind: .circle(CircleData(center: Vector(0, 0), radius: 5))
        )
        #expect(ExplodeTextTool.explodePolylines(circle).isEmpty)
    }

    // MARK: - Stroke font path (open polylines)

    @Test("a stroke-font text resolves to OPEN stroke polylines (flattening preserved)")
    func strokeFontOpenPolylines() throws {
        // Build a stroke '.lff' provider over the shipped standard.lff and resolve a
        // text whose style maps to it — the resolve yields OPEN stroke polylines.
        // (The tool itself has no style table, so this exercises the flattening of
        // the stroke path directly via the same resolve the tool calls.)
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()   // CADEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // engine
            .deletingLastPathComponent()   // macos
            .deletingLastPathComponent()   // <repo>
        let url = repoRoot.appendingPathComponent("librecad/support/fonts/standard.lff")
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "standard.lff fixture not found at \(url.path)")
        let provider = StrokeFontProvider()
        provider.registerFont(at: url, name: "standard")
        var styles = TextStyleTable()
        styles.upsert(TextStyle(name: "S", primaryFont: .stroke(lff: "standard")))
        let table = styles
        let ctx = ResolveContext(tessellationTolerance: 0.01, fontProvider: provider,
                                 textStyleProvider: { table.style(named: $0) })

        let d = TextData(position: Vector(0, 0), height: 10, text: "AB", styleName: "S")
        let geo = EntityKind.text(d).resolve(pen: .toolPreview, ctx: ctx)
        // Stroke fonts → open polylines, no fills.
        #expect(!geo.polylines.isEmpty)
        #expect(geo.fills.isEmpty)
        for line in geo.polylines { #expect(!line.closed) }
    }
}
