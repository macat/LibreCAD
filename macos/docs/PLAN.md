# Master Plan — LibreCAD Native macOS (Swift)

Synthesis of the five foundation investigations (engine map, DXF bridge, scaffold, feature
inventory, rendering performance). This is the roadmap the parallel build fans out from.
Living document — update as phases complete.

## Vision
A fully native macOS 2D CAD app — a modern, friendlier reimagining of LibreCAD, written in Swift
on the latest macOS APIs (SwiftUI `DocumentGroup`, Observation, MetalKit). Mac-only. We **port the
engine** (geometry, entity model, document model) to clean Swift, **bridge `libdxfrw`** (C++) for
real DXF/DWG fidelity, **render with Metal** for fluid pan/zoom at scale, and **reimagine the UI**
(unified toolbar, SwiftUI inspector + sidebar, ⌘K palette, on-canvas gizmos).

## Architecture (decided)
- **Modules:** `DxfBridge` (C++ shim over libdxfrw, **pure C ABI** so Swift imports it as C — C++ stays internal) → `CADEngine` (pure-Swift engine: math, entities, document, tools, spatial index) → `LibreCADmacOS` (SwiftUI + Metal app). Build: SwiftPM (engine, CLI-testable) + manual `.app` assembly now; add XcodeGen when network returns.
- **Entity model (see ADR-001):** ALL entities — atomic AND composite (polyline/text/insert/hatch/
  **all dimensions**) — are **value `struct`s** holding only defining data; derived geometry is
  computed via `resolve()` into an invalidatable cache, **never stored as a child graph**. Document
  holds entities by stable `EntityID`; relationships are ID references, not object pointers.
  `RS2::` enums → Swift enums/OptionSets. `Vector` is 2D-first (drop RS_Vector's Y-flip; Metal is Y-up).
- **Undo (see ADR-002):** `UndoManager` (free from `DocumentGroup`) restoring **COW value snapshots of
  the dirty set only** (cheap because entities are value types) — NOT LibreCAD's flag-based scheme.
- **Rendering (Metal):** geometry in **world coords** in persistent `.shared` MTLBuffers; **single
  world→clip float4x4 uniform** (pan=translate, zoom=scale — buffers never rebuild on pan/zoom).
  Lines/polylines/curves = **instanced screen-space quads** (constant px width, analytic AA). Curves =
  CPU sagitta tessellation with **zoom-bucketed LOD**. Fills/hatches = **earcut triangulation**.
  **CAD text/dims = stroked `.lff` polylines through the line pipeline (ADR-004), NOT SDF**; SDF atlas
  is for UI chrome only. **Float precision per ADR-003** (f64 engine, f32 floating-origin buffers).
  **Loose quadtree** shared by viewport culling + CPU snapping. On-demand draw
  (`enableSetNeedsDisplay`+`isPaused`); continuous only during gestures.
  Budget: ~6 ms of 8.3 ms/frame @120 Hz; single-entity edits <1 ms via dirty-region patching.
- **Hit-testing/snapping:** CPU only, against exact engine kernels (port of `RS_Information`); never
  GPU readback — snaps stay exact regardless of render LOD. Snapping decoupled from tools.
- **Tools:** each tool owns a `Snapper` collaborator; per-tool `enum State` (not magic int status).

## Phased roadmap
*(Sequencing follows ADR.md, which supersedes prior phase order. Revised per plan-critic 2026-06-11.)*
- **Phase 0 — Foundation spine** ✅ *(DONE — merged to `native-macos`)*: SwiftPM package builds;
  libdxfrw compiles clean (c++20) + entity-counting DXF reader through the C-ABI shim; SwiftUI
  `DocumentGroup` app with a Metal canvas; `.app` assembles. **13/13 tests green; dim_sample.dxf=103
  entities. Reviewed: APPROVE w/ follow-ups (rolled into Phase 0.5).**
- **Phase 0.5 — Freeze foundation ADRs + skeleton** ✅ *(DONE — merged)*: value-type entity model +
  `resolve()` + `@MainActor CADDrawing` (snapshot-undo) + render seam, reviewed (APPROVE; must-fix +
  widen-now applied), **49/49 tests green**. Shared type contract FROZEN (see ADR.md / phase1-fanout.md).
- **Phase 1 — Engine core** ✅ *(DONE — all 5 workstreams merged)*: A math/intersection kernels +
  solvers, B ellipse+spline(NURBS)+splinePoints, C document/layers/blocks/units/vars, D loose quadtree,
  E `.lff` stroke-font loader. 5 parallel builders + 5 reviewers (all APPROVE, no must-fix); one A/B
  test-suite name collision caught at integration + fixed. **174 tests green** on native-macos.
- **Consolidated gate — Render + Interaction core** ✅ *(DONE — Wave 1 (reader/viewport/select-snap)
  + Wave 2 (Metal renderer/canvas) all merged; renderer reviewed REVISE→fixed; 254 tests green; .app
  assembles + runs. App OPENS & NAVIGATES dim_sample.dxf: pan/zoom/fit/grid + snap + select + HUD.)*:
  full `DxfBridge` reader (flatten all DRW_* → Swift model); the real Metal pipeline (instanced lines →
  tessellated arcs/curves → fills → `.lff` text) rendering `dim_sample.dxf`; world/screen transform +
  pan/zoom/fit/grid; selection (single/window/crossing); snapping (free/grid/endpoint/center/on-entity)
  + ortho; **preview overlay**; coordinate HUD + typed entry (`@dx,dy`, `dist<angle`); ⌘K palette.
  **This whole gate must be green before tool fan-out** — tools are untestable without on-screen
  geometry + selection + snapping + preview.
- **Phase 4 — Broad tool parity** *(heavy parallel fan-out — the "broad parity" goal)*: P0 wave first
  (Line/Polyline/Rect/Circle/Arc/Point draw; Move/Copy/Rotate/Scale/Trim/Offset/Delete/Props modify),
  then P1/P2. Each independent tool = its own worktree/builder/reviewer. Modernized as ~12 tools +
  variant pickers. **Hatch, Dimensions, Blocks/Inserts span engine+render+interaction → SINGLE owner,
  not the wide pool.** Spline = higher-risk P1, port with tests.
- **Phase 5 — UI shell**: unified toolbar, SwiftUI sidebar (Layers/Blocks/Views), trailing Inspector
  (entity properties + transforms), on-canvas gizmos, status bar, native menus/shortcuts, dark mode.
- **Phase 6 — File I/O**: DXF **write** (via libdxfrw writer), DWG read; export PDF/PNG/SVG; native
  open/save/recents/autosave/versions via DocumentGroup.
- **Phase 7 — Polish & perf**: profiling passes (perf agent) at 100k–1M entities, accessibility,
  printing, preferences.

## Parallelization & integration
- Every write-agent works in its own git worktree on a `ws/<area>` branch; non-overlapping file
  ownership. Coordinator merges `ws/*` → `native-macos`, rebuilds green, commits. Code-review every
  branch before merge. Test+validate before every commit. (See CONVENTIONS.md.)
- Fan-out is gated on Phase 0 green + the shared engine protocols from Phase 1 existing, so tools
  build against stable types (consistency > speed).

## Open decisions / risks
1. **Product name / bundle id / UTIs** — defaulting to `LibreCADmacOS` / `org.librecad.macos` /
   `org.librecad.dxf|dwg`. Trivially renamable; confirm desired product name. (GPL fork can keep
   "LibreCAD" naming but a distinct name may be cleaner.)
2. **License** — LibreCAD + libdxfrw are **GPLv2-or-later**; static-linking makes this app a GPL
   derivative. Fine for an open-source fork; conscious call needed before any closed distribution.
3. **DWG write is R2000-only** (read R2000–2018). Acceptable; surface as a limitation in export UI.
4. **Rendering refs need web re-verification** — the perf doc leaned on canonical (settled)
   techniques because web retrieval was gated this session; re-verify specifics before the renderer.
5. **Network blocked this session** — no push / brew / web. Commits are local; push when connectivity
   returns: `git push -u origin native-macos`.
6. **XcodeGen deferred** — SwiftPM + manual `.app` now; revisit XcodeGen for a nicer Xcode/debug/
   signing workflow once installable.
