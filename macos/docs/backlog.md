# Backlog — non-blocking follow-ups

Tracked items from reviews/builders that are NOT merge-blockers but should be addressed in a polish
pass or by the relevant downstream owner. Each cites its source.

## Audit follow-ups (2026-06-18)
Newly-found open items from the 2026-06-18 docs/state reconciliation audit.
- **Insert tool block picker UNWIRED** — `InsertTool` is inert without a `blockName`
  (`InsertTool.swift:53,94,108-111`); `CanvasModel.beginInsert(name:)` (`CanvasModel.swift:3899-3908`) has
  ZERO View-layer callers (only tests), and the Insert ToolOptionsBar arm offers scale/rotation/MINSERT-array
  but NO block picker. So interactive click-to-place Insert (⇧I) does nothing. Existing blocks are only
  placeable via the Blocks-sidebar "Insert at View Center" / "Insert Block from File…" / ⌘K (view-center, not
  interactive). **FIX:** add a block-name picker to the Insert tool options + a `beginInsert` View caller.
  (High-value small wiring fix; see next-features-roadmap.) *(audit 2026-06-18)*
- **Dead block drag-and-drop** — BlocksSidebar advertises `.draggable(BlockDragItem)`
  (`BlocksSidebar.swift:94`) but the canvas only has `.dropDestination(for: PartLibraryDragItem.self)`
  (`ContentView.swift:276`); there is NO `BlockDragItem` drop handler → dragging a sidebar block onto the
  canvas is a no-op. **FIX:** add a `BlockDragItem` drop handler that begins an interactive insert at the
  drop point. *(audit 2026-06-18)*
- **Stale "UNWIRED" comments** — `InsertTool.swift` header (line 29) + class doc (45-46) say "intentionally
  UNWIRED until that wave wires a ToolKind case" and `DimStyleManagerView.swift:28-31` says "UNWIRED" — both
  are FALSE now (`ToolKind.insert` dispatches to `InsertTool`; `DimStyleManagerView` is wired). Fix the
  comments. *(audit 2026-06-18)*
- **Multi-select shared-property edit has no multi-record test** — `MultiCommonEditor` + the 2+-record
  one-undo path have ZERO direct test coverage (all ~30 `applyInspectorEdits` call sites pass single-element
  arrays). The engine is array-generic so it works, but the differentiating multi case is untested. (Also:
  `feature-catalog.md:109/249` mislabel this P0 — handled in the catalog refresh.) *(audit 2026-06-18)*
- **Relative-zero Lock menu item is static** — the View-menu Lock item is a static "Lock Relative Zero" label
  with no checkmark / dynamic Lock↔Unlock title; lock state is surfaced only via the status-bar RelZero chip
  (`CanvasModel.swift:3157/3165`). Minor UX polish. *(audit 2026-06-18)*

## Constraints program follow-ups (2026-06-18)
Deferred items from the parametric-constraints program (AutoConstrain + 7 new kinds + GUI). The bug
fix + the 7 straightforward AutoCAD kinds + the panel shipped; these are the documented residuals.
- **tangent + symmetric constraints not implemented** — left DECLARED + `.failed(.unsupported)` in every
  switch (critic IMPORTANT-7 split). `tangent` needs a distance-to-curve residual (line↔circle:
  `dist(center,line)==r`; circle↔circle: `|c1−c2|==r1±r2`); `symmetric` needs a symmetry-AXIS reference and
  a defined `points`-ordering contract (the value model's `points` ordering is unspecified for it) — a small
  ADR addendum + residual-design pass. *(constraints Lane B, deferred)*
- **Inline dimensional-value edit in the Constraints panel** — the panel shows dimensional values READ-ONLY;
  editing them needs an undo-grouped `setConstraintValue` re-solve funnel on `CanvasModel` (today only
  `drawing.editConstraint` + a separate `resolveConstraints` exist). Add the funnel, then surface an editable
  field in `ConstraintsSidebar`/Inspector. *(constraints Lane C, deferred)*
- **AutoConstrain weld tolerance is exact (1e-6)** — welds endpoints that are coincident-by-value (snapped /
  chained LineTool draws — the owner's case). Eyeballed corners with a real gap do NOT weld. Add an
  AutoConstrain **distance tolerance** setting (AutoCAD "Constraint Settings ▸ Tolerances ▸ Distance") and use
  the snap aperture, with the tentative-solve safeguard, so non-snapped "drawn-like-that" corners also weld.
  Also: auto-constrain currently lines-only (the MVP solver can't resolve polyline endpoints — `VariableLayout`
  returns `false` for them); welding polyline vertices needs solver work. *(constraints Lane A, deferred)*
- **AutoConstrain perf** — `nearestExistingLineEndpoint` linearly scans all entities per new endpoint (fine for
  the single-segment LineTool path; `// TODO(perf)` in place). Use the quadtree for a future bulk/polyline-draw
  path. *(constraints Lane A, NIT)*
- **Lane B review NITs** — (a) `ConstraintSolver.swift:874` equal-lines comment says "L is a line DOF
  (half-length)" but `lineLength` computes the true Euclidean segment length — reword. (b) H/V-distance on an
  arc/ellipse: the engine's `addConstraint` resolves it (center) but `currentDimensionalValue`→`startPoint`
  returns `nil` for arc/ellipse, so the UI rejects it (fails closed, no crash) — extend `startPoint` to
  arc/ellipse centers or document the point-only restriction. *(constraints review-laneB NITs)*
- **Constraints panel** — `pairJoiner` (ConstraintListLogic.swift:209) has a `default` arm (not
  compiler-exhaustive like `displayName`) — a future kind silently gets the neutral "·" joiner (cosmetic).
  Optionally drop the `default`. Add a test for `referenceDescription`'s multi-role single-entity branch.
  *(constraints review-laneC NITs)*
- **`unsatisfiedConstraintIDs` stale id on entity DELETE** — `CADDrawing.remove(_:)` drops an entity's
  constraints via `dropDangling` without going through the app-level `removeConstraint`, so a flagged id for a
  deleted entity lingers in `CanvasModel.unsatisfiedConstraintIDs`. Harmless for display (overlay/list key off
  live `allConstraints`; no aggregate reader) and bounded, but the `deleteSelection` path should `subtract` the
  deleted entities' constraint ids (or recompute). *(constraints review-robust NIT-1)*
- **Over-constrain rollback NITs** — `ConstraintsSidebar.unsatisfiedNote` (~245) is called with `[constraint.id]`
  inside an `if isUnsatisfied`, so its `?? fallback` is dead code — pass `model.unsatisfiedConstraintIDs` or
  inline the string; and the `commitConstraints` re-solve comment (~6020) overstates "undo motion" (a `.failed`
  solve writes nothing — the re-solve just refreshes the unsatisfied set). Cosmetic. *(constraints review-robust NIT-2,3)*
- **Reproduce the 2nd-screenshot symptom (H/V on diagonal lines) from a real artifact** — synthetic repros
  couldn't produce it; if it recurs after relaunch, capture the owner's file or a badged line's endpoints. The
  one un-exercised surface is the DXF/DWG constraint-IMPORT path (whether imported constraints enforce/flag on
  open) — note `setDrawing` now re-solves payload-restored constraints, but pure-DXF carries none today.
  *(constraints follow-up)*

## Parity program — W1 follow-up NITs (text-style round-trip)
- **Loaded-file re-save adds a benign `1071=1` on Standard** — `DXFReader` decodes libdxfrw's default stroke font "txt" to `.native(family:"txt")`, which `makeTextStyle` re-encodes WITH the TTF flag, so re-saving a *loaded* file gains a spurious `1071=1` on Standard. Functionally benign (code-3 name preserved; consistent with the dimStyle precedent) — but scope the "byte-identical" comment (DXFWriter.swift ~266-279) to new/in-memory drawings, OR decode a bare no-flag/no-extension name to a flag-free source. *(review-w1a NIT-1)*
- **Partial 1071 fidelity** — reader extracts only TTF/bold/italic bits from code 1071; AutoCAD charset/pitch low-byte bits are dropped on round-trip. Acceptable (name is what renders); a raw-int `LCTextStyle.fontFamily` model field would be needed for full fidelity. *(review-w1a NIT-2)*
- **Optional test** — add coverage for the loaded-file (non-default Standard) re-read path + the "txt"→native decode. *(review-w1a NIT-3)*

## Parity program — W3 Wipeout follow-up NITs
- ~~**clipMode doc contradiction** — engine doc (Entity.swift ~1390) says `clipMode 0 ⇒ mask interior`; vendored `drw_entities.h` says `0 ⇒ outside masked`. Engine always masks the interior (round-trips clipMode losslessly but ignores it for region selection) — reconcile the comment.~~ **DONE** — `Entity.swift:1429-1432` reconciled (always masks interior; flag carried for round-trip only). *(review-w3 NIT-1)*
- **InspectorEditors.swift ~625 comment** says the wipeout boundary is "edited by grips/transform" but `EntityGrips` returns `[]` for `.wipeout` (transform-only this wave) — drop "grips". *(review-w3 NIT-2)*
- **`LineRenderer.uploadWipeoutVertices`** re-stamps every wipeout vertex each frame even when `view.clearColor` is unchanged — gate on a color-change check (optional micro-perf; early-returns when no wipeout). *(review-w3 NIT-3)*
- **Wipeout masking residual** — a stroke deliberately raised ABOVE a wipeout in draw order is still masked (single post-line render pass); true per-entity interleaving deferred. Also CG/SVG/PDF export draws the mask with its fallback color (not background-aware). *(W3 builder, documented)*

## Build / tooling
- **Bundle `.lff` fonts in `Package.swift`** (test currently reads `standard.lff` by `#filePath`). When
  network/XcodeGen returns or via a manifest edit, add the fonts dir as a resource and switch the LFF
  test to `Bundle.module`. *(ws-lff, review-lff #4)*
- **Add XcodeGen `project.yml`** for the `.app` (deferred; SwiftPM + make-app.sh is the validated path now).

## Engine — document/layers/blocks (Phase 1C)
- ~~Fix `removeLayer` doc-label drift (`reassignTo:` vs the note's `reassigningEntitiesTo:`).~~ **DONE** — `CADDrawing.swift:987-991` consistent. *(review-document #1)*
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
- ~~**HATCH write uses edge (line) boundary loops, not polyline boundaries** — libdxfrw's `writeHatch`
  has a `//RLZ: polyline boundary writeme` stub, so a polyline boundary path (type & 2) would emit no
  geometry. We therefore write each loop as a chain of `DRW_Line` edges. Consequence: boundary-arc
  bulges are NOT preserved across a write (each ring vertex's `bulge` is dropped).~~ **DONE** both ways:
  WRITE — `lcdxf.cpp:3069` `appendBulgeArcEdge()` emits a `DRW_Arc` edge for any nonzero-bulge segment;
  READ — `lcdxf.cpp:1589` `appendBulgeArcVertex()` recovers each ARC edge as one bulged vertex. Commits
  edcc7ca5a + 177d413a1/025ba14bc. **RESIDUAL:** ellipse/spline boundary edges are still flattened to
  straight chords on write (`lcdxf.cpp:1324`) — arcs are preserved, but curved (ellipse/spline-bounded)
  hatches still reopen as polygon approximations. *(ws-dxf-write-fidelity)*
- ~~**TEXT write emits single-line DXF TEXT, never MTEXT** — an MTEXT read back as `.text` is written
  as TEXT; multi-line layout, MTEXT attachment-point alignment, and inline format codes are not
  reconstructed.~~ **DONE**: there is now a first-class `EntityKind.mtext` (`Entity.swift:1714`); WRITE —
  `DXFWriter.swift:770-787` → `lcdxf.cpp` `writeMText` emits real `DRW_MText` (attachment 71, line-spacing
  44/73, rect width 41). Commit f107dbe00. The TEXT→TEXT note now applies ONLY to entities that were
  genuinely single-line TEXT. *(ws-dxf-write-fidelity)*
- ~~**SPLINE / splinePoints write still skipped**~~ DONE: `writeSpline` added to the C bridge
  (`.spline` → control-point DXF SPLINE w/ degree+knots+weights+code-70 flags; `.splinePoints` →
  degree-2 SPLINE w/ control polygon + fit points). No longer counted as skipped. *(ws-dxf-write-fidelity)*
- **DIMENSION read+write covers linear/aligned/radial/diametric/angular only** — the five
  `DimKind`-modelled variants round-trip (read: `addDim*` → `LC_ENT_DIMENSION` → `.dimension`; write:
  `.dimension` → `DRW_Dim*`).
  ~~DXF **ordinate** and **angular-3p** dimensions are NOT in the frozen `DimKind`, so they still surface
  as a "DIMENSION" reader warning and are never written (dim_sample.dxf has 6 ordinate dims that stay
  warnings). Add `DimKind.ordinate`/`.angular3p` + resolve arms first.~~ **DONE**: `DimKind.ordinate`
  (`Entity.swift:826`) + `.angular3p` (`Entity.swift:843`) with the full read/write/resolve chain
  (`lcdxf.cpp:1765`/`:1781` read, `:3293`/`:3302` write; `DXFReader.swift:868-883`;
  `DXFWriter.swift:1447-1477`; `Resolve.swift:1926`/`:1933`). Commit 022ff732d — dim_sample's 6 ordinate
  dims now import instead of warning.
  ~~Also: the DIMENSION entity's **text height / arrow size live in DIMSTYLE, not on the entity**, so
  `DimData.textHeight`/`arrowSize` do NOT survive a DXF *round-trip* on WRITE (they reset to the resolve
  defaults); carrying them on write needs a DIMSTYLE table writer.~~ **DONE**: `lcdxf.cpp:2344`
  `writeDimstyles()` emits one `DRW_Dimstyle` per style, and per-entity overrides also survive via
  `ACAD:DSTYLE` xdata (`lcdxf.cpp:3239-3250`). Commits 1e660df61 + 888bb2956. **CAVEAT:**
  `writeDimstyles` starts with `if (m_dwg) return;` (`lcdxf.cpp:2345`) → DWG WRITE of named DIMSTYLE is a
  no-op (named styles dropped on `.dwg` save; DXF is full).
  ~~**READ side: `addHeader`/`addDimStyle` were no-ops → every dim fell back to the 2.5 engine default**~~
  DONE (ws-dimstyle-header-read, DC.5): the bridge now reads the HEADER vars (`$INSUNITS`/`$LUNITS`/
  `$LUPREC`/`$AUNITS`/`$AUPREC`/`$DIMTXT`/`$DIMASZ`/`$DIMSCALE`/`$DIMLUNIT`/`$DIMDEC`) and the DIMSTYLE
  table via new `LCHeader`/`LCDimStyle` PODs + `lc_header()`/`lc_dimstyles()`/`lc_dimstyle_count()`
  accessors (both DXF and DWG paths, since both use `FlatteningReader`). `DXFReader` maps them into
  `CADDrawing.graphicVariables`, so the existing `dimStyleProvider` resolves dims at the file's real size.
  Per-dimension `ACAD:DSTYLE` xdata overrides (1070 140/41 + 1040 value) are stamped onto
  `DimData.textHeight`/`arrowSize` (per-entity wins). Validated on the owner's
  `mechanical_example-imperial.dwg`: dim text height 2.5 → 0.125, units mm → inch. *(ws-dimstyle-header-read)*
  The rendered geometry's **anonymous block (code 2) is not
  authored** — we write the entity definition with an empty block name (libdxfrw forces the type-70 |32
  bit); a real CAD app regenerates the block and our own `resolve()` regenerates the visual on read.
  *(ws-dim-dxf)*

## Render gate — DXF reader (F)
- Add a DXF fixture covering SPLINE + ELLIPSE + true-color (color24) to lock the mapping (dim_sample.dxf has none). *(review-dxfread #3)*
- Strengthen `pensMapped` test (currently `allSatisfy { _ in true }` no-op) with a real pen assertion. *(review-dxfread #2)*
- Comment that `lc_dxf_count_entities` now parses+flattens the whole file (no longer alloc-free). *(review-dxfread #4)*
- Layer with ACI 256 silently → green instead of inheriting (rare/invalid edge). *(review-dxfread #1)*

## Coordinate / canvas (offset resolved)
- ~~Add a `worldToScreen ↔ worldToClip` consistency regression test (same world point → same screen pixel across sizes/backing/pan/zoom) — locks in the offset fix.~~ **DONE** — `CoordinateConsistencyTests.swift` asserts same world → same pixel across sizes/backing/pan/zoom + far-origin offset.
- ~~Remove (or keep env-gated) the `LC_DEBUG_COORDS` instrumentation in CADCanvasView once we're confident the offset stays fixed.~~ **DONE** — zero hits across Sources; `CoordinateConsistencyTests` header documents the removal.

## Layers / rendering
- ~~**Layer visibility render filter** (sidebar gap)~~ DONE (verified already-correct): `LineRenderer.packEntity` skips hidden/frozen-layer entities (lines AND fills) via `layers.layer(e.layer)?.isVisible==false`, and the sidebar eye toggle bumps `modelVersion` to re-cull. Extracted the predicate into GPU-free `RendererVisibility` + added `RendererVisibilityTests`. (ws-sidebar flag)
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
- ~~DXF/DWG **write** + Save (currently read-only viewer). *(DXF Save now native via DocumentGroup.)*~~
  **DWG read + write DONE** (feature DC.2): the vendored libdxfrw exposes `dwgRW` (read + write) in this
  repo — read for R2000+ DWG, write for R2000 (AC1015) ONLY. Surfaced via new C ABI `lc_dwg_read` /
  `lc_dwg_write` (`lcdxf.{cpp,h}`), reusing the SAME `FlatteningReader`/`WritingInterface` and POD entity
  stream as DXF; the writer dispatches per-entity to `dxfRW` or `dwgRW` via `emit*` helpers. Engine entry
  points: `CADEngine.readEntities(dwgPath:)` / `writeEntities(...toDWGPath:)` + `loadDrawing(dwgPath:)`.
  App: `.dwg` registered in `LibreCADUTType` (`com.autodesk.dwg`, imported), `LibreCADDocument`
  readable+writable, `DXFDocumentCodec` routes by content type, Info.plist DWG type promoted to Editor.
  **Known DWG gaps** (libdxfrw writer phase, not our wiring): (a) DWG write is R2000-only; (b) block
  **member geometry** does NOT round-trip to DWG — `dwgWriter15::defineBlock` makes EMPTY user blocks, so an
  INSERT references an empty block on re-read (DXF writes full block contents). (c) NO real third-party
  `.dwg` sample ships in the repo, so the read path is verified only against files our own writer produces
  (self-generated round-trip in `DWGReadWriteTests`); reading AutoCAD-authored DWGs rides on libdxfrw's
  shared reader (the same code LibreCAD-Qt uses) but is NOT directly tested here — add a real sample when one
  is obtainable.

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

## Test infra
- **Core Text static-init deadlock (parallel `swift test`)** — `CADFonts.provider` (CADDrawing.swift) makes its first `CTFont*` calls inside a `swift_once` static-init critical section; under the parallel test runner this lock-inverts with `@MainActor` tests → ~2-3/30 runs hang at 0% CPU. **Workaround in use:** run the gate with `--no-parallel` (0 hangs, <1s). **Proper fix (TODO):** ensure NO `CTFont*`/font resolution happens during ANY `static let`/`swift_once` initializer — make the provider static-init cheap and move first Core Text touch to a lazy per-call path (or a deterministic main-thread warm-up). A prior attempt (`/tmp/font-fix-attempt.diff`, 2026-06-15) reduced but did not eliminate it — needs a complete audit of all font static-init paths. *(diagnosis: decision-log 2026-06-15)*
- **Relocate `enum PaperSize` out of `DocumentSettingsView.swift`** (a SwiftUI file) into a non-SwiftUI model file. `CanvasModel` references `PaperSize`, so tests that symlink `CanvasModel.swift` into the test target (`_SharedCanvasModel.swift`) can't resolve it and currently rely on a test-only `PaperSize` shim in `RelativeZeroTests.swift`. Moving the enum lets the symlink resolve cleanly and removes the shim. S. *(decision-log 2026-06-15, G5)*
