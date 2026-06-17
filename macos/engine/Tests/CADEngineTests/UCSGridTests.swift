//
//  UCSGridTests.swift
//  CADEngineTests
//
//  UCS-W4 — the GRID render + GRID SNAP follow the active UCS (origin + rotation),
//  so a rotated/translated user coordinate system gets a grid (and grid snap) laid
//  out along its own axes, matching LibreCAD/AutoCAD. Two halves:
//
//   1. Grid GEOMETRY (`OverlayGeometry.grid(... ucs:)`): a world UCS is BYTE-IDENTICAL
//      to the pre-UCS world grid (regression-lock — the grid is invisible until a UCS
//      is set); a translated/rotated UCS shifts the grid origin and rotates the lines.
//   2. Grid SNAP (`Snapping.snap(... gridOrigin:gridAngle:)` and the pure
//      `Snapping.snappedToGrid(... gridOrigin:gridAngle:)` kernel): the default
//      params (a world frame) are byte-identical to the existing callers, and a
//      rotated/translated UCS snaps the cursor to the UCS lattice node in world coords.
//
//  Suites are domain-prefixed (CONVENTIONS.md) so this file can't collide with the
//  existing grid / snapping suites.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
import CoreGraphics
import simd
@testable import CADEngine

// MARK: - Grid geometry (OverlayGeometry.grid with a UCS)

@Suite("UCS-W4 — grid geometry follows the active UCS")
struct UCSGridGeometryTests {

    /// A representative viewport for the grid tests (matches the existing
    /// OverlayGeometryTests fixture: scale 10, 800×600, centered on origin → spacing 5).
    private func makeViewport(center: Vector = Vector(0, 0)) -> Viewport {
        Viewport(scale: 10, center: center, size: CGSize(width: 800, height: 600))
    }

    @Test("world UCS produces a byte-identical grid to the default (regression-lock)")
    func worldUCSByteIdentical() {
        let vp = makeViewport()
        let origin = Vector(0, 0)

        let baseline = OverlayGeometry.grid(viewport: vp, renderOrigin: origin)
        let withWorldUCS = OverlayGeometry.grid(viewport: vp, renderOrigin: origin, ucs: .world)

        #expect(withWorldUCS.spacing == baseline.spacing)
        #expect(withWorldUCS.vertices.count == baseline.vertices.count)
        // Byte-identical: every FlatVertex (position f32 + color) matches exactly.
        #expect(withWorldUCS.vertices == baseline.vertices)
    }

    @Test("a near-world UCS (origin .zero, angle 0) still takes the world path")
    func explicitlyWorldFrameByteIdentical() {
        let vp = makeViewport(center: Vector(1234, -567))
        let origin = Vector(1234, -567)

        let baseline = OverlayGeometry.grid(viewport: vp, renderOrigin: origin)
        let ucs = UCS(origin: .zero, angle: 0)
        let withUCS = OverlayGeometry.grid(viewport: vp, renderOrigin: origin, ucs: ucs)

        #expect(withUCS.vertices == baseline.vertices)
        #expect(withUCS.spacing == baseline.spacing)
    }

    @Test("the chosen spacing is unchanged by the UCS (depends only on scale)")
    func spacingUnaffectedByUCS() {
        let vp = makeViewport()
        let origin = Vector(0, 0)
        let world = OverlayGeometry.grid(viewport: vp, renderOrigin: origin)
        let rotated = OverlayGeometry.grid(
            viewport: vp, renderOrigin: origin,
            ucs: UCS(origin: Vector(3, 4), angle: .pi / 6))
        #expect(world.spacing == 5)
        #expect(rotated.spacing == 5)
    }

    @Test("a TRANSLATED UCS shifts the grid lattice onto the UCS origin")
    func translatedUCSAnchorsGridOnOrigin() {
        // Preferred spacing 5, UCS translated by (2,3) but unrotated. The grid nodes
        // must coincide with (UCS.origin + integer·spacing) — i.e. there is a grid
        // vertex at x ≡ 2 (mod 5) and y ≡ 3 (mod 5), NOT at the world multiples of 5.
        let vp = makeViewport()
        let origin = Vector(0, 0)
        let ucs = UCS(origin: Vector(2, 3), angle: 0)
        let (verts, spacing) = OverlayGeometry.grid(
            viewport: vp, renderOrigin: origin, preferredSpacing: 5, ucs: ucs)
        #expect(spacing == 5)
        #expect(!verts.isEmpty)

        // Every grid vertex (in world == render space here, renderOrigin 0) sits on
        // the translated lattice: (x-2) and (y-3) are integer multiples of 5.
        func onLattice(_ v: Float, _ shift: Double) -> Bool {
            let rel = (Double(v) - shift) / 5
            return abs(rel - rel.rounded()) < 1e-3
        }
        // A vertical line has the SAME x at both its endpoints; a horizontal line the
        // same y. So for every vertex, AT LEAST ONE of (x on lattice, y on lattice)
        // holds (the coordinate that the line is constant in).
        for v in verts {
            #expect(onLattice(v.position.x, 2) || onLattice(v.position.y, 3))
        }
        // Spot-check that a column actually sits ON the UCS-origin lattice (x ≡ 2 mod 5),
        // proving the lattice was shifted rather than left on world multiples of 5.
        let hasTranslatedColumn = verts.contains { onLattice($0.position.x, 2) }
        #expect(hasTranslatedColumn)
    }

    @Test("a ROTATED UCS rotates the grid lines off the world axes")
    func rotatedUCSRotatesLines() {
        // 30° rotated UCS. A world-aligned grid is made of perfectly axis-aligned
        // segments (each segment is purely horizontal OR purely vertical). A rotated
        // grid must have segments that are NEITHER — confirming the rotation took.
        let vp = makeViewport()
        let origin = Vector(0, 0)
        let angle = Double.pi / 6
        let (verts, _) = OverlayGeometry.grid(
            viewport: vp, renderOrigin: origin, preferredSpacing: 5,
            ucs: UCS(origin: .zero, angle: angle))
        #expect(verts.count % 2 == 0)
        #expect(verts.count >= 2)

        var foundDiagonal = false
        var i = 0
        while i + 1 < verts.count {
            let a = verts[i].position
            let b = verts[i + 1].position
            let dx = Double(b.x - a.x)
            let dy = Double(b.y - a.y)
            // A rotated line is neither horizontal (dy≈0) nor vertical (dx≈0).
            if abs(dx) > 1e-3 && abs(dy) > 1e-3 { foundDiagonal = true; break }
            i += 2
        }
        #expect(foundDiagonal, "a rotated UCS grid must have non-axis-aligned segments")
    }

    @Test("rotated grid segment direction matches the UCS axes")
    func rotatedSegmentsAlignToUCSAxes() {
        // For a 30° UCS, every drawn segment is parallel to either the UCS +X axis
        // (angle 30°) or the UCS +Y axis (angle 120°) — the lattice runs along the
        // UCS axes. Check each segment's direction is one of those two (mod π).
        let vp = makeViewport()
        let origin = Vector(0, 0)
        let angle = Double.pi / 6
        let (verts, _) = OverlayGeometry.grid(
            viewport: vp, renderOrigin: origin, preferredSpacing: 5,
            ucs: UCS(origin: .zero, angle: angle))

        func nearAxis(_ segAngle: Double) -> Bool {
            // Compare to UCS X (angle) and UCS Y (angle + π/2), each modulo π.
            func diffModPi(_ a: Double, _ b: Double) -> Double {
                var d = (a - b).truncatingRemainder(dividingBy: .pi)
                if d < 0 { d += .pi }
                return Swift.min(d, .pi - d)
            }
            return diffModPi(segAngle, angle) < 1e-6
                || diffModPi(segAngle, angle + .pi / 2) < 1e-6
        }

        var i = 0
        var checked = 0
        while i + 1 < verts.count {
            let a = verts[i].position
            let b = verts[i + 1].position
            let segAngle = atan2(Double(b.y - a.y), Double(b.x - a.x))
            #expect(nearAxis(segAngle))
            checked += 1
            i += 2
        }
        #expect(checked > 0)
    }
}

// MARK: - Grid snap (Snapping.snappedToGrid + Snapping.snap)

@Suite("UCS-W4 — grid snap follows the active UCS")
struct UCSGridSnapTests {

    // -- The pure kernel: snappedToGrid(... gridOrigin:gridAngle:) --

    @Test("world frame kernel is byte-identical to the world-anchored kernel")
    func kernelWorldFrameMatchesWorldAnchored() {
        let spacing = 0.1
        for cursor in [Vector(2.43, 7.57), Vector(-3.04, 0.06), Vector(0, 0), Vector(99.97, -0.03)] {
            let worldAnchored = Snapping.snappedToGrid(cursor, spacing: spacing)
            let framed = Snapping.snappedToGrid(cursor, spacing: spacing,
                                                gridOrigin: .zero, gridAngle: 0)
            #expect(framed == worldAnchored)
        }
    }

    @Test("an angle that is a multiple of 2π is still the world frame")
    func kernelTwoPiAngleIsWorldFrame() {
        let cursor = Vector(2.43, 7.57)
        let worldAnchored = Snapping.snappedToGrid(cursor, spacing: 0.1)
        let framed = Snapping.snappedToGrid(cursor, spacing: 0.1,
                                            gridOrigin: .zero, gridAngle: 2 * .pi)
        #expect(framed.distance(to: worldAnchored) < 1e-9)
    }

    @Test("a TRANSLATED frame snaps to the UCS lattice node, not the world node")
    func kernelTranslatedFrame() {
        // Spacing 1, frame origin (0.5, 0.5). The cursor (2.4, 3.4) is nearest the
        // UCS node (2.5, 3.5) — i.e. origin + (2,3)·spacing — NOT the world node (2,3).
        let p = Snapping.snappedToGrid(Vector(2.4, 3.4), spacing: 1,
                                       gridOrigin: Vector(0.5, 0.5), gridAngle: 0)
        #expect(p.distance(to: Vector(2.5, 3.5)) < 1e-9)
    }

    @Test("a ROTATED frame snaps to a node on the rotated lattice (in world coords)")
    func kernelRotatedFrame() {
        // 30° frame at the world origin, spacing 2. The UCS node at UCS-coords (1,0)
        // maps to world = rotate((2,0), 30°) = (2·cos30, 2·sin30) = (√3, 1). A cursor
        // a touch off that world point must snap exactly back to it.
        let angle = Double.pi / 6
        let nodeWorld = Vector(2, 0).rotated(by: angle)   // the (1·spacing, 0) node
        let cursor = nodeWorld + Vector(0.05, -0.04)
        let p = Snapping.snappedToGrid(cursor, spacing: 2, gridOrigin: .zero, gridAngle: angle)
        #expect(p.distance(to: nodeWorld) < 1e-9)
    }

    @Test("the kernel preserves the cursor z component")
    func kernelPreservesZ() {
        let p = Snapping.snappedToGrid(Vector(2.4, 3.4, 9.5), spacing: 1,
                                       gridOrigin: Vector(0.5, 0.5), gridAngle: .pi / 6)
        #expect(abs(p.z - 9.5) < 1e-12)
    }

    // -- Through the full Snapping.snap pipeline --

    @MainActor
    @Test("snap default params reproduce the existing world grid snap (regression)")
    func snapDefaultParamsByteIdentical() {
        let drawing = CADDrawing()
        let quadtree = Quadtree()
        let cursor = Vector(2.43, 7.57)
        let spacing = 0.1
        let worldTol = 0.16

        // Existing callers omit gridOrigin/gridAngle (the defaults).
        let r = Snapping.snap(
            worldPoint: cursor, modes: [.grid, .free],
            worldTolerance: worldTol, gridSpacing: spacing,
            in: drawing, using: quadtree)
        #expect(r.kind == SnapKind.grid)
        // Identical world node to the pre-UCS behavior: nearest 0.1 multiple.
        #expect(r.point.distance(to: Vector(2.4, 7.6)) < 1e-9)
    }

    @MainActor
    @Test("passing an explicit world frame matches the default-param result")
    func snapExplicitWorldFrameMatchesDefault() {
        let drawing = CADDrawing()
        let quadtree = Quadtree()
        let cursor = Vector(2.43, 7.57)
        let spacing = 0.1
        let worldTol = 0.16

        let base = Snapping.snap(
            worldPoint: cursor, modes: [.grid, .free],
            worldTolerance: worldTol, gridSpacing: spacing,
            in: drawing, using: quadtree)
        let framed = Snapping.snap(
            worldPoint: cursor, modes: [.grid, .free],
            worldTolerance: worldTol, gridSpacing: spacing,
            in: drawing, using: quadtree,
            gridOrigin: .zero, gridAngle: 0)
        #expect(base.point.distance(to: framed.point) < 1e-12)
        #expect(base.kind == framed.kind)
    }

    @MainActor
    @Test("a 30°-rotated UCS: a cursor near a UCS grid node snaps to it (world coords)")
    func snapRotatedUCSNode() {
        let drawing = CADDrawing()   // no entities — only grid can fire
        let quadtree = Quadtree()
        let angle = Double.pi / 6
        let ucs = UCS(origin: Vector(1, 2), angle: angle)
        let spacing = 2.0

        // Pick the UCS node at UCS-coords (3·spacing, 1·spacing) = (6, 2) and map it
        // to world: it is the node the rotated grid actually draws.
        let nodeWorld = ucs.toWorld(Vector(6, 2))
        // Cursor a little off the node (well within the aperture).
        let cursor = nodeWorld + Vector(0.12, -0.08)
        // Worldwide tolerance large enough to catch the node.
        let r = Snapping.snap(
            worldPoint: cursor, modes: [.grid, .free],
            worldTolerance: 0.5, gridSpacing: spacing,
            in: drawing, using: quadtree,
            gridOrigin: ucs.origin, gridAngle: ucs.angle)
        #expect(r.kind == SnapKind.grid)
        #expect(r.point.distance(to: nodeWorld) < 1e-9)
        // The snapped node round-trips to integer UCS multiples of the spacing.
        let nodeUCS = ucs.toUCS(r.point)
        #expect(abs((nodeUCS.x / spacing).rounded() * spacing - nodeUCS.x) < 1e-6)
        #expect(abs((nodeUCS.y / spacing).rounded() * spacing - nodeUCS.y) < 1e-6)
    }

    @MainActor
    @Test("UCS grid snap respects the spacing (a far-off cursor is out of aperture)")
    func snapRotatedUCSRespectsSpacing() {
        let drawing = CADDrawing()
        let quadtree = Quadtree()
        let angle = Double.pi / 6
        let ucs = UCS(origin: Vector(1, 2), angle: angle)
        let spacing = 2.0

        // Cursor at the MIDPOINT between two UCS nodes (1 unit, half a spacing of 2,
        // along the UCS X axis from a node) — exactly `spacing/2` from the nearest
        // node. With a tiny aperture (0.1 < 1) the grid candidate is out of reach, so
        // the snap free-falls.
        let nodeWorld = ucs.toWorld(Vector(6, 2))
        let midWorld = nodeWorld + ucs.directionToWorld(Vector(1, 0))   // half a 2-spacing
        let r = Snapping.snap(
            worldPoint: midWorld, modes: [.grid, .free],
            worldTolerance: 0.1, gridSpacing: spacing,
            in: drawing, using: quadtree,
            gridOrigin: ucs.origin, gridAngle: ucs.angle)
        #expect(r.kind == SnapKind.free)
        #expect(r.point.distance(to: midWorld) < 1e-12)
    }
}
