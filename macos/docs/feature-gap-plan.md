# LibreCAD Feature-Gap Plan (refreshed, code-grounded)

> Supersedes the stale `feature-catalog.md`. Produced by the `librecad-feature-gap-audit` workflow
> (10 code-grounded category auditors → synthesis → disjointness critic, verdict REVISE-BEFORE-DISPATCH
> with 5 fixes applied below). _2026-06-16, `native-macos @ 863f1a991`._
>
> **Finding:** the catalog was right that most of LibreCAD is already implemented. Genuine gaps cluster
> into cheap **wire-waves** (engine present, UI missing) + two strategic P0s, with heavy/niche items deferred.

## Critic fixes applied
1. Grip overlay mounts in **`Canvas/CADCanvasView.swift`** (where GizmoOverlay/DynamicGripOverlay mount), NOT ContentView — owned by the grip-mount slot.
2. **`DrawingExporter.swift` is app-module** (`Sources/LibreCADmacOS/Export/`, imports CADEngine) — isolated file, but 3C consumes its new `ExportFormat` cases (dependency edge).
3. **`ToolKind.measureLength` already exists** (a Total-Length HUD) → DivideTool `.byLength` is a **mode on `.divide`**, NO new ToolKind.
4. **Control-point NURBS = a MODE on the existing `.spline` tool** (SplineTool currently emits `.splinePoints`; add a control-point mode emitting `.spline`/`SplineData`) — NO new ToolKind.
5. **DimStyle Manager = standalone `Sidebar/DimStyleManagerView.swift`**; `InspectorEditors.swift` gets ONLY the hatch dropdown + dim text-edit fields. (Also: `ToolCatalog` flyouts/roster live in ContentView → roster edits are ContentView-owner only; option-bar arms are ToolOptionsBar-owner only.)

## Build-now set (Tiers A–C); Tier D + XL deferred

### WAVE 1 — engine / isolated files (build UNWIRED, ≤4 parallel)
| B | Owned files | Deliverable |
|---|---|---|
| 1A | `CADEngine/EntityGrips.swift` (new) + tests | Pure per-EntityKind grip-point generator + `drag grip i → new EntityRecord` solver (sibling to GizmoTransform). **Fix the public API as a day-1 contract** (2E overlay + 3B mount consume it). NO app import. |
| 1B | `CADEngine/Inspect/InspectorEdits.swift` | `setDimTextMiddle`/`setDimTextRotation`/`setDimOblique` setters (model+DXF round-trip already present). |
| 1C | `CADEngine/Tools/DivideTool.swift` + tests | `.byLength` mode (spacing) reusing `SnapGeometry.pointsAlong*`. **Mode on `.divide`, NO new ToolKind.** |
| 1D | `CADEngine/Tools/SplineTool.swift` + tests | Control-point construction **mode** emitting `.spline` (`SplineData`/NURBS); fit-point `.splinePoints` stays default. **NO new ToolKind.** |
| 1E | `CADEngine/Tools/ScaleTool.swift` + tests | Non-uniform `sx/sy` mode via `EntityTransform.scale(sx:sy:about:)`. |
| 1F | `LibreCADmacOS/Export/DrawingExporter.swift` (app-module; isolated) | `.jpg/.bmp/.tiff` `ExportFormat` cases + UTType + DPI param (generalize `writePNG` via CGImageDestination). → feeds 3C. |

### WAVE 2 — UI additive / new files (parallel, different app files)
| B | Owned files | Deliverable |
|---|---|---|
| 2A | `LibreCADmacOS/Sidebar/InspectorEditors.swift` | Hatch pattern dropdown (swatch over `HatchPatternLibrary.patterns`) + dim text-edit fields (consume 1B). |
| 2B | `LibreCADmacOS/Sidebar/DimStyleManagerView.swift` (new) | Standalone DimStyle Manager driving `mutateDimStyles/upsertDimStyle`. |
| 2C | `LibreCADmacOS/ToolOptionsBar.swift` | Option-bar arms: hatch pattern/scale/angle · ScaleTool X/Y · DivideTool mode+length · SplineTool mode picker · polar increment. |
| 2D | `LibreCADmacOS/AppSettingsView.swift` | Snapping-pref read-site seeding + polar-increment + intermediate DXF tiers (R14/R2004/R2007). |
| 2E | `LibreCADmacOS/Canvas/EntityGripOverlay.swift` (new) | Grip overlay NSView (clone of DynamicGripOverlay): hit-test + drag → 1A solver. (Mount in Wave 3.) |

### WAVE 3 — SERIALIZED wire-waves (hot files; single owner each)
- 3A **`Tools/ToolKind.swift` (SOLO)** — append `.splineEdit` case + makeTool arm (the only genuinely-new ToolKind: wiring the existing unwired `SplineEditTool`). (DivideTool/SplineTool/ScaleTool modes need NO new case.)
- 3B **`Canvas/CanvasModel.swift` (SOLO)** — `applyToolConfig` arms (hatch/scale/divide/spline modes); grip-overlay state+commit; `isolateLayer`→`LayerIsolation` (+ unisolate/off-others/make-current); snap-distance/manual-arm state.
- 3B′ **`Canvas/CADCanvasView.swift` (SOLO)** — mount `EntityGripOverlay` (the real mount point). (Pair with 3B contract.)
- 3C **`ContentView.swift` (SOLO)** — `ToolCatalog` roster/flyouts for new modes; export-options DPI/format accessory (consume 1F).
- 3D **`LibreCADApp.swift` (SOLO)** — Edit-menu Cut/Copy/Paste/Paste-as-Block + ⌘X/C/V; spline-edit + layer-op + import/merge menus; custom About panel (GPLv2 credits).
- 3E **`LayersSidebar.swift` (SOLO)** — layer-row Select-Entities + Make-Current + isolate-selection context items (call 3B funnels).

### WAVE 4 — substantial P1 (later; each solo due to hot-file/lockstep contention)
- 4A Per-entity transparency (DXF 440): `Pen`/`Resolve`/`lcdxf.{h,cpp}`/`DXFReader`+`Writer`/`Shaders`+`LineRenderer` — DXF C-ABI lockstep + LineInstance byte-match (solo).
- 4B LTSCALE + LTYPE real-dash geometry: `lcdxf.cpp` + header var + both render paths (solo; conflicts with 4A on lcdxf.cpp).
- 4C Rich MTEXT authoring: `Canvas/TextEditorOverlay.swift` + a CADEngine/Text attributed↔run converter (View-layer editor; engine converter UI-free).

## Deferred (recommended; override if wanted)
XREF · MLEADER · GD&T tolerance · ACAD_TABLE · UCS (settable) · DWG-write >R2000 / DWG block-members · multi-layout DXF fidelity (libdxfrw-blocked) · plot styles CTB/STB · localization · scripting/LISP · keyboard-shortcut editor · gradient hatch · dynamic input · tracking guides · welcome screen · tiled viewports. _Rationale: XL and/or new-EntityKind and/or vendored-libdxfrw-blocked; low ROI for a personal 2D fork. The unified command line (a P0) is also held until after Tiers A–C since scripting depends on it._

## Traps
EntityKind switch (every item here is ADDITIVE — no new EntityKind) · ToolKind switch = solo (3A) · LineInstance byte-match (4A/4B) · DXF C-ABI lockstep (4A/4B/2D) · CADEngine-no-app-import (1A/1B engine UI-free) · headless-modal View-layer only (DimStyle/export/import/About/MTEXT) · serial tests · worktree discipline + merge-by-hash.
