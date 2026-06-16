//
//  SymbolGenerator.swift
//  CADBench
//
//  OFFLINE, AUTHOR-TIME generator for the bundled starter symbol library
//  (backlog #6). Builds ~10-12 simple, recognizable architectural/electrical
//  symbols from primitive lines / arcs / circles / polylines, and writes each to
//  `macos/assets/symbols/<name>.dxf` through the EXISTING engine block-export
//  seam (`BlockExport.writeRecords`). The generated `.dxf` files are COMMITTED;
//  this generator never runs at app runtime (libdxfrw is non-reentrant on the
//  shared engine — the symbols are produced once, serially, and checked in).
//
//  ## Why a CADBench subcommand?
//  CADBench is the project's existing offline executable target. Adding the
//  generator here (rather than a new SwiftPM target) keeps `Package.swift`
//  untouched and `swift test` unaffected. Run it explicitly:
//      swift run --package-path macos/engine --disable-sandbox CADBench gen-symbols
//  (optionally pass an output directory:  ... CADBench gen-symbols /path/to/out)
//
//  ## Units & frame
//  Every symbol is authored in millimetres at a sensible real-world size and
//  centred near the origin so it inserts cleanly at the cursor. Geometry uses
//  only the four primitive `EntityKind` cases line / arc / circle / polyline —
//  NO new EntityKind. `BlockExport.writeRecords(basePoint:)` re-bases each file
//  so the symbol's base point lands on (0,0); we pass the design base point per
//  symbol (usually its natural insertion/origin point).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation
import CADEngine

// MARK: - One symbol's definition

/// A single starter symbol: a file base name, the geometry records, and the
/// base point the file is re-based around (the symbol's natural insertion point).
struct SymbolDef {
    let fileName: String          // e.g. "Door" -> Door.dxf
    let basePoint: Vector         // re-based to (0,0) on export / restored on import
    let records: [EntityRecord]
}

// MARK: - Primitive builders (id 0 => the writer mints; we only need geometry)

private func ln(_ a: Vector, _ b: Vector) -> EntityRecord {
    EntityRecord(id: EntityID(0), kind: .line(LineData(start: a, end: b)))
}

private func circ(_ c: Vector, _ r: Double) -> EntityRecord {
    EntityRecord(id: EntityID(0), kind: .circle(CircleData(center: c, radius: r)))
}

/// An arc, angles in DEGREES (converted to the radians `ArcData` stores), CCW
/// from `start` to `end` (the default DXF orientation).
private func arc(_ c: Vector, _ r: Double, _ startDeg: Double, _ endDeg: Double) -> EntityRecord {
    let toRad = Double.pi / 180.0
    return EntityRecord(id: EntityID(0),
                        kind: .arc(ArcData(center: c, radius: r,
                                           startAngle: startDeg * toRad,
                                           endAngle: endDeg * toRad)))
}

/// A polyline through the given points (straight segments). `closed` joins last→first.
private func poly(_ pts: [Vector], closed: Bool = false) -> EntityRecord {
    EntityRecord(id: EntityID(0),
                 kind: .polyline(PolylineData(vertices: pts.map { PolylineVertex(point: $0) },
                                              closed: closed)))
}

/// A closed rectangle polyline with corners (x0,y0)-(x1,y1).
private func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> EntityRecord {
    poly([Vector(x0, y0), Vector(x1, y0), Vector(x1, y1), Vector(x0, y1)], closed: true)
}

// MARK: - The starter catalog

enum SymbolCatalog {

    /// All starter symbols. Sizes are in millimetres at common architectural /
    /// electrical drafting scales. Each is simple but recognizable.
    static func all() -> [SymbolDef] {
        [
            door(),
            window(),
            duplexReceptacle(),
            singlePoleSwitch(),
            table(),
            chair(),
            roundTable(),
            sink(),
            lightFixture(),
            northArrow(),
            leaderArrow(),
            doubleDoor(),
        ]
    }

    // MARK: Architectural

    /// A 900 mm single swing door: jamb line at the hinge, the leaf shown open
    /// (vertical), and the swing arc from the leaf tip to the closed position.
    /// Base point = the hinge (origin of the swing).
    private static func door() -> SymbolDef {
        let w = 900.0
        let hinge = Vector(0, 0)
        let leafOpen = Vector(0, w)        // leaf swung 90° open (pointing up)
        let closed = Vector(w, 0)          // where the leaf tip would be when shut
        return SymbolDef(
            fileName: "Door",
            basePoint: hinge,
            records: [
                ln(hinge, Vector(0, -50)),      // jamb stub at the hinge
                ln(hinge, leafOpen),            // the open leaf
                arc(hinge, w, 0, 90),           // swing arc (closed -> open), CCW
                ln(closed, Vector(w, -50)),     // strike-side jamb stub
            ])
    }

    /// A 1500 mm double (French) door: two 750 mm leaves meeting in the middle,
    /// each with its swing arc. Base point = the centre of the opening.
    private static func doubleDoor() -> SymbolDef {
        let half = 750.0
        let leftHinge = Vector(-half, 0)
        let rightHinge = Vector(half, 0)
        return SymbolDef(
            fileName: "Double Door",
            basePoint: Vector(0, 0),
            records: [
                ln(leftHinge, Vector(0, half)),    // left leaf open (toward centre-up)
                arc(leftHinge, half, 0, 90),       // left swing
                ln(rightHinge, Vector(0, half)),   // right leaf open
                arc(rightHinge, half, 90, 180),    // right swing
                ln(leftHinge, Vector(-half, -40)), // jamb stubs
                ln(rightHinge, Vector(half, -40)),
            ])
    }

    /// A 1200 mm single window in a wall: outer frame rectangle (wall thickness
    /// 150 mm) plus the centre mullion / glazing line. Base point = mid-left of
    /// the sill.
    private static func window() -> SymbolDef {
        let w = 1200.0, t = 150.0
        return SymbolDef(
            fileName: "Window",
            basePoint: Vector(0, 0),
            records: [
                rect(0, 0, w, t),               // wall opening frame
                ln(Vector(0, t / 2), Vector(w, t / 2)),   // glazing centre line
            ])
    }

    /// A 1500×750 mm rectangular table. Base point = the lower-left corner.
    private static func table() -> SymbolDef {
        SymbolDef(fileName: "Table", basePoint: Vector(0, 0),
                  records: [ rect(0, 0, 1500, 750) ])
    }

    /// A 450×450 mm chair: seat square plus a back-rest line on the top edge.
    /// Base point = the seat centre.
    private static func chair() -> SymbolDef {
        let s = 450.0, h = s / 2
        return SymbolDef(
            fileName: "Chair",
            basePoint: Vector(0, 0),
            records: [
                rect(-h, -h, h, h),                       // seat
                ln(Vector(-h, h), Vector(h, h)),          // back rest (top edge, doubled)
                ln(Vector(-h, h * 1.1), Vector(h, h * 1.1)),
            ])
    }

    /// A round table, 1000 mm diameter. Base point = centre.
    private static func roundTable() -> SymbolDef {
        SymbolDef(fileName: "Round Table", basePoint: Vector(0, 0),
                  records: [ circ(Vector(0, 0), 500) ])
    }

    /// A kitchen sink: 600×500 mm counter rectangle with a circular basin.
    /// Base point = lower-left.
    private static func sink() -> SymbolDef {
        let w = 600.0, d = 500.0
        return SymbolDef(
            fileName: "Sink",
            basePoint: Vector(0, 0),
            records: [
                rect(0, 0, w, d),                         // counter
                circ(Vector(w / 2, d / 2), 180),          // basin
                ln(Vector(w / 2, d - 40), Vector(w / 2, d + 10)),  // tap
            ])
    }

    // MARK: Electrical

    /// A duplex receptacle (US outlet symbol): a circle with two short parallel
    /// leads. Base point = the circle centre. Drawn at ~10 mm symbol size.
    private static func duplexReceptacle() -> SymbolDef {
        let r = 5.0
        return SymbolDef(
            fileName: "Duplex Receptacle",
            basePoint: Vector(0, 0),
            records: [
                circ(Vector(0, 0), r),
                ln(Vector(-2, -r), Vector(-2, -r - 4)),    // two leads
                ln(Vector(2, -r), Vector(2, -r - 4)),
            ])
    }

    /// A single-pole switch (S): a small circle with a lever line. Base point =
    /// the circle centre. ~8 mm.
    private static func singlePoleSwitch() -> SymbolDef {
        let r = 4.0
        return SymbolDef(
            fileName: "Switch",
            basePoint: Vector(0, 0),
            records: [
                circ(Vector(0, 0), r),
                ln(Vector(0, 0), Vector(r * 1.6, r * 1.6)),  // the lever
            ])
    }

    /// A ceiling light fixture: a circle with an inscribed cross. Base = centre.
    /// ~150 mm.
    private static func lightFixture() -> SymbolDef {
        let r = 75.0
        return SymbolDef(
            fileName: "Light Fixture",
            basePoint: Vector(0, 0),
            records: [
                circ(Vector(0, 0), r),
                ln(Vector(-r, 0), Vector(r, 0)),     // horizontal arm
                ln(Vector(0, -r), Vector(0, r)),     // vertical arm
            ])
    }

    // MARK: Annotation

    /// A north arrow: an elongated triangle pointing up with an "N" tick, drawn
    /// from lines so it needs no fill. Base point = the arrow tip's base (origin
    /// at the bottom centre). ~300 mm tall.
    private static func northArrow() -> SymbolDef {
        let h = 300.0, halfW = 60.0
        let tip = Vector(0, h)
        let left = Vector(-halfW, 0)
        let right = Vector(halfW, 0)
        return SymbolDef(
            fileName: "North Arrow",
            basePoint: Vector(0, 0),
            records: [
                poly([left, tip, right], closed: false),   // open chevron
                ln(left, Vector(0, h * 0.35)),             // inner fold (filled look)
                ln(right, Vector(0, h * 0.35)),
                // "N" above the tip
                ln(Vector(-30, h + 40), Vector(-30, h + 120)),
                ln(Vector(-30, h + 40), Vector(30, h + 120)),
                ln(Vector(30, h + 40), Vector(30, h + 120)),
            ])
    }

    /// A leader / dimension arrow head: a narrow closed triangle approximating a
    /// filled arrowhead, plus a short leader line. Base point = the arrow point.
    /// ~50 mm leader.
    private static func leaderArrow() -> SymbolDef {
        let len = 50.0, half = 6.0
        let tip = Vector(0, 0)
        return SymbolDef(
            fileName: "Leader Arrow",
            basePoint: tip,
            records: [
                // Arrowhead (closed triangle — a hollow head; "filled-ish" via lines).
                poly([tip, Vector(len * 0.4, half), Vector(len * 0.4, -half)], closed: true),
                ln(Vector(len * 0.4, 0), Vector(len, 0)),   // the leader shaft
            ])
    }
}

// MARK: - Driver (runs serially — one symbol at a time on the shared engine)

enum SymbolGenerator {

    /// Resolves the output directory. If `argDir` is provided it is used verbatim;
    /// otherwise the in-repo `macos/assets/symbols` is derived from this source
    /// file's path (the same #filePath idiom the engine uses for its asset dirs).
    static func defaultOutputDirectory() -> URL {
        // <repo>/macos/engine/Sources/CADBench/SymbolGenerator.swift
        //   drop filename + CADBench + Sources + engine -> .../macos
        let thisFile = URL(fileURLWithPath: #filePath)
        let macosDir = thisFile
            .deletingLastPathComponent()   // CADBench
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // engine
            .deletingLastPathComponent()   // macos
        return macosDir.appendingPathComponent("assets/symbols", isDirectory: true)
    }

    /// Generates every starter symbol into `outputDir` (created if needed), one at
    /// a time (libdxfrw is non-reentrant on `CADEngine.shared`). Prints a per-file
    /// summary. Returns the number of files written.
    @MainActor
    @discardableResult
    static func generate(into outputDir: URL) async -> Int {
        let fm = FileManager.default
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var written = 0
        for def in SymbolCatalog.all() {
            let dest = outputDir.appendingPathComponent("\(def.fileName).dxf")
            do {
                let result = try await BlockExport.writeRecords(
                    def.records,
                    basePoint: def.basePoint,
                    layers: LayerTable(),
                    toPath: dest.path
                )
                if let result {
                    print("  wrote \(def.fileName).dxf  (\(result.written) entities)")
                    written += 1
                } else {
                    print("  SKIPPED \(def.fileName).dxf  (no records?)")
                }
            } catch {
                print("  ERROR writing \(def.fileName).dxf: \(error)")
            }
        }
        print("Generated \(written) symbol(s) into \(outputDir.path)")
        return written
    }
}
