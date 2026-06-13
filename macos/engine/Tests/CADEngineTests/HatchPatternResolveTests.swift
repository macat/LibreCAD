//
//  HatchPatternResolveTests.swift
//  CADEngineTests
//
//  Tests for real hatch-pattern support (v5 WAVE-4a, feature F6):
//   - the `.pat` parser (HatchPatternParser) and the bundled library
//     (HatchPatternLibrary);
//   - the pattern-line generator clipped to the boundary loops
//     (HatchPatternGenerator) — honoring scale + angle;
//   - boundary-arc tessellation of bulged boundary edges (HatchBoundary);
//   - the hatch resolve arm: a KNOWN pattern → lines, a SOLID/unknown → fill.
//
//  Uniquely-namespaced suite (CONVENTIONS / §7 namespacing): the bundled `.pat`
//  library loads from macos/assets/hatchpatterns via the same #filePath repo
//  fallback CADFonts uses for `.lff`, so these run without an app bundle.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("Hatch patterns — parser / library / generator / boundary (W4a F6)")
struct HatchPatternResolveTests {

    // A unit square boundary ring (CCW), 0..10.
    private var squareRing: [PolylineVertex] {
        [
            PolylineVertex(point: Vector(0, 0)),
            PolylineVertex(point: Vector(10, 0)),
            PolylineVertex(point: Vector(10, 10)),
            PolylineVertex(point: Vector(0, 10)),
        ]
    }

    // MARK: - `.pat` parser

    @Test("parser reads name, description, angle (deg→rad), origin, delta, dashes")
    func parsesPatRecords() {
        let text = """
        ; a comment
        *DEMO, demo pattern, with, commas
        45, 0,0, 0,.125
        0, 1,2, 3,4, .5,-.25
        """
        let pats = HatchPatternParser.parse(text)
        let demo = try! #require(pats.first { $0.name == "DEMO" })
        #expect(demo.description == "demo pattern, with, commas")
        #expect(demo.lines.count == 2)

        let l0 = demo.lines[0]
        #expect(abs(l0.angle - .pi / 4) < 1e-12)       // 45° → π/4
        #expect(l0.origin == Vector(0, 0))
        #expect(l0.delta == Vector(0, 0.125))
        #expect(l0.dashes.isEmpty)

        let l1 = demo.lines[1]
        #expect(l1.origin == Vector(1, 2))
        #expect(l1.delta == Vector(3, 4))
        #expect(l1.dashes == [0.5, -0.25])
    }

    @Test("parser is lenient: blank/comment lines skipped, bad records dropped")
    func parserLenient() {
        let text = """

        *X, ok
        45, 0,0, 0,.5
        this is not a record
        90, 0,0       ; too few fields
        """
        let pats = HatchPatternParser.parse(text)
        let x = try! #require(pats.first { $0.name == "X" })
        #expect(x.lines.count == 1)        // only the valid record survives
    }

    // MARK: - Bundled library

    @Test("bundled library contains the shipped patterns; SOLID is not a pattern")
    func bundledLibraryLoaded() {
        let names = Set(HatchPatternLibrary.patterns.keys)
        // The brief's shipped set.
        #expect(names.contains("ANSI31"))
        #expect(names.contains("ANSI32"))
        #expect(names.contains("ANSI37"))
        #expect(names.contains("LINE"))
        #expect(names.contains("NET"))
        // Lookup is case-insensitive; SOLID / nil map to "no pattern".
        #expect(HatchPatternLibrary.pattern(named: "ansi31") != nil)
        #expect(HatchPatternLibrary.pattern(named: "SOLID") == nil)
        #expect(HatchPatternLibrary.pattern(named: nil) == nil)
        #expect(HatchPatternLibrary.pattern(named: "NOSUCHPATTERN") == nil)
    }

    // MARK: - Resolve: ANSI31 → pattern lines (the headline done-criterion)

    @Test("ANSI31 hatch resolves to clipped pattern LINES, not a solid fill")
    func ansi31ResolvesToLines() {
        let e = EntityRecord(
            id: EntityID(1),
            pen: Pen(lineColor: .explicit(.black)),
            kind: .hatch(HatchData(loops: [squareRing], solidFill: false, patternName: "ANSI31")))
        let geo = e.resolve(ResolveContext())

        #expect(geo.fills.isEmpty)                    // NOT a solid fill
        #expect(!geo.polylines.isEmpty)               // real pattern lines
        // ANSI31 is a 45° family at 0.125 spacing; a 10×10 box yields many lines.
        #expect(geo.polylines.count > 10)
        // Every generated line is a 2-point open segment INSIDE the boundary box.
        for pl in geo.polylines {
            #expect(pl.points.count == 2)
            #expect(!pl.closed)
            for p in pl.points {
                #expect(p.x >= -1e-6 && p.x <= 10 + 1e-6)
                #expect(p.y >= -1e-6 && p.y <= 10 + 1e-6)
            }
        }
        // The lines carry the entity's pen color (black), not the layer green.
        #expect(geo.polylines.allSatisfy { $0.pen.color == .black })
    }

    @Test("unknown pattern name falls back to a SOLID fill (no lines)")
    func unknownPatternFallsBackToSolid() {
        let e = EntityRecord(
            id: EntityID(1),
            kind: .hatch(HatchData(loops: [squareRing], solidFill: false,
                                   patternName: "DEFINITELY_NOT_A_PATTERN")))
        let geo = e.resolve(ResolveContext())
        #expect(geo.polylines.isEmpty)
        #expect(geo.fills.count == 1)
        #expect(geo.fills[0].loops.count == 1)
    }

    @Test("a SOLID hatch still resolves to a solid fill (no regression)")
    func solidHatchStillFills() {
        let e = EntityRecord(
            id: EntityID(1),
            kind: .hatch(HatchData(loops: [squareRing], solidFill: true, patternName: "SOLID")))
        let geo = e.resolve(ResolveContext())
        #expect(geo.polylines.isEmpty)
        #expect(geo.fills.count == 1)
        #expect(geo.fills[0].loops[0] == squareRing.map(\.point))
    }

    // MARK: - scale + angle honored

    @Test("a larger pattern scale yields fewer (more widely spaced) lines")
    func patternScaleHonored() {
        func lineCount(scale: Double) -> Int {
            let e = EntityRecord(
                id: EntityID(1),
                kind: .hatch(HatchData(loops: [squareRing], solidFill: false,
                                       patternName: "ANSI31", patternScale: scale)))
            return e.resolve(ResolveContext()).polylines.count
        }
        let small = lineCount(scale: 1)
        let large = lineCount(scale: 4)
        #expect(large < small)        // 4× spacing ⇒ ~¼ the lines
        #expect(large > 0)
    }

    @Test("the pattern angle offset rotates the line family")
    func patternAngleHonored() {
        func firstDir(angle: Double) -> Vector {
            let e = EntityRecord(
                id: EntityID(1),
                kind: .hatch(HatchData(loops: [squareRing], solidFill: false,
                                       patternName: "ANSI31", patternAngle: angle)))
            let pls = e.resolve(ResolveContext()).polylines
            let pl = pls.first { ($0.points[1] - $0.points[0]).magnitude > 1e-6 }!
            let d = pl.points[1] - pl.points[0]
            return d / d.magnitude
        }
        // ANSI31's native family is 45°. Adding +45° (π/4) makes it ~90° (vertical):
        // the direction's x-component should drop toward 0.
        let base = firstDir(angle: 0)
        let rotated = firstDir(angle: .pi / 4)
        #expect(abs(base.x) > 0.5)            // ~45° ⇒ |x| ≈ 0.707
        #expect(abs(rotated.x) < abs(base.x)) // rotated toward vertical
    }

    // MARK: - dashed pattern (NET / dash handling)

    @Test("a continuous pattern (no dashes) emits unbroken inside spans")
    func continuousPatternUnbroken() {
        // LINE is a single continuous horizontal family; across the convex square
        // every inside span is one segment, so each line is exactly one polyline.
        let e = EntityRecord(
            id: EntityID(1),
            kind: .hatch(HatchData(loops: [squareRing], solidFill: false, patternName: "LINE")))
        let geo = e.resolve(ResolveContext())
        #expect(!geo.polylines.isEmpty)
        // Horizontal lines: each spans the full 10-wide box (y constant).
        for pl in geo.polylines {
            #expect(abs(pl.points[0].y - pl.points[1].y) < 1e-6)
            #expect(abs((pl.points[1] - pl.points[0]).magnitude - 10) < 1e-3)
        }
    }

    // MARK: - holes (even-odd) clipping

    @Test("a hole is left UNHATCHED (even-odd clipping across loops)")
    func holeLeftUnhatched() {
        let outer = squareRing
        // A centered 4×4 hole (3..7).
        let hole = [
            PolylineVertex(point: Vector(3, 3)),
            PolylineVertex(point: Vector(7, 3)),
            PolylineVertex(point: Vector(7, 7)),
            PolylineVertex(point: Vector(3, 7)),
        ]
        let e = EntityRecord(
            id: EntityID(1),
            kind: .hatch(HatchData(loops: [outer, hole], solidFill: false, patternName: "LINE")))
        let geo = e.resolve(ResolveContext())
        #expect(!geo.polylines.isEmpty)
        // No generated segment's MIDPOINT lies strictly inside the hole.
        for pl in geo.polylines {
            let mid = (pl.points[0] + pl.points[1]) * 0.5
            let inHole = mid.x > 3 + 1e-6 && mid.x < 7 - 1e-6
                      && mid.y > 3 + 1e-6 && mid.y < 7 - 1e-6
            #expect(!inHole)
        }
    }

    // MARK: - Boundary-arc tessellation

    @Test("a bulged boundary edge tessellates into arc samples (HatchBoundary)")
    func bulgedBoundaryTessellates() {
        // Two vertices with a semicircle bulge between them (bulge = 1 ⇒ 180°),
        // then a straight return — a half-disc boundary.
        let ring = [
            PolylineVertex(point: Vector(0, 0), bulge: 1),   // semicircle to (10,0)
            PolylineVertex(point: Vector(10, 0), bulge: 0),  // straight back to (0,0)
        ]
        let pts = HatchBoundary.tessellate(ring, tolerance: 0.05)
        // Way more than the 2 raw vertices (the arc is sampled).
        #expect(pts.count > 8)
        // The arc bows to y > 0 (a left-bulging semicircle above the chord),
        // peaking near (5, 5) for radius 5.
        let maxY = pts.map(\.y).max() ?? 0
        #expect(maxY > 4)
        // The first point is the start vertex; the ring does not repeat it.
        #expect(pts.first == Vector(0, 0))
        #expect(pts.last != Vector(0, 0))
    }

    @Test("a circle-bounded (full-bulge) hatch fills/clips over the tessellated arc")
    func circleBoundedHatchClipsArc() {
        // A closed 2-vertex loop, each bulge = 1 (two semicircles) ⇒ a full circle
        // of radius 5 centered at (5,0): vertices (0,0) and (10,0).
        let ring = [
            PolylineVertex(point: Vector(0, 0), bulge: 1),
            PolylineVertex(point: Vector(10, 0), bulge: 1),
        ]
        // Solid first: the fill loop is the tessellated circle (a real ring).
        let solid = EntityRecord(
            id: EntityID(1),
            kind: .hatch(HatchData(loops: [ring], solidFill: true)))
        let solidGeo = solid.resolve(ResolveContext())
        #expect(solidGeo.fills.count == 1)
        #expect(solidGeo.fills[0].loops[0].count > 8)   // tessellated, not 2 verts

        // Pattern: lines clipped to the circular boundary — every endpoint lies
        // within the circumscribing radius (no line escapes the disc).
        let pat = EntityRecord(
            id: EntityID(1),
            kind: .hatch(HatchData(loops: [ring], solidFill: false, patternName: "LINE")))
        let patGeo = pat.resolve(ResolveContext())
        #expect(!patGeo.polylines.isEmpty)
        let center = Vector(5, 0)
        for pl in patGeo.polylines {
            for p in pl.points {
                #expect(p.distance(to: center) <= 5 + 0.2)  // inside the disc (+slack)
            }
        }
    }

    @Test("the hatch bounding box includes the bulged-edge arc bow")
    func boundingBoxIncludesArcBow() {
        // The half-disc from bulgedBoundaryTessellates: a chord-only box would give
        // maxY ≈ 0; the arc bow reaches y ≈ 5.
        let ring = [
            PolylineVertex(point: Vector(0, 0), bulge: 1),
            PolylineVertex(point: Vector(10, 0), bulge: 0),
        ]
        let e = EntityRecord(id: EntityID(1), kind: .hatch(HatchData(loops: [ring])))
        let box = e.boundingBox()
        #expect(box.max.y > 4)        // arc bow captured, not the flat chord
    }
}
