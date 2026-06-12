//
//  DXFWriterTests.swift
//  CADEngineTests
//
//  Tests for the DXF writer (DXFWriter.swift + the DxfBridge write C ABI). The
//  key test is a full round-trip: read dim_sample.dxf, write it back out, re-read
//  the result, and assert the supported-kind entity counts are preserved
//  (including the TEXT, MTEXT and SOLID kinds the writer now emits). A second test
//  builds a CADDrawing from scratch (line + circle + arc + a custom layer),
//  writes, re-reads, and asserts the geometry round-trips. Dedicated tests assert
//  TEXT, MTEXT, SOLID, and HATCH (the previously-dropped display kinds) now survive
//  the round-trip with their key fields — the MTEXT test exercises BOTH the
//  reconstruct-from-run-tree path (no stored rawCode) and the verbatim rawCode
//  passthrough path.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("DXF writer")
struct DXFWriterTests {

    /// Path to the bundled dim_sample.dxf (copied from
    /// librecad/res/dxf/dim_sample.dxf into the test resources).
    private func samplePath() throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: "dim_sample", withExtension: "dxf"),
            "dim_sample.dxf resource missing from the test bundle"
        )
        return url.path
    }

    /// Path to the bundled hatch_sample.dxf (a crafted minimal fixture: one LINE
    /// plus one solid-fill HATCH with a 10x10 square edge boundary).
    private func hatchSamplePath() throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: "hatch_sample", withExtension: "dxf"),
            "hatch_sample.dxf resource missing from the test bundle"
        )
        return url.path
    }

    /// A fresh temp .dxf path in the system temp dir; the caller cleans it up.
    private func tempDXFPath() -> String {
        let dir = FileManager.default.temporaryDirectory
        let name = "dxfwriter-test-\(UUID().uuidString).dxf"
        return dir.appendingPathComponent(name).path
    }

    private func removeFile(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Per-kind tally over the supported set.

    private struct KindTally: Equatable {
        var line = 0, point = 0, circle = 0, arc = 0, ellipse = 0, polyline = 0
        var text = 0, mtext = 0, solid = 0, hatch = 0, dimension = 0
        /// The supported set the writer emits (spline/splinePoints excluded; MTEXT
        /// and DIMENSION are now written, so they count toward the round-trippable
        /// total).
        var supportedTotal: Int {
            line + point + circle + arc + ellipse + polyline
                + text + mtext + solid + hatch + dimension
        }
    }

    private func tally(_ records: [EntityRecord]) -> KindTally {
        var t = KindTally()
        for r in records {
            switch r.kind {
            case .line:         t.line += 1
            case .point:        t.point += 1
            case .circle:       t.circle += 1
            case .arc:          t.arc += 1
            case .ellipse:      t.ellipse += 1
            case .polyline:     t.polyline += 1
            case .text:         t.text += 1      // now written (DRW_Text)
            case .mtext:        t.mtext += 1     // now written (DRW_MText)
            case .solid:        t.solid += 1     // now written (DRW_Solid)
            case .hatch:        t.hatch += 1     // now written (DRW_Hatch)
            case .dimension:    t.dimension += 1 // now written (DRW_Dim*)
            case .spline, .splinePoints: break   // still skipped by the writer
            }
        }
        return t
    }

    // MARK: - The key round-trip test.

    @Test("round-trips supported entity counts through read -> write -> read")
    func roundTripsSampleCounts() async throws {
        // First read: the source-of-truth supported-kind counts.
        let first = try await CADEngine.shared.readEntities(dxfPath: samplePath())
        let firstTally = tally(first.records)
        // The sample carries real supported geometry to round-trip.
        #expect(firstTally.supportedTotal > 0)
        #expect(firstTally.line >= 1)
        #expect(firstTally.circle >= 1)
        #expect(firstTally.arc >= 1)
        #expect(firstTally.polyline >= 1)

        // dim_sample carries MTEXT (-> .mtext, now WRITTEN as DRW_MText) and SOLID
        // (-> .solid, written), so both should round-trip.
        #expect(firstTally.mtext >= 1)
        #expect(firstTally.solid >= 1)
        // …and the 14 DimKind-modelled DIMENSION entities (-> .dimension, now
        // WRITTEN as DRW_Dim*).
        #expect(firstTally.dimension == 14)

        let outPath = tempDXFPath()
        defer { removeFile(outPath) }

        // Write everything the reader produced. dim_sample has no splines; MTEXT
        // and DIMENSION are now emitted (R2000 default), so only spline kinds
        // (none here) are skipped.
        let writeResult = try await CADEngine.shared.writeEntities(
            first.records, layers: first.layers, toPath: outPath
        )
        let unsupported = first.records.filter {
            switch $0.kind {
            case .spline, .splinePoints: return true
            default: return false
            }
        }.count
        // MTEXT and DIMENSION no longer count as skipped.
        #expect(writeResult.skipped == unsupported)
        #expect(FileManager.default.fileExists(atPath: outPath))

        // Re-read and compare the supported-kind tallies exactly.
        let second = try await CADEngine.shared.readEntities(dxfPath: outPath)
        let secondTally = tally(second.records)

        #expect(secondTally.line == firstTally.line)
        #expect(secondTally.circle == firstTally.circle)
        #expect(secondTally.arc == firstTally.arc)
        #expect(secondTally.polyline == firstTally.polyline)
        #expect(secondTally.ellipse == firstTally.ellipse)
        // The previously-dropped display kinds now survive the round-trip.
        #expect(secondTally.text == firstTally.text)
        #expect(secondTally.mtext == firstTally.mtext)
        #expect(secondTally.solid == firstTally.solid)
        // Dimensions survive the round-trip as `.dimension` (the writer no longer
        // drops them).
        #expect(secondTally.dimension == firstTally.dimension)
        #expect(secondTally.supportedTotal == firstTally.supportedTotal)
    }

    @Test("written file preserves the layer table")
    func roundTripsLayers() async throws {
        let first = try await CADEngine.shared.readEntities(dxfPath: samplePath())
        let outPath = tempDXFPath()
        defer { removeFile(outPath) }
        _ = try await CADEngine.shared.writeEntities(
            first.records, layers: first.layers, toPath: outPath
        )
        let second = try await CADEngine.shared.readEntities(dxfPath: outPath)
        // Layer "0" must survive, and the named layers from the source should too.
        #expect(second.layers.contains("0"))
        for layer in first.layers.layers {
            #expect(second.layers.contains(layer.name),
                    "layer \(layer.name) missing after round-trip")
        }
    }

    // MARK: - Direct build -> write -> read geometry round-trip.

    @Test("a hand-built drawing round-trips geometry")
    func roundTripsBuiltGeometry() async throws {
        // Build value records directly (ids minted explicitly).
        let line = EntityRecord(
            id: EntityID(1),
            layer: LayerID("walls"),
            kind: .line(LineData(start: Vector(1, 2), end: Vector(10, 20)))
        )
        let circle = EntityRecord(
            id: EntityID(2),
            layer: LayerID("0"),
            kind: .circle(CircleData(center: Vector(5, 5), radius: 3.5))
        )
        let arc = EntityRecord(
            id: EntityID(3),
            layer: LayerID("0"),
            kind: .arc(ArcData(center: Vector(0, 0), radius: 2,
                               startAngle: 0, endAngle: .pi / 2))
        )
        let records = [line, circle, arc]

        var layers = LayerTable(layers: [Layer(name: "0"), Layer(name: "walls")],
                                activeLayerName: "0")
        _ = layers   // (table built explicitly to exercise the layer writer)

        let outPath = tempDXFPath()
        defer { removeFile(outPath) }

        let result = try await CADEngine.shared.writeEntities(
            records, layers: layers, toPath: outPath
        )
        #expect(result.skipped == 0)
        #expect(result.written == 3)

        let back = try await CADEngine.shared.readEntities(dxfPath: outPath)
        let t = tally(back.records)
        #expect(t.line == 1)
        #expect(t.circle == 1)
        #expect(t.arc == 1)
        #expect(back.layers.contains("walls"))

        // Verify the actual geometry values survived (within tolerance).
        let tol = 1e-6
        for r in back.records {
            switch r.kind {
            case .line(let d):
                #expect(abs(d.start.x - 1) < tol)
                #expect(abs(d.start.y - 2) < tol)
                #expect(abs(d.end.x - 10) < tol)
                #expect(abs(d.end.y - 20) < tol)
            case .circle(let d):
                #expect(abs(d.center.x - 5) < tol)
                #expect(abs(d.center.y - 5) < tol)
                #expect(abs(d.radius - 3.5) < tol)
            case .arc(let d):
                #expect(abs(d.center.x) < tol)
                #expect(abs(d.center.y) < tol)
                #expect(abs(d.radius - 2) < tol)
                #expect(abs(d.startAngle) < tol)
                #expect(abs(d.endAngle - .pi / 2) < tol)
            default:
                break
            }
        }
    }

    @Test("a polyline with bulges round-trips")
    func roundTripsPolyline() async throws {
        let verts = [
            PolylineVertex(point: Vector(0, 0), bulge: 0),
            PolylineVertex(point: Vector(10, 0), bulge: 0.5),
            PolylineVertex(point: Vector(10, 10), bulge: 0),
        ]
        let poly = EntityRecord(
            id: EntityID(1),
            kind: .polyline(PolylineData(vertices: verts, closed: true))
        )
        let outPath = tempDXFPath()
        defer { removeFile(outPath) }

        _ = try await CADEngine.shared.writeEntities(
            [poly], layers: LayerTable(), toPath: outPath
        )
        let back = try await CADEngine.shared.readEntities(dxfPath: outPath)
        let polys = back.records.compactMap { r -> PolylineData? in
            if case .polyline(let d) = r.kind { return d } else { return nil }
        }
        let d = try #require(polys.first, "polyline missing after round-trip")
        #expect(d.closed)
        #expect(d.vertices.count == verts.count)
        let tol = 1e-6
        for (a, b) in zip(d.vertices, verts) {
            #expect(abs(a.point.x - b.point.x) < tol)
            #expect(abs(a.point.y - b.point.y) < tol)
            #expect(abs(a.bulge - b.bulge) < tol)
        }
    }

    // MARK: - Display-kind round-trips (TEXT / SOLID / HATCH).

    @Test("a hand-built text entity round-trips its key fields")
    func roundTripsText() async throws {
        let textRec = EntityRecord(
            id: EntityID(1),
            layer: LayerID("annot"),
            kind: .text(TextData(
                position: Vector(3, 4),
                height: 2.5,
                rotation: .pi / 6,
                text: "HELLO DXF",
                styleName: "STANDARD",
                hAlign: .center,
                vAlign: .middle
            ))
        )
        let outPath = tempDXFPath()
        defer { removeFile(outPath) }

        let result = try await CADEngine.shared.writeEntities(
            [textRec], layers: LayerTable(layers: [Layer(name: "0"), Layer(name: "annot")],
                                          activeLayerName: "0"),
            toPath: outPath
        )
        #expect(result.written == 1)
        #expect(result.skipped == 0)

        let back = try await CADEngine.shared.readEntities(dxfPath: outPath)
        let texts = back.records.compactMap { r -> TextData? in
            if case .text(let d) = r.kind { return d } else { return nil }
        }
        let d = try #require(texts.first, "text missing after round-trip")
        let tol = 1e-6
        #expect(d.text == "HELLO DXF")
        #expect(abs(d.position.x - 3) < tol)
        #expect(abs(d.position.y - 4) < tol)
        #expect(abs(d.height - 2.5) < tol)
        #expect(abs(d.rotation - .pi / 6) < 1e-9)
        #expect(d.hAlign == .center)
        #expect(d.vAlign == .middle)
    }

    // MARK: - MTEXT round-trip (reconstruct-from-run-tree + rawCode passthrough).

    /// Concatenate the plain (decode-expanded) text of all `.run` inlines in a
    /// paragraph — the "line" content, ignoring per-run formatting.
    private func paragraphText(_ p: MTextParagraph) -> String {
        p.inlines.reduce(into: "") { acc, inline in
            if case .run(let r) = inline { acc += r.text }
        }
    }

    @Test("MTEXTwrite: a hand-built multi-line formatted mtext round-trips as .mtext")
    func mtextWriteRoundTripsRunTree() async throws {
        // Build a MULTI-LINE mtext (two paragraphs via \P) with a FORMATTING code
        // (a bold red middle run) and NO stored rawCode, so the writer must
        // RECONSTRUCT the coded string from the run tree (MTextEncoder).
        let para1 = MTextParagraph(inlines: [
            .run(TextRun(text: "First ")),
            .run(TextRun(text: "BOLD", bold: true, italic: false)),  // \f...|b1|i0; formatting
            .run(TextRun(text: " line")),
        ])
        let para2 = MTextParagraph(inlines: [
            .run(TextRun(text: "Second line")),
        ])
        let mtextRec = EntityRecord(
            id: EntityID(1),
            layer: LayerID("annot"),
            kind: .mtext(MTextData(
                position: Vector(7, 8),
                height: 3.0,
                rectWidth: 50,
                rotation: .pi / 4,
                styleName: "STANDARD",
                attachment: .middleCenter,
                lineSpacingStyle: .exact,
                lineSpacingFactor: 1.5,
                paragraphs: [para1, para2],
                rawCode: nil))            // force the reconstruct-from-run-tree path
        )
        let outPath = tempDXFPath()
        defer { removeFile(outPath) }

        let result = try await CADEngine.shared.writeEntities(
            [mtextRec],
            layers: LayerTable(layers: [Layer(name: "0"), Layer(name: "annot")],
                               activeLayerName: "0"),
            toPath: outPath
        )
        #expect(result.written == 1)   // MTEXT is now written, not skipped
        #expect(result.skipped == 0)

        let back = try await CADEngine.shared.readEntities(dxfPath: outPath)
        let mtexts = back.records.compactMap { r -> MTextData? in
            if case .mtext(let d) = r.kind { return d } else { return nil }
        }
        let d = try #require(mtexts.first, "mtext missing after round-trip")

        let tol = 1e-6
        // Block-level layout survived.
        #expect(abs(d.position.x - 7) < tol)
        #expect(abs(d.position.y - 8) < tol)
        #expect(abs(d.height - 3.0) < tol)
        #expect(abs(d.rectWidth - 50) < tol)
        #expect(abs(d.rotation - .pi / 4) < 1e-9)
        #expect(d.attachment == .middleCenter)
        #expect(d.lineSpacingStyle == .exact)
        #expect(abs(d.lineSpacingFactor - 1.5) < tol)

        // Two LINES (paragraphs) survived, with matching text content per line.
        #expect(d.paragraphs.count == 2)
        #expect(paragraphText(d.paragraphs[0]) == "First BOLD line")
        #expect(paragraphText(d.paragraphs[1]) == "Second line")

        // The formatting code survived: a run carries the bold flag.
        let allRuns = d.paragraphs.flatMap { p in
            p.inlines.compactMap { i -> TextRun? in
                if case .run(let r) = i { return r } else { return nil }
            }
        }
        #expect(allRuns.contains { $0.text == "BOLD" && $0.bold == true })
    }

    @Test("MTEXTwrite: a preserved rawCode mtext round-trips verbatim")
    func mtextWriteRoundTripsRawCode() async throws {
        // An entity carrying a verbatim rawCode (the lossless-passthrough path the
        // reader uses): the writer emits THAT string, so the re-read coded string
        // matches exactly and the parsed paragraphs reproduce the lines.
        let raw = "Alpha\\PBeta {\\C1;red} gamma"
        let data = MTextParser.makeData(
            coded: raw,
            position: Vector(1, 1),
            height: 2.0,
            attachment: .bottomRight)
        #expect(data.rawCode == raw)   // makeData preserves it

        let mtextRec = EntityRecord(id: EntityID(1), kind: .mtext(data))
        let outPath = tempDXFPath()
        defer { removeFile(outPath) }

        let result = try await CADEngine.shared.writeEntities(
            [mtextRec], layers: LayerTable(), toPath: outPath
        )
        #expect(result.written == 1)
        #expect(result.skipped == 0)

        let back = try await CADEngine.shared.readEntities(dxfPath: outPath)
        let d = try #require(back.records.compactMap { r -> MTextData? in
            if case .mtext(let m) = r.kind { return m } else { return nil }
        }.first, "mtext missing after round-trip")

        // The raw coded string survived verbatim (lossless passthrough).
        #expect(d.rawCode == raw)
        // …and it parses back into the two lines.
        #expect(d.paragraphs.count == 2)
        #expect(paragraphText(d.paragraphs[0]) == "Alpha")
        #expect(d.attachment == .bottomRight)
    }

    @Test("a hand-built solid (triangle + quad) round-trips its corners")
    func roundTripsSolid() async throws {
        let tri = EntityRecord(
            id: EntityID(1),
            kind: .solid(SolidData(corners: [Vector(0, 0), Vector(10, 0), Vector(5, 8)]))
        )
        let quad = EntityRecord(
            id: EntityID(2),
            kind: .solid(SolidData(corners: [Vector(0, 0), Vector(10, 0),
                                             Vector(10, 10), Vector(0, 10)]))
        )
        let outPath = tempDXFPath()
        defer { removeFile(outPath) }

        let result = try await CADEngine.shared.writeEntities(
            [tri, quad], layers: LayerTable(), toPath: outPath
        )
        #expect(result.written == 2)
        #expect(result.skipped == 0)

        let back = try await CADEngine.shared.readEntities(dxfPath: outPath)
        let solids = back.records.compactMap { r -> [Vector]? in
            if case .solid(let d) = r.kind { return d.corners } else { return nil }
        }
        #expect(solids.count == 2)

        // Compare corner SETS (the bow-tie swap is applied symmetrically on
        // write and un-applied on read, so the ring order round-trips exactly).
        let tol = 1e-6
        func sameRing(_ a: [Vector], _ b: [Vector]) -> Bool {
            guard a.count == b.count else { return false }
            return zip(a, b).allSatisfy { abs($0.x - $1.x) < tol && abs($0.y - $1.y) < tol }
        }
        #expect(solids.contains { sameRing($0, [Vector(0, 0), Vector(10, 0), Vector(5, 8)]) })
        #expect(solids.contains {
            sameRing($0, [Vector(0, 0), Vector(10, 0), Vector(10, 10), Vector(0, 10)])
        })
    }

    @Test("a hand-built solid-fill hatch round-trips its boundary loop")
    func roundTripsHatch() async throws {
        let ring = [
            PolylineVertex(point: Vector(0, 0)),
            PolylineVertex(point: Vector(10, 0)),
            PolylineVertex(point: Vector(10, 10)),
            PolylineVertex(point: Vector(0, 10)),
        ]
        let hatchRec = EntityRecord(
            id: EntityID(1),
            kind: .hatch(HatchData(loops: [ring], solidFill: true, patternName: "SOLID"))
        )
        let outPath = tempDXFPath()
        defer { removeFile(outPath) }

        let result = try await CADEngine.shared.writeEntities(
            [hatchRec], layers: LayerTable(), toPath: outPath
        )
        #expect(result.written == 1)
        #expect(result.skipped == 0)

        let back = try await CADEngine.shared.readEntities(dxfPath: outPath)
        let hatches = back.records.compactMap { r -> HatchData? in
            if case .hatch(let d) = r.kind { return d } else { return nil }
        }
        let d = try #require(hatches.first, "hatch missing after round-trip")
        #expect(d.solidFill)
        #expect(d.loops.count == 1)
        // The 4 ring vertices survive (edge-line boundary: each edge's start
        // point is read back, recovering the original ring).
        let pts = d.loops[0].map(\.point)
        #expect(pts.count == 4)
        let tol = 1e-6
        for (a, b) in zip(pts, ring.map(\.point)) {
            #expect(abs(a.x - b.x) < tol)
            #expect(abs(a.y - b.y) < tol)
        }
    }

    @Test("the crafted hatch_sample fixture round-trips through write")
    func roundTripsHatchFixture() async throws {
        let first = try await CADEngine.shared.readEntities(dxfPath: try hatchSamplePath())
        let firstTally = tally(first.records)
        // The fixture carries at least one HATCH (plus a LINE).
        #expect(firstTally.hatch >= 1)

        let outPath = tempDXFPath()
        defer { removeFile(outPath) }
        let result = try await CADEngine.shared.writeEntities(
            first.records, layers: first.layers, toPath: outPath
        )
        #expect(result.skipped == 0)

        let second = try await CADEngine.shared.readEntities(dxfPath: outPath)
        let secondTally = tally(second.records)
        #expect(secondTally.hatch == firstTally.hatch)
        #expect(secondTally.line == firstTally.line)
    }

    // MARK: - DIMENSION round-trips (linear / aligned / radial / diameter / angular).

    /// Recompute the measured value of a `DimKind` from its defining points,
    /// mirroring what `resolve()` measures (linear/aligned = distance; radial =
    /// radius; diameter = |p1-p2|; angular = subtended angle in radians). Used to
    /// assert the measurement survives the round-trip (it is recomputed on read,
    /// never stored, so equal defining points => equal measure).
    private func measure(_ kind: DimKind) -> Double {
        switch kind {
        case let .linear(e1, e2, angle):
            // Distance projected onto the dimension-line direction (angle).
            let dir = Vector(angle: angle)
            return abs((e2 - e1).dot(dir))
        case let .aligned(e1, e2):
            return (e2 - e1).magnitude
        case let .radial(center, pointOnCircle):
            return (pointOnCircle - center).magnitude
        case let .diameter(p1, p2):
            return (p2 - p1).magnitude
        case let .angular(l1s, l1e, l2s, l2e):
            let a1 = (l1e - l1s).angle
            let a2 = (l2e - l2s).angle
            return abs(Vector.correctAngle(a2 - a1))
        }
    }

    @Test("DIMwrite: a linear, radial, and angular dimension survive read->write->read")
    func dimensionRoundTrips() async throws {
        // A LINEAR dimension: horizontal distance between (0,0) and (10,0),
        // dim line offset up to y=5. Explicit text override + style to exercise the
        // shared base-field round-trip.
        let linear = EntityRecord(
            id: EntityID(1),
            layer: LayerID("dims"),
            kind: .dimension(DimData(
                kind: .linear(extension1: Vector(0, 0), extension2: Vector(10, 0), angle: 0),
                definitionPoint: Vector(5, 5),
                textOverride: "10.0",
                styleName: "STANDARD",
                attachmentPoint: .middleCenter))
        )
        // A RADIAL dimension: radius from center (20,20) to a point on the circle.
        let radial = EntityRecord(
            id: EntityID(2),
            layer: LayerID("dims"),
            kind: .dimension(DimData(
                kind: .radial(center: Vector(20, 20), pointOnCircle: Vector(25, 20)),
                definitionPoint: Vector(25, 20)))
        )
        // An ANGULAR dimension: angle between two lines meeting at (0,30); arc
        // through the definitionPoint.
        let angular = EntityRecord(
            id: EntityID(3),
            layer: LayerID("dims"),
            kind: .dimension(DimData(
                kind: .angular(line1Start: Vector(0, 30), line1End: Vector(10, 30),
                               line2Start: Vector(0, 30), line2End: Vector(10, 40)),
                definitionPoint: Vector(5, 35)))
        )
        let records = [linear, radial, angular]

        let outPath = tempDXFPath()
        defer { removeFile(outPath) }

        let result = try await CADEngine.shared.writeEntities(
            records,
            layers: LayerTable(layers: [Layer(name: "0"), Layer(name: "dims")],
                               activeLayerName: "0"),
            toPath: outPath
        )
        // All three written, none skipped — dimensions are no longer dropped.
        #expect(result.written == 3)
        #expect(result.skipped == 0)

        let back = try await CADEngine.shared.readEntities(dxfPath: outPath)
        let dims = back.records.compactMap { r -> DimData? in
            if case .dimension(let d) = r.kind { return d } else { return nil }
        }
        #expect(dims.count == 3)

        let tol = 1e-6

        // LINEAR survived as `.linear` with its extension points + angle + measure.
        let l = try #require(dims.first { if case .linear = $0.kind { return true }; return false },
                             "linear dimension missing after round-trip")
        if case let .linear(e1, e2, angle) = l.kind {
            #expect(abs(e1.x - 0) < tol && abs(e1.y - 0) < tol)
            #expect(abs(e2.x - 10) < tol && abs(e2.y - 0) < tol)
            #expect(abs(angle - 0) < tol)
        }
        #expect(abs(l.definitionPoint.x - 5) < tol && abs(l.definitionPoint.y - 5) < tol)
        #expect(l.textOverride == "10.0")
        #expect(l.styleName == "STANDARD")
        #expect(abs(measure(l.kind) - 10.0) < tol)

        // RADIAL survived as `.radial` with center + point + radius measure.
        let r = try #require(dims.first { if case .radial = $0.kind { return true }; return false },
                             "radial dimension missing after round-trip")
        if case let .radial(center, pt) = r.kind {
            #expect(abs(center.x - 20) < tol && abs(center.y - 20) < tol)
            #expect(abs(pt.x - 25) < tol && abs(pt.y - 20) < tol)
        }
        #expect(abs(measure(r.kind) - 5.0) < tol)   // radius == 5

        // ANGULAR survived as `.angular` with its four line points + arc point
        // (definitionPoint) + the 90° subtended angle.
        let a = try #require(dims.first { if case .angular = $0.kind { return true }; return false },
                             "angular dimension missing after round-trip")
        if case let .angular(l1s, l1e, l2s, l2e) = a.kind {
            #expect(abs(l1s.x - 0) < tol && abs(l1s.y - 30) < tol)
            #expect(abs(l1e.x - 10) < tol && abs(l1e.y - 30) < tol)
            #expect(abs(l2s.x - 0) < tol && abs(l2s.y - 30) < tol)
            #expect(abs(l2e.x - 10) < tol && abs(l2e.y - 40) < tol)
        }
        #expect(abs(a.definitionPoint.x - 5) < tol && abs(a.definitionPoint.y - 35) < tol)
        #expect(abs(measure(a.kind) - .pi / 4) < 1e-9)   // 45° between horizontal and the diagonal
    }

    @Test("DIMwrite: aligned + diameter dimensions also round-trip")
    func alignedAndDiameterRoundTrip() async throws {
        // ALIGNED: distance measured parallel to the line through the two points.
        let aligned = EntityRecord(
            id: EntityID(1),
            kind: .dimension(DimData(
                kind: .aligned(extension1: Vector(0, 0), extension2: Vector(3, 4)),
                definitionPoint: Vector(1, 5)))
        )
        // DIAMETER: across a circle through the two opposite points.
        let diameter = EntityRecord(
            id: EntityID(2),
            kind: .dimension(DimData(
                kind: .diameter(point1: Vector(0, 0), point2: Vector(8, 0)),
                definitionPoint: Vector(8, 0)))
        )
        let outPath = tempDXFPath()
        defer { removeFile(outPath) }

        let result = try await CADEngine.shared.writeEntities(
            [aligned, diameter], layers: LayerTable(), toPath: outPath
        )
        #expect(result.written == 2)
        #expect(result.skipped == 0)

        let back = try await CADEngine.shared.readEntities(dxfPath: outPath)
        let dims = back.records.compactMap { r -> DimData? in
            if case .dimension(let d) = r.kind { return d } else { return nil }
        }
        #expect(dims.count == 2)
        let tol = 1e-6

        let al = try #require(dims.first { if case .aligned = $0.kind { return true }; return false },
                              "aligned dimension missing after round-trip")
        if case let .aligned(e1, e2) = al.kind {
            #expect(abs(e1.x - 0) < tol && abs(e1.y - 0) < tol)
            #expect(abs(e2.x - 3) < tol && abs(e2.y - 4) < tol)
        }
        #expect(abs(measure(al.kind) - 5.0) < tol)   // 3-4-5 distance

        let di = try #require(dims.first { if case .diameter = $0.kind { return true }; return false },
                              "diameter dimension missing after round-trip")
        if case let .diameter(p1, p2) = di.kind {
            #expect(abs(p1.x - 0) < tol && abs(p1.y - 0) < tol)
            #expect(abs(p2.x - 8) < tol && abs(p2.y - 0) < tol)
        }
        #expect(abs(measure(di.kind) - 8.0) < tol)   // diameter == 8
    }

    // MARK: - Skipped kinds are counted, not fatal.

    @Test("unsupported kinds are skipped and counted")
    func skipsUnsupportedKinds() async throws {
        let spline = EntityRecord(
            id: EntityID(1),
            kind: .spline(SplineData(
                degree: 3,
                controlPoints: [Vector(0, 0), Vector(1, 1), Vector(2, 0), Vector(3, 1)]
            ))
        )
        let line = EntityRecord(
            id: EntityID(2),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 1)))
        )
        let outPath = tempDXFPath()
        defer { removeFile(outPath) }

        let result = try await CADEngine.shared.writeEntities(
            [spline, line], layers: LayerTable(), toPath: outPath
        )
        #expect(result.skipped == 1)   // the spline
        #expect(result.written == 1)   // the line

        let back = try await CADEngine.shared.readEntities(dxfPath: outPath)
        #expect(tally(back.records).line == 1)
    }

    // MARK: - High-level save helper + error path.

    @MainActor
    @Test("writeDrawing saves a loaded drawing")
    func writeDrawingSaves() async throws {
        let drawing = try await loadDrawing(dxfPath: samplePath())
        let supportedBefore = drawing.entities.filter { isSupported($0) }.count
        #expect(supportedBefore > 0)

        let outPath = tempDXFPath()
        defer { removeFile(outPath) }

        let result = try await writeDrawing(drawing, toPath: outPath)
        #expect(result.written == supportedBefore)
        #expect(FileManager.default.fileExists(atPath: outPath))

        // The saved file re-opens as a non-empty drawing.
        let reopened = try await loadDrawing(dxfPath: outPath)
        #expect(reopened.count > 0)
    }

    @Test("empty path throws invalidPath")
    func emptyPathThrows() async throws {
        await #expect(throws: CADWriteError.invalidPath) {
            _ = try await CADEngine.shared.writeEntities(
                [], layers: LayerTable(), toPath: ""
            )
        }
    }

    // Whether a record's kind is in the writer's supported set.
    private func isSupported(_ r: EntityRecord) -> Bool {
        switch r.kind {
        case .line, .point, .circle, .arc, .ellipse, .polyline,
             .text, .mtext, .solid, .hatch, .dimension: return true
        case .spline, .splinePoints: return false
        }
    }
}
