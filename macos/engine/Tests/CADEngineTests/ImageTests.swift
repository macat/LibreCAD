//
//  ImageTests.swift
//  CADEngineTests
//
//  Tests for the raster-image (`.image`) entity — the DXF IMAGE feature:
//   - ImageData.corners produces the four world corners from insertion + u/v;
//   - resolve() emits a textured-quad `ResolvedImage` + a frame polyline;
//   - resolve() of a missing/hidden image marks the placeholder flag (no crash);
//   - boundingBox() encloses the quad corners;
//   - EntityTransform translates / rotates / scales / mirrors the placement;
//   - snapping exposes the corners + center + insertion + edge midpoints;
//   - ImageTool places an `.image` from two clicks keeping the pixel aspect;
//   - a DXF IMAGE + IMAGEDEF round-trips via the bridge (path + placement).
//
//  Uniquely namespaced (`@Suite("raster image entity")`) so it does not collide
//  with the existing suites.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("raster image entity")
struct ImageTests {

    // MARK: - Helpers

    /// An axis-aligned 200×100-pixel image whose bottom edge spans 200 world units
    /// and left edge 100 world units (u/v == 1 world-unit per pixel), lower-left at
    /// (10, 20). So the four corners are a 200×100 rectangle.
    private func axisAlignedImage(
        lowerLeft: Vector = Vector(10, 20),
        pixelWidth: Double = 200,
        pixelHeight: Double = 100
    ) -> ImageData {
        ImageData(
            insertion: lowerLeft,
            uVector: Vector(1, 0),           // 1 world-unit per pixel in +x
            vVector: Vector(0, 1),           // 1 world-unit per pixel in +y
            imageDef: ImageDefData(path: "/tmp/pic.png",
                                   pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        )
    }

    private func approx(_ a: Vector, _ b: Vector, _ tol: Double = 1e-9) -> Bool {
        (a - b).magnitude < tol
    }

    // MARK: - corners

    @Test("corners are the four world quad corners CCW from the lower-left")
    func cornersFromUV() {
        let d = axisAlignedImage()
        let c = d.corners
        #expect(c.count == 4)
        #expect(approx(c[0], Vector(10, 20)))    // LL = insertion
        #expect(approx(c[1], Vector(210, 20)))   // LR = +u·W (200)
        #expect(approx(c[2], Vector(210, 120)))  // UR = +u·W +v·H
        #expect(approx(c[3], Vector(10, 120)))   // UL = +v·H (100)
        #expect(abs(d.worldWidth - 200) < 1e-9)
        #expect(abs(d.worldHeight - 100) < 1e-9)
        #expect(abs(d.rotation) < 1e-9)
    }

    @Test("the path/whole-edge convenience initializer derives per-pixel u/v")
    func wholeEdgeInitializer() {
        // Place a 4×2-pixel image whose full bottom edge is (40,0) and left (0,20).
        let d = ImageData(path: "/x.png",
                          lowerLeft: Vector(0, 0),
                          widthVector: Vector(40, 0),
                          heightVector: Vector(0, 20),
                          pixelWidth: 4, pixelHeight: 2)
        // u = edge / pixels → (10, 0); v = (0, 10).
        #expect(approx(d.uVector, Vector(10, 0)))
        #expect(approx(d.vVector, Vector(0, 10)))
        // Corners reconstruct the full edges.
        #expect(approx(d.corners[1], Vector(40, 0)))
        #expect(approx(d.corners[3], Vector(0, 20)))
    }

    // MARK: - resolve

    @Test("resolve emits a textured-quad image + a frame polyline over the corners")
    func resolveEmitsImageAndFrame() {
        let rec = EntityRecord(id: EntityID(1), kind: .image(axisAlignedImage()))
        let geo = rec.resolve(.default)

        #expect(geo.images.count == 1)
        let img = geo.images[0]
        #expect(img.textureKey == "/tmp/pic.png")
        #expect(img.corners.count == 4)
        #expect(!img.placeholder)        // showImage default true + non-empty path

        // A closed frame polyline over the same four corners.
        #expect(geo.polylines.count == 1)
        let frame = geo.polylines[0]
        #expect(frame.closed)
        #expect(frame.points.count == 4)
        #expect(approx(frame.points[0], Vector(10, 20)))
    }

    @Test("a hidden image (showImage == false) resolves to a placeholder, frame kept")
    func resolveHiddenIsPlaceholder() {
        var d = axisAlignedImage()
        d.display.showImage = false
        let geo = EntityRecord(id: EntityID(1), kind: .image(d)).resolve(.default)
        #expect(geo.images.count == 1)
        #expect(geo.images[0].placeholder)        // hidden → placeholder
        #expect(geo.polylines.count == 1)         // frame still drawn
    }

    @Test("an empty path resolves to a placeholder (no crash)")
    func resolveEmptyPathIsPlaceholder() {
        var d = axisAlignedImage()
        d.imageDef.path = ""
        let geo = EntityRecord(id: EntityID(1), kind: .image(d)).resolve(.default)
        #expect(geo.images.count == 1)
        #expect(geo.images[0].placeholder)
        #expect(geo.images[0].textureKey.isEmpty)
    }

    @Test("fade maps to the resolved image's opacity")
    func fadeOpacity() {
        var d = axisAlignedImage()
        d.display.fade = 25
        let img = EntityRecord(id: EntityID(1), kind: .image(d)).resolve(.default).images[0]
        #expect(abs(img.opacity - 0.75) < 1e-6)
    }

    // MARK: - boundingBox

    @Test("boundingBox encloses the quad corners")
    func boundingBoxEnclosesCorners() {
        let box = EntityKind.image(axisAlignedImage()).boundingBox()
        #expect(abs(box.min.x - 10) < 1e-9)
        #expect(abs(box.min.y - 20) < 1e-9)
        #expect(abs(box.max.x - 210) < 1e-9)
        #expect(abs(box.max.y - 120) < 1e-9)
    }

    @Test("a rotated image's box is the rotated quad's extent")
    func boundingBoxRotated() {
        // A 100×100 image rotated 45° about its lower-left at the origin: u along the
        // 45° diagonal so the quad spans a diamond.
        let d = ImageData(path: "/r.png",
                          lowerLeft: Vector(0, 0),
                          widthVector: Vector(angle: .pi / 4) * 100,
                          heightVector: Vector(angle: 3 * .pi / 4) * 100,
                          pixelWidth: 100, pixelHeight: 100)
        let box = EntityKind.image(d).boundingBox()
        // The far corner (LR) is at (cos45, sin45)*100 ≈ (70.71, 70.71); UL at
        // (cos135, sin135)*100 ≈ (-70.71, 70.71); UR is their sum's tip at (0, 141.4).
        #expect(abs(box.min.x - (-70.71)) < 0.1)
        #expect(abs(box.max.x - 70.71) < 0.1)
        #expect(abs(box.min.y - 0) < 0.1)
        #expect(abs(box.max.y - 141.42) < 0.1)
    }

    // MARK: - transform (move / rotate / scale / mirror)

    @Test("translate shifts the insertion, keeps u/v (size + orientation)")
    func transformTranslate() {
        let d = axisAlignedImage()
        let t = Affine2D.translation(Vector(5, 7))
        guard case .image(let m) = EntityKind.image(d).transformed(by: t) else {
            Issue.record("not an image"); return
        }
        #expect(approx(m.insertion, Vector(15, 27)))
        #expect(approx(m.uVector, d.uVector))
        #expect(approx(m.vVector, d.vVector))
        #expect(m.imageDef == d.imageDef)
    }

    @Test("uniform scale about the insertion scales the quad, keeps the corner anchored")
    func transformScale() {
        let d = axisAlignedImage(lowerLeft: Vector(0, 0))
        let t = Affine2D.scale(factor: 2, about: Vector(0, 0))
        guard case .image(let m) = EntityKind.image(d).transformed(by: t) else {
            Issue.record("not an image"); return
        }
        #expect(approx(m.insertion, Vector(0, 0)))   // anchored at the pivot
        // u/v doubled → the quad's far corner doubles.
        #expect(approx(m.corners[2], Vector(400, 200)))
        #expect(abs(m.worldWidth - 400) < 1e-9)
        #expect(abs(m.worldHeight - 200) < 1e-9)
    }

    @Test("rotation spins the placement by the transform's angle")
    func transformRotate() {
        let d = axisAlignedImage(lowerLeft: Vector(0, 0))
        let t = Affine2D.rotation(angle: .pi / 2, about: Vector(0, 0))
        guard case .image(let m) = EntityKind.image(d).transformed(by: t) else {
            Issue.record("not an image"); return
        }
        // The bottom edge (was +x) now points +y → rotation ≈ 90°.
        #expect(abs(Vector.correctAngle(m.rotation) - .pi / 2) < 1e-9)
        // LR corner (was (200,0)) rotates to ≈ (0, 200).
        #expect(approx(m.corners[1], Vector(0, 200), 1e-6))
        // Size preserved.
        #expect(abs(m.worldWidth - 200) < 1e-6)
        #expect(abs(m.worldHeight - 100) < 1e-6)
    }

    @Test("mirror across the y-axis reflects the placement (u flips, quad mirrors)")
    func transformMirror() {
        let d = axisAlignedImage(lowerLeft: Vector(10, 20))
        // Mirror across the vertical line x = 0 (axis through origin at 90°).
        let t = Affine2D.mirror(axisPoint1: Vector(0, 0), axisPoint2: Vector(0, 1))
        guard case .image(let m) = EntityKind.image(d).transformed(by: t) else {
            Issue.record("not an image"); return
        }
        // Insertion reflects to (-10, 20); the +x u-vector reflects to -x.
        #expect(approx(m.insertion, Vector(-10, 20), 1e-6))
        #expect(approx(m.uVector, Vector(-1, 0), 1e-6))
        #expect(approx(m.vVector, Vector(0, 1), 1e-6))
        // The LR corner (was (210,20)) reflects to (-210, 20).
        #expect(approx(m.corners[1], Vector(-210, 20), 1e-6))
    }

    // MARK: - snapping

    @Test("snapping exposes the corners + insertion as endpoints, and the center")
    func snapPoints() {
        let rec = EntityRecord(id: EntityID(1), kind: .image(axisAlignedImage()))
        let ends = Snapping.endpoints(of: rec)
        // 4 corners + the insertion (a 5th point, which equals corner 0).
        #expect(ends.contains { approx($0, Vector(10, 20)) })
        #expect(ends.contains { approx($0, Vector(210, 20)) })
        #expect(ends.contains { approx($0, Vector(210, 120)) })
        #expect(ends.contains { approx($0, Vector(10, 120)) })

        let centers = Snapping.centers(of: rec)
        #expect(centers.count == 1)
        #expect(approx(centers[0], Vector(110, 70)))   // quad center

        // Edge midpoints (the frame's 4 edge mids).
        let mids = Snapping.middles(of: rec, ctx: .default)
        #expect(mids.count == 4)
        #expect(mids.contains { approx($0, Vector(110, 20)) })   // bottom edge mid
        #expect(mids.contains { approx($0, Vector(210, 70)) })   // right edge mid
        #expect(mids.contains { approx($0, Vector(110, 120)) })  // top edge mid
        #expect(mids.contains { approx($0, Vector(10, 70)) })    // left edge mid
    }

    // MARK: - ImageTool (unwired)

    @Test("ImageTool places an image from two clicks keeping the pixel aspect")
    func imageToolPlacesFromTwoClicks() {
        // A 200×100-pixel source; click LL at (0,0) then the bottom-edge corner at
        // (200,0) → a 200-wide image; the height keeps the 100/200 = 0.5 aspect → 100.
        var tool = ImageTool(path: "/photo.png", pixelWidth: 200, pixelHeight: 100)
        // 1st click: lower-left corner (advances state, no commit).
        let o1 = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(o1 == .none)
        // 2nd click: the bottom-edge corner sets width + rotation → commits + adds.
        let o2 = tool.handle(.click(Vector(200, 0)), context: .empty)
        guard case .commit(let edits) = o2, case .add(let rec) = edits.first,
              case .image(let d) = rec.kind else {
            Issue.record("expected a committed .add(.image)"); return
        }
        #expect(d.imageDef.path == "/photo.png")
        // Width edge = (200,0); height keeps the aspect → 100 along +y.
        #expect(approx(d.corners[0], Vector(0, 0)))
        #expect(approx(d.corners[1], Vector(200, 0)))
        #expect(approx(d.corners[3], Vector(0, 100), 1e-6))
        #expect(abs(d.worldWidth - 200) < 1e-6)
        #expect(abs(d.worldHeight - 100) < 1e-6)
    }

    @Test("ImageTool is inert with no file chosen, and previews after the 1st click")
    func imageToolInertAndPreview() {
        var noFile = ImageTool()
        #expect(noFile.handle(.click(Vector(0, 0)), context: .empty) == .none)
        #expect(noFile.preview.isEmpty)

        var tool = ImageTool(path: "/p.png", pixelWidth: 100, pixelHeight: 100)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)   // place LL
        _ = tool.handle(.move(Vector(50, 0)), context: .empty)   // rubber-band
        #expect(!tool.preview.isEmpty)                           // frame quad previewed
        // The preview is a single closed 4-corner frame.
        #expect(tool.preview.count == 1)
        #expect(tool.preview[0].closed)
        #expect(tool.preview[0].points.count == 4)
    }

    // MARK: - Inspector edits

    @Test("inspector edits move / resize / rotate / fade an image")
    func inspectorEdits() {
        let base = EntityKind.image(axisAlignedImage(lowerLeft: Vector(0, 0)))

        // Move.
        if case .image(let d) = InspectorEdits.setImageInsertion(base, Vector(5, 5)) {
            #expect(approx(d.insertion, Vector(5, 5)))
        } else { Issue.record("move failed") }

        // Width: rescale to 100 world units (was 200).
        if case .image(let d) = InspectorEdits.setImageWidth(base, 100) {
            #expect(abs(d.worldWidth - 100) < 1e-6)
            #expect(abs(d.worldHeight - 100) < 1e-6)   // height unchanged
        } else { Issue.record("width failed") }

        // Rotation: aim the bottom edge at 90°.
        if case .image(let d) = InspectorEdits.setImageRotation(base, .pi / 2) {
            #expect(abs(Vector.correctAngle(d.rotation) - .pi / 2) < 1e-9)
            #expect(abs(d.worldWidth - 200) < 1e-6)    // size preserved
        } else { Issue.record("rotation failed") }

        // Fade clamps to 0–100.
        if case .image(let d) = InspectorEdits.setImageFade(base, 250) {
            #expect(d.display.fade == 100)
        } else { Issue.record("fade failed") }
    }

    // MARK: - DXF round-trip (write → read via the bridge)

    @Test("a DXF IMAGE round-trips its path, insertion, u/v and pixel size")
    func dxfImageRoundTrips() async throws {
        let img = ImageData(
            insertion: Vector(100, 50),
            uVector: Vector(0.5, 0),     // 0.5 world-units per pixel
            vVector: Vector(0, 0.5),
            imageDef: ImageDefData(path: "/Users/cad/sample.png",
                                   pixelWidth: 640, pixelHeight: 480),
            display: ImageDisplay(brightness: 60, contrast: 55, fade: 10,
                                  showImage: true, clipping: false))
        let rec = EntityRecord(id: EntityID(1), layer: LayerID("0"), kind: .image(img))
        let layers = LayerTable(layers: [Layer(name: "0")], activeLayerName: "0")

        let outPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-roundtrip-\(UUID().uuidString).dxf").path
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        let writeResult = try await CADEngine.shared.writeEntities(
            [rec], layers: layers, toPath: outPath)
        // The IMAGE is written (not skipped) at R2000.
        #expect(writeResult.skipped == 0)

        let back = try await CADEngine.shared.readEntities(dxfPath: outPath)
        let images = back.records.compactMap { r -> ImageData? in
            if case .image(let d) = r.kind { return d } else { return nil }
        }
        #expect(images.count == 1)
        let d = try #require(images.first)

        // Path round-trips (libdxfrw may normalize separators, so compare the suffix).
        #expect(d.imageDef.path.hasSuffix("sample.png"))
        // Insertion + per-pixel u/v survive.
        #expect(approx(d.insertion, Vector(100, 50), 1e-6))
        #expect(approx(d.uVector, Vector(0.5, 0), 1e-6))
        #expect(approx(d.vVector, Vector(0, 0.5), 1e-6))
        // Pixel size round-trips via the IMAGEDEF.
        #expect(abs(d.imageDef.pixelWidth - 640) < 1e-6)
        #expect(abs(d.imageDef.pixelHeight - 480) < 1e-6)
        // The full edge vectors reconstruct (0.5 * 640 = 320 wide, 0.5 * 480 = 240).
        #expect(abs(d.worldWidth - 320) < 1e-6)
        #expect(abs(d.worldHeight - 240) < 1e-6)
        // Display params round-trip.
        #expect(d.display.brightness == 60)
        #expect(d.display.contrast == 55)
        #expect(d.display.fade == 10)
    }
}
