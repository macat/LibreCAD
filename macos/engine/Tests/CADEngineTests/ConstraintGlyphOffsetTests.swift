//
//  ConstraintGlyphOffsetTests.swift
//  CADEngineTests
//
//  Tests the SCREEN-space OUTWARD OFFSET applied to constraint glyph badges so they sit a
//  bit AWAY FROM the geometry instead of on top of it (the owner's "move the badges a bit
//  away from the object" ask). The testable seam is the pure `ConstraintGlyphLayout`
//  (`placements` + `offset`), reached via the `_SharedConstraintGlyphOverlay.swift` symlink
//  into the app target — exactly like `ConstraintGlyphLayoutTests`. The PER-KIND outward
//  *direction* (`outwardWorld`) is computed against a live `CanvasModel`, which a unit test
//  can't reach without a GUI; here we verify the LAYOUT contract — that a supplied outward
//  direction floats the badge by a CONSTANT on-screen gap, normalized in screen space so it
//  is ZOOM-STABLE, and that omitting it preserves the old on-feature placement.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import CoreGraphics
import Testing

@testable import CADEngine

@Suite("Wave-3 constraint glyph — outward screen offset")
struct ConstraintGlyphOffsetTests {

    /// The (gap) distance two CGPoints differ by.
    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    @Test("an H badge on a horizontal line floats OFF the line, not on it")
    func horizontalBadgeOffLine() {
        // A horizontal line along y=0; its midpoint feature is (5,0). Outward = +normal
        // (0,1) → in flipped screen space the badge floats a gap below the line, clearly
        // NOT sitting on y=0.
        let cons = [Constraint.horizontal(line: EntityID(1))]
        let places = ConstraintGlyphLayout.placements(
            for: cons,
            worldAnchor: { _ in Vector(5, 0) },              // line midpoint
            worldToScreen: { CGPoint(x: $0.x, y: $0.y) },    // identity (1:1) projection
            worldOutward: { _ in Vector(0, 1) })             // perpendicular to the line
        #expect(places.count == 1)
        let a = places[0].anchor
        // Floated by the full gap along +y; the x is unchanged.
        #expect(a.x == 5)
        #expect(abs(a.y - (0 + ConstraintGlyphLayout.offsetGap)) < 1e-6)
        // The badge is now a badge-size GAP off the feature, not on it.
        #expect(dist(a, CGPoint(x: 5, y: 0)) > ConstraintGlyphLayout.offsetGap - 1e-6)
    }

    @Test("omitting the outward direction keeps the old on-feature placement")
    func noDirectionKeepsOnFeature() {
        // Back-compat: the 3-arg call (no `worldOutward`) must place the badge exactly on
        // the feature, as before this change.
        let cons = [Constraint.horizontal(line: EntityID(1))]
        let places = ConstraintGlyphLayout.placements(
            for: cons,
            worldAnchor: { _ in Vector(5, 0) },
            worldToScreen: { CGPoint(x: $0.x, y: $0.y) })   // no worldOutward → default nil
        #expect(places.count == 1)
        #expect(places[0].anchor == CGPoint(x: 5, y: 0))
    }

    @Test("the gap is ZOOM-STABLE — same on-screen distance at any scale")
    func gapIsZoomStable() {
        let cons = [Constraint.horizontal(line: EntityID(1))]
        func gapAt(scale s: CGFloat) -> CGFloat {
            let base = CGPoint(x: 5 * s, y: 0)
            let places = ConstraintGlyphLayout.placements(
                for: cons,
                worldAnchor: { _ in Vector(5, 0) },
                // A pure scale (zoom) world→screen map.
                worldToScreen: { CGPoint(x: $0.x * s, y: $0.y * s) },
                worldOutward: { _ in Vector(0, 1) })
            return dist(places[0].anchor, base)
        }
        // At 1×, 5×, and 0.25× zoom the on-screen gap is the SAME constant — proving the
        // offset is normalized in screen space, not world space.
        #expect(abs(gapAt(scale: 1) - ConstraintGlyphLayout.offsetGap) < 1e-6)
        #expect(abs(gapAt(scale: 5) - ConstraintGlyphLayout.offsetGap) < 1e-6)
        #expect(abs(gapAt(scale: 0.25) - ConstraintGlyphLayout.offsetGap) < 1e-6)
    }

    @Test("the offset respects a FLIPPED (Y-down) world→screen projection")
    func offsetUnderFlippedProjection() {
        // The real canvas projects with Y flipped. A world +y outward must still produce a
        // constant-gap screen move along the projected direction (here screen -y), proving
        // we normalize the SCREEN delta rather than blindly adding the world direction.
        let base = CGPoint(x: 10, y: 100)
        let world = Vector(10, 0)
        let p = ConstraintGlyphLayout.offset(
            base: base, world: world, outward: Vector(0, 1),
            worldToScreen: { CGPoint(x: $0.x, y: 100 - $0.y) })   // Y-flip about y=100
        // World +y maps to screen −y, so the badge moves UP the screen by exactly the gap.
        #expect(p.x == 10)
        #expect(abs(p.y - (100 - ConstraintGlyphLayout.offsetGap)) < 1e-6)
        #expect(abs(dist(p, base) - ConstraintGlyphLayout.offsetGap) < 1e-6)
    }

    @Test("a degenerate / nil outward direction leaves the badge on the feature")
    func degenerateDirectionIsSafe() {
        let base = CGPoint(x: 3, y: 7)
        let toScreen: (Vector) -> CGPoint = { CGPoint(x: $0.x, y: $0.y) }
        // nil direction → unchanged.
        #expect(ConstraintGlyphLayout.offset(
            base: base, world: Vector(3, 7), outward: nil, worldToScreen: toScreen) == base)
        // zero-length direction → unchanged.
        #expect(ConstraintGlyphLayout.offset(
            base: base, world: Vector(3, 7), outward: Vector(0, 0), worldToScreen: toScreen) == base)
        // invalid-vector direction → unchanged.
        #expect(ConstraintGlyphLayout.offset(
            base: base, world: Vector(3, 7), outward: .invalid, worldToScreen: toScreen) == base)
    }

    @Test("offset then stack-step still applies — offset badges that co-locate fan out")
    func offsetThenStack() {
        // Two constraints whose features map to the same offset spot still get the vertical
        // stack-step nudge, so the offset and the de-overprint logic compose.
        let cons = [
            Constraint.horizontal(line: EntityID(1)),
            Constraint.vertical(line: EntityID(1)),
        ]
        let places = ConstraintGlyphLayout.placements(
            for: cons,
            worldAnchor: { _ in Vector(0, 0) },
            worldToScreen: { CGPoint(x: $0.x, y: $0.y) },
            worldOutward: { _ in Vector(0, 1) })            // both float to the same offset spot
        #expect(places.count == 2)
        // First at the offset spot (0, gap); second nudged up by the stack step.
        #expect(places[0].anchor == CGPoint(x: 0, y: ConstraintGlyphLayout.offsetGap))
        #expect(places[1].anchor
            == CGPoint(x: 0, y: ConstraintGlyphLayout.offsetGap - ConstraintGlyphLayout.stackStep))
    }
}
