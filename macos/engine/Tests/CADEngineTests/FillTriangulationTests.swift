//
//  FillTriangulationTests.swift
//  CADEngineTests
//
//  Unit tests for the renderer's GPU-FREE fill triangulator (`FillTriangulation`,
//  ear-clipping — rendering-performance.md §1.3). The triangulator turns a
//  `ResolvedFill.loops[0]` outer boundary into a flat triangle list (3 vertices per
//  triangle) for the shared flat/triangle pipeline.
//
//  Proven here without a GPU:
//    - a convex square triangulates to exactly 2 triangles,
//    - a concave L-shape triangulates to the right triangle count AND the triangle
//      areas sum to the polygon's own (shoelace) area — i.e. the fan exactly tiles
//      the polygon with no overlap/gap,
//    - CW input is handled (the algorithm normalizes to CCW),
//    - degenerate (< 3 point) rings yield an empty list (no crash),
//    - the fill-vertex packer applies the ADR-003 floating-origin offset + color.
//
//  Compiles the EXACT shipping `FillTriangulation`/`RendererGeometry` source via the
//  existing `_SharedRendererGeometry.swift` symlink (same trick as
//  `RendererGeometryTests` / `RendererCullTests`), since they live in the
//  non-importable `LibreCADmacOS` executable target.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import CADEngine
import simd

@Suite("Fill triangulation — ear-clipping")
struct FillTriangulationTests {

    /// Area of a flat triangle list (3 vertices per triangle), summed as unsigned
    /// shoelace areas. The triangulator emits CCW triangles, so each area is +.
    private func triangleListArea(_ verts: [Vector]) -> Double {
        precondition(verts.count % 3 == 0, "triangle list must be a multiple of 3")
        var sum = 0.0
        var i = 0
        while i < verts.count {
            let a = verts[i], b = verts[i + 1], c = verts[i + 2]
            let cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            sum += abs(cross) * 0.5
            i += 3
        }
        return sum
    }

    // MARK: - Square → 2 triangles

    @Test("a unit square triangulates to exactly 2 triangles tiling its area")
    func squareTwoTriangles() {
        // CCW square, first vertex NOT repeated (the loop convention).
        let square = [Vector(0, 0), Vector(1, 0), Vector(1, 1), Vector(0, 1)]
        let tris = FillTriangulation.triangulate(square)
        #expect(tris.count == 6)                  // 2 triangles × 3 vertices
        #expect(abs(triangleListArea(tris) - 1.0) < 1e-9)   // tiles the unit square
    }

    @Test("a clockwise square also triangulates to 2 area-correct triangles")
    func clockwiseSquare() {
        // Same square wound CW — the triangulator must normalize internally.
        let cw = [Vector(0, 0), Vector(0, 1), Vector(1, 1), Vector(1, 0)]
        let tris = FillTriangulation.triangulate(cw)
        #expect(tris.count == 6)
        #expect(abs(triangleListArea(tris) - 1.0) < 1e-9)
    }

    @Test("a square with a duplicated closing vertex still yields 2 triangles")
    func squareWithClosingVertex() {
        // Defensive: a ring that repeats its first vertex must not double-count.
        let closed = [Vector(0, 0), Vector(2, 0), Vector(2, 2), Vector(0, 2), Vector(0, 0)]
        let tris = FillTriangulation.triangulate(closed)
        #expect(tris.count == 6)
        #expect(abs(triangleListArea(tris) - 4.0) < 1e-9)   // 2×2 square
    }

    // MARK: - Concave L-shape

    @Test("a concave L-shape triangulates to the right tri count + exact area")
    func concaveLShape() {
        // An L (6 vertices): a 2×2 square with the top-right 1×1 corner removed.
        //   (0,0) (2,0) (2,1) (1,1) (1,2) (0,2)
        // Area = full 2×2 (4) minus the missing 1×1 corner (1) = 3.
        let lShape = [
            Vector(0, 0), Vector(2, 0), Vector(2, 1),
            Vector(1, 1), Vector(1, 2), Vector(0, 2),
        ]
        let tris = FillTriangulation.triangulate(lShape)
        // A simple polygon of N vertices triangulates to N−2 triangles.
        #expect(tris.count == (6 - 2) * 3)        // 4 triangles × 3 vertices = 12
        // The fan exactly tiles the L (no overlap into the removed corner, no gap).
        #expect(abs(triangleListArea(tris) - 3.0) < 1e-9)
    }

    @Test("a concave arrow (reflex vertex) tiles its own shoelace area")
    func concaveArrow() {
        // A chevron/arrow with a deep reflex notch at the bottom-center.
        let arrow = [
            Vector(0, 0), Vector(2, 1), Vector(4, 0),
            Vector(4, 4), Vector(0, 4),
        ]
        let tris = FillTriangulation.triangulate(arrow)
        #expect(tris.count == (5 - 2) * 3)        // 3 triangles
        let expected = abs(FillTriangulation.signedArea(arrow))
        #expect(abs(triangleListArea(tris) - expected) < 1e-9)
    }

    // MARK: - Degenerate input

    @Test("fewer than 3 points → empty triangle list (no crash)")
    func degenerateEmpty() {
        #expect(FillTriangulation.triangulate([]).isEmpty)
        #expect(FillTriangulation.triangulate([Vector(0, 0)]).isEmpty)
        #expect(FillTriangulation.triangulate([Vector(0, 0), Vector(1, 1)]).isEmpty)
    }

    // MARK: - Fill-vertex packing (offset + color)

    @Test("appendFillVertices triangulates loops[0] with the floating-origin offset")
    func fillVertexPacking() {
        let fill = ResolvedFill(
            outline: [Vector(10, 10), Vector(12, 10), Vector(12, 12), Vector(10, 12)],
            color: RGBAColor(0.2, 0.4, 0.6, 0.5)
        )
        var verts: [FlatVertex] = []
        RendererGeometry.appendFillVertices(for: fill, renderOrigin: Vector(10, 10), into: &verts)
        #expect(verts.count == 6)                 // square → 2 triangles
        // Every vertex is offset by renderOrigin (10,10) → coords in [0, 2].
        for v in verts {
            #expect(v.position.x >= -1e-6 && v.position.x <= 2 + 1e-6)
            #expect(v.position.y >= -1e-6 && v.position.y <= 2 + 1e-6)
            #expect(v.color == SIMD4<Float>(0.2, 0.4, 0.6, 0.5))
        }
    }

    @Test("a fill with a < 3 point outer boundary packs nothing")
    func fillVertexDegenerate() {
        let fill = ResolvedFill(outline: [Vector(0, 0), Vector(1, 1)], color: .white)
        var verts: [FlatVertex] = []
        RendererGeometry.appendFillVertices(for: fill, renderOrigin: .init(0, 0), into: &verts)
        #expect(verts.isEmpty)
    }

    // MARK: - Holes (earcut bridge) — glyph counters render as cut-outs

    @Test("a square with a square hole triangulates to (outer − hole) area")
    func squareWithHole() {
        // Outer 10×10 CCW, hole 4×4 centered, wound CW.
        let outer = [Vector(0, 0), Vector(10, 0), Vector(10, 10), Vector(0, 10)]
        let hole  = [Vector(3, 3), Vector(3, 7), Vector(7, 7), Vector(7, 3)]   // CW
        let tris = FillTriangulation.triangulateLoops([outer, hole])
        #expect(!tris.isEmpty)
        // The filled area must be the annulus area (100 − 16 = 84), NOT 100
        // (over-filled). The bridge stitches a zero-area channel, so the total
        // triangulated area equals outer − hole.
        let area = triangleListArea(tris)
        #expect(abs(area - 84.0) < 1e-6)
    }

    @Test("the bridge handles a CCW-wound hole input too (winding normalized)")
    func holeWindingNormalized() {
        let outer = [Vector(0, 0), Vector(10, 0), Vector(10, 10), Vector(0, 10)]
        let holeCCW = [Vector(3, 3), Vector(7, 3), Vector(7, 7), Vector(3, 7)]   // CCW
        let tris = FillTriangulation.triangulateLoops([outer, holeCCW])
        #expect(abs(triangleListArea(tris) - 84.0) < 1e-6)
    }

    @Test("two holes both get subtracted")
    func twoHoles() {
        let outer = [Vector(0, 0), Vector(20, 0), Vector(20, 10), Vector(0, 10)]   // area 200
        let h1 = [Vector(2, 2), Vector(2, 8), Vector(6, 8), Vector(6, 2)]          // 24, CW
        let h2 = [Vector(12, 2), Vector(12, 8), Vector(16, 8), Vector(16, 2)]      // 24, CW
        let tris = FillTriangulation.triangulateLoops([outer, h1, h2])
        #expect(abs(triangleListArea(tris) - (200.0 - 48.0)) < 1e-6)
    }

    @Test("a single loop (no holes) forwards to the simple triangulator")
    func singleLoopForwarded() {
        let square = [Vector(0, 0), Vector(2, 0), Vector(2, 2), Vector(0, 2)]
        let tris = FillTriangulation.triangulateLoops([square])
        #expect(tris.count == 2 * 3)
        #expect(abs(triangleListArea(tris) - 4.0) < 1e-9)
    }

    @Test("appendFillVertices subtracts a hole (counter renders as a cut-out)")
    func fillVertexWithHole() {
        let outer = [Vector(0, 0), Vector(10, 0), Vector(10, 10), Vector(0, 10)]
        let hole  = [Vector(3, 3), Vector(3, 7), Vector(7, 7), Vector(7, 3)]
        let fill = ResolvedFill(loops: [outer, hole], color: .white)
        var verts: [FlatVertex] = []
        RendererGeometry.appendFillVertices(for: fill, renderOrigin: .init(0, 0), into: &verts)
        #expect(verts.count % 3 == 0)
        let area = triangleListArea(verts.map { Vector(Double($0.position.x), Double($0.position.y)) })
        // Cut-out (84), not over-filled (100).
        #expect(abs(area - 84.0) < 1e-3)
    }
}
