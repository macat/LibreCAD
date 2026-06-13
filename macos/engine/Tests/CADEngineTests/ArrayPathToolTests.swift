//
//  ArrayPathToolTests.swift
//  CADEngineTests
//
//  Drives the ARRAY-ALONG-PATH modify tool PURELY (no GUI): feeds `ToolInput`
//  events + a read-only `ToolContext` carrying a known selection (and, where the
//  path is picked by click, a boundary scan) and asserts the path-array contract:
//    - `N` copies are distributed at EQUAL arc-length along a picked path
//      (line / arc / polyline);
//    - on a 10-unit line the copies land at the expected even stations;
//    - on an arc the copies sit ON the arc (correct radius from the center);
//    - `alignToTangent` rotates each copy to the local path direction;
//    - axis-aligned mode keeps the copies' orientation;
//    - the path can be supplied in the config OR picked by the first click;
//    - attrs are preserved, the placeholder id is used, `.selected` is stripped,
//      originals are never modified (only `.add`), and cancel/reset works.
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("ArrayPathTool modify (array along a path)")
struct ArrayPathToolTests {

    // MARK: - Fixtures

    /// A small selected MARKER (a 1×1 line) with distinctive attrs so the anchor
    /// (its bbox center) is well-defined and attr-preservation is observable. Its
    /// anchor (bbox center) sits at (0.5, 0.5).
    private static let selectedMarker = EntityRecord(
        id: EntityID(201),
        layer: LayerID("items"),
        pen: Pen(lineColor: .explicit(RGBAColor(0, 0, 1, 1))),
        flags: [.visible, .selected],
        kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 1)))
    )

    /// A horizontal arrow-like marker (start at its anchor) for tangent-rotation
    /// checks: a line from (0,0) to (1,0). Its bbox center (anchor) is (0.5, 0).
    private static let selectedArrow = EntityRecord(
        id: EntityID(202),
        layer: LayerID("items"),
        pen: .byLayer,
        flags: [.visible, .selected],
        kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0)))
    )

    /// A horizontal 10-unit path line from (0,0) to (10,0).
    private static let pathLine = EntityRecord(
        id: EntityID(1),
        flags: [.visible],
        kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0)))
    )

    /// A quarter arc, radius 4, centered at the origin, sweeping CCW from 0 to 90°.
    private static let pathArc = EntityRecord(
        id: EntityID(2),
        flags: [.visible],
        kind: .arc(ArcData(center: Vector(0, 0), radius: 4,
                           startAngle: 0, endAngle: Double.pi / 2, reversed: false))
    )

    /// Context with only a selection (path supplied via config).
    private func selectionContext(_ sel: [EntityRecord]) -> ToolContext {
        ToolContext(
            selected: sel,
            entity: { id in sel.first { $0.id == id } },
            gridSpacing: nil
        )
    }

    /// Context whose `nearbyEntities`/`allEntities` scan `records`, so a click can
    /// pick the path. Mirrors the app's `makeToolContext` exact-distance scan.
    private func pickContext(selected sel: [EntityRecord], world records: [EntityRecord]) -> ToolContext {
        ToolContext(
            selected: sel,
            entity: { id in (sel + records).first { $0.id == id } },
            gridSpacing: nil,
            nearbyEntities: { point, tolerance in
                guard point.valid else { return [] }
                let tol = Swift.max(tolerance, 0)
                return records.filter { r in
                    guard r.flags.contains(.visible) else { return false }
                    return HitTesting.worldDistance(from: point, to: r) <= tol
                }
            },
            allEntities: { records }
        )
    }

    /// Pulls the ordered `.add` records out of a `.commit` (nil if not pure-add).
    private func addedRecords(_ outcome: ToolOutcome) -> [EntityRecord]? {
        guard case .commit(let edits) = outcome else { return nil }
        var records: [EntityRecord] = []
        for edit in edits {
            guard case .add(let r) = edit else { return nil }
            records.append(r)
        }
        return records
    }

    private func approxEqual(_ a: Vector, _ b: Vector, eps: Double = 1e-6) -> Bool {
        a.distance(to: b) < eps
    }

    /// The anchor (start, here == anchor offset applied) of a line copy.
    private func lineOf(_ r: EntityRecord) -> LineData? {
        guard case .line(let l) = r.kind else { return nil }
        return l
    }

    // MARK: - Basics

    @Test("title is Array Along Path")
    func title() {
        #expect(ArrayPathTool().title == "Array Along Path")
    }

    @Test("status nudges to select first when nothing is selected")
    func statusEmptySelection() {
        #expect(ArrayPathTool().status == "Select objects to array along a path first")
    }

    @Test("a fire with an empty selection is a no-op")
    func emptySelectionNoop() {
        var tool = ArrayPathTool(config: .init(count: 3, alignToTangent: false, path: Self.pathLine))
        #expect(tool.handle(.commit, context: .empty) == .finished)
    }

    // MARK: - Count

    @Test("N copies are distributed along the path (one per station)")
    func count() {
        var tool = ArrayPathTool(config: .init(count: 6, alignToTangent: false, path: Self.pathLine))
        let records = addedRecords(tool.handle(.commit, context: selectionContext([Self.selectedMarker])))
        #expect(records?.count == 6)   // path-array commits all `count` stations
    }

    // MARK: - Equal arc-length on a 10-unit line

    @Test("on a 10-unit line, N copies land at equal arc-length stations (endpoints inclusive)")
    func equalSpacingOnLine() {
        // 5 copies over a 10-unit open path → stations at 0, 2.5, 5, 7.5, 10.
        let count = 5
        var tool = ArrayPathTool(config: .init(count: count, alignToTangent: false, path: Self.pathLine))
        let records = addedRecords(tool.handle(.commit, context: selectionContext([Self.selectedMarker])))
        #expect(records?.count == count)

        // The marker's anchor is (0.5, 0.5); each station moves it onto the path
        // (y = 0). The copy's start was (0,0); after translating anchor→station the
        // start lands at station − (anchor − start) = station − (0.5, 0.5).
        let anchor = Vector(0.5, 0.5)
        let stationStep = 10.0 / Double(count - 1)
        for (i, r) in (records ?? []).enumerated() {
            guard let l = lineOf(r) else { Issue.record("expected a line copy"); return }
            let station = Vector(stationStep * Double(i), 0)
            // Anchor (start of marker is (0,0), so start = station − anchorOffset).
            let expectedStart = Vector(0, 0) + (station - anchor)
            #expect(approxEqual(l.start, expectedStart))
        }
    }

    @Test("the first and last copies sit at the path endpoints (anchor on the endpoint)")
    func endpointsInclusive() {
        let count = 4
        var tool = ArrayPathTool(config: .init(count: count, alignToTangent: false, path: Self.pathLine))
        let records = addedRecords(tool.handle(.commit, context: selectionContext([Self.selectedMarker])))
        #expect(records?.count == count)
        let anchor = Vector(0.5, 0.5)
        // First copy's anchor at (0,0); last copy's anchor at (10,0).
        guard let first = lineOf(records![0]), let last = lineOf(records![count - 1]) else {
            Issue.record("expected line copies"); return
        }
        #expect(approxEqual(first.start + anchor, Vector(0, 0)))    // anchor == station
        #expect(approxEqual(last.start + anchor, Vector(10, 0)))
    }

    // MARK: - On an arc

    @Test("copies along an arc sit ON the arc (anchor at the arc radius from the center)")
    func copiesSitOnArc() {
        let count = 5
        var tool = ArrayPathTool(config: .init(count: count, alignToTangent: false, path: Self.pathArc))
        let records = addedRecords(tool.handle(.commit, context: selectionContext([Self.selectedMarker])))
        #expect(records?.count == count)

        // The anchor of each copy must land on the arc (distance 4 from center).
        // Reconstruct the anchor position: copy.start + anchorOffset (the marker's
        // anchor is (0.5,0.5), its start is (0,0), so anchorOffset == (0.5,0.5)).
        let anchorOffset = Vector(0.5, 0.5)
        let center = Vector(0, 0)
        for r in records ?? [] {
            guard let l = lineOf(r) else { Issue.record("expected a line copy"); return }
            let anchorPos = l.start + anchorOffset
            // Tessellation introduces a small chord error; allow a generous eps.
            #expect(abs(anchorPos.distance(to: center) - 4) < 0.05)
        }
    }

    // MARK: - Align to tangent

    @Test("align-to-tangent rotates each copy to the local path direction (line: all horizontal)")
    func alignToTangentOnLine() {
        // On a horizontal line every tangent is 0° — the arrow stays horizontal,
        // but it is REBUILT through the rotate-about-station path. The arrow points
        // +X originally; after a 0° rotate it still points +X.
        let count = 3
        var tool = ArrayPathTool(config: .init(count: count, alignToTangent: true, path: Self.pathLine))
        let records = addedRecords(tool.handle(.commit, context: selectionContext([Self.selectedArrow])))
        #expect(records?.count == count)
        for r in records ?? [] {
            guard let l = lineOf(r) else { Issue.record("expected a line copy"); return }
            // Arrow direction stays +X (tangent 0 on a horizontal line).
            let dir = l.end - l.start
            #expect(abs(dir.angle) < 1e-6 || abs(dir.angle - 2 * Double.pi) < 1e-6)
            #expect(approxEqual(dir, Vector(1, 0)))
        }
    }

    @Test("align-to-tangent on an arc points each copy along the local tangent (≈ angle + 90°)")
    func alignToTangentOnArc() {
        // On a CCW circle the tangent at parameter angle φ is φ + 90°. With copies
        // distributed by arc length on a quarter arc (0..90°), the first copy is at
        // φ ≈ 0 (tangent ≈ 90°) and the last at φ ≈ 90° (tangent ≈ 180°).
        let count = 4
        var tool = ArrayPathTool(config: .init(count: count, alignToTangent: true, path: Self.pathArc))
        let records = addedRecords(tool.handle(.commit, context: selectionContext([Self.selectedArrow])))
        #expect(records?.count == count)

        guard let first = lineOf(records![0]), let last = lineOf(records![count - 1]) else {
            Issue.record("expected line copies"); return
        }
        let firstDir = (first.end - first.start).angle
        let lastDir = (last.end - last.start).angle
        // First copy tangent ≈ 90° (π/2); last ≈ 180° (π). The tangent is the
        // CHORD direction of the tessellated segment the station lands on, so it
        // differs from the analytic curve tangent by up to ~half the per-segment
        // sweep — allow that chord slack (clearly distinct from the 0° an
        // axis-aligned copy would have).
        #expect(abs(firstDir - Double.pi / 2) < 0.2)
        #expect(abs(lastDir - Double.pi) < 0.2)
    }

    @Test("axis-aligned mode keeps the copies' original orientation")
    func axisAlignedKeepsOrientation() {
        let count = 4
        var tool = ArrayPathTool(config: .init(count: count, alignToTangent: false, path: Self.pathArc))
        let records = addedRecords(tool.handle(.commit, context: selectionContext([Self.selectedArrow])))
        #expect(records?.count == count)
        for r in records ?? [] {
            guard let l = lineOf(r) else { Issue.record("expected a line copy"); return }
            // The arrow stays pointing +X regardless of where on the arc it sits.
            #expect(approxEqual(l.end - l.start, Vector(1, 0)))
        }
    }

    // MARK: - Closed path

    @Test("a closed polyline distributes copies without doubling the first station")
    func closedPathNoDoubledFirst() {
        // A closed unit square path (perimeter 4). 4 copies → stations every 1.0,
        // and the last station does NOT coincide with the first.
        let square = EntityRecord(
            id: EntityID(3),
            flags: [.visible],
            kind: .polyline(PolylineData(vertices: [
                PolylineVertex(point: Vector(0, 0)),
                PolylineVertex(point: Vector(1, 0)),
                PolylineVertex(point: Vector(1, 1)),
                PolylineVertex(point: Vector(0, 1)),
            ], closed: true))
        )
        let count = 4
        var tool = ArrayPathTool(config: .init(count: count, alignToTangent: false, path: square))
        let records = addedRecords(tool.handle(.commit, context: selectionContext([Self.selectedMarker])))
        #expect(records?.count == count)

        // Anchors should be 4 distinct stations along the perimeter (not 3 + a
        // duplicate). Reconstruct anchors and check they're all distinct.
        let anchorOffset = Vector(0.5, 0.5)
        var anchors: [Vector] = []
        for r in records ?? [] {
            guard let l = lineOf(r) else { Issue.record("expected a line copy"); return }
            anchors.append(l.start + anchorOffset)
        }
        // No two anchors coincide.
        for i in 0..<anchors.count {
            for j in (i + 1)..<anchors.count {
                #expect(anchors[i].distance(to: anchors[j]) > 1e-6)
            }
        }
    }

    // MARK: - Pick the path by click

    @Test("the path can be picked by the first click when not in the config")
    func picksPathOnClick() {
        var tool = ArrayPathTool(config: .init(count: 3, alignToTangent: false, path: nil))
        let ctx = pickContext(selected: [Self.selectedMarker], world: [Self.pathLine])
        // Before a path is picked, the status asks for it (after capturing).
        _ = tool.handle(.move(Vector(5, 0)), context: ctx)
        #expect(tool.status == "Pick the path to array along")
        // A commit with no path yet is a no-op (still waiting).
        #expect(tool.handle(.commit, context: ctx) == .none)
        // A click on the path fires.
        let records = addedRecords(tool.handle(.click(Vector(5, 0)), context: ctx))
        #expect(records?.count == 3)
    }

    @Test("a click in empty space (no path under the pick) keeps waiting")
    func clickMissKeepsWaiting() {
        var tool = ArrayPathTool(config: .init(count: 3, alignToTangent: false, path: nil))
        let ctx = pickContext(selected: [Self.selectedMarker], world: [Self.pathLine])
        // Click far from the path → nothing pickable → no-op, still picking.
        #expect(tool.handle(.click(Vector(100, 100)), context: ctx) == .none)
        #expect(tool.status == "Pick the path to array along")
    }

    // MARK: - Attrs / placeholder / selected-stripped / originals untouched

    @Test("copies preserve layer/pen, use the placeholder id, and strip .selected")
    func attrsPreserved() {
        var tool = ArrayPathTool(config: .init(count: 2, alignToTangent: false, path: Self.pathLine))
        let records = addedRecords(tool.handle(.commit, context: selectionContext([Self.selectedMarker])))
        #expect(records?.count == 2)
        for copy in records ?? [] {
            #expect(copy.id == .placeholder)
            #expect(copy.layer == Self.selectedMarker.layer)
            #expect(copy.pen == Self.selectedMarker.pen)
            #expect(!copy.flags.contains(.selected))   // .selected stripped on .add
            #expect(copy.flags.contains(.visible))
        }
    }

    @Test("array only emits .add edits — never .replace/.remove")
    func originalsUntouched() {
        var tool = ArrayPathTool(config: .init(count: 4, alignToTangent: true, path: Self.pathLine))
        guard case .commit(let edits) = tool.handle(.commit, context: selectionContext([Self.selectedMarker])) else {
            Issue.record("expected a commit"); return
        }
        for edit in edits {
            switch edit {
            case .add: break
            case .replace, .remove: Issue.record("Array-along-path must not modify originals: \(edit)")
            }
        }
    }

    // MARK: - Degenerate

    @Test("count ≤ 0 commits nothing")
    func degenerateCount() {
        var tool = ArrayPathTool(config: .init(count: 0, alignToTangent: false, path: Self.pathLine))
        #expect(tool.handle(.commit, context: selectionContext([Self.selectedMarker])) == .finished)
    }

    @Test("a zero-length path commits nothing")
    func zeroLengthPath() {
        let degenerate = EntityRecord(
            id: EntityID(9),
            flags: [.visible],
            kind: .line(LineData(start: Vector(3, 3), end: Vector(3, 3)))
        )
        var tool = ArrayPathTool(config: .init(count: 3, alignToTangent: false, path: degenerate))
        #expect(tool.handle(.commit, context: selectionContext([Self.selectedMarker])) == .finished)
    }

    // MARK: - Cancel + preview

    @Test("cancel discards the captured selection and finishes")
    func cancelResets() {
        var tool = ArrayPathTool(config: .init(count: 3, alignToTangent: false, path: Self.pathLine))
        let ctx = selectionContext([Self.selectedMarker])
        _ = tool.handle(.move(Vector(1, 1)), context: ctx)   // captures selection
        #expect(tool.status == "Press Return to array along the path")
        #expect(tool.handle(.cancel, context: ctx) == .finished)
        #expect(tool.status == "Select objects to array along a path first")
    }

    @Test("preview shows the copies once a selection is captured and a path is in config")
    func previewShowsCopies() {
        var tool = ArrayPathTool(config: .init(count: 4, alignToTangent: false, path: Self.pathLine))
        let ctx = selectionContext([Self.selectedMarker])
        _ = tool.handle(.move(Vector(0, 0)), context: ctx)   // captures
        // 4 copies × 1 polyline each (a line marker resolves to one polyline).
        #expect(tool.preview.count == 4)
        #expect(tool.preview.allSatisfy { $0.pen == .toolPreview })
    }
}
