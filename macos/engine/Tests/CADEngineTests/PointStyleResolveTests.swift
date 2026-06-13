//
//  PointStyleResolveTests.swift
//  CADEngineTests
//
//  Verifies AutoCAD point display styles (w5-pointstyle / F19): the additive
//  `PointData.style` field ($PDMODE encoding), each marker glyph resolving to the
//  expected geometry, the enclosure bits (circle/square), `$PDSIZE` scaling the
//  marker, the additive field round-tripping (Codable, back-compat), and the
//  document default ($PDMODE/$PDSIZE) applying to points left at the inherit
//  sentinel via `CADDrawing.makeResolveContext` → `ResolveContext.pointStyleProvider`.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_Point / $PDMODE semantics).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("Point display styles ($PDMODE/$PDSIZE)")
struct PointStyleResolveTests {

    private let tol = 1e-9

    /// Resolves a point with the given per-entity style under a context whose point
    /// provider supplies the given document mode + size (or no provider when `nil`).
    private func resolvePoint(
        position: Vector,
        style: PointDisplayMode = .dot,
        docMode: PointDisplayMode? = nil,
        docSize: Double = 0
    ) -> ResolvedGeometry {
        let rec = EntityRecord(id: EntityID(1), kind: .point(PointData(position: position, style: style)))
        var ctx = ResolveContext.default
        if let docMode {
            ctx.pointStyleProvider = { (mode: docMode, size: docSize) }
        }
        return rec.resolve(ctx)
    }

    /// True if any resolved polyline runs between (≈)`a` and (≈)`b` (either order).
    private func hasSegment(_ geo: ResolvedGeometry, _ a: Vector, _ b: Vector) -> Bool {
        geo.polylines.contains { poly in
            guard poly.points.count == 2 else { return false }
            let p0 = poly.points[0], p1 = poly.points[1]
            let fwd = p0.distance(to: a) < 1e-6 && p1.distance(to: b) < 1e-6
            let rev = p0.distance(to: b) < 1e-6 && p1.distance(to: a) < 1e-6
            return fwd || rev
        }
    }

    // MARK: - $PDMODE encoding

    @Test("PointDisplayMode decodes base glyph + circle/square bits from the raw $PDMODE")
    func encodingDecodesBitsAndGlyph() {
        #expect(PointDisplayMode(rawMode: 0).glyph == .dot)
        #expect(PointDisplayMode(rawMode: 1).glyph == .none)
        #expect(PointDisplayMode(rawMode: 2).glyph == .plus)
        #expect(PointDisplayMode(rawMode: 3).glyph == .cross)
        #expect(PointDisplayMode(rawMode: 4).glyph == .tick)

        // 35 = 3 (cross) + 32 (circle).
        let crossCircle = PointDisplayMode(rawMode: 35)
        #expect(crossCircle.glyph == .cross)
        #expect(crossCircle.hasCircle)
        #expect(!crossCircle.hasSquare)

        // 66 = 2 (plus) + 64 (square).
        let plusSquare = PointDisplayMode(rawMode: 66)
        #expect(plusSquare.glyph == .plus)
        #expect(plusSquare.hasSquare)
        #expect(!plusSquare.hasCircle)

        // 96 = 32 (circle) + 64 (square) over a dot.
        let both = PointDisplayMode(rawMode: 96)
        #expect(both.glyph == .dot)
        #expect(both.hasCircle && both.hasSquare)
    }

    @Test("the glyph+flags initializer composes the right raw $PDMODE")
    func encodingComposesRawMode() {
        #expect(PointDisplayMode(glyph: .cross, circle: true).rawMode == 35)
        #expect(PointDisplayMode(glyph: .plus, square: true).rawMode == 66)
        #expect(PointDisplayMode(glyph: .dot, circle: true, square: true).rawMode == 96)
        #expect(PointDisplayMode.dot.rawMode == 0)
    }

    // MARK: - Default dot stays the historical single-point marker (no regression)

    @Test("a default-style point resolves to the historical single-point polyline")
    func defaultDotIsSinglePoint() {
        let geo = resolvePoint(position: Vector(3, 4))
        #expect(geo.polylines.count == 1)
        #expect(geo.polylines[0].points == [Vector(3, 4)])
        #expect(geo.fills.isEmpty)
    }

    // MARK: - Each glyph resolves to the expected geometry

    @Test("the plus glyph resolves to a horizontal + vertical arm")
    func plusResolvesToCrossArms() {
        let c = Vector(0, 0)
        let h = Resolve_pointHalfDefault
        let geo = resolvePoint(position: c, style: .plus)
        #expect(geo.polylines.count == 2)
        #expect(hasSegment(geo, Vector(-h, 0), Vector(h, 0)))   // horizontal
        #expect(hasSegment(geo, Vector(0, -h), Vector(0, h)))   // vertical
    }

    @Test("the cross (X) glyph resolves to the two diagonals")
    func crossResolvesToDiagonals() {
        let c = Vector(5, 5)
        let h = Resolve_pointHalfDefault
        let geo = resolvePoint(position: c, style: .cross)
        #expect(geo.polylines.count == 2)
        #expect(hasSegment(geo, Vector(5 - h, 5 - h), Vector(5 + h, 5 + h)))
        #expect(hasSegment(geo, Vector(5 - h, 5 + h), Vector(5 + h, 5 - h)))
    }

    @Test("the tick glyph resolves to a vertical segment running UP from the point")
    func tickResolvesToUpwardSegment() {
        let c = Vector(2, 2)
        let h = Resolve_pointHalfDefault
        let geo = resolvePoint(position: c, style: .tick)
        #expect(geo.polylines.count == 1)
        #expect(hasSegment(geo, c, Vector(2, 2 + h)))
    }

    @Test("the circle enclosure resolves to a closed ring around the dot")
    func circleResolvesToClosedRing() {
        let c = Vector(0, 0)
        let h = Resolve_pointHalfDefault
        let geo = resolvePoint(position: c, style: .circle)
        // A dot (single-point polyline) + the circle ring.
        let rings = geo.polylines.filter { $0.closed }
        #expect(rings.count == 1)
        let ring = try! #require(rings.first)
        #expect(ring.points.count >= 3)
        // Every ring vertex is at the marker radius from the centre.
        for p in ring.points {
            #expect(abs(p.distance(to: c) - h) < 1e-3)
        }
    }

    @Test("the square enclosure resolves to a closed 4-corner ring at the marker box")
    func squareResolvesToClosedBox() {
        let c = Vector(0, 0)
        let h = Resolve_pointHalfDefault
        let geo = resolvePoint(position: c, style: .square)
        let rings = geo.polylines.filter { $0.closed }
        #expect(rings.count == 1)
        let ring = try! #require(rings.first)
        #expect(ring.points.count == 4)
        let corners = Set(ring.points.map { "\($0.x),\($0.y)" })
        #expect(corners.contains("\(-h),\(-h)"))
        #expect(corners.contains("\(h),\(-h)"))
        #expect(corners.contains("\(h),\(h)"))
        #expect(corners.contains("\(-h),\(h)"))
    }

    @Test("the none glyph with no enclosure resolves to NOTHING")
    func noneResolvesEmpty() {
        let geo = resolvePoint(position: Vector(1, 1), style: .none)
        #expect(geo.polylines.isEmpty)
        #expect(geo.fills.isEmpty)
    }

    @Test("a cross-in-a-circle resolves to BOTH the diagonals and the ring")
    func crossInCircleResolvesBoth() {
        let geo = resolvePoint(position: Vector(0, 0),
                               style: PointDisplayMode(glyph: .cross, circle: true))
        let openSegs = geo.polylines.filter { !$0.closed && $0.points.count == 2 }
        let rings = geo.polylines.filter { $0.closed }
        #expect(openSegs.count == 2)   // the X
        #expect(rings.count == 1)      // the circle
    }

    // MARK: - $PDSIZE scales the marker

    @Test("the document $PDSIZE scales the marker half-extent")
    func docSizeScalesMarker() {
        let c = Vector(0, 0)
        let size = 7.0
        // A plus point that INHERITS the document size (its own style is explicit
        // plus, so the size — but not the mode — comes from the document default).
        let geo = resolvePoint(position: c, style: .plus, docMode: .dot, docSize: size)
        #expect(hasSegment(geo, Vector(-size, 0), Vector(size, 0)))
        #expect(hasSegment(geo, Vector(0, -size), Vector(0, size)))
    }

    @Test("a non-positive document $PDSIZE falls back to the built-in default size")
    func nonPositiveSizeFallsBack() {
        let h = Resolve_pointHalfDefault
        let geo = resolvePoint(position: Vector(0, 0), style: .plus, docMode: .dot, docSize: 0)
        #expect(hasSegment(geo, Vector(-h, 0), Vector(h, 0)))
    }

    // MARK: - Document default applies to points with no per-entity style

    @Test("a plain (.dot) point picks up the document $PDMODE default")
    func docModeAppliesToInheritingPoint() {
        // The point carries the .dot inherit sentinel; the document default is cross.
        let geo = resolvePoint(position: Vector(0, 0), style: .dot,
                               docMode: .cross, docSize: 4)
        // It now resolves as a cross (two diagonals), NOT a single dot.
        let openSegs = geo.polylines.filter { !$0.closed && $0.points.count == 2 }
        #expect(openSegs.count == 2)
        #expect(hasSegment(geo, Vector(-4, -4), Vector(4, 4)))
    }

    @Test("an explicit per-entity style WINS over the document default")
    func perEntityStyleWinsOverDoc() {
        // The point is explicitly tick; the document default is cross — tick wins.
        let h = 4.0
        let geo = resolvePoint(position: Vector(0, 0), style: .tick,
                               docMode: .cross, docSize: h)
        #expect(geo.polylines.count == 1)
        #expect(hasSegment(geo, Vector(0, 0), Vector(0, h)))
    }

    @Test("with no provider, an explicit styled point still resolves its glyph")
    func explicitStyleResolvesWithoutProvider() {
        let geo = resolvePoint(position: Vector(0, 0), style: .plus)  // no docMode
        #expect(geo.polylines.count == 2)
    }

    // MARK: - Additive field round-trips (Codable, back-compat)

    @Test("the additive style field round-trips through Codable")
    func styleRoundTripsCodable() throws {
        let original = PointData(position: Vector(7, 8),
                                 style: PointDisplayMode(glyph: .cross, circle: true, square: true))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PointData.self, from: data)
        #expect(decoded == original)
        #expect(decoded.style.rawMode == 99)   // 3 + 32 + 64
        #expect(decoded.style.glyph == .cross)
        #expect(decoded.style.hasCircle && decoded.style.hasSquare)
    }

    @Test("a point serialized WITHOUT a style (older data) decodes to .dot")
    func backCompatMissingStyleDecodesToDot() throws {
        // Simulate an OLD payload (position only, no `style` key) by encoding just
        // the position under the `position` key — the field PointData's Decodable
        // tolerates a missing `style` and defaults it to `.dot`.
        let posData = try JSONEncoder().encode(Vector(3, 4))
        let json = "{\"position\":" + String(decoding: posData, as: UTF8.self) + "}"
        let decoded = try JSONDecoder().decode(PointData.self, from: Data(json.utf8))
        #expect(decoded.position == Vector(3, 4))
        #expect(decoded.style == .dot)
    }
}

/// The resolve step's built-in default marker half-extent (mirrors
/// `EntityKind.pointMarkerDefaultHalf`). A free `let` kept module-private to the
/// test would shadow; named with the file prefix to stay unambiguous.
private let Resolve_pointHalfDefault: Double = 2.5
