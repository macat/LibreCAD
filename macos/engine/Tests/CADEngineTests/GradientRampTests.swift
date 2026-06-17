//
//  GradientRampTests.swift
//  CADEngineTests
//
//  Unit tests for the renderer's GPU-FREE gradient-hatch color ramp (GH-W2):
//  `RendererGeometry.gradientColor(at:gradient:bounds:fallback:)` plus its pure
//  `lerp` / `lightenedTint` helpers. This is the CPU per-vertex ramp that maps a
//  world-space point to an `RGBAColor` by sampling a `ResolvedGradient` across a
//  fill's bounding box (no shader / vertex-format change — the flat vertex already
//  carries per-vertex color).
//
//  Proven here without a GPU (pure color math):
//    - LINEAR: t=0 at the box's near edge → c0; t=1 at the far edge → c1;
//      center → the c0/c1 average; the angle rotates the ramp axis (a 90° gradient
//      ramps vertically); points beyond the box clamp to c0 / c1.
//    - RADIAL: center → c0; a corner (half-diagonal) → ≈ c1; clamps past the edge.
//    - SINGLE-color gradient still SHADES (c0 → a 50%-toward-white tint of c0).
//    - EMPTY stop list / degenerate bbox degrade gracefully (fallback / c0).
//
//  Compiles the EXACT shipping `RendererGeometry` source via the existing
//  `_SharedRendererGeometry.swift` symlink (it lives in the non-importable
//  `LibreCADmacOS` executable target — same trick as `FillTriangulationTests`).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import CADEngine
import simd
import Foundation

@Suite("Gradient hatch ramp (GH-W2)")
struct GradientRampTests {

    /// Approx-equal for an RGBAColor (per-channel) to absorb f32/f64 rounding.
    private func approxEqual(_ a: RGBAColor, _ b: RGBAColor, tol: Float = 1e-4) -> Bool {
        abs(a.r - b.r) <= tol && abs(a.g - b.g) <= tol
            && abs(a.b - b.b) <= tol && abs(a.a - b.a) <= tol
    }

    /// A 10×10 box from (0,0) to (10,10); center (5,5).
    private var unitBox: AABB { AABB(min: Vector(0, 0), max: Vector(10, 10)) }

    private let red = RGBAColor(1, 0, 0, 1)
    private let blue = RGBAColor(0, 0, 1, 1)

    // MARK: - Linear

    @Test("linear: near edge → c0, far edge → c1, center → average")
    func linearEndpointsAndMidpoint() {
        // angle 0 → axis (1,0): ramps left→right across the box.
        let g = ResolvedGradient(kind: .linear, colors: [red, blue], angle: 0)
        let box = unitBox

        // Left edge x=0 → t=0 → c0 (red).
        let atLeft = RendererGeometry.gradientColor(
            at: Vector(0, 5), gradient: g, bounds: box, fallback: .white)
        #expect(approxEqual(atLeft, red))

        // Right edge x=10 → t=1 → c1 (blue).
        let atRight = RendererGeometry.gradientColor(
            at: Vector(10, 5), gradient: g, bounds: box, fallback: .white)
        #expect(approxEqual(atRight, blue))

        // Center x=5 → t=0.5 → the c0/c1 average (0.5, 0, 0.5).
        let atMid = RendererGeometry.gradientColor(
            at: Vector(5, 5), gradient: g, bounds: box, fallback: .white)
        #expect(approxEqual(atMid, RGBAColor(0.5, 0, 0.5, 1)))
    }

    @Test("linear: a 90° angle rotates the axis so the ramp runs vertically")
    func linearAngleRotatesAxis() {
        // angle π/2 → axis (0,1): ramps bottom→top.
        let g = ResolvedGradient(kind: .linear, colors: [red, blue], angle: .pi / 2)
        let box = unitBox

        // Bottom edge y=0 → t=0 → c0 (red).
        let atBottom = RendererGeometry.gradientColor(
            at: Vector(5, 0), gradient: g, bounds: box, fallback: .white)
        #expect(approxEqual(atBottom, red))

        // Top edge y=10 → t=1 → c1 (blue).
        let atTop = RendererGeometry.gradientColor(
            at: Vector(5, 10), gradient: g, bounds: box, fallback: .white)
        #expect(approxEqual(atTop, blue))

        // A horizontal move (x varies) does NOT change t for a 90° gradient:
        // y=5 (center) → average regardless of x.
        let mA = RendererGeometry.gradientColor(
            at: Vector(0, 5), gradient: g, bounds: box, fallback: .white)
        let mB = RendererGeometry.gradientColor(
            at: Vector(10, 5), gradient: g, bounds: box, fallback: .white)
        #expect(approxEqual(mA, RGBAColor(0.5, 0, 0.5, 1)))
        #expect(approxEqual(mB, RGBAColor(0.5, 0, 0.5, 1)))
    }

    @Test("linear: points beyond the box clamp to c0 / c1")
    func linearClamps() {
        let g = ResolvedGradient(kind: .linear, colors: [red, blue], angle: 0)
        let box = unitBox

        // Far past the left edge → clamps to c0.
        let beyondLeft = RendererGeometry.gradientColor(
            at: Vector(-100, 5), gradient: g, bounds: box, fallback: .white)
        #expect(approxEqual(beyondLeft, red))

        // Far past the right edge → clamps to c1.
        let beyondRight = RendererGeometry.gradientColor(
            at: Vector(100, 5), gradient: g, bounds: box, fallback: .white)
        #expect(approxEqual(beyondRight, blue))
    }

    // MARK: - Radial

    @Test("radial: center → c0, corner (half-diagonal) → c1")
    func radialCenterAndEdge() {
        let g = ResolvedGradient(kind: .radial, colors: [red, blue])
        let box = unitBox  // half-diagonal = sqrt(5^2 + 5^2) = 5√2 ≈ 7.071

        // Center → t=0 → c0 (red).
        let atCenter = RendererGeometry.gradientColor(
            at: Vector(5, 5), gradient: g, bounds: box, fallback: .white)
        #expect(approxEqual(atCenter, red))

        // A box corner is exactly at the half-diagonal → t=1 → c1 (blue).
        let atCorner = RendererGeometry.gradientColor(
            at: Vector(10, 10), gradient: g, bounds: box, fallback: .white)
        #expect(approxEqual(atCorner, blue))

        // Halfway out along an axis (x=5+ (5√2)/2 ... ) — simpler: a point at
        // distance = halfRadius gives t≈0.5. Distance from center to (5 + 5√2/2*?,..)
        // Use a point at distance half the half-diagonal along +x:
        let halfDiag = (5.0 * 5 + 5 * 5).squareRoot()
        let p = Vector(5 + halfDiag / 2, 5)
        let atHalf = RendererGeometry.gradientColor(
            at: p, gradient: g, bounds: box, fallback: .white)
        #expect(approxEqual(atHalf, RGBAColor(0.5, 0, 0.5, 1), tol: 1e-3))
    }

    @Test("radial: a point past the corner clamps to c1")
    func radialClamps() {
        let g = ResolvedGradient(kind: .radial, colors: [red, blue])
        let box = unitBox
        let farOut = RendererGeometry.gradientColor(
            at: Vector(1000, 1000), gradient: g, bounds: box, fallback: .white)
        #expect(approxEqual(farOut, blue))
    }

    // MARK: - Single-color gradient (still shades)

    @Test("single-color linear gradient shades c0 → a lightened tint of c0")
    func singleColorShades() {
        // One stop: gray 0.4. The synthetic far endpoint is 50% toward white:
        // 0.4 + (1 - 0.4)*0.5 = 0.7 (per channel), alpha preserved.
        let gray = RGBAColor(0.4, 0.4, 0.4, 1)
        let g = ResolvedGradient(kind: .linear, colors: [gray], angle: 0)
        let box = unitBox

        // Near edge → c0 (the original gray).
        let near = RendererGeometry.gradientColor(
            at: Vector(0, 5), gradient: g, bounds: box, fallback: .white)
        #expect(approxEqual(near, gray))

        // Far edge → the lightened tint (0.7 gray), NOT flat → it shades.
        let far = RendererGeometry.gradientColor(
            at: Vector(10, 5), gradient: g, bounds: box, fallback: .white)
        #expect(approxEqual(far, RGBAColor(0.7, 0.7, 0.7, 1)))
        #expect(!approxEqual(far, gray))  // genuinely different → visible shading
    }

    @Test("lightenedTint moves each RGB channel 50% toward white, preserving alpha")
    func lightenedTintFormula() {
        let c = RGBAColor(0.2, 0.6, 1.0, 0.8)
        let t = RendererGeometry.lightenedTint(c)
        // 0.2→0.6, 0.6→0.8, 1.0→1.0, alpha unchanged.
        #expect(approxEqual(t, RGBAColor(0.6, 0.8, 1.0, 0.8)))
    }

    // MARK: - lerp helper

    @Test("lerp: t=0 → a, t=1 → b, t=0.5 → midpoint")
    func lerpHelper() {
        let a = RGBAColor(0, 0.2, 0.4, 1)
        let b = RGBAColor(1, 0.8, 0.6, 0)
        #expect(approxEqual(RendererGeometry.lerp(a, b, 0), a))
        #expect(approxEqual(RendererGeometry.lerp(a, b, 1), b))
        #expect(approxEqual(RendererGeometry.lerp(a, b, 0.5),
                            RGBAColor(0.5, 0.5, 0.5, 0.5)))
    }

    // MARK: - Degenerate inputs degrade gracefully

    @Test("empty stop list returns the fallback color")
    func emptyStopsFallback() {
        let g = ResolvedGradient(kind: .linear, colors: [], angle: 0)
        let out = RendererGeometry.gradientColor(
            at: Vector(5, 5), gradient: g, bounds: unitBox, fallback: RGBAColor(0.1, 0.2, 0.3, 1))
        #expect(approxEqual(out, RGBAColor(0.1, 0.2, 0.3, 1)))
    }

    @Test("a degenerate (empty) bbox returns c0 without crashing")
    func degenerateBoxReturnsC0() {
        let g = ResolvedGradient(kind: .linear, colors: [red, blue], angle: 0)
        let out = RendererGeometry.gradientColor(
            at: Vector(5, 5), gradient: g, bounds: .empty, fallback: .white)
        #expect(approxEqual(out, red))
    }

    // MARK: - End-to-end: appendFillVertices threads the gradient per-vertex

    @Test("appendFillVertices applies the gradient (corners differ; nil path is flat)")
    func appendFillVerticesGradientVsFlat() {
        let outline = [Vector(0, 0), Vector(10, 0), Vector(10, 10), Vector(0, 10)]

        // Gradient fill: a horizontal red→blue ramp. Vertices on the left side must
        // be redder; vertices on the right side bluer — i.e. NOT all one color.
        let gradFill = ResolvedFill(
            outline: outline,
            color: red,
            gradient: ResolvedGradient(kind: .linear, colors: [red, blue], angle: 0))
        var gradVerts: [FlatVertex] = []
        RendererGeometry.appendFillVertices(for: gradFill, renderOrigin: Vector(0, 0),
                                            into: &gradVerts)
        #expect(gradVerts.count == 6)   // square → 2 triangles
        let distinctColors = Set(gradVerts.map { "\($0.color.x),\($0.color.y),\($0.color.z)" })
        #expect(distinctColors.count > 1)  // genuinely ramped, not flat

        // Flat fill (gradient == nil): every vertex carries the single fill color
        // BYTE-IDENTICAL to the prior solid path.
        let flatFill = ResolvedFill(outline: outline, color: red)
        var flatVerts: [FlatVertex] = []
        RendererGeometry.appendFillVertices(for: flatFill, renderOrigin: Vector(0, 0),
                                            into: &flatVerts)
        #expect(flatVerts.count == 6)
        for v in flatVerts {
            #expect(v.color == SIMD4<Float>(1, 0, 0, 1))
        }
    }
}
