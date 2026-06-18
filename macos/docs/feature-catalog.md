# Feature Gap Catalog — Upstream LibreCAD vs. our Swift app

> ## ⚠️ AUDITED 2026-06-18 — this catalog's per-row tables are HISTORICAL; the decision-log + README are authoritative
> A full code-level audit on 2026-06-18 (with an adversarial verification pass) found that **all 14 documented P0
> must-haves are DONE end-to-end**, with **one exception** (below). The 2026-06-12 per-row tables (sections 1–14)
> and the old "Recommended implementation order (next ~10)" + "P0 list" further down are **HISTORICAL** — treat them
> as a snapshot of the project ~5 feature-programs in the past. The authoritative "what shipped" record is
> **`decision-log.md`** (newest-first); the current forward plan is **`next-features-roadmap.md`**; the doc map is
> **`README.md`**.
>
> **THE ONE EXCEPTION (a real, actionable gap):** the interactive **Insert-a-block tool is PARTIAL, not done.**
> Engine + DXF INSERT/MINSERT round-trip are complete, BUT there is **no GUI block-name picker**: `InsertTool` is
> inert without a `blockName` (`InsertTool.swift:53,94,108-111`); `CanvasModel.beginInsert(name:)`
> (`CanvasModel.swift:3899-3908`) has **zero View-layer callers** (only tests call it); the Insert tool's
> `ToolOptionsBar` arm offers scale/rotation/MINSERT-array but **no block picker**; and the Blocks sidebar's
> `.draggable(BlockDragItem)` (`BlocksSidebar.swift:94`) has no matching canvas
> `.dropDestination(for: BlockDragItem.self)` (the canvas only handles `PartLibraryDragItem`) → a **dead drag**.
> Existing/imported blocks ARE placeable via the F9 Blocks sidebar's "Insert at View Center", "Insert Block from
> File…", and ⌘K — but **NOT** by interactive click-to-place. So pressing ⇧I / "Insert Block" and clicking
> currently does nothing.
>
> **Headline corrections — even the 2026-06-15 banner is now WRONG on these:**
> - **G7** "app Preferences window missing" is **FALSE** — `Settings { AppSettingsView() }` (⌘,) exists with 5 panes
>   (`LibreCADApp.swift:809`).
> - **G6a** "hatch boundary-arc bulge flattened on write" is **FALSE** — `writeHatch` emits real `DRW_Arc` loop edges
>   via `appendBulgeArcEdge` (`lcdxf.cpp:3069`).
> - **G6c** DXF version picker + DWG versioned save — **DONE**.
> - **G8** library browser / import-block-from-file / in-place block edit / ATTDEF–ATTRIB — **DONE**
>   (`PartsLibraryPanel.swift`, `BlockVisibilityStatesPanel`, `BlockAttributesEditor`).
> - Paper space & layouts + UCS — **DONE**.
>
> **Also DONE since the tables:** DIMSTYLE table + writer (DXF full; DWG-write is a no-op = lossy); hatch pattern
> lines (`.pat`); MTEXT true multi-line write; dim text-height/arrow round-trip; `DimKind` ordinate/arcLength/
> angular3p; INSERT entity + DXF; measure/info tools; zoom-window; Match-Properties; recent files; DocumentGroup;
> stretch/lengthen/break/join/align; all circle/arc/line construction variants; perpendicular/tangent snap;
> multi-select shared-property edit.
>
> **THE GENUINE REMAINING FRONTIER** (no longer table-stakes features — it's interop fidelity + test-infra):
> 1. **Foreign-AutoCAD DWG/DXF fidelity verification** — every round-trip today is self-generated (our writer ↔ our
>    reader); no real third-party sample lives in the repo.
> 2. **GUI-chrome screenshot tier beyond LCShot** (LCShot's ceiling is committed-geometry-only).
> 3. **Insert-tool block-picker wiring** (the exception above).
> 4. **Multileader full `CONTEXT_DATA` DXF write** — currently geometry-light; drawn callouts don't survive a DXF
>    round-trip.
> 5. **Non-modal save-loss notice.**
> 6. **Durable cross-session persistence** of tables + parametric constraints/parameters (DXF/DWG can't carry them).
> 7. **DWG-write fidelity** (empty blocks; `writeDimstyles` no-op).
> 8. **Per-type inline inspector geometry editors (G1)** + scale-aware print preview/page-setup (G2).
>
> See **`next-features-roadmap.md`** for the ranked plan.

**Purpose:** a *prioritized backlog* of features that **upstream LibreCAD has and our
native-macOS Swift port does NOT yet** (or only partially). This drives the build
waves. It complements `feature-inventory.md` (which catalogs the *full* upstream
surface); this doc focuses on the **delta** and our **implementation status**.

**Date:** 2026-06-12 · **Branch:** `feature-catalog-wt` (off `native-macos`) · **Audited/superseded:** 2026-06-15 (see banner)

## How to read this
- **Status:** `missing` (no engine support at all) · `partial` (model/engine
  support exists but no tool / no UI / lossy) · `stub` (UI placeholder only).
- **Priority:** `P0` = core daily CAD, must-have → `P3` = niche/advanced.
- **Effort:** `S` ≤ ~1 day · `M` ~2–4 days · `L` ~1+ week (engine + tool + UI + DXF).
- **Where (upstream):** the LibreCAD file/action/entity that implements it
  (grounded in `librecad/src/`), so a builder can read the reference.

## What we already have (baseline — NOT in the gap list)
For context, the current Swift surface:
- **Entities** (`Entity.swift` `EntityKind`): point, line, circle, arc, polyline (w/ bulge),
  ellipse, spline (NURBS), splinePoints, text, mtext, hatch, solid, dimension
  (linear/aligned/radial/diameter/angular).
- **Tools** (`Tools/`, ~29 via `ToolKind`): line, circle, arc, rectangle, polyline,
  point, ellipse, polygon, spline · move, copy, rotate, scale, mirror, offset, array,
  divide, explode (polyline) · trim, extend, fillet, chamfer · hatch · text ·
  linear/aligned/radial/diameter/angular dimension.
- **Snap** (`Snapping.swift`): free, grid, endpoint, center, middle, onEntity,
  intersection.
- **DXF** read (`DXFReader`) + write (`DXFWriter`, R2000 default) for the entities above.
- **Layers** (`Layer.swift`): name/color/linetype/width, frozen/locked/printable/
  construction flags; sidebar with visibility/lock toggles.
- **Blocks** (`Block.swift`): block *table* (add/remove/rename/active) — but NO insert
  entity (see gaps).
- **Text** (`Text/`): `.lff` + `.shx` stroke fonts, MText parser/shaper, text styles.
- **Export**: PDF, PNG, SVG; native Print. **App**: ⌘K command palette, undo/redo,
  layers/inspector sidebar, Save/Save As to DXF.

---

> **The tables in sections 1–14 below are the 2026-06-12 snapshot, kept for historical reference. For current status see the 2026-06-18 banner above + `decision-log.md`.**

## 1. Entities we lack

| Feature | Where upstream | Status | Pri | Eff | Note |
|---|---|---|---|---|---|
| **Block reference (INSERT)** | `rs_insert.h`, `RS_ActionBlocksInsert` | **missing** (no `EntityKind.insert`; reader skips INSERT → warning) | **P0** | L | Blockbiggest gap: we store block *tables* but cannot place/reference them. Needed for real DXF round-trip + symbol reuse. Add `case insert(InsertData)` + resolve (transform members) + reader/writer mapping. |
| **Construction line / ray (xline)** | `rs_constructionline.h`, `RS_ActionDrawLineRelAngle` etc. | missing | P1 | M | Infinite/semi-infinite reference lines. Add entity + draw tool; resolve clips to view. |
| **Image (raster underlay)** | `rs_image.h`, `RS_ActionDrawImage` | missing (reader skips IMAGE) | P2 | M | External raster reference; drag-drop place. |
| **Leader / multi-leader** | `rs_leader.h`, `lc_mleader.h`, `RS_ActionDimLeader` | missing | P1 | M | Annotation arrow + text. Pairs with dimension work. |
| **Hyperbola** | `lc_hyperbola.h` | missing | P3 | M | Advanced conic; niche. |
| **Parabola** | `lc_parabola.h`, `LC_ActionDrawParabola*` | missing | P3 | M | Advanced conic; niche. |
| **Hatch *patterns*** | `rs_hatch.h` (pattern lines) | **partial** (we model `patternName` + boundary loops but render every pattern as solid fill) | P1 | M | Pattern hatches (ANSI31 etc.) draw as solid today. Need a pattern-line generator (.pat library) + boundary-arc tessellation (bulges dropped now). |
| **Dimension: ordinate** | `LC_ActionDimOrdinate`, DXF ordinate dim | missing (not in frozen `DimKind`; reader → warning) | P2 | M | Add `DimKind.ordinate` + resolve + reader/writer. dim_sample.dxf has 6 ordinate dims that warn. |
| **Dimension: arc-length** | `lc_dimarc.h`, `LC_ActionDimArc` | missing | P2 | M | Add `DimKind.arc`. |
| **Dimension: angular-3-point** | (DXF angular3p) | missing (reader → warning) | P2 | S | Add `DimKind.angular3p`. |
| **Tolerance / GD&T frame** | `LC_ActionDrawGdtFeatureControlFrame` | missing | P3 | M | Partially disabled even upstream. |

---

## 2. Draw / construction tools we lack

| Feature | Where upstream | Status | Pri | Eff | Note |
|---|---|---|---|---|---|
| **Circle variants: 2P / 3P / CR** | `RS_ActionDrawCircle2P/3P/CR` | missing (only center+radius) | P1 | M | High-value daily variants; fold into circle tool as a mode toggle. |
| **Arc variants: 3-point / tangential** | `RS_ActionDrawArc3P`, `…Tangential` | missing (only center-pt-angle) | P1 | M | 3-point arc is daily-use; tangential chains off an endpoint. |
| **Line by angle / rel-angle** | `RS_ActionDrawLineAngle`, `…RelAngle` | missing | P1 | S | Typed angle entry. |
| **Parallel line (through pt / offset)** | `RS_ActionDrawLineParallel`, `…Through` | partial (Offset tool covers offset case) | P2 | S | Merge UX with offset. |
| **Bisector / tangent / orth-tangent** | `RS_ActionDrawLineBisector`, `Tangent1/2`, `OrthTan` | missing | P2 | M | Construction submenu. |
| **Perpendicular foot (point→line)** | `LC_ActionDrawLineFromPointToLine` | missing | P2 | S | Construction. |
| **Cross / centerline / midline** | `LC_ActionDrawCross`, `LC_ActionDrawMidLine` | missing | P2 | S | Annotation helpers. |
| **Ellipse variants (foci / 4-pt / inscribe / arc)** | `RS_ActionDrawEllipseFociPoint`, `4Points`, `Inscribe`, arc | partial (only axis) | P2 | M | Variant modes on ellipse tool. |
| **Rectangle variants (1-pt size / rounded / rotated 3-pt)** | `LC_ActionDrawRectangle1/2/3Points` | partial (only corner-corner) | P2 | M | Typed W×H + corner radius/chamfer. |
| **Polygon corner-corner / side-side / star** | `RS_ActionDrawLinePolygon2`, `LC_ActionDrawStar` | partial (only center→corner/tangent) | P2 | S | Variant modes. |
| **Circle from arc / inscribed / tangent circles** | `LC_ActionDrawCircleByArc`, `…Inscribe`, `Tan*` | missing | P2 | M | Construction submenu. |
| **Points along line / midpoints / lattice** | `LC_ActionDrawLinePoints`, `PointsLattice` | partial (Divide covers along-entity) | P3 | S | Power-user point generators. |
| **Bounding box** | `LC_ActionDrawBoundingBox` | missing | P3 | S | Utility. |
| **Slice/divide line·circle, snake line, dual** | `LC_ActionDrawSliceDivide`, `Snake`, `Dual` | missing | P3 | M | Advanced. |

---

## 3. Modify ops we lack

| Feature | Where upstream | Status | Pri | Eff | Note |
|---|---|---|---|---|---|
| **Stretch (crossing-window)** | `rs_actionmodifystretch.h` | missing | **P0** | M | Core editing op; move only the vertices inside a crossing window. |
| **Lengthen / line gap** | `lc_actionmodifylinegap.h` | missing | P1 | S | Numeric extend/trim by amount. |
| **Break / break-at-point (cut)** | `rs_actionmodifycut.h` | missing | P1 | M | Split an entity into two at a point (or remove a gap). |
| **Trim by amount / mutual trim-2** | `rs_actionmodifytrimamount.h`, `RS_ActionModifyTrim` (trim2) | partial (single-boundary trim only) | P1 | S | Numeric + both-segment trim. |
| **Join / line-join** | `lc_actionmodifylinejoin.h` | missing | P1 | M | Join collinear/connected lines into a polyline. |
| **Align (single / ref)** | `lc_actionmodifyalign*.h` | missing | P2 | M | Align selection to a reference. |
| **Properties on multiple / attributes edit** | `RS_ActionModifyAttributes`, `RS_ActionModifyEntity` | partial (`InspectorEdits` single-entity, geometry+pen; no multi-select shared-prop edit) | **P0** | M | Multi-select shared-property editing in the inspector. |
| **Move+rotate / rotate-2 combined** | `RS_ActionModifyMoveRotate`, `Rotate2` | missing | P2 | S | Combined transform. |
| **Revert direction** | `rs_actionmodifyrevertdirection.h` | missing | P2 | S | Flip entity direction (context menu). |
| **Order: raise/lower/top/bottom** | `rs_actionorder.h` | missing | P1 | S | Draw-order / arrange menu (Bring to Front etc.). |
| **Explode text → geometry** | `rs_actionmodifyexplodetext.h` | missing (we explode polylines only) | P2 | M | Convert text to stroke geometry. |
| **Explode INSERT (block)** | `rs_actionblocksexplode.h` | missing (needs INSERT first) | P1 | M | Blocked on §1 INSERT entity. |
| **Polyline node editing (add/del/append/trim-seg)** | `RS_ActionPolyline*` | missing | P1 | L | Add/append/delete node, delete-between, trim segment, arcs↔lines, equidistant. Direct handle manipulation. |
| **Spline node editing / convert** | `LC_ActionSpline*Point*`, `SplineExplode`, `FromPolyline` | missing | P2 | M | Add/remove fit points, explode, from-polyline. |
| **Duplicate (⌘D)** | `LC_ActionModifyDuplicate` | partial (Copy tool exists) | P1 | S | Quick in-place duplicate. |

---

## 4. Snap / OSNAP modes + restrictions we lack

| Feature | Where upstream | Status | Pri | Eff | Note |
|---|---|---|---|---|---|
| **Perpendicular snap** | `RS_Snapper` snap logic | missing | P1 | M | Snap to the perpendicular foot from the last point. |
| **Tangent snap** | `RS_Snapper` snap logic | missing | P1 | M | Snap to a tangent point on circle/arc/ellipse. |
| **Distance-along-entity snap** | `ActionSnapDist` | missing | P1 | S | Snap at a fixed distance along an entity. |
| **Middle-manual / intersection-manual** | `LC_ActionSnapMiddleManual`, `RS_ActionSnapIntersectionManual` | missing (auto middle/intersection only) | P2 | S | On-demand override. |
| **Ortho / horizontal / vertical restriction** | `ActionRestrictOrthogonal/Horizontal/Vertical` | **missing** | **P0** | S | Hold-⇧ ortho is table-stakes for drawing straight. |
| **Relative zero: set / lock / unlock** | `RS_ActionSetRelativeZero`, `LockRelativeZero` | **missing** | **P0** | M | "Set origin here" + relative coordinate base; pairs with typed `@dx,dy` entry. |
| **Snap settings (aperture/toggles UI)** | snap toolbar / settings | partial (`setSnapMode` exists; no UI surface) | P1 | S | Toolbar/menu toggles + aperture slider. |

---

## 5. Coordinate / command input we lack

| Feature | Where upstream | Status | Pri | Eff | Note |
|---|---|---|---|---|---|
| **Typed coordinate entry (`@dx,dy` / `dist<angle`)** | command-line parser + snapper | **missing** | **P0** | M | Precise input while drawing; absolute + relative + polar. |
| **Coordinate widget (live abs/rel readout)** | `QG_CoordinateWidget` | partial (snap result shown; no abs/rel HUD) | P1 | S | On-canvas/status HUD. |
| **Command line / palette extended commands** | `QG_CommandWidget` | partial (⌘K palette runs tools; no command-string parser) | P1 | M | Classic command bar for power users. |
| **Mouse-hint / selection-count widgets** | `QG_MouseWidget`, `QG_SelectionWidget` | missing | P2 | S | Status bar segments. |
| **Info cursor (live measurements)** | `LC_InfoCursorSettingsManager` | missing | P2 | M | On-canvas live length/angle while drawing. |

---

## 6. Selection tools we lack

| Feature | Where upstream | Status | Pri | Eff | Note |
|---|---|---|---|---|---|
| **Select all / deselect all** | `RS_ActionSelectAll` | missing (no ⌘A/⌘⇧A action) | **P0** | S | Engine has primitives; just wire actions + menu. |
| **Invert selection** | `RS_ActionSelectInvert` | missing | P1 | S | Edit menu. |
| **Select by layer** | `RS_ActionSelectLayer` | missing | P1 | S | Right-click layer → Select Entities. |
| **Select contour / connected** | `RS_ActionSelectContour` | missing | P1 | M | Select a connected chain. |
| **Select intersected (crossing line)** | `RS_ActionSelectIntersected` | missing | P2 | M | Fence selection. |
| **Window vs crossing semantics** | `RS_ActionSelectWindow` | partial (`Selection.swift` has window+crossing predicates; verify L→R/R→L UX) | P1 | S | Confirm directional rubber-band semantics in app. |

---

## 7. Blocks / inserts / attributes we lack

| Feature | Where upstream | Status | Pri | Eff | Note |
|---|---|---|---|---|---|
| **Insert a block (place reference)** | `RS_ActionBlocksInsert` | **missing** (no INSERT entity) | **P0** | L | Depends on §1 INSERT entity. The keystone for symbol reuse + DXF fidelity. |
| **Create block from selection** | `RS_ActionBlocksCreate` | partial (table add exists; no "group selection into block" tool) | P1 | M | Tool: group selection → named block + replace with INSERT. |
| **Edit block / explode insert** | `RS_ActionBlocksEdit`, `Explode` | missing | P1 | M | In-place block editing; explode → members. |
| **Block attributes (ATTDEF/ATTRIB)** | `RS_ActionBlocksAttributes` | missing | P2 | L | Parametric block text fields. |
| **Block list panel** | `QG_BlockWidget` | **stub** (`LayersSidebar` blocks section is read-only stub) | P1 | M | Make blocks sidebar live (insert/toggle/freeze). |
| **Library browser + insert** | `QG_LibraryWidget`, `RS_ActionLibraryInsert` | missing | P1 | L | Parts/symbols gallery; drag-drop place. |
| **Import block from file** | `RS_ActionBlocksImport`, `BlocksSave` | missing | P2 | M | Import a .dxf as a block. |

---

## 8. Layers we lack

| Feature | Where upstream | Status | Pri | Eff | Note |
|---|---|---|---|---|---|
| **Layer visibility *render* filter** | (engine) | **partial/bug** | **P0** | S | Sidebar eye toggles model state but the renderer + `resolve()` don't skip hidden/frozen-layer entities (see `backlog.md`). Pixels don't hide. |
| **Add / remove / edit layer (full)** | `RS_ActionLayersAdd/Remove/Edit` | partial (engine ops exist; sidebar add/edit UI limited) | P1 | S | Inline add/rename/color/linetype editing. |
| **Toggle print / construction per layer** | `RS_ActionLayersTogglePrint`, `…Construction` | partial (flags modeled; sidebar exposes visibility/lock only) | P1 | S | Surface print/construction toggles in sidebar. |
| **Freeze/lock all, defreeze/unlock all** | `RS_ActionLayersFreezeAll`, `LockAll` | missing | P2 | S | Sidebar overflow menu. |
| **Per-entity layer ops (activate/hide-others/move-to)** | `LC_ActionEntityLayer*` | missing | P1 | S | Right-click entity → Layer submenu. |
| **Layer tree (groups/filter)** | `LC_LayerTreeWidget` | missing | P3 | L | Advanced grouping. |
| **Export selected/visible layers** | `LC_ActionLayersExport` | missing | P2 | S | Export sheet. |

---

## 9. Dimensioning we lack

| Feature | Where upstream | Status | Pri | Eff | Note |
|---|---|---|---|---|---|
| **Dimension styles (DIMSTYLE table)** | `lc_dlgdimstylemanager.ui`, dimstyles builder | **missing** | **P0** | L | We carry `styleName` but never resolve it; text height/arrow size DON'T survive DXF round-trip (live in DIMSTYLE). A style table is required for real interop. |
| **Baseline / continue** | `LC_ActionDrawDimBaseline` | missing | P1 | M | Chained dimensions off a common origin. |
| **Leader** | `RS_ActionDimLeader` | missing | P1 | M | See §1 leader entity. |
| **Ordinate / arc-length / angular-3p** | (see §1) | missing | P2 | M | New `DimKind` cases + resolve + DXF. |
| **Tolerance text** | `lc_dlgtolerance.ui` | missing | P2 | M | ± tolerance on dimension text. |
| **Apply dim style / regenerate dims** | `LC_ActionDimStyleApply`, `RS_ActionToolRegenerateDimensions` | missing | P2 | S | Re-apply style after changes. |
| **Dimension text height/arrow round-trip** | DIMSTYLE | **partial/lossy** | P1 | M | Blocked on DIMSTYLE writer (backlog `ws-dim-dxf`). |

---

## 10. File formats we lack

| Feature | Where upstream | Status | Pri | Eff | Note |
|---|---|---|---|---|---|
| **Spline DXF write** | libdxfrw `writeSpline` | **missing** (counted/skipped on write) | **P0** | M | Splines created in-app are LOST on save. Must add `writeSpline` mapping. |
| **INSERT DXF read/write** | `RS_FilterDXFRW` | missing (blocked on §1) | **P0** | L | Block refs not preserved through DXF. |
| **Hatch pattern + boundary-arc round-trip** | libdxfrw `writeHatch` | partial/lossy (boundary written as line edges; bulges dropped; pattern → solid) | P1 | M | Backlog `ws-dxf-write-fidelity`. |
| **MTEXT write (true multi-line)** | `RS_FilterDXFRW` | partial/lossy (MTEXT written as single-line TEXT) | P1 | M | Reconstruct MTEXT codes on write. |
| **DXF version picker (R12 / R2018)** | `RS_FilterDXFRW` versions | **done** (Preferences ▸ General ▸ Files picker; default R2000; resolved off-main through the codec) | — | — | `DXFExportVersion` + `DXFVersionPickerTests`. |
| **DWG read / write** | `RS_FilterDXFRW` (DWGSUPPORT) | **done** (open `.dwg` + versioned save R2000/R2004/R2010/R2013/R2018 over libdxfrw round-3 writers; UTType/Info.plist registered; round-trip tested) | — | — | DWG save-version picker in Preferences (R2007/R12/R14 excluded — no `dwgwriter21`, clamp to R2000); honest "may not round-trip" caption; foreign-AutoCAD fidelity unverified in-repo. |
| **Image (raster) import** | `rs_image.h` | missing | P2 | M | See §1 image entity. |
| **SVG / PDF *import*** | (not native upstream; PDF via poppler-ish) | missing | P3 | L | We export SVG/PDF but can't import. |
| **LFF / CXF font *files* as user fonts** | `RS_FilterLFF/CXF` | partial (LFF/SHX parsing exists; bundling/user-font picker TBD) | P2 | S | Font management UI. |
| **JWW / JWC / DXF1 legacy import** | `RS_FilterJWW`, `RS_FilterDXF1` | missing | P3 | M | Legacy formats. |
| **CLI: dxf2pdf / dxf2png** | `console_dxf2pdf/png` | missing | P3 | M | Headless converters reusing the engine. |
| **MakerCAM / CAM SVG export** | `LC_ActionFileExportMakerCam` | missing | P3 | M | CAM export. |

---

## 11. Layout / print we lack

| Feature | Where upstream | Status | Pri | Eff | Note |
|---|---|---|---|---|---|
| **Paper space / layouts** | `$PINSBASE` paper space; layout model | **missing** (model-space only) | P1 | L | Multiple named layouts/viewports for plotting. |
| **Print preview (scale/options)** | `RS_ActionPrintPreview`, `qg_printpreviewoptions.ui` | missing (native Print only, no preview-with-scale) | P1 | M | Live print-layout with scale + paper size. |
| **Page setup / device options** | `lc_deviceoptions.ui`, PaperFormat | partial (system print dialog) | P1 | S | Paper size / margins sheet. |
| **Print to PDF (layout-aware)** | `ActionFilePrintPDF` | partial (PDF *export* of model exists; not layout/scale-aware) | P2 | M | Scale-correct plot. |
| **Named views (save/restore)** | `LC_NamedViewsListWidget` | missing | P2 | M | Saved camera views sidebar. |
| **UCS (user coordinate systems)** | `LC_ActionUCSCreate`, `LC_UCSListWidget` | missing | P3 | L | Custom axes/origin. |

---

## 12. View / zoom we lack

| Feature | Where upstream | Status | Pri | Eff | Note |
|---|---|---|---|---|---|
| **Zoom window (drag-zoom)** | `RS_ActionZoomWindow` | missing (have fit + scroll-zoom) | P1 | S | Drag a box to zoom. |
| **Zoom previous** | `RS_ActionZoomPrevious` | missing | P2 | S | Back to prior view. |
| **Grid / draft-mode toggles in UI** | `ActionViewGrid`, `ActionViewDraft` | partial (grid exists; verify View-menu toggles) | P1 | S | Surface in View menu. |

---

## 13. UI/UX features we lack

| Feature | Where upstream | Status | Pri | Eff | Note |
|---|---|---|---|---|---|
| **Per-type entity inspector editors** | `lc_dlgentityproperties.ui` + per-type widgets | partial (`InspectorEditors` covers some types/fields) | P1 | M | Full per-type editing (ellipse/spline/hatch/dim/mtext fields). |
| **Multi-select shared-property edit** | `RS_ActionModifyAttributes` | missing | **P0** | M | Edit pen/layer/common props across a selection. |
| **Pen palette / eyedropper / copy-pen** | `LC_PenPaletteWidget`, `LC_ActionPenPick/Apply/Copy` | missing (pen editable per-entity in inspector) | P1 | M | Pick/apply pen, "reset to layer". |
| **Recent files** | `QG_RecentFiles` | missing | P1 | S | File → Open Recent. |
| **New from template** | `ActionFileNewTemplate` | missing | P2 | S | Template chooser. |
| **DocumentGroup (native open/save/recents/autosave/versions)** | (macOS) | **missing** (intentionally on WindowGroup after a launch crash) | **P0** | L | Backlog: reintroduce off-main-safe `ReferenceFileDocument`. Blocks autosave/versions/recents. |
| **Measure / info tools (distance, angle, area, total length)** | `rs_actioninfo*.h` (`InfoDist/Angle/Area/TotalLength`) | **missing** (no engine measure tools) | P1 | M | Daily-use query tools. |
| **Keyboard shortcuts editor** | `lc_actionsshortcutsdialog.ui` | missing | P3 | M | Customize shortcuts. |
| **Workspaces (saved layouts)** | `dock_widgets/workspaces` | missing | P3 | M | Saved panel arrangements. |
| **About / welcome / update dialogs** | `lc_dlgabout.ui`, `qg_dlginitial.ui` | missing | P3 | S | Standard chrome. |

---

## 14. Settings / preferences we lack

| Feature | Where upstream | Status | Pri | Eff | Note |
|---|---|---|---|---|---|
| **Drawing options (units/grid/paper/dims/splines/points/vars)** | `RS_ActionOptionsDrawing` → `qg_dlgoptionsdrawing.ui` | **missing** (no document-settings sheet) | **P0** | M | Units, grid spacing, paper size, default dim/spline/point settings. |
| **Application preferences (appearance/snap/render/paths/startup)** | `qg_dlgoptionsgeneral.ui` | missing (theme exists; no Settings window) | P1 | M | macOS Settings (⌘,) panes. |
| **Dimension style manager** | `lc_dlgdimstylemanager.ui` | missing | P2 | L | See §9 DIMSTYLE. |
| **Point display style** | drawing options Points tab | missing | P2 | S | Point glyph/size picker. |

---

## Current status & next steps (2026-06-18)

The original **14 P0 must-haves are all done** end-to-end — **except** the interactive
Insert-tool block picker (see the 2026-06-18 banner at the top: engine + DXF INSERT/MINSERT
round-trip ship, but there is no GUI block-name picker wired into `InsertTool` / the canvas).
The prioritized **forward plan now lives in `next-features-roadmap.md`** — it's no longer about
table-stakes features but about interop fidelity (foreign-AutoCAD DWG/DXF), DWG-write fidelity,
multileader DXF, and test-infra. The four **owner-decision questions** flagged on 2026-06-12 are
all **resolved**:

- **DocumentGroup vs WindowGroup** → shipped (native open/save/recents/autosave via DocumentGroup).
- **DWG path** → wired and **versioned** (R2000/R2004/R2010/R2013/R2018 save picker).
- **Hatch patterns vs solid** → implemented as `.pat` pattern-line families.
- **Dimension model scope** → all three subtypes added (`DimKind` ordinate / arcLength / angular3p).

See **`next-features-roadmap.md`** for the ranked plan and **`decision-log.md`** for the
chronological "what shipped" record.
