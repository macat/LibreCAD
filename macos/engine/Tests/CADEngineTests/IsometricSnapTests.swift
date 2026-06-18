//
//  IsometricSnapTests.swift
//  CADEngineTests
//
//  Wave 2c — the ISOMETRIC drafting engine: the `IsoPlane` model + iso lattice math,
//  the iso GRID SNAP (`Snapping.snappedToIsoGrid` + the `isoPlane`-parameterized
//  `Snapping.snap`), the iso GRID GEOMETRY (`OverlayGeometry.grid(... isoPlane:)`),
//  and the `$SNAPSTYLE` / `$LC_ISOPLANE` persistence (DXF round-trip + the Codable
//  plane-resets-on-pure-DXF-reopen contract).
//
//  REGRESSION-LOCK (the load-bearing invariant): with `isoPlane == nil` the snap and
//  the grid geometry are BYTE-IDENTICAL to the pre-iso rectangular behavior — the iso
//  branches are fully gated off. The tests below pin both halves of that, plus the
//  three planes' lattice nodes + line angles, and the DXF round-trip with ZERO
//  vendored libdxfrw edits (the `$SNAPSTYLE` curated-emit + generic-read mechanism).
//
//  Suites are domain-prefixed (CONVENTIONS.md) so this file can't collide with the
//  existing snapping / grid suites.
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

// MARK: - IsoPlane model + lattice math

@Suite("Iso — IsoPlane model + lattice basis")
struct IsoPlaneModelTests {

    /// Returns the angle (radians, in [0, 2π)) of `v`.
    private func ang(_ v: Vector) -> Double { Vector.correctAngle(atan2(v.y, v.x)) }

    @Test("the three planes carry the canonical 30°/90°/150° axis directions")
    func axisAnglesPerPlane() {
        let a30 = Double.pi / 6, a90 = Double.pi / 2, a150 = Double.pi - Double.pi / 6
        let top = IsoPlane.top.axisDirections
        #expect(abs(ang(top.0) - a30) < 1e-12)
        #expect(abs(ang(top.1) - a150) < 1e-12)

        let left = IsoPlane.left.axisDirections
        #expect(abs(ang(left.0) - a90) < 1e-12)
        #expect(abs(ang(left.1) - a150) < 1e-12)

        let right = IsoPlane.right.axisDirections
        #expect(abs(ang(right.0) - a30) < 1e-12)
        #expect(abs(ang(right.1) - a90) < 1e-12)
    }

    @Test("axis directions are unit vectors; the grid basis scales them by spacing")
    func basisLengthsScaleWithSpacing() {
        for plane in IsoPlane.allCases {
            let (d1, d2) = plane.axisDirections
            #expect(abs(d1.magnitude - 1) < 1e-12)
            #expect(abs(d2.magnitude - 1) < 1e-12)
            let (e1, e2) = plane.gridBasis(spacing: 2.5)
            #expect(abs(e1.magnitude - 2.5) < 1e-12)
            #expect(abs(e2.magnitude - 2.5) < 1e-12)
        }
    }

    @Test("every plane's basis is non-degenerate (the two axes are independent)")
    func basisNonDegenerate() {
        for plane in IsoPlane.allCases {
            let (e1, e2) = plane.gridBasis(spacing: 1)
            let det = e1.x * e2.y - e1.y * e2.x
            #expect(abs(det) > 0.1, "iso axes must not be parallel for \(plane)")
        }
    }

    @Test("IsoPlane round-trips through its raw value (the $LC_ISOPLANE encoding)")
    func rawValueRoundTrip() {
        #expect(IsoPlane(rawValue: 0) == .top)
        #expect(IsoPlane(rawValue: 1) == .left)
        #expect(IsoPlane(rawValue: 2) == .right)
        for plane in IsoPlane.allCases {
            #expect(IsoPlane(rawValue: plane.rawValue) == plane)
        }
    }
}

// MARK: - Iso grid snap (Snapping.snappedToIsoGrid)

@Suite("Iso — snappedToIsoGrid lands on the correct lattice node")
struct IsoSnapKernelTests {

    @Test("each plane snaps a near-node cursor exactly to that iso node")
    func eachPlaneSnapsToItsNode() {
        let spacing = 2.0
        let origin = Vector(0, 0)
        for plane in IsoPlane.allCases {
            let (e1, e2) = plane.gridBasis(spacing: spacing)
            // The lattice node at (i=2, j=-1) for this plane.
            let node = origin + e1 * 2 + e2 * (-1)
            // A cursor a touch off the node must snap exactly back to it.
            let cursor = node + Vector(0.07, -0.05)
            let snapped = Snapping.snappedToIsoGrid(cursor, spacing: spacing,
                                                    plane: plane, origin: origin)
            #expect(snapped.distance(to: node) < 1e-9,
                    "\(plane): cursor near node (2,-1) must snap to it")
        }
    }

    @Test("the iso snap honors a translated origin")
    func snapHonorsOrigin() {
        let plane = IsoPlane.top
        let spacing = 1.0
        let origin = Vector(3, 4)
        let (e1, e2) = plane.gridBasis(spacing: spacing)
        let node = origin + e1 * 1 + e2 * 2
        let cursor = node + Vector(-0.03, 0.04)
        let snapped = Snapping.snappedToIsoGrid(cursor, spacing: spacing,
                                                plane: plane, origin: origin)
        #expect(snapped.distance(to: node) < 1e-9)
    }

    @Test("the iso snap preserves the cursor z component")
    func snapPreservesZ() {
        let p = Snapping.snappedToIsoGrid(Vector(1.2, 3.4, 7.25), spacing: 1,
                                          plane: .right, origin: .zero)
        #expect(abs(p.z - 7.25) < 1e-12)
    }

    @Test("a snapped point is an exact integer combination of the basis vectors")
    func snappedPointIsIntegerLatticeNode() {
        let plane = IsoPlane.left
        let spacing = 1.5
        let origin = Vector(0, 0)
        let (e1, e2) = plane.gridBasis(spacing: spacing)
        let det = e1.x * e2.y - e1.y * e2.x
        // Snap an arbitrary cursor; the result's lattice coefficients must be integers.
        let snapped = Snapping.snappedToIsoGrid(Vector(4.37, -2.91), spacing: spacing,
                                                plane: plane, origin: origin)
        let p = snapped - origin
        let iCoef = (p.x * e2.y - p.y * e2.x) / det
        let jCoef = (e1.x * p.y - e1.y * p.x) / det
        #expect(abs(iCoef - iCoef.rounded()) < 1e-9)
        #expect(abs(jCoef - jCoef.rounded()) < 1e-9)
    }

    @Test("non-positive spacing leaves the point unchanged")
    func nonPositiveSpacingNoOp() {
        let p = Vector(1.23, 4.56)
        #expect(Snapping.snappedToIsoGrid(p, spacing: 0, plane: .top) == p)
        #expect(Snapping.snappedToIsoGrid(p, spacing: -1, plane: .top) == p)
    }
}

// MARK: - The snap DISPATCH: nil == byte-identical world-frame snap (regression-lock)

@Suite("Iso — snap(... isoPlane:) nil path is byte-identical to the world grid snap")
struct IsoSnapDispatchTests {

    @MainActor
    @Test("isoPlane nil reproduces the EXISTING world grid snap exactly (regression)")
    func nilIsoPlaneByteIdenticalToWorldGrid() {
        let drawing = CADDrawing()   // no entities — only grid can fire
        let quadtree = Quadtree()
        let spacing = 0.1
        let worldTol = 0.16
        // A spread of cursors; each must match the pre-iso world grid snap exactly,
        // whether isoPlane is omitted (existing callers) or passed explicitly as nil.
        for cursor in [Vector(2.43, 7.57), Vector(-3.04, 0.06),
                       Vector(0, 0), Vector(99.97, -0.03)] {
            let baseline = Snapping.snap(
                worldPoint: cursor, modes: [.grid, .free],
                worldTolerance: worldTol, gridSpacing: spacing,
                in: drawing, using: quadtree)
            let explicitNil = Snapping.snap(
                worldPoint: cursor, modes: [.grid, .free],
                worldTolerance: worldTol, gridSpacing: spacing,
                in: drawing, using: quadtree,
                isoPlane: nil)
            #expect(baseline.kind == explicitNil.kind)
            #expect(baseline.point == explicitNil.point,   // exact f64 equality
                    "isoPlane nil must be byte-identical to the default world grid snap")
            #expect(baseline.entity == explicitNil.entity)
        }
    }

    @MainActor
    @Test("an active iso plane snaps the grid candidate to an iso node, not a world node")
    func activeIsoPlaneSnapsToIsoNode() {
        let drawing = CADDrawing()
        let quadtree = Quadtree()
        let plane = IsoPlane.top
        let spacing = 2.0
        let (e1, e2) = plane.gridBasis(spacing: spacing)
        let node = e1 * 3 + e2 * 1                     // an iso node
        let cursor = node + Vector(0.1, -0.08)
        let r = Snapping.snap(
            worldPoint: cursor, modes: [.grid, .free],
            worldTolerance: 0.5, gridSpacing: spacing,
            in: drawing, using: quadtree,
            isoPlane: plane)
        #expect(r.kind == SnapKind.grid)
        #expect(r.point.distance(to: node) < 1e-9)
        // The iso node is NOT a rectangular node: it does not sit on world multiples
        // of the spacing (its y is e1.y·3 + e2.y·1 = 3·sin30·2 + 1·sin150·2 = 4, but
        // its x = 3·cos30·2 + 1·cos150·2 = √3·3·... — irrational), proving it took the
        // iso branch rather than the rectangular round.
        let rectNode = Snapping.snappedToGrid(cursor, spacing: spacing)
        #expect(r.point.distance(to: rectNode) > 1e-6,
                "the iso snap must differ from the rectangular grid snap")
    }

    @MainActor
    @Test("iso grid snap respects the aperture (a far cursor free-falls)")
    func isoSnapRespectsAperture() {
        let drawing = CADDrawing()
        let quadtree = Quadtree()
        let plane = IsoPlane.right
        let spacing = 2.0
        let (e1, e2) = plane.gridBasis(spacing: spacing)
        let nodeA = e1 * 1 + e2 * 1
        // Midway between two iso nodes along e1 → spacing/2 == 1 from each node.
        let mid = nodeA + e1 * 0.5
        let r = Snapping.snap(
            worldPoint: mid, modes: [.grid, .free],
            worldTolerance: 0.1, gridSpacing: spacing,
            in: drawing, using: quadtree,
            isoPlane: plane)
        #expect(r.kind == SnapKind.free)
        #expect(r.point.distance(to: mid) < 1e-12)
    }
}

// MARK: - Iso grid GEOMETRY (OverlayGeometry.grid with an iso plane)

@Suite("Iso — grid geometry: nil byte-identical, plane draws the 30/90/150 lattice")
struct IsoGridGeometryTests {

    private func makeViewport(center: Vector = Vector(0, 0)) -> Viewport {
        Viewport(scale: 10, center: center, size: CGSize(width: 800, height: 600))
    }

    @Test("isoPlane nil produces a byte-identical grid to the default (regression-lock)")
    func nilIsoPlaneByteIdentical() {
        let vp = makeViewport()
        let origin = Vector(0, 0)
        let baseline = OverlayGeometry.grid(viewport: vp, renderOrigin: origin)
        let explicitNil = OverlayGeometry.grid(viewport: vp, renderOrigin: origin, isoPlane: nil)
        #expect(explicitNil.spacing == baseline.spacing)
        #expect(explicitNil.vertices == baseline.vertices)
    }

    @Test("the iso grid spacing follows the same rule as the rectangular grid")
    func isoSpacingMatchesRectangular() {
        let vp = makeViewport()
        let origin = Vector(0, 0)
        let rect = OverlayGeometry.grid(viewport: vp, renderOrigin: origin)
        let iso = OverlayGeometry.grid(viewport: vp, renderOrigin: origin, isoPlane: .top)
        #expect(iso.spacing == rect.spacing)   // depends only on scale
    }

    /// The set of segment directions (angle mod π, in degrees) present in the grid.
    private func segmentAnglesDeg(_ verts: [FlatVertex]) -> [Double] {
        var out: [Double] = []
        var i = 0
        while i + 1 < verts.count {
            let a = verts[i].position, b = verts[i + 1].position
            let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
            guard abs(dx) > 1e-6 || abs(dy) > 1e-6 else { i += 2; continue }
            var deg = atan2(dy, dx) * 180 / .pi
            deg = deg.truncatingRemainder(dividingBy: 180)
            if deg < 0 { deg += 180 }
            out.append(deg)
            i += 2
        }
        return out
    }

    private func hasAngle(_ angles: [Double], _ target: Double) -> Bool {
        angles.contains { abs($0 - target) < 0.5 }
    }

    @Test("each plane's iso grid draws lines at the expected two iso angles")
    func planeLineAnglesAreIsometric() {
        let vp = makeViewport()
        let origin = Vector(0, 0)

        // .top → 30° and 150°.
        let top = OverlayGeometry.grid(viewport: vp, renderOrigin: origin,
                                       preferredSpacing: 5, isoPlane: .top)
        let topAngles = segmentAnglesDeg(top.vertices)
        #expect(!topAngles.isEmpty)
        #expect(hasAngle(topAngles, 30))
        #expect(hasAngle(topAngles, 150))
        // No purely vertical (90°) lines in the top plane.
        #expect(!hasAngle(topAngles, 90))

        // .left → 90° and 150°.
        let left = OverlayGeometry.grid(viewport: vp, renderOrigin: origin,
                                        preferredSpacing: 5, isoPlane: .left)
        let leftAngles = segmentAnglesDeg(left.vertices)
        #expect(hasAngle(leftAngles, 90))
        #expect(hasAngle(leftAngles, 150))
        #expect(!hasAngle(leftAngles, 30))

        // .right → 30° and 90°.
        let right = OverlayGeometry.grid(viewport: vp, renderOrigin: origin,
                                         preferredSpacing: 5, isoPlane: .right)
        let rightAngles = segmentAnglesDeg(right.vertices)
        #expect(hasAngle(rightAngles, 30))
        #expect(hasAngle(rightAngles, 90))
        #expect(!hasAngle(rightAngles, 150))
    }

    @Test("the iso grid has NO axis-aligned (0°/90°) lines for the top plane")
    func topPlaneIsAllDiagonal() {
        let vp = makeViewport()
        let (verts, _) = OverlayGeometry.grid(viewport: vp, renderOrigin: Vector(0, 0),
                                              preferredSpacing: 5, isoPlane: .top)
        #expect(!verts.isEmpty)
        for ang in segmentAnglesDeg(verts) {
            // Every top-plane segment is a 30° or 150° diagonal — never horizontal (0°).
            #expect(abs(ang - 0) > 0.5 && abs(ang - 180) > 0.5,
                    "top-plane iso grid must have no horizontal lines, got \(ang)°")
        }
    }
}

// MARK: - DXF round-trip ($SNAPSTYLE) + the plane-resets-on-pure-DXF contract

@Suite("Iso — $SNAPSTYLE DXF round-trip + $LC_ISOPLANE Codable-only persistence")
struct IsoDXFRoundTripTests {

    private func tempDXFPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("iso_\(UUID().uuidString).dxf").path
    }

    // -- The GraphicVariables accessors --

    @Test("snapIsometric defaults off and toggles $SNAPSTYLE")
    func snapIsometricAccessor() {
        var gv = GraphicVariables()
        #expect(gv.snapIsometric == false)
        #expect(gv.int("$SNAPSTYLE", default: -1) == -1)   // unset until written
        gv.snapIsometric = true
        #expect(gv.int("$SNAPSTYLE") == 1)
        gv.snapIsometric = false
        #expect(gv.int("$SNAPSTYLE") == 0)
    }

    @Test("isoPlane defaults to .top and stores $LC_ISOPLANE")
    func isoPlaneAccessor() {
        var gv = GraphicVariables()
        #expect(gv.isoPlane == .top)
        gv.isoPlane = .right
        #expect(gv.int("$LC_ISOPLANE") == IsoPlane.right.rawValue)
        #expect(gv.isoPlane == .right)
    }

    // -- The DXF FILE round-trip (the real codec; ZERO vendored libdxfrw edits) --

    @Test("$SNAPSTYLE == 1 survives a DXF save → reopen")
    func snapStyleRoundTrips() async throws {
        var gv = GraphicVariables()
        gv.snapIsometric = true
        let rec = EntityRecord(
            id: EntityID(1), layer: LayerID("0"),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let path = tempDXFPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try await CADEngine.shared.writeEntities(
            [rec], layers: LayerTable(), graphicVariables: gv, toPath: path, version: .r2000)
        let back = try await CADEngine.shared.readEntities(dxfPath: path)
        #expect(back.graphicVariables.snapIsometric == true,
                "$SNAPSTYLE=1 must round-trip through a .dxf save → reopen")
    }

    @Test("$SNAPSTYLE == 0 round-trips as rectangular (off)")
    func rectangularRoundTrips() async throws {
        var gv = GraphicVariables()
        gv.snapIsometric = false       // explicit rectangular
        let path = tempDXFPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try await CADEngine.shared.writeEntities(
            [], layers: LayerTable(), graphicVariables: gv, toPath: path, version: .r2000)
        let back = try await CADEngine.shared.readEntities(dxfPath: path)
        #expect(back.graphicVariables.snapIsometric == false)
    }

    @Test("a written iso DXF carries the $SNAPSTYLE header group")
    func writesSnapStyleHeaderGroup() async throws {
        var gv = GraphicVariables()
        gv.snapIsometric = true
        let path = tempDXFPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try await CADEngine.shared.writeEntities(
            [], layers: LayerTable(), graphicVariables: gv, toPath: path, version: .r2000)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.contains("$SNAPSTYLE"),
                "the iso header must emit the $SNAPSTYLE var (libdxfrw curated emit)")
    }

    // -- The plane is Codable-only: it RESETS to .top on a pure-DXF reopen --

    @Test("the active plane is DROPPED on a pure-DXF reopen (resets to .top)")
    func planeResetsOnPureDXFReopen() async throws {
        var gv = GraphicVariables()
        gv.snapIsometric = true
        gv.isoPlane = .right          // a non-default plane
        let path = tempDXFPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try await CADEngine.shared.writeEntities(
            [], layers: LayerTable(), graphicVariables: gv, toPath: path, version: .r2000)
        let back = try await CADEngine.shared.readEntities(dxfPath: path)
        // $SNAPSTYLE (is-iso) survives, but the private $LC_ISOPLANE (which face) does
        // NOT — so the plane comes back at the default .top after a pure-DXF reopen.
        #expect(back.graphicVariables.snapIsometric == true)
        #expect(back.graphicVariables.isoPlane == .top,
                "a pure-DXF reopen drops $LC_ISOPLANE; the plane resets to .top")
        #expect(!back.graphicVariables.has("$LC_ISOPLANE"),
                "$LC_ISOPLANE must not appear in the re-read .dxf header")
    }

    // -- The plane DOES survive the Codable payload (in-memory document persistence) --

    @Test("the active plane survives a Codable GraphicVariables round-trip")
    func planeSurvivesCodable() throws {
        var gv = GraphicVariables()
        gv.snapIsometric = true
        gv.isoPlane = .left
        let back = try JSONDecoder().decode(
            GraphicVariables.self, from: JSONEncoder().encode(gv))
        #expect(back.snapIsometric == true)
        #expect(back.isoPlane == .left,
                "$LC_ISOPLANE persists through the Codable document payload")
    }
}
