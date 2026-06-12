//
//  main.swift
//  CADBench
//
//  Scale benchmark harness for the LibreCAD macOS engine/render pipeline. MEASURE,
//  don't optimize: generate synthetic drawings at 100k / 500k / 1M entities and
//  time the hot CPU paths the renderer + interaction layers depend on, comparing
//  each against the budgets in macos/docs/rendering-performance.md §8.
//
//  Metrics (per drawing size):
//    1. Quadtree build           — Spatial/Quadtree.insert over all boxes.
//    2. Cull query               — Quadtree.query(region:) for a typical viewport.
//    3. Hit-test / nearest       — Selection.hitTest (cursor pick) + Quadtree.nearest.
//    4. Line-instance rebuild    — the EXACT CPU-side buffer build the renderer runs
//                                  (cull → resolve() → RendererGeometry.appendInstances
//                                  /appendFillVertices), reachable here because the
//                                  GPU-free renderer geometry is symlinked in (same
//                                  pattern as the test target). The only step skipped
//                                  vs. LineRenderer.rebuildLineInstancesIfNeeded is the
//                                  final MTLBuffer memcpy (a device blit, not CPU work).
//                                  Pure engine-side resolve()-over-all is also reported.
//    5. Peak memory              — resident size after the index is built (approx peak).
//
//  This target is NOT part of the normal test suite (it is a separate executable),
//  so `swift test` is unaffected. Run it explicitly:
//      swift run --package-path macos/engine --disable-sandbox -c release CADBench
//  Optional: pass sizes as args, e.g. `... CADBench 100000 500000`.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation
import CoreGraphics
import CADEngine

// MARK: - Fixed seed (reproducible numbers)

/// One fixed seed for the whole run so every size's geometry — and every measured
/// number — reproduces exactly (brief: no Date()/random without a fixed seed).
let benchSeed: UInt64 = 0x1BCD_EF01_2345_6789

// MARK: - Per-size result row

struct Row {
    let count: Int
    let quadtreeBuildMs: Double
    let cullQueryMs: Double
    let cullVisibleCount: Int
    let hitTestMs: Double
    let nearestMs: Double
    let lineRebuildMs: Double
    let lineRebuildInstances: Int
    let resolveAllMs: Double
    let peakResidentBytes: UInt64
}

// MARK: - The single-size benchmark

/// `RendererGeometry.defaultHalfWidthPx` is internal to the symlinked source; the
/// bench packs with the same constant so the instance count matches the shipping
/// renderer exactly.
@MainActor
func benchmark(count: Int) -> Row {
    // ---- Generate the synthetic drawing (fixed seed).
    let gen = SyntheticDrawing.generate(count: count, seed: benchSeed)
    let drawing = gen.drawing
    let boxes = gen.boxes

    // ---- 1. Quadtree build: insert every (id, box). reserveWorld() once up front
    // so we measure steady-state insertion, not the early grow-by-rebuilds (the
    // renderer/engine seeds the index from the drawing bbox the same way).
    let worldBound = drawing.boundingBox()
    let quadtreeBuildMs = bestOf(iterations: 3, warmup: 1) {
        let tree = Quadtree()
        tree.reserveWorld(worldBound)
        for (id, box) in boxes {
            tree.insert(id, bounds: box)
        }
        blackHole(tree.count)
    }

    // Build the index ONCE more to drive the query/hit benches against a real tree.
    let tree = Quadtree()
    tree.reserveWorld(worldBound)
    for (id, box) in boxes { tree.insert(id, bounds: box) }

    // ---- A "typical" working viewport. 1400×900 pt, centered on the world origin,
    // scaled so it spans ~2% of the world extent on the long axis — a normal
    // zoomed-in working view where culling does real work (a few hundred to a few
    // thousand of the count are visible). The visible rect is padded the same way
    // the renderer pads its cull region (RendererCull.defaultMargin).
    let viewSize = CGSize(width: 1400, height: 900)
    let worldSpan = SyntheticDrawing.worldHalf * 2.0
    let visibleWorldWidth = worldSpan * 0.02
    let scale = Double(viewSize.width) / visibleWorldWidth   // pts per world unit
    let viewport = Viewport(scale: scale, center: Vector(0, 0), size: viewSize)
    let visibleRect = viewport.visibleWorldRect
    let cullRect = RendererCull.expanded(visibleRect, byFraction: RendererCull.defaultMargin)

    // ---- 2. Cull query: the renderer's per-view-change quadtree region query.
    var visibleIDs: [EntityID] = []
    let cullQueryMs = bestOf(iterations: 50, warmup: 5) {
        visibleIDs = tree.query(region: cullRect)
    }
    let cullVisibleCount = visibleIDs.count

    // ---- 3a. Hit-test (click-to-select): cursor pick at the view center. Tolerance
    // is the GUI catch range (~8 px) converted to world units, same as the
    // interaction layer (Viewport.worldPerPixel × catch px).
    let cursor = Vector(0, 0)
    let catchPx = 8.0
    let worldTol = viewport.worldPerPixel * catchPx
    let selection = Selection()
    let ctx = drawing.makeResolveContext()
    let hitTestMs = bestOf(iterations: 50, warmup: 5) {
        let hit = selection.hitTest(worldPoint: cursor, worldTolerance: worldTol,
                                    in: drawing, using: tree, ctx: ctx)
        blackHole(hit?.rawValue ?? 0)
    }

    // ---- 3b. Nearest-entity query (the snapping candidate selector on the index).
    let nearestMs = bestOf(iterations: 50, warmup: 5) {
        let n = tree.nearest(to: cursor, maxDistance: worldTol)
        blackHole(n?.rawValue ?? 0)
    }

    // ---- 4. Line-instance rebuild — the EXACT CPU buffer build the renderer runs:
    // cull → for each visible entity resolve() → RendererGeometry.appendInstances /
    // appendFillVertices into reused scratch (the renderer reuses scratch with
    // keepingCapacity; we mirror that to measure steady-state, not first-alloc).
    let origin = RendererGeometry.renderOrigin(for: worldBound)
    let layers = drawing.layers
    var instanceScratch: [LineInstance] = []
    var fillScratch: [FlatVertex] = []
    var lineInstanceCount = 0
    let lineRebuildMs = bestOf(
        iterations: 20, warmup: 3,
        setup: {
            instanceScratch.removeAll(keepingCapacity: true)
            fillScratch.removeAll(keepingCapacity: true)
        }
    ) {
        // This block mirrors LineRenderer.rebuildLineInstancesIfNeeded's CPU body.
        let ids = tree.query(region: cullRect)
        instanceScratch.reserveCapacity(ids.count * 2)
        for id in ids {
            guard let e = drawing.entity(id) else { continue }
            if layers.layer(e.layer)?.isVisible == false { continue }
            let geo = e.resolve(ctx)
            for poly in geo.polylines {
                RendererGeometry.appendInstances(for: poly, renderOrigin: origin,
                                                 into: &instanceScratch)
            }
            for fill in geo.fills {
                RendererGeometry.appendFillVertices(for: fill, renderOrigin: origin,
                                                    into: &fillScratch)
            }
        }
        lineInstanceCount = instanceScratch.count
    }

    // ---- 4b. Pure engine-side resolve() over ALL entities (the "initial cache
    // build" cost the renderer pays once off the main actor — the gap vs. the
    // culled per-frame rebuild above). Measured without packing so it isolates the
    // resolve() kernel cost across the whole drawing.
    let resolveAllMs = bestOf(iterations: 3, warmup: 1) {
        var sink = 0
        for e in drawing.entities {
            let geo = e.resolve(ctx)
            sink &+= geo.polylines.count &+ geo.fills.count
        }
        blackHole(sink)
    }

    // ---- 5. Peak memory: resident size with the index + drawing live (sampled at
    // the high-water point — the index is the largest auxiliary structure).
    let peak = MemoryProbe.residentBytes()

    // Keep the tree alive past the memory sample.
    blackHole(tree.count)

    return Row(
        count: count,
        quadtreeBuildMs: quadtreeBuildMs,
        cullQueryMs: cullQueryMs,
        cullVisibleCount: cullVisibleCount,
        hitTestMs: hitTestMs,
        nearestMs: nearestMs,
        lineRebuildMs: lineRebuildMs,
        lineRebuildInstances: lineInstanceCount,
        resolveAllMs: resolveAllMs,
        peakResidentBytes: peak
    )
}

// MARK: - Output

func printRows(_ rows: [Row]) {
    func ms(_ v: Double) -> String { String(format: "%.3f", v) }
    func msShort(_ v: Double) -> String { String(format: "%.2f", v) }

    print("")
    print("=== LibreCAD macOS engine/render scale benchmark ===")
    print("seed: 0x\(String(benchSeed, radix: 16))   build: release recommended (-c release)")
    print("viewport: 1400x900 pt, centered (0,0), ~2% world span (typical working zoom)")
    print("")

    // Wide table.
    let header = String(
        format: "%-10@ | %-14@ | %-14@ | %-9@ | %-12@ | %-12@ | %-18@ | %-14@ | %-10@",
        "entities" as CVarArg, "quadtree(ms)" as CVarArg, "cull q.(ms)" as CVarArg,
        "visible" as CVarArg, "hitTest(ms)" as CVarArg, "nearest(ms)" as CVarArg,
        "lineRebuild(ms)" as CVarArg, "resolveAll(ms)" as CVarArg, "peakRSS" as CVarArg
    )
    print(header)
    print(String(repeating: "-", count: header.count))
    for r in rows {
        let line = String(
            format: "%-10d | %-14@ | %-14@ | %-9d | %-12@ | %-12@ | %-18@ | %-14@ | %-10@",
            r.count,
            ms(r.quadtreeBuildMs) as CVarArg,
            ms(r.cullQueryMs) as CVarArg,
            r.cullVisibleCount,
            msShort(r.hitTestMs) as CVarArg,
            msShort(r.nearestMs) as CVarArg,
            "\(msShort(r.lineRebuildMs)) (\(r.lineRebuildInstances))" as CVarArg,
            ms(r.resolveAllMs) as CVarArg,
            MemoryProbe.mib(r.peakResidentBytes) as CVarArg
        )
        print(line)
    }
    print("")
    print("Notes:")
    print(" - lineRebuild(ms) shows ms and the packed instance count in parens.")
    print(" - cull q. / hitTest / nearest are best-of-50; quadtree/resolveAll best-of-3.")
    print(" - peakRSS is cumulative resident size (grows across sizes in one process).")
    print(" - Budgets (rendering-performance.md §8): cull query < 0.3 ms,")
    print("   build instance list < 1.5 ms, initial 1M cache build a few seconds,")
    print("   single-entity edit < 1 ms.")
    print("")
}

// MARK: - Entry point

@MainActor
func run() {
    // Sizes: from args (ints) or the default 100k / 500k / 1M.
    let argSizes = CommandLine.arguments.dropFirst().compactMap { Int($0) }.filter { $0 > 0 }
    let sizes = argSizes.isEmpty ? [100_000, 500_000, 1_000_000] : argSizes

    var rows: [Row] = []
    for n in sizes {
        FileHandle.standardError.write("benchmarking \(n) entities…\n".data(using: .utf8)!)
        rows.append(benchmark(count: n))
    }
    printRows(rows)
}

/// Prevents the optimizer from dead-code-eliminating a benched computation by
/// forcing its result to be "observed". Kept trivially cheap.
@inline(never)
func blackHole<T>(_ value: T) {
    withExtendedLifetime(value) {}
}

MainActor.assumeIsolated {
    run()
}
