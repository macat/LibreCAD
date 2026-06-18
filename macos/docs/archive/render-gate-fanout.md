# Render + Interaction Gate — fan-out plan

Consolidated gate (per ADR.md / plan-critic): real geometry on screen + selection + snapping +
preview overlay must be GREEN before the broad tool fan-out (Phase 4). Builds on the Phase 1 engine
(entities/resolve, Math/Intersections, Spatial/Quadtree, Text/.lff, document model, DxfBridge).

## Wave 1 — parallel, engine-side, disjoint files (3 builders)
| WS | Branch | OWNS (only-edit) | Scope |
|----|--------|------------------|-------|
| **F. DXF reader** | `ws/dxfread` | `Sources/DxfBridge/{lcdxf.h,lcdxf.cpp}`, `Sources/CADEngine/DXFReader.swift`(new), `Tests/.../DXFReaderTests.swift` | Expand the C-ABI shim from counting → flattening: DRW_Interface add* callbacks collect POD per entity (line/circle/arc/ellipse/lwpolyline/polyline/point + layer/color/lineweight); C-ABI returns the array (+ free). `DXFReader` maps POD→EntityRecord + layers→LayerTable → `CADDrawing`. Ref `rs_filterdxfrw.cpp`. Unsupported kinds (text/insert/dimension/hatch) skipped+logged for now. |
| **G. Viewport** | `ws/viewport` | `Sources/CADEngine/Viewport.swift`(new), `Tests/.../ViewportTests.swift` | Pure f64 transform: worldToScreen/screenToWorld, zoom(by:about:), pan(byScreenDelta:), zoomToFit(AABB,viewSize), pixelsPerUnit, screenToWorldScale, and the world→clip `float4x4` (Metal Y-up NDC) with ADR-003 `renderOrigin` f32 rebasing. |
| **H. Selection + snapping** | `ws/selectsnap` | `Sources/CADEngine/{Selection.swift,Snapping.swift}`(new), `Tests/.../SelectionSnapTests.swift` | hitTest(point,worldTol)/windowSelect(rect,crossing) via Quadtree candidates + exact geometry; `SnapMode` OptionSet (free/grid/endpoint/center/middle/onEntity/intersection) → `snap(...)->SnapResult`. Tolerance in WORLD units (caller converts via Viewport) so H stays transform-agnostic. Uses Quadtree(D)+Intersections(A). |

## Wave 2 — Metal renderer + canvas integration (after Wave 1 merges)
`ws/renderer` owns `Sources/LibreCADmacOS/*` (MetalCanvasView, new Renderer/*, shaders, ContentView):
instanced screen-space line quads (width+AA) for ResolvedPolylines, world→clip via Viewport(G),
pan/zoom/fit/grid gestures, load+display a real DXF via reader(F), quadtree-culled draw, selection
highlight + snap markers + preview overlay using H. This is the integration hub → single focused
builder (may split into renderer-core + interaction/overlay).

## Rules (every brief) — see CONVENTIONS.md
- Touch ONLY owned files; new files under owned paths (SwiftPM auto-discovers; do NOT edit Package.swift).
- **Namespace test-suite type names by domain** (e.g. `DXFReaderTests`, `ViewportTests`, `SelectionTests`/
  `SnappingTests`) — avoid the same-target redeclaration that bit Phase 1 A/B. New helpers = `static` on a
  namespaced type, never module-scope free functions.
- Swift 6.2 strict concurrency; GPLv2 headers on ported logic; build+test green (`--disable-sandbox`) before commit.
- Commit to `ws/<name>` in your worktree; do NOT merge/push. Coordinator merges + rebuilds green after each.
