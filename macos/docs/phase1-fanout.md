# Phase 1 Fan-out — Engine Core (parallel)

Gate passed: Phase 0 + 0.5 merged, foundation contract FROZEN (see ADR.md). Now we fan out the
engine core across parallel builders. **Disjoint file ownership** is what keeps it conflict-free —
SwiftPM auto-discovers `.swift` files under a target, so new files in new subfolders need NO
`Package.swift` edits, and no two builders touch the same file.

## Frozen contract (every builder reads ADR.md; key shapes)
```swift
struct EntityRecord { var id: EntityID; var layer: LayerID; var pen: Pen; var flags: EntityFlags; var kind: EntityKind }
enum EntityKind { case point(PointData), line(LineData), circle(CircleData), arc(ArcData), polyline(PolylineData) }
extension EntityRecord { func resolve(_ ctx: ResolveContext = .default) -> ResolvedGeometry; func boundingBox() -> AABB }
struct ResolvedGeometry { var polylines: [ResolvedPolyline]; var fills: [ResolvedFill] }
struct ResolvedFill { var loops: [[Vector]]; var color: RGBAColor }   // loops[0]=outer CCW, [1...]=holes CW
struct ResolveContext { var tessellationTolerance: Double; var layerAttributes:(LayerID)->ResolvedPen; var blockAttributes:(ResolvedPen?)->ResolvedPen; var currentBlockPen: ResolvedPen? }
@MainActor @Observable final class CADDrawing { func mintID()->EntityID; @discardableResult func add(_:)->EntityID; func remove(_:); func replace(_:); func load(...); var undoManager: UndoManager? }
// CADEngine.shared (only path; init is internal). Engine returns value types; apply on @MainActor.
```
**Recipe to add an entity type:** add `*Data` struct + `EntityKind` case + arms in the two `switch self`
in `Resolve.swift` (`resolve` + `boundingBox`). Compiler exhaustiveness = your checklist.

## Workstreams (5 parallel builders; each → own `ws/<name>` branch + reviewer + tests)

| WS | Branch | OWNS (only-edit) | Scope |
|----|--------|------------------|-------|
| **A. Math/intersection kernels** | `ws/math` | `Sources/CADEngine/Math/*` (new), `Tests/CADEngineTests/IntersectionTests.swift` | Port `rs_math` + `lc_quadratic`: line-line, line-circle, circle-circle, line-arc, arc-arc, ellipse intersections; quadratic/quartic solver; angle utils. Port `librecad/src/lib/math/tests/{rs_math_tests,lc_quadratic_tests}.cpp` as Swift tests. |
| **B. Entity-set expansion** | `ws/entities` | `Sources/CADEngine/Entity.swift`, `Resolve.swift`, `Tests/CADEngineTests/EntitySetTests.swift` | Add **Ellipse** + **Spline** (NURBS + interpolation; HIGHER-RISK — port with tests) to `EntityKind` + resolve + bbox. Ellipse/spline tessellation w/ sagitta. The ONLY builder touching Entity.swift/Resolve.swift. |
| **C. Document / layers / blocks** | `ws/document` | `Sources/CADEngine/CADDrawing.swift`, `Layer.swift`, `Block.swift`(new), `Tests/CADEngineTests/DocumentTests.swift` | Full LayerTable ops (add/remove/rename/visibility/lock/active/color/print/construction flags), BlockTable + block storage (`[BlockID:[EntityID]]`, id-refs per ADR-001), graphic variables, units. (Insert *resolve* is the Blocks owner later, not here.) |
| **D. Spatial index** | `ws/spatial` | `Sources/CADEngine/Spatial/*` (new), `Tests/CADEngineTests/QuadtreeTests.swift` | Loose quadtree indexing `EntityID→AABB`: insert/remove/update, viewport query (culling), point/region query (hit-test). Standalone API + perf test (build 100k AABBs, query subset). |
| **E. `.lff` stroke-font loader** | `ws/lff` | `Sources/CADEngine/Text/*` (new), `Tests/CADEngineTests/LFFFontTests.swift`, may read `librecad/support/fonts/*.lff` | Parse `.lff` format → glyph stroke polylines; a `StrokeFontProvider` (loads/caches fonts) matching the reserved `ResolveContext.fontProvider` shape (ADR-004). Test against a shipped `.lff` (e.g. `standard.lff`/`simplex.lff`). Does NOT touch Entity.swift (Text resolve arm comes with the Text owner later). |

## Rules for every builder (in each brief)
- Read `ADR.md` + `CONVENTIONS.md`. Swift 6.2 strict concurrency, macOS 26, GPLv2 headers on ported logic.
- **Touch ONLY your owned files** (above). New files go under your subfolder. Do NOT edit `Package.swift`
  (auto-discovery) or any other workstream's files.
- Validate `swift build --disable-sandbox` (0 warnings) + `swift test --disable-sandbox` (all green) before commit.
- Commit to your `ws/<name>` branch in your worktree; do NOT merge/push. Coordinator merges + rebuilds green after each.

## Integration order (coordinator)
Merge disjoint branches sequentially, rebuild+test green after each: A → D → E → C → B (B last; it owns the
hot files and benefits from A's kernels being present). Each merge is conflict-free by construction.

## Single-owner (NOT in this wide pool — later, sequential)
Insert/Block-resolve, Dimensions, Hatch, Text-entity (uses E's font loader) — each crosses
engine+render+interaction → one careful owner each (per critic), after Phase 1 lands.
