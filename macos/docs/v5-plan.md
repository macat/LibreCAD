# v5 Plan — Parallel Push for the Remaining LibreCAD Feature Backlog

**Author:** integration-architect (autonomous; owner away) · **Date:** 2026-06-12
**Baseline:** `native-macos` @ `aa725782f` — **1185 tests / 87 test files**, app reassembled green.
**Goal:** implement *most of the still-missing* P0/P1 (+ select P2) features from
`feature-catalog.md`, organized so parallel agents' outputs **integrate cleanly** — no file
collisions, no broken exhaustive switches, consistent UX, properly wired. This is the
**wave-by-wave execution plan** the coordinator runs.

> **Read-order for the coordinator:** this doc → `CONVENTIONS.md` (worktree/merge discipline) →
> `decision-log.md` (what v3/v4 shipped) → the per-agent briefs you cut from §4. Every agent
> brief MUST carry §7 (Consistency conventions) + the namespace-test-suites rule from CONVENTIONS.

---

## 0. What is ALREADY done (do NOT re-plan — supersedes the stale catalog)

`feature-catalog.md` (dated 2026-06-12, branch `feature-catalog-wt`) predates the v3/v4 build and
lists several things as "missing" that **already shipped**. Per `decision-log.md` + `DEVLOG.md`,
these are DONE and out of scope here:

- **Entities:** INSERT/block-reference (`EntityKind.insert` + MINSERT + resolve via
  `blockProvider` + DXF read/write). text/mtext/hatch(solid)/solid/dimension(5 kinds).
- **Tools (37 in `ToolKind`):** the draw/modify/edit set incl. **Stretch / Lengthen / Break /
  PolylineEdit**, Trim/Extend/Fillet/Chamfer, Array/Divide/Explode, Spline/Hatch/Ellipse/Polygon,
  5 dimension tools, Text, Insert.
- **Snaps:** free/grid/endpoint/center/middle/onEntity/intersection/**nearest/perpendicular/
  tangent/parallel** (`SnapMode` bits 0–10). **Ortho** (F8/⇧).
- **Input/UX:** command/coordinate input line (`@dx,dy` / `dist<angle`), tool-options bar,
  status bar + crosshair, marquee select (window/crossing), hover highlight, right-click context
  menus, entity clipboard (cut/copy/paste/duplicate), Select All/Deselect/Invert, ⌘K palette,
  on-canvas gizmos, Inspector (single-entity geometry/pen/text-style edit).
- **Files:** DXF read+write (R2000 default, version-capable), **DWG read+write** surfaced
  (open/save .dwg), spline-DXF-write, dimension DXF round-trip (5 kinds), MTEXT write, SHX import.
- **App:** **DocumentGroup** (`LibreCADDocument: ReferenceFileDocument`, native recents/autosave/
  versions/dirty), Document Settings sheet (⌥⌘,), Export PDF/PNG/SVG + Print, NavigationSplitView
  Layers sidebar, layer-visibility render filter, CI + ad-hoc signing.
- **Read fix (today):** header/DIMSTYLE/units read (`$DIMTXT`/`$DIMASZ`/`$DIMSCALE`/`$INSUNITS`).

**Net:** v5 picks up the *true* remainder — construction lines, leader/mleader, raster image,
MLINE, real hatch **patterns** (.pat), named **DIMSTYLE table**, create-block-from-selection +
**live blocks sidebar**, layer states/filters, measurement/info tools, more modify tools (align /
join / scale-by-reference / array-path), point display styles, property-painter, the U4 toolbar
reorg, and the dim subtypes (ordinate/arc/angular-3p).

---

## 1. Feature set (the v5 backlog)

Legend — **Pri** P0–P2 · **Eff** S(≤1d)/M(2–4d)/L(1wk+) · **Class** (the integration property
that decides scheduling):
- **EK** = adds an `EntityKind` case → **serial** (one EK agent per wave; updates every exhaustive
  switch — see §3).
- **DK** = adds a `DimKind` case → serial like EK (the `DimData.kind` switches; see §3).
- **R** = touches `Resolve.swift` / `ResolveContext` (provider hooks) but adds no EK → serialize
  against the EK agent (same file).
- **T** = new **Tool** in its OWN `Tools/<Name>.swift` (parallel-safe; only a 2-line wire touch).
- **UI** = app-shell / sidebar / inspector / renderer surface (one UI-shell agent per wave).
- **BR** = touches the C++ bridge (`lcdxf.{cpp,h}`) — serialize against other BR agents.

| # | Feature | Catalog § | Pri | Eff | Class | Notes / integration touch |
|---|---|---|---|---|---|---|
| F1 | **Construction line / ray (xline/ray)** | §1 | P1 | M | **EK** | `EntityKind.xline(XLineData)` (infinite) + `ray`. resolve clips to view bounds (needs `ResolveContext.clipBounds`). Bridge `addXline/addRay` already read as unsupported → wire real read/write. New `XLineTool`/`RayTool`. |
| F2 | **Leader / multileader** | §1/§9 | P1 | M | **EK** | `EntityKind.leader(LeaderData)` (vertices + arrow + attached text/mtext block). resolve = polyline + arrowhead fill + text strokes. Bridge `addLeader` currently unsupported. `LeaderTool`. |
| F3 | **Raster image entity** | §1/§10 | P2 | M | **EK** | `EntityKind.image(ImageData)` (path/uv/size/rotation/brightness). resolve emits a textured-quad descriptor → renderer needs a **texture pipeline** (UI/renderer agent). Bridge `addImage` unsupported. Drag-drop place. |
| F4 | **MLINE (multi-line)** | §1 | P2 | L | **EK** | `EntityKind.mline(MLineData)` (style + vertices). resolve offsets parallel element lines. Lower value; can stage to a later wave. |
| F5 | **Dim subtypes: ordinate / arc-length / angular-3p** | §1/§9 | P2 | M | **DK** | Add `DimKind.ordinate`/`.arcLength`/`.angular3p` + resolve arms + bridge read/write. **dim_sample.dxf has 6 ordinate dims that currently warn.** ONE DK agent does all three together (single enum churn). |
| F6 | **Real hatch patterns (.pat)** | §1/§10 | P1 | M | **R** | No new EK. Pattern-line generator (.pat library bundled) + boundary-arc tessellation (bulges currently dropped). Touches `Resolve.swift` hatch arm + bundles `.pat`. Pairs with DXF pattern + boundary-arc round-trip. |
| F7 | **Named DIMSTYLE table + ext-line offsets** | §9/§14 | P0 | L | **R+BR** | The big interop gap. `DimStyleTable` on `CADDrawing` + resolve via the existing `dimStyleProvider` hook (per-entity wins, style fills); DXF/DWG **DIMSTYLE writer** (read already lands today). Ext-line offset/extension/gap (DIMEXO/DIMEXE/DIMGAP). Touches `Resolve.swift` + bridge writer. Unblocks baseline/continue/tolerance. |
| F8 | **Baseline / continue dimensions** | §9 | P1 | M | **T** | Chained dims off a common origin / previous dim. New tools; consume the existing `DimData`. Depends on F7 landing first (style coherence) but is a new-file Tool. |
| F9 | **Create-block-from-selection + live blocks sidebar** | §7 | P1 | M | **T+UI** | Tool: group selection → named block + replace with INSERT (engine op on `CADDrawing`/BlockTable). Sidebar: turn the read-only Blocks stub live (insert/rename/delete; drag-to-place). Tool part is new-file; sidebar part is the UI-shell agent. |
| F10 | **Explode INSERT (block) + edit-block** | §3/§7 | P1 | M | **T** | Explode = replace `.insert` with transformed member records (uses `blockProvider` + `EntityTransform`). New-file modify tool. |
| F11 | **Measurement / info tools (distance / angle / area / total-length)** | §13 | P1 | M | **T** | Read-only query tools → result to status bar / info panel. Pure-engine `MeasureTool` variants; no entity mutation. New files. |
| F12 | **Modify: Align (single/ref)** | §3 | P2 | M | **T** | Align selection to a reference (2-pt source→dest). New-file modify tool (uses `EntityTransform`). |
| F13 | **Modify: Join (collinear/connected → polyline)** | §3 | P1 | M | **T** | Join touching lines/arcs into one polyline. New-file modify tool. |
| F14 | **Modify: Scale-by-reference / offset-through-point** | §2/§3 | P1 | S | **T** | Scale tool reference mode; Offset "through a point" mode. Fold as **modes** into existing ScaleTool/OffsetTool — but to keep parallelism, deliver as additive options on those tool files (ONE owner each, no other agent touches them this wave). |
| F15 | **Modify: Array along path** | §3 | P2 | M | **T** | Distribute copies along a picked path entity. New-file modify tool (sibling to ArrayTool). |
| F16 | **Modify: Revert direction / draw-order (raise/lower/top/bottom)** | §3 | P1 | S | **T+UI** | Revert = flip entity direction (engine op + context-menu). Order = z-order list on `CADDrawing` + Arrange menu. Order needs a model field (draw-order index) → small `CADDrawing` touch; schedule with the doc-model agent. |
| F17 | **Layer states / filters + per-layer print/construction toggles + freeze-all** | §8 | P1 | M | **UI** | Sidebar: surface print/construction toggles, freeze/lock-all, per-entity layer ops (activate / move-to / hide-others). Layer "states" save/restore (named snapshots of layer flags). Sidebar/inspector-only. |
| F18 | **Select by layer / contour / connected** | §6 | P1 | M | **T/UI** | Select-by-layer = sidebar action. Contour/connected = engine traversal in `Selection.swift` (default-arm safe) + menu. Pure selection. |
| F19 | **Point display styles ($PDMODE/$PDSIZE)** | §1/§14 | P2 | S | **R+UI** | `PointData.style` field (additive) + resolve renders the marker glyph; Document-Settings Points tab picker. Touches `Resolve.swift` point arm + Entity (additive field, NOT a new EK) + settings UI. |
| F20 | **Property-painter (eyedropper / copy-pen / apply-pen)** | §3/§13 | P1 | M | **UI** | Pick pen+layer from an entity, apply to others; "reset to layer." Inspector/canvas-tool surface; engine op = `.replace` pen/layer. |
| F21 | **Multi-select shared-property edit** | §3/§13 | P0→ (verify) | M | **UI** | Inspector edits common pen/layer/props across a selection. *Check whether v4 Inspector already does this single-only; if so this is the gap.* Inspector-only. |
| F22 | **Explode text → geometry** | §3 | P2 | M | **T** | Convert `.text`/`.mtext` to stroke `.polyline`s (uses `fontProvider` resolve). New-file modify tool. |
| F23 | **Zoom window (drag-box) + zoom previous** | §12 | P1 | S | **UI** | Canvas interaction (CanvasModel/CADCanvasView) + View menu. UI-shell. |
| F24 | **Recent-from-template / new-from-template** | §13 | P2 | S | **UI** | Template chooser on new-doc. App-shell. (Recents already via DocumentGroup.) |
| F25 | **U4 toolbar reorg + menu grouping (decision D6)** | §13 | P1 | M | **UI** | Draw▾ / Modify▾ / Annotate▾ groupings + a slim customizable default set, rest via menu+⌘K. Big ContentView/LibreCADApp touch → its OWN wave (touches the wiring files everyone else avoids). |

**Deferred to a later round (out of v5 scope, by recommended default):** hyperbola/parabola (P3),
GD&T/tolerance frame (P3, disabled even upstream), table/regions (assess — DXF ACAD_TABLE is an
anonymous-block proxy; low value), paper-space/layouts + UCS + named views (P1/P3 L, a whole
subsystem — its own future plan), library browser (P1 L, rides on F9), JWW/legacy import + CLI
converters (P3). MLINE (F4) is included but lowest-priority; drop it if waves run long.

---

## 2. File-ownership matrix (the core integration tool)

Rows = the **shared hotspot files** (a write here forces serialization). Columns = the v5 features
that touch each. **Two features that share a ✗ row cannot run in the same wave** unless one is the
single serial owner of that file for the wave.

| Hotspot file | F1 xline | F2 leader | F3 image | F4 mline | F5 dimsub | F6 hatchpat | F7 dimstyle | F9 block | F10 explodeins | F16 order | F19 pointstyle | rest |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `CADEngine/Entity.swift` (EntityKind / *Data) | ✗ | ✗ | ✗ | ✗ | ✗(DimKind) | | | | | | ✗(field) | |
| `CADEngine/Resolve.swift` (+ResolveContext) | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | | | | ✗ | |
| `CADEngine/EntityTransform.swift` (exhaustive) | ✗ | ✗ | ✗ | ✗ | (dim arm ok) | | | | | | | |
| `CADEngine/Snapping.swift` (exhaustive ×2) | ✗ | ✗ | ✗ | ✗ | ✗(dim subswitch) | | | | | | | |
| `CADEngine/Selection.swift` (has default) | △ | △ | △ | △ | △ | | | | | | | F18 |
| `CADEngine/Inspect/InspectorEdits.swift` (exhaustive) | ✗ | ✗ | ✗ | ✗ | ✗ | | | | | | ✗ | |
| `CADEngine/DXFWriter.swift` (has default) | ✗ | ✗ | ✗ | ✗ | ✗ | ✗(boundary) | ✗(dimstyle) | | | | | |
| `DxfBridge/lcdxf.{cpp,h}` (BR) | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | | | | | |
| `CADEngine/CADDrawing.swift` (tables/undo) | | | | | | | ✗(DimStyleTable) | ✗(block ops) | ✗ | ✗(order) | | F17 |
| `Tools/ToolKind.swift` (wire only) | wire | wire | wire | wire | wire | | | wire | wire | wire | | wire |
| `LibreCADmacOS/ContentView.swift` (UI-shell) | | | drag-drop | | | | | sidebar | | menu | | F17 F20 F21 F23 F24 F25 |
| `LibreCADmacOS/LibreCADApp.swift` (menu/keymap) | wire | wire | wire | wire | wire | | | wire | wire | wire | | wire F25 |
| `LibreCADmacOS/Canvas/CanvasModel.swift` (config funnel) | △ | △ | △ | | | | | △ | | | | F20 F23 |
| `LibreCADmacOS/Renderer/LineRenderer.swift` | | | ✗(texture) | | | | | | | | ✗(point glyph) | |
| `LibreCADmacOS/Sidebar/*` | | | | | | | | ✗ | | | ✗ | F17 F20 F21 |

✗ = exclusive write · △ = read-only / default-arm safe (additive arm only, no behavior change to
existing kinds) · *wire* = the 2-line ToolKind/menu touch done in the **wire-wave**, never by the
feature agent.

**Reading the matrix:**
- The **Entity/Resolve/EntityTransform/Snapping/InspectorEdits cluster** is the critical section.
  F1, F2, F3, F4, F5, F19 all write some subset. → **at most ONE of these per wave** (§3).
- F6 (hatch patterns), F7 (dimstyle) write `Resolve.swift` but add **no EK** → they still collide
  with the EK agent on `Resolve.swift`. → they go in a wave where the EK slot is *them* (R-class),
  OR a wave with no EK agent.
- The **bridge** `lcdxf.cpp` is a second critical section (F1/F2/F3/F4/F5/F6/F7 all touch it). →
  bridge work for an entity is **part of that entity's serial EK step**, not a separate parallel
  agent.
- The **wiring trio** (`ToolKind` / `ContentView` / `LibreCADApp`) is touched ONLY in wire-waves
  (§5) and in F25 (its own wave). Feature agents never touch them.
- Everything else (new `Tools/*.swift`, info tools, join/align/explode-text, baseline-dim) is
  **parallel-safe new-file** work.

---

## 3. EntityKind / DimKind isolation list (serial steps — the merge MUST keep the build green)

Adding an `EntityKind` (or `DimKind`) case breaks every **exhaustive** switch until updated. Each
such feature is its **OWN serial step**; **at most one EK/DK/Resolve agent runs at a time.** Below
is the complete checklist of switches an EK addition must touch (verified by grepping the tree at
`aa725782f`).

### 3a. Exhaustive `switch entity.kind` sites (NO `default:` — build breaks if not updated)
These MUST get a new arm for any new `EntityKind` case:
1. `CADEngine/Resolve.swift` — **3 switches**: `resolve()` (line ~699), `boundingBox()` (~1498),
   plus the snap-point helper. The new arm produces `ResolvedGeometry` (+ bbox).
2. `CADEngine/EntityTransform.swift` — `transformed(by:)` (exhaustive). New arm transforms the
   *Data.
3. `CADEngine/Snapping.swift` — **2 exhaustive** switches (snap-point collection at ~308 and the
   geometry switch at ~394; the others at 380/477/514/539/568/693 have `default:`). New arm yields
   snap candidates (endpoints/center/etc.).
4. `CADEngine/Inspect/InspectorEdits.swift` — exhaustive (per-type editable fields). New arm lists
   the entity's editable defining fields.

### 3b. Switches with `default:` (safe — but SHOULD get a real arm for fidelity)
`DXFWriter.swift` (write mapping → needs a real arm to not silently skip), `Selection.swift`
(hit-test), and the tool files that branch on kind (`OffsetTool`/`HatchTool`/`ExtendTool` are
exhaustive but additive-arm-able; `TrimTool`/`BreakTool`/`StretchTool`/`LengthenTool`/`DivideTool`/
`DimensionTools` use `default:`). The EK agent adds a real `DXFWriter` arm + bridge write; the rest
fall through `default:` (acceptable — those tools simply don't operate on the new kind).

### 3c. The bridge (`DxfBridge/lcdxf.{cpp,h}`) — part of the same serial step
- `lcdxf.h`: add a `LC_ENT_*` enum value + any per-kind fields on `LCEntity`.
- `lcdxf.cpp`: implement the reader override (`addXline`/`addRay`/`addLeader`/`addImage`/…
  currently route to `addUnsupportedEntity`) → emit the real POD; add the writer `emit*` arm.
- `DXFReader.swift`: map the new `LC_ENT_*` → the new `EntityKind` case.

### 3d. DimKind (F5) — same discipline, narrower blast radius
`DimKind` switches live in `Resolve.swift` (the `switch d.kind` arms at ~902/1635/1658),
`Snapping.swift` (the dim sub-switch at ~361), and `DXFWriter.swift` / bridge dim mapping. F5 adds
`ordinate`/`arcLength`/`angular3p` to all of them in one serial step.

### 3e. The serial roster (one of these per wave, in this order)
| Step | Feature | EK/DK added | Why this order |
|---|---|---|---|
| S1 | **F7 DIMSTYLE** (R+BR, no new EK) | — | Highest value (P0 interop); unblocks F5/F8. Owns `Resolve.swift` dim arm + `CADDrawing.DimStyleTable` + bridge writer. |
| S2 | **F5 dim subtypes** (DK ×3) | DimKind ×3 | Rides on F7's style coherence; closes the 6 ordinate warnings in dim_sample. |
| S3 | **F1 xline/ray** (EK ×2) | xline, ray | Adds `clipBounds` to ResolveContext (cheap, additive). High daily value. |
| S4 | **F2 leader** (EK) | leader | Pairs with dimension annotation; reuses arrow + text resolve. |
| S5 | **F19 point style** (R, additive field) | — (field on PointData) | Touches `Resolve.swift` point arm + Entity field; can share a wave with an EK agent ONLY IF disjoint — but both write `Resolve.swift`, so it is its OWN R-slot. |
| S6 | **F3 image** (EK + renderer texture) | image | Needs the renderer texture pipeline (UI agent same wave). |
| S7 | **F4 MLINE** (EK) — *optional/last* | mline | Lowest priority; drop if waves run long. |

> **Rule:** the EK/DK/R agent for a wave is the wave's critical-section owner. It also does that
> entity's bridge + DXFWriter arm + tests, in its single worktree, so the merge is atomic and the
> build never breaks mid-wave.

---

## 4. Waves (ordered; within a wave all agents own DISJOINT files)

Wave shape (from CONVENTIONS / the v4 pattern): **≤1 critical-section agent** (EK/DK/R/bridge) **+
several new-file Tool agents + ≤1 UI-shell agent**, all disjoint; ≤~4 concurrent (watchdog-safe,
the v4 learning). Each wave ends with an **integration gate** (§6) and a **wire-wave** (§5) for any
new tools/entities. Per agent: **name · goal · OWNED files (exclusive) · deps · done-criterion.**

### WAVE 1 — Dimension interop + measurement + join (foundation value)
Critical section: **F7 DIMSTYLE** (the P0 lever). Parallel new-file tools alongside it.

| Agent | Goal | OWNED files (exclusive) | Deps | Done-criterion |
|---|---|---|---|---|
| **w1-dimstyle** (S1, R+BR) | Named DIMSTYLE table + ext-line offsets; resolve via `dimStyleProvider`; DXF/DWG DIMSTYLE **writer** | `Resolve.swift` (dim arm + `ResolvedDimStyle`), `CADDrawing.swift` (`DimStyleTable`), `DXFWriter.swift` (DIMSTYLE block), `DxfBridge/lcdxf.{cpp,h}` (write DIMSTYLE), `Tests/DimStyle*Tests.swift` | header-read (landed today) | `mechanical_example-imperial.dwg` dim text-height/arrow **round-trip** (write→reread preserves 0.125, not 2.5); named style applied; build+tests green. |
| **w1-measure** (F11, T) | Distance / angle / area / total-length info tools → status bar | `Tools/MeasureTool.swift` (+ variants), `Tests/MeasureToolTests.swift` | — | Each tool reports the correct value (engine-tested) to `ToolOutcome`/status; no entity mutation. |
| **w1-join** (F13, T) | Join touching lines/arcs → one polyline | `Tools/JoinTool.swift`, `Tests/JoinToolTests.swift` | — | Two collinear/touching lines → single `.polyline` `.add` + 2 `.remove`; gap tolerance respected. |
| **w1-explodetext** (F22, T) | Explode `.text`/`.mtext` → `.polyline` strokes | `Tools/ExplodeTextTool.swift`, `Tests/ExplodeTextToolTests.swift` | uses `fontProvider` (read-only) | A text entity → N polylines matching its resolve strokes; original removed. |

Then **wire-wave-1** (§5) for MeasureTool/JoinTool/ExplodeTextTool. Then **gate-1** (§6).

### WAVE 2 — Dim subtypes + blocks loop + select traversals
Critical section: **F5 dim subtypes (DK ×3)**. Block work is new-file/sidebar (disjoint from dims).

| Agent | Goal | OWNED files | Deps | Done-criterion |
|---|---|---|---|---|
| **w2-dimsub** (S2, DK) | `DimKind.ordinate`/`.arcLength`/`.angular3p` + resolve + bridge + DXF | `Entity.swift` (DimKind cases), `Resolve.swift` (dim sub-arms), `Snapping.swift` (dim subswitch), `DXFWriter.swift` (dim write), `DxfBridge/lcdxf.{cpp,h}` (dim read/write), `Tests/DimSubtype*Tests.swift` | W1 (F7 style) merged | dim_sample.dxf's **6 ordinate dims import (no warning)** + round-trip; +3 dim tools built UNWIRED. |
| **w2-blocktool** (F9 tool half, T) | Create-block-from-selection; explode-insert | `Tools/CreateBlockTool.swift`, `Tools/ExplodeInsertTool.swift`, `CADDrawing` block-from-selection op *(see note)*, `Tests/BlockOpsTests.swift` | INSERT (done) | Selection → named block + replaced by `.insert`; explode reverses it. ⚠ **CADDrawing collision:** w2-blocktool owns the new `CADDrawing.makeBlockFromEntities` method; no other W2 agent touches `CADDrawing`. |
| **w2-select** (F18, T) | Select contour / connected (engine traversal) | `Selection.swift` (additive, default-safe), `Tests/SelectTraversalTests.swift` | — | Click a chain → all connected entities selected; by-layer handled in W3 sidebar. |

Then **wire-wave-2** (dim subtypes + CreateBlock/ExplodeInsert tools). Then **gate-2**.

### WAVE 3 — Construction lines + UI-shell (sidebar/blocks/layers/property-painter)
Critical section: **F1 xline/ray (EK ×2)**. The UI-shell agent is the wave's single app-surface owner.

| Agent | Goal | OWNED files | Deps | Done-criterion |
|---|---|---|---|---|
| **w3-xline** (S3, EK) | `EntityKind.xline`/`.ray` + `ResolveContext.clipBounds` + bridge + tools | `Entity.swift`, `Resolve.swift`, `EntityTransform.swift`, `Snapping.swift`, `Inspect/InspectorEdits.swift`, `DXFWriter.swift`, `DxfBridge/lcdxf.{cpp,h}`, `Tools/XLineTool.swift`, `Tools/RayTool.swift`, `Tests/XLine*Tests.swift` | — | xline/ray draw, resolve clips to view, selectable/snappable, DXF read (was unsupported→real) + write; tools UNWIRED. |
| **w3-ui-blocks-layers** (F9 sidebar + F17 + F20 + F21, UI) | Live blocks sidebar (insert/rename/delete/drag-place); layer print/construction toggles + freeze-all + per-entity layer ops + layer states; property-painter; multi-select shared-prop edit | `LibreCADmacOS/Sidebar/*` (LayersSidebar, InspectorView, InspectorEditors), `ContentView.swift` (sidebar wiring only), `CanvasModel.swift` (painter state) | INSERT + W2 block op | Blocks panel places a block; layer toggles affect render; painter copies pen/layer; multi-select edits a shared prop; **app launches (USER-verified)**. |

⚠ **W3 disjointness:** w3-xline owns `Inspect/InspectorEdits.swift` (engine); w3-ui owns
`Sidebar/InspectorEditors.swift` + `InspectorView.swift` (app). These are DIFFERENT files — verify
no overlap on `ContentView.swift` (w3-ui owns it this wave; w3-xline must not touch it — its tools
wire in wire-wave-3).

Then **wire-wave-3** (xline/ray tools). Then **gate-3** (the heaviest GUI gate — sidebar + new EK).

### WAVE 4 — Hatch patterns + leader + more modify (align/array-path/scale-ref/offset-thru)
Critical section: **F6 hatch patterns (R)** — owns `Resolve.swift` hatch arm; **F2 leader (EK)**
CANNOT co-run (both write `Resolve.swift`). → split: **W4a** = hatch patterns + new-file modify
tools; **W4b** = leader. (Or schedule leader in W5.)

**W4a:**
| Agent | Goal | OWNED files | Deps | Done-criterion |
|---|---|---|---|---|
| **w4a-hatchpat** (F6, R+BR) | `.pat` pattern-line generator + boundary-arc tessellation + DXF pattern/arc round-trip | `Resolve.swift` (hatch arm), `DXFWriter.swift` (hatch boundary+pattern), `DxfBridge/lcdxf.{cpp,h}` (hatch write), bundled `.pat` resource + `make-app.sh`, `Tests/HatchPattern*Tests.swift` | — | ANSI31 renders as lines (not solid); bulged boundary round-trips; build+tests green. |
| **w4a-align** (F12, T) | Align selection to a 2-pt reference | `Tools/AlignTool.swift`, `Tests/AlignToolTests.swift` | EntityTransform (done) | source→dest maps the selection (move+rotate+optional scale). |
| **w4a-arraypath** (F15, T) | Array along a picked path | `Tools/ArrayPathTool.swift`, `Tests/ArrayPathToolTests.swift` | — | N copies distributed along a path entity at equal arc-length. |
| **w4a-toolmodes** (F14, T) | Scale-by-reference mode + offset-through-point mode | `Tools/ScaleTool.swift` (additive mode), `Tools/OffsetTool.swift` (additive mode), `Tests/*ModeTests.swift` | — | Each tool gains a mode flag honored end-to-end; existing modes unchanged. ⚠ sole owner of those two files this wave. |

Then **wire-wave-4a**. Then **gate-4a**.

**W4b (leader):**
| Agent | Goal | OWNED files | Deps | Done-criterion |
|---|---|---|---|---|
| **w4b-leader** (S4, EK) | `EntityKind.leader` + resolve (polyline+arrow+text) + bridge + `LeaderTool` | `Entity.swift`, `Resolve.swift`, `EntityTransform.swift`, `Snapping.swift`, `Inspect/InspectorEdits.swift`, `DXFWriter.swift`, `DxfBridge/lcdxf.{cpp,h}`, `Tools/LeaderTool.swift`, `Tests/Leader*Tests.swift` | W4a merged | leader draws + resolves + round-trips; `addLeader` (was unsupported) reads real; tool UNWIRED. |
| **w4b-baseline** (F8, T) | Baseline / continue dimension tools | `Tools/BaselineDimTool.swift`, `Tools/ContinueDimTool.swift`, `Tests/ChainDim*Tests.swift` | F7 (style) | chained dims share origin / continue from the last; consume existing DimData. |

Then **wire-wave-4b**. Then **gate-4b**.

### WAVE 5 — Point styles + raster image + view tools + order/revert + templates
| Agent | Goal | OWNED files | Deps | Done-criterion |
|---|---|---|---|---|
| **w5-pointstyle** (S5/F19, R) | `PointData.style` field + resolve marker glyphs + settings Points tab | `Entity.swift` (additive field), `Resolve.swift` (point arm), `LineRenderer.swift` (point glyph — IF needed), `DocumentSettingsView.swift` (Points tab), `Tests/PointStyleTests.swift` | — | $PDMODE/$PDSIZE honored; glyph renders; round-trips header vars. **Sole `Resolve.swift` owner this wave.** |
| **w5-image** (S6/F3, EK + renderer) | `EntityKind.image` + texture pipeline + drag-drop place + bridge read/write | `Entity.swift`, `Resolve.swift`(image arm)*, `EntityTransform.swift`, `Snapping.swift`, `Inspect/InspectorEdits.swift`, `DXFWriter.swift`, `DxfBridge/lcdxf.{cpp,h}`, `LineRenderer.swift`*(texture)*, `ContentView.swift`*(drop)*, `Tools/ImageTool.swift` | — | image places + renders textured + selectable; bridge `addImage` real. ⚠ **conflicts with w5-pointstyle on `Resolve.swift` + `LineRenderer.swift`** → **w5-image and w5-pointstyle CANNOT co-run.** Put image in a separate sub-wave (W5b) or serialize. |
| **w5-viewtools** (F23+F16, UI) | Zoom-window + zoom-previous + View menu; draw-order (raise/lower/top/bottom) + revert-direction | `CanvasModel.swift`, `CADCanvasView.swift`, `CADDrawing.swift`(order index), `ContentView.swift`(menu) | — | drag-box zooms; arrange menu reorders; revert flips direction. |
| **w5-templates** (F24, UI) | New-from-template chooser | `LibreCADApp.swift`(menu), `ContentView.swift`(picker), template resources | — | New doc from a chosen template. ⚠ shares `ContentView.swift`/`LibreCADApp.swift` with w5-viewtools → **serialize the two UI agents** (one app-shell owner per wave). |

> **W5 is over-subscribed on shared files.** Recommended split: **W5a** = w5-pointstyle (R) +
> w5-viewtools (UI) [disjoint: Resolve vs Canvas/menu — but both want ContentView → viewtools owns
> it, pointstyle stays out]; **W5b** = w5-image (EK+renderer) + w5-templates (UI) [disjoint]. Then
> wire-waves + gates. If F4 MLINE is in scope, it is **W5c** (its own EK serial step).

---

## 5. Wire-waves (batch the UI wiring; keep feature agents OUT of the wiring trio)

Mirror the existing pattern (wire-wave-A/B/C/D in DEVLOG). After a feature wave merges, a **single
serialized wire-wave agent** registers all of that wave's new tools/entities. Feature agents NEVER
touch `ToolKind.swift` / `ContentView.swift` / `LibreCADApp.swift`.

Each wire-wave touches exactly these and nothing else:
1. `Tools/ToolKind.swift` — one `case` + one `title` arm + one `makeTool()` arm per new tool
   (append-only, per the in-file collision note).
2. `LibreCADmacOS/ContentView.swift` — one `toolButton(...)` in the correct toolbar group (Draw /
   Modify / Annotate) with an SF Symbol + help text incl. the shortcut.
3. `LibreCADmacOS/LibreCADApp.swift` — one `Button` in the Tools `CommandMenu` + `.keyboardShortcut`.
4. `LibreCADmacOS/Canvas/CanvasModel.swift` — `activateTool` config funnel (if the tool reads
   options bar state, e.g. radius/rows) + any `handleKey` shift-twin split.
5. `LibreCADmacOS/ToolOptionsBar.swift` — an option row for tools with config (fillet-radius
   pattern).
6. `ToolKindWiringTests.swift` + `ToolOptionsU2Tests.swift` — extend the wiring assertions.

**Per-wave wire-wave roster:**
- **wire-wave-1:** MeasureTool variants, JoinTool, ExplodeTextTool.
- **wire-wave-2:** 3 dim-subtype tools (ordinate/arc/angular-3p), CreateBlockTool, ExplodeInsertTool.
- **wire-wave-3:** XLineTool, RayTool (Draw group, construction-line submenu).
- **wire-wave-4a/4b:** AlignTool, ArrayPathTool, (Scale/Offset mode toggles in options bar);
  LeaderTool, BaselineDimTool, ContinueDimTool (Annotate group).
- **wire-wave-5a/5b:** PointTool style options; ImageTool; view/order/revert menu items;
  template chooser.

**Suggested new keymap (avoid the taken set V/L/C/A/R/P/O/E/G/S/H/T + shift-twins):** measure
distance ⇧K, join ⇧J, leader ⌥L, baseline-dim ⌥D, create-block ⌥B, align ⌥A, xline ⌥X, ray ⌥Y.
Confirm against the live keymap at wire time (it's the source of truth).

**Keystone wiring decision (F25 / D6):** the **U4 toolbar reorg** is its OWN wave (it rewrites the
toolbar groups + adds Draw▾/Modify▾/Annotate▾ menus + a customizable default set). Run it AFTER all
feature waves so it organizes the final, complete tool set in one pass. It exclusively owns
`ContentView.swift` + `LibreCADApp.swift` for that wave; nothing else runs concurrently with it.

---

## 6. Integration gates (after each wave) + the FINAL acceptance pass

### Per-wave gate (coordinator-run, before deleting any worktree)
1. Merge each agent's branch **by reported commit hash** (CONVENTIONS — not the harness
   `worktree-agent-*` branch); **verify the test count moved** before deleting.
2. `swift build` (0 warnings) + `swift test` (count strictly ≥ pre-wave) on the reassembled tree.
3. **Exhaustiveness check:** if an EK/DK landed, confirm every §3 switch got a real arm (the
   compiler enforces 3a; manually confirm 3b/3c got real arms, not silent `default:` drops).
4. Run `make-app.sh` → `.app` assembles + ad-hoc signs + bare-binary stays alive (NOT a GUI pass).
5. For any GUI-affecting wave (W3, W5): **ask the USER to launch** and confirm (CONVENTIONS GUI
   rule — headless ≠ verified).

### FINAL integration / acceptance pass (one dedicated agent + USER, after the last feature wave)
A real end-to-end exercise — NOT just the suite:
- **Open the owner's real files:** `mechanical_example-imperial.dwg` **and** a DXF (dim_sample.dxf +
  one with ordinate dims). Confirm: dims render at correct size (DIMSTYLE), ordinate dims no longer
  warn, hatch patterns draw as lines, any blocks place.
- **Exercise several new features together in one document:** draw an xline + a leader pointing at
  geometry; create a block from a selection and re-insert it; apply a named dim style; run
  measure-distance/area; use the property-painter across entities; place a raster image; zoom-window.
- **Round-trip:** Save→reopen (DXF and DWG); assert every new entity/dim subtype survives
  (selectable, snappable, correct geometry). Re-import counts match.
- **Regression sweep:** full `swift test`; spot-check that existing tools/entities still resolve +
  render (no exhaustive-switch regressions, no perf regression on a 100k-entity drawing).
- **UX consistency audit (the owner's explicit priority):** every new tool follows the §7 Tool
  pattern; every new tool's options appear in the **options bar** AND (where editable) the
  **Inspector**; every new entity is selectable + snappable + round-trips + appears in resolve +
  bbox; keymap has no collisions; toolbar grouping (post-F25) is coherent.

A wave is "done" only when its gate passes; the milestone is "done" only when the final pass +
USER GUI confirmation pass.

---

## 7. Consistency conventions (every feature agent's brief MUST embed these)

So parallel outputs mesh, every agent follows these (grounded in the real types):

1. **Tool pattern:** a new tool is a `struct …Tool: Tool` (value type, `mutating func handle(_
   input: ToolInput, context: ToolContext) -> ToolOutcome`) in its OWN `Tools/<Name>Tool.swift`.
   It exposes `title` / `status` / `preview`. Lives entirely in its own file — the only shared touch
   is the 2-line `ToolKind` wire, done in the wire-wave, NOT by the tool agent.
2. **Typed input:** support `ToolInput.value(Vector)` (the `@dx,dy` / `dist<angle` path) wherever a
   draw tool takes a point — `ToolInput` is append-only (D7); don't add new cases.
3. **New entity checklist (EK agent):** implement, in the SAME worktree, ALL of —
   `Resolve.swift` `resolve()` + `boundingBox()` arms, `EntityTransform.transformed(by:)` arm,
   `Snapping.swift` snap arms (both exhaustive switches), `Inspect/InspectorEdits.swift` editable
   fields, `DXFWriter.swift` write arm, `DxfBridge/lcdxf.{cpp,h}` read+write + `DXFReader.swift`
   mapping — so the entity is **selectable, snappable, transformable, inspectable, and round-trips**
   on the first merge (no half-wired entity).
4. **Provider hooks:** entities that reference external data resolve via a `ResolveContext`
   `@Sendable` provider (`blockProvider` / `fontProvider` / `dimStyleProvider` / new
   `clipBounds` for xline). Don't store derived geometry (ADR-001).
5. **Tool options flow:** tool config is `CanvasModel` state (e.g. `filletRadius`), surfaced in
   `ToolOptionsBar.swift`, and pushed into the tool in `CanvasModel.activateTool` (the existing
   funnel). New options follow this exact path — never a private dialog.
6. **Undo/edit:** mutate only via `ToolEdit` (`.add` / `.replace(id, kind)` / `.remove(id)`) and
   `CADDrawing`'s undoable methods (value-snapshot undo, ADR-002). Strip `.selected` on `.add`.
7. **Namespacing (fan-out hazard):** name test suites by domain (`LeaderEntityTests`, not
   `LeaderTests`) — parallel test files share one target (CONVENTIONS). New engine helpers are
   `static` members of a namespaced type, never module-scope free functions.
8. **GPLv2 headers** on every new file (LibreCAD derivative; cite the `RS_*`/`DRW_*` source).
9. **Worktree discipline:** harness `isolation:"worktree"`; `git switch -C <name> native-macos`;
   report your commit hash; coordinator merges **by hash** + verifies test-count before deleting.
10. **Disjoint ownership:** touch ONLY your OWNED files (§4). If you discover you need a hotspot
    another agent owns this wave, STOP and tell the coordinator — don't edit it.

---

## 8. Owner decisions (recommended defaults in **bold** — proceed unless overridden)

1. **Dim subtype scope (F5 / catalog DC.4):** add ordinate + arc-length + angular-3p? — **YES, all
   three in one DK step** (dim_sample has 6 ordinate dims warning today; doing them together avoids
   re-churning the enum). Reverses the v4 "stage on demand" call now that there's demand.
2. **Hatch patterns now (F6 / DC.3):** ship a real `.pat` generator vs keep solid? — **YES, ship
   patterns** (P1, common ANSI patterns; pairs with the boundary-arc round-trip fix). Bundle a
   small `.pat` set.
3. **MLINE (F4):** include in v5 or defer? — **DEFER to W5c / drop if waves run long** (P2, L,
   lowest value; full parallel infra cost not worth it this round).
4. **Raster image (F3):** worth the renderer texture pipeline? — **YES but last (W5b)** — it's the
   only feature needing a *new GPU pipeline*; isolate it so a texture-pipeline bug can't block the
   rest.
5. **Paper-space / layouts / UCS / named views (§11):** in scope? — **NO, out of v5** — a whole
   subsystem; deserves its own plan. v5 stays model-space.
6. **F25 U4 toolbar reorg timing:** before or after features? — **AFTER all feature waves** (one
   pass over the final tool set; owns the wiring files alone). Confirms D6's Draw/Modify/Annotate
   grouping + customizable default set.
7. **F21 multi-select prop edit:** confirm it's actually still a gap — **verify the v4 Inspector
   first**; if it already edits a selection, drop F21 and reallocate the W3 UI agent's budget.
8. **Concurrency cap:** keep the v4 watchdog-safe **≤4 concurrent agents** per wave? — **YES**
   (two stalls in v4 came from larger fan-outs).

---

## 9. Wave summary (the coordinator's run-list)

| Wave | Critical-section (serial) | Parallel new-file Tools | UI-shell (≤1) | Agents | Gate |
|---|---|---|---|---|---|
| **W1** | w1-dimstyle (R+BR, P0) | measure, join, explode-text | — | 4 | +wire-wave-1, gate-1 |
| **W2** | w2-dimsub (DK ×3) | block-tool (create/explode-insert), select-traversal | — | 3 | +wire-wave-2, gate-2 |
| **W3** | w3-xline (EK ×2) | — | w3-ui (blocks sidebar + layers + painter + multi-edit) | 2 | +wire-wave-3, gate-3 (USER GUI) |
| **W4a** | w4a-hatchpat (R+BR) | align, array-path, tool-modes | — | 4 | +wire-wave-4a, gate-4a |
| **W4b** | w4b-leader (EK) | baseline/continue dim | — | 2 | +wire-wave-4b, gate-4b |
| **W5a** | w5-pointstyle (R) | — | w5-viewtools (zoom-window + order + revert) | 2 | +wire-wave-5a, gate-5a |
| **W5b** | w5-image (EK + texture) | — | w5-templates | 2 | +wire-wave-5b, gate-5b (USER GUI) |
| **W5c** | w5-mline (EK) *— optional* | — | — | 1 | +wire, gate |
| **W6** | — | — | **F25 U4 toolbar reorg** (owns wiring files alone) | 1 | gate-6 (USER GUI) |
| **FINAL** | — | — | acceptance agent + USER | 1 | §6 final pass |

**Critical sections that force serialization (the integration hotspots):**
`Entity.swift` (EntityKind/DimKind) · `Resolve.swift`+`ResolveContext` · `EntityTransform.swift` ·
`Snapping.swift` · `Inspect/InspectorEdits.swift` · `DXFWriter.swift` · `DxfBridge/lcdxf.{cpp,h}` ·
`CADDrawing.swift` (tables/order) · and the wiring trio `ToolKind.swift`/`ContentView.swift`/
`LibreCADApp.swift` (wire-waves only). **At most one agent writing each per wave.**
