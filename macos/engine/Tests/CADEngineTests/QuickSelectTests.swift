//
//  QuickSelectTests.swift
//  CADEngineTests
//
//  Exercises the pure `QuickSelect` predicate: a fixture drawing with mixed
//  kinds / layers / pen colors / widths is filtered through `QuickSelectFilter`,
//  and the returned id set is asserted to be EXACTLY the matching entities.
//  Covers each single criterion (kind, layer, color, line width), the AND of
//  several criteria, the hidden-entity inclusion toggle, the all-`nil` "match
//  all", the empty-`kinds` "match none", the convenience builders, the
//  `combine(mode:)` selection composition, and degenerate (empty) inputs.
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

@Suite("QuickSelect — filter → id set")
struct QuickSelectTests {

    // MARK: - Fixtures

    private static let red = RGBAColor(1, 0, 0)
    private static let blue = RGBAColor(0, 0, 1)

    private func rec(_ id: UInt64,
                     kind: EntityKind,
                     layer: String = "0",
                     color: PenColor = .byLayer,
                     width: PenLineWidth = .byLayer,
                     visible: Bool = true) -> EntityRecord {
        let flags: EntityFlags = visible ? [.visible] : []
        return EntityRecord(id: EntityID(id),
                            layer: LayerID(layer),
                            pen: Pen(lineColor: color, lineType: .byLayer, lineWidth: width),
                            flags: flags,
                            kind: kind)
    }

    private func line(_ id: UInt64, layer: String = "0",
                      color: PenColor = .byLayer,
                      width: PenLineWidth = .byLayer,
                      visible: Bool = true) -> EntityRecord {
        rec(id, kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0))),
            layer: layer, color: color, width: width, visible: visible)
    }

    private func circle(_ id: UInt64, layer: String = "0",
                        color: PenColor = .byLayer) -> EntityRecord {
        rec(id, kind: .circle(CircleData(center: Vector(0, 0), radius: 5)),
            layer: layer, color: color)
    }

    private func point(_ id: UInt64, layer: String = "0") -> EntityRecord {
        rec(id, kind: .point(PointData(position: Vector(0, 0))), layer: layer)
    }

    /// A mixed fixture: lines, circles, a point across layers + colors.
    private func fixture() -> [EntityRecord] {
        [
            line(1, layer: "walls", color: .explicit(Self.red), width: .millimeters(0.5)),
            line(2, layer: "walls", color: .explicit(Self.blue)),
            circle(3, layer: "walls", color: .explicit(Self.red)),
            circle(4, layer: "doors", color: .byLayer),
            point(5, layer: "doors"),
        ]
    }

    // MARK: - Single criterion

    @Test("by kind: only the circles")
    func byKind() {
        let ids = QuickSelect.matches(QuickSelectFilter(kinds: [.circle]),
                                      in: fixture())
        #expect(ids == [EntityID(3), EntityID(4)])
    }

    @Test("by multiple kinds: lines OR points")
    func byMultipleKinds() {
        let ids = QuickSelect.matches(QuickSelectFilter(kinds: [.line, .point]),
                                      in: fixture())
        #expect(ids == [EntityID(1), EntityID(2), EntityID(5)])
    }

    @Test("by layer: everything on 'walls'")
    func byLayer() {
        let ids = QuickSelect.matches(QuickSelectFilter(layer: "walls"),
                                      in: fixture())
        #expect(ids == [EntityID(1), EntityID(2), EntityID(3)])
    }

    @Test("by color: explicit red")
    func byColor() {
        let ids = QuickSelect.matches(QuickSelectFilter(color: .explicit(Self.red)),
                                      in: fixture())
        #expect(ids == [EntityID(1), EntityID(3)])
    }

    @Test("by color: the byLayer sentinel is matchable")
    func byColorByLayerSentinel() {
        let ids = QuickSelect.matches(QuickSelectFilter(color: .byLayer),
                                      in: fixture())
        #expect(ids == [EntityID(4), EntityID(5)])
    }

    @Test("by line width: explicit 0.5mm")
    func byLineWidth() {
        let ids = QuickSelect.matches(QuickSelectFilter(lineWidth: .millimeters(0.5)),
                                      in: fixture())
        #expect(ids == [EntityID(1)])
    }

    // MARK: - Conjunction (AND of criteria)

    @Test("kind AND layer AND color narrows to one")
    func conjunction() {
        let f = QuickSelectFilter(kinds: [.line], layer: "walls",
                                  color: .explicit(Self.red))
        let ids = QuickSelect.matches(f, in: fixture())
        #expect(ids == [EntityID(1)])   // line 2 is blue; circle 3 is not a line
    }

    @Test("a non-matching conjunction yields the empty set")
    func conjunctionNoMatch() {
        let f = QuickSelectFilter(kinds: [.point], layer: "walls")  // no points on walls
        #expect(QuickSelect.matches(f, in: fixture()).isEmpty)
    }

    // MARK: - Hidden entities

    @Test("hidden entities are excluded by default, included on request")
    func hiddenToggle() {
        let entities = [
            line(1, layer: "walls"),
            line(2, layer: "walls", visible: false),
        ]
        let visibleOnly = QuickSelect.matches(QuickSelectFilter(layer: "walls"),
                                              in: entities)
        #expect(visibleOnly == [EntityID(1)])

        let withHidden = QuickSelect.matches(
            QuickSelectFilter(layer: "walls", includeHidden: true), in: entities)
        #expect(withHidden == [EntityID(1), EntityID(2)])
    }

    // MARK: - Match-all / match-none

    @Test("an all-nil filter matches every visible entity")
    func matchAll() {
        let f = QuickSelectFilter()
        #expect(f.matchesAllProperties)
        let ids = QuickSelect.matches(f, in: fixture())
        #expect(ids == Set((1...5).map { EntityID($0) }))
    }

    @Test("an EMPTY kinds set matches nothing (distinct from nil)")
    func emptyKindsMatchesNone() {
        let f = QuickSelectFilter(kinds: [])
        #expect(!f.matchesAllProperties)
        #expect(QuickSelect.matches(f, in: fixture()).isEmpty)
    }

    @Test("an empty entity list yields the empty set")
    func emptyEntities() {
        #expect(QuickSelect.matches(QuickSelectFilter(), in: []).isEmpty)
    }

    // MARK: - Convenience builders

    @Test("convenience builders mirror the single-criterion filters")
    func convenienceBuilders() {
        let f = fixture()
        #expect(QuickSelect.ofKind(.circle, in: f) == [EntityID(3), EntityID(4)])
        #expect(QuickSelect.onLayer("doors", in: f) == [EntityID(4), EntityID(5)])
        #expect(QuickSelect.withColor(.explicit(Self.blue), in: f) == [EntityID(2)])
        #expect(QuickSelect.withLineWidth(.millimeters(0.5), in: f) == [EntityID(1)])
    }

    // MARK: - QuickSelectKind tag

    @Test("kind tag projects every EntityKind case + is CaseIterable")
    func kindTag() {
        #expect(line(1).quickSelectKind == .line)
        #expect(circle(1).quickSelectKind == .circle)
        #expect(point(1).quickSelectKind == .point)
        // CaseIterable covers all 18 geometry kinds.
        #expect(QuickSelectKind.allCases.count == 18)
    }

    // MARK: - Selection composition (combine)

    @Test("combine: replace / add / remove / intersect")
    func combine() {
        let prior: Set<EntityID> = [EntityID(1), EntityID(2)]
        let result: Set<EntityID> = [EntityID(2), EntityID(3)]
        #expect(QuickSelect.combine(prior: prior, result: result, mode: .replace) == result)
        #expect(QuickSelect.combine(prior: prior, result: result, mode: .add)
                == [EntityID(1), EntityID(2), EntityID(3)])
        #expect(QuickSelect.combine(prior: prior, result: result, mode: .remove)
                == [EntityID(1)])
        #expect(QuickSelect.combine(prior: prior, result: result, mode: .intersect)
                == [EntityID(2)])
    }

    // MARK: - @MainActor convenience (live drawing)

    @MainActor
    @Test("matches(_:in: CADDrawing) reads the live entity list")
    func liveDrawing() {
        let d = CADDrawing()
        _ = d.add(line(1, layer: "walls", color: .explicit(Self.red)))
        _ = d.add(circle(2, layer: "walls", color: .explicit(Self.red)))
        _ = d.add(point(3, layer: "doors"))

        let ids = QuickSelect.matches(QuickSelectFilter(color: .explicit(Self.red)),
                                      in: d)
        #expect(ids == [EntityID(1), EntityID(2)])
    }
}
