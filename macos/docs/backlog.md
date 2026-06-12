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

## DXF writer (text/solid/hatch fidelity)
- **HATCH write uses edge (line) boundary loops, not polyline boundaries** — libdxfrw's `writeHatch`
  has a `//RLZ: polyline boundary writeme` stub, so a polyline boundary path (type & 2) would emit no
  geometry. We therefore write each loop as a chain of `DRW_Line` edges. Consequence: **boundary-arc
  bulges are NOT preserved** across a write (each ring vertex's `bulge` is dropped; the boundary is
  straight-segment only). A curved hatch boundary round-trips as its vertex polygon. Fix when
  libdxfrw's polyline-boundary writer is implemented, or by emitting `DRW_Arc` edges for bulged
  segments. *(ws-dxf-write-fidelity)*
- **TEXT write emits single-line DXF TEXT, never MTEXT** — the POD model carries one insertion point +
  the 72/73 alignment codes (which `DRW_Text` round-trips); an MTEXT read back as `.text` is written
  as TEXT. Multi-line layout, MTEXT attachment-point alignment, and inline format codes are not
  reconstructed (the reader already strips them). *(ws-dxf-write-fidelity)*
- **SPLINE / splinePoints write still skipped** (counted, not fatal) — no `writeSpline` mapping yet.
  *(ws-dxf-write-fidelity)*
- **DIMENSION read+write covers linear/aligned/radial/diametric/angular only** — the five
  `DimKind`-modelled variants round-trip (read: `addDim*` → `LC_ENT_DIMENSION` → `.dimension`; write:
  `.dimension` → `DRW_Dim*`). DXF **ordinate** and **angular-3p** dimensions are NOT in the frozen
  `DimKind`, so they still surface as a "DIMENSION" reader warning and are never written (dim_sample.dxf
  has 6 ordinate dims that stay warnings). Add `DimKind.ordinate`/`.angular3p` + resolve arms first.
  Also: the DIMENSION entity's **text height / arrow size live in DIMSTYLE, not on the entity**, so
  `DimData.textHeight`/`arrowSize` do NOT survive a DXF round-trip (they reset to the resolve defaults);
  carrying them needs a DIMSTYLE table writer. The rendered geometry's **anonymous block (code 2) is not
  authored** — we write the entity definition with an empty block name (libdxfrw forces the type-70 |32
  bit); a real CAD app regenerates the block and our own `resolve()` regenerates the visual on read.
  *(ws-dim-dxf)*

## Render gate — DXF reader (F)
- Add a DXF fixture covering SPLINE + ELLIPSE + true-color (color24) to lock the mapping (dim_sample.dxf has none). *(review-dxfread #3)*
- Strengthen `pensMapped` test (currently `allSatisfy { _ in true }` no-op) with a real pen assertion. *(review-dxfread #2)*
- Comment that `lc_dxf_count_entities` now parses+flattens the whole file (no longer alloc-free). *(review-dxfread #4)*
- Layer with ACI 256 silently → green instead of inheriting (rare/invalid edge). *(review-dxfread #1)*

## Coordinate / canvas (offset resolved)
- Add a `worldToScreen ↔ worldToClip` consistency regression test (same world point → same screen pixel across sizes/backing/pan/zoom) — locks in the offset fix. (offset-fix3's intended test; agent was stopped before landing it.)
- Remove (or keep env-gated) the `LC_DEBUG_COORDS` instrumentation in CADCanvasView once we're confident the offset stays fixed.

## Layers / rendering
- **Layer visibility render filter** (sidebar gap): the render path (`LineRenderer.rebuildLineInstancesIfNeeded`) + `resolve()` don't skip entities on hidden/frozen layers — toggling the eye in the sidebar updates model state but doesn't hide pixels. Fix in the renderer (skip ids whose `layers.layer(e.layer)?.isVisible==false`) — fold into the renderer-fills wave. (ws-sidebar flag)
- Add a `CADDrawing.setLayerColor(_:_:)` convenience wrapper (sidebar used `mutateLayers{ setColor }`). (ws-sidebar)

## App shell
- ~~**Reintroduce DocumentGroup** (native open/save/recents/autosave/versions) with an OFF-MAIN-SAFE
  `ReferenceFileDocument`: store Sendable parsed data (entities/layers or raw bytes) in
  `init/snapshot/fileWrapper` (these run off-main), and build the `@MainActor CADDrawing` in the view.
  NO `MainActor.assumeIsolated` in document entry points. (Replaced by WindowGroup after the launch crash.)~~
  **DONE** — `LibreCADDocument: ReferenceFileDocument` over `.dxf`. The document holds ONLY a Sendable
  `DXFPayload` (entity records + layer/block tables + header vars); `init(configuration:)`/`snapshot`/
  `fileWrapper` parse/serialize off-main via `CADEngine.shared.readEntities`/`writeEntities` (the
  `DXFDocumentCodec` bridges the async engine actor to the sync document requirements with a semaphore —
  SAFE because those entry points run on a background queue, never main). The `@MainActor CADDrawing` +
  `CanvasModel` are built in `ContentView.task` (main actor) from the payload, NEVER in the document init —
  no `MainActor.assumeIsolated` anywhere. `WindowGroup`→`DocumentGroup(newDocument:)`. The model adopts
  SwiftUI's environment `UndoManager` (`CanvasModel.adoptUndoManager`) so edits mark the document dirty.
  Custom NSOpenPanel/NSSavePanel Open/Save removed (DocumentGroup owns them); Export (PDF/PNG/SVG) + Print
  stay custom. Headless launch verified: stays alive 10s, NO new crash report. (4 doc-payload round-trip tests.)
- DXF/DWG **write** + Save (currently read-only viewer). *(DXF Save now native via DocumentGroup.)*

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
