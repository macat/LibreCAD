# Backlog — non-blocking follow-ups

Tracked items from reviews/builders that are NOT merge-blockers but should be addressed in a polish
pass or by the relevant downstream owner. Each cites its source.

## Build / tooling
- **Bundle `.lff` fonts in `Package.swift`** (test currently reads `standard.lff` by `#filePath`). When
  network/XcodeGen returns or via a manifest edit, add the fonts dir as a resource and switch the LFF
  test to `Bundle.module`. *(ws-lff, review-lff #4)*
- **Add XcodeGen `project.yml`** for the `.app` (deferred; SwiftPM + make-app.sh is the validated path now).

## Engine — document/layers/blocks (Phase 1C)
- Fix `removeLayer` doc-label drift (`reassignTo:` vs the note's `reassigningEntitiesTo:`). *(review-document #1)*
- Add tests: remove-active-layer (+reassign) and removeBlock(deletingContents:) + their undo. *(review-document #2)*
- Decide **case-insensitive uniqueness** for layer/block names (DXF round-trip fidelity). *(review-document #3)*
- `removeBlock(deletingContents:)` deletes shared member entities unconditionally — guard with
  `removeEntityIDEverywhere`/ref-count once Insert sharing exists. *(review-document #4)*
- `removeLayer(reassignTo:)` doesn't validate the target layer exists (harmless fallback today). *(review-document #5)*

## Engine — spatial (Phase 1D)
- `nearest()` is DFS (conservative prune); switch to best-first heap if it lands on a hot snapping path. *(review-spatial #1)*
- Move `overlaps2D`/`contains2D` onto `AABB` in `Geometry.swift` as the shared 2D predicate (culling +
  selection owners want it; remove the test oracle duplication). *(review-spatial #2)*
- `query` doc wording (stack reused within-call, not cross-call); strengthen 100k point-query assertion to equality. *(review-spatial #3,#4)*

## Engine — text/.lff (Phase 1E)
- `StrokeFontProvider.font(named:)` path-branch should cache-read before re-parsing (re-parses on every
  call for a full path). *(review-lff #1)*
- Remove dead line in `registerFont` (`cache[key]=nil` then `removeValue`). *(review-lff #2)*
- Add a comment noting the self-ref handling intentionally diverges from `rs_font.cpp:432` (keeps glyph
  strokes instead of dropping the whole glyph). *(review-lff #3)*
- Optionally keep raw `(point,bulge)` on glyphs for zoom-LOD re-tessellation later. *(review-lff nice-to-have)*

## Engine — math (Phase 1A)
- `VectorSolutions.closest(to:)` has a return-type-only overload pair (tuple vs Vector) — ergonomic
  footgun (call sites must annotate). Rename one (e.g. `closestWithDistance`) before many tool call
  sites land. *(review-math #1)*
- Comment the faithful upstream-bug carry in `simultaneousQuadraticFull` (`+f` vs `+l`, rs_math.cpp:1157)
  so it isn't "fixed" accidentally. *(review-math #2)*

## Render gate — viewport (G)
- `Viewport.worldToClip(drawableSize:)` — `drawableSize` is currently a dead param. Either assert its
  aspect ≈ `size`'s aspect, or drop it + document `size` as authoritative. *(review-viewport #1)*
- **Wave-2 renderer MUST set the canvas `NSView.isFlipped = true`** (Viewport assumes top-left Y-down
  screen) or picking/pan is vertically mirrored — add a runtime assert at the view seam. *(review-viewport #2)*
- Add a far-origin precision-bound assertion + document worst-case ULP (~3e-4 NDC at 1e6 offset). *(review-viewport #3)*

## Render gate — selection/snapping (H)
- Snap perf: `appendIfNear` recomputes sqrt per candidate; snap does 7 filter passes — group into one reduce in the perf pass (24-cap makes it fine now). *(review-selectsnap #1)*
- Thread the caller's `ctx` through `intersections`→`resolvedIntersections` (currently uses `.default` tolerance for polyline/spline intersection snaps). *(review-selectsnap #2)*
- Cache resolved geometry on entity/quadtree (hitTest/snap re-tessellate curves per call). *(review-selectsnap #3)*
- Test gaps: arc/ellipse window-vs-crossing, closed-loop-encloses-rect crossing, degenerate-entity snap NaN-safety. *(review-selectsnap nice-to-have)*

## Render gate — DXF reader (F)
- Add a DXF fixture covering SPLINE + ELLIPSE + true-color (color24) to lock the mapping (dim_sample.dxf has none). *(review-dxfread #3)*
- Strengthen `pensMapped` test (currently `allSatisfy { _ in true }` no-op) with a real pen assertion. *(review-dxfread #2)*
- Comment that `lc_dxf_count_entities` now parses+flattens the whole file (no longer alloc-free). *(review-dxfread #4)*
- Layer with ACI 256 silently → green instead of inheriting (rare/invalid edge). *(review-dxfread #1)*

## Coordinate / canvas (offset resolved)
- Add a `worldToScreen ↔ worldToClip` consistency regression test (same world point → same screen pixel across sizes/backing/pan/zoom) — locks in the offset fix. (offset-fix3's intended test; agent was stopped before landing it.)
- Remove (or keep env-gated) the `LC_DEBUG_COORDS` instrumentation in CADCanvasView once we're confident the offset stays fixed.

## App shell
- **Reintroduce DocumentGroup** (native open/save/recents/autosave/versions) with an OFF-MAIN-SAFE
  `ReferenceFileDocument`: store Sendable parsed data (entities/layers or raw bytes) in
  `init/snapshot/fileWrapper` (these run off-main), and build the `@MainActor CADDrawing` in the view.
  NO `MainActor.assumeIsolated` in document entry points. (Replaced by WindowGroup after the launch crash.)
- DXF/DWG **write** + Save (currently read-only viewer).

## Render gate — renderer/canvas (Wave 2)
- **Extract a `CADRender` library target** in Package.swift so renderer logic is `@testable import`-able;
  drop the `_Shared*.swift` test symlinks. (Pattern risk if copied to other exe sources.) *(review-renderer #7)*
- Cache selection-highlight geometry (currently full `resolve()` per frame of selected entities); key on
  selection-version + LOD. *(review-renderer #7)*
- Pixel-scale the single-point selection marker (currently a world-unit constant → changes on-screen size with zoom).
- Map pen `lineWidth` + dash patterns to pixels (currently constant hairline); miter/bevel joins for thick strokes.
- Render `ResolvedFill` (hatch/solid triangulation) and `.lff` stroke text (ADR-004) — needed before dimensions show.
- Zoom-bucketed LOD for curve tessellation (currently fixed tolerance per `resolve()`).

## Cross-cutting / later phases
- **Zoom-bucketed LOD** for curve tessellation (ellipse/arc/spline/lff bulges) — currently fixed-by-tolerance,
  marked `// TODO` in Resolve.swift / LFFParser.swift. *(ADR-003 / rendering-performance.md)*
- **Real DXF read/write in `CADDocument`** (currently empty round-trip stub) — Phase 2 / consolidated gate.
- **Spline tight bbox** (currently conservative control-hull) + closed-spline wrapping on DXF import. *(ws-entities)*
- **Ellipse/arc-tangent recovery** (TangentFinder) if exact ellipse tangents are needed by tools. *(ws-math)*
