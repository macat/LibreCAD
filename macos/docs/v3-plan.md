# v3 Plan — Features v3 (the 4 user-picked themes)

Sequenced, overlap-analyzed fan-out plan for the remaining feature work, so the coordinator can
dispatch parallel builders **without merge hell or a broken exhaustive switch**. Style mirrors
`features-v2-plan.md`: dependency-ordered waves, **disjoint file ownership**, controlled batches
(≤4 concurrent — the prior infra watchdog stall is the reason for the cap), coordinator merges +
wires central registries between waves, user GUI-verifies.

Grounded in the merged `native-macos` tree at `0b5517aa0` (FEATURES V2 COMPLETE, 654 tests, 22
tools wired). Verified by reading the actual source — file/type names below are real.

## Themes (all four; the user picked all)
1. **Lossless Save + files (remainder):** DocumentGroup reintroduction (off-main-safe
   `ReferenceFileDocument`), dirty indicator, recents, autosave/versions, DXF **dimension** write.
   *(Excludes text/solid/hatch write — that is the in-flight `ws/dxf-write-fidelity` wave; see
   "In-flight work" below.)*
2. **Authoring tools:** Dimensions (linear/aligned/radial/angular), Text creation, Hatch, Spline,
   Array / Divide / Explode / Blocks-insert.
3. **Modern UX:** Inspector panel, ⌘K command palette, on-canvas gizmos, snap/grid toggle UI,
   Fillet/Chamfer parameter input UI.
4. **Output & scale:** Print + PDF/PNG/SVG export, CI + code-signing/notarization, perf (gated on
   the separate profiling agent's report — placeholder wave only).

---

## In-flight work (do NOT re-dispatch; account for the merge order)
`git worktree list` shows three locked worktrees branched off `0b5517aa0` with **no committed diff
yet** vs `native-macos`:
- `ws/dxf-write-fidelity` — the **text/solid/hatch DXF write** wave (this owns `DXFWriter.swift` +
  `DxfBridge/lcdxf.{cpp,h}` write side). **The dimension-write task (#S3 below) depends on it** and
  must serialize AFTER it (both touch `DXFWriter.swift` + the C bridge).
- `ws/coord-consistency-test` — the backlogged `worldToScreen↔worldToClip` regression test
  (touches Tests only; harmless, no hotspot overlap).
- `ws/app-icon-theme` — app icon + theme polish (touches `make-app.sh` / Resources / `ContentView`
  chrome). If it touches `ContentView.swift`, serialize the Inspector (#W4-inspector) after it.

The coordinator must merge these (or confirm them abandoned) **before** the dimension-write and any
`DXFWriter.swift`/`ContentView.swift` task in this plan starts.

---

## Overlap map — shared hotspot files × tasks that touch them

Tasks are named `ws/<slug>`. A cell marked ●=owns/edits, ○=reads-only (no edit). **Two ● in the
same row that are not in the same serialized step = a collision → must be serialized.**

| Hotspot file | dim-entity (S1) | text-tool | hatch-tool | spline-tool | array/divide | explode | blocks-insert | dim-write (S3) | docgroup | inspector | palette | gizmos | snapgrid-ui | fillet-ui | export | wire-wave3 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `Entity.swift` | ● | | | | | | ●¹ | | | | | | | | | |
| `Resolve.swift` | ● | | | | | | ●¹ | | | | | | | | ○ | |
| `EntityTransform.swift` | ● | | | | | | ●¹ | | | | | | | | | |
| `Snapping.swift` | ● | | | | | | | | | | | | | | | |
| `Selection.swift` | ● (def-ok) | | | | | | | | | | | | | | | |
| `DXFReader.swift` | ●² | | | | | | ●¹ | | | | | | | | | |
| `DXFWriter.swift` | | | | | | | | ● | | | | | | | | |
| `DxfBridge/lcdxf.{cpp,h}` | ○ | | | | | | ●¹ | ● | | | | | | | | |
| `ToolKind.swift` | | ○ | ○ | ○ | ○ | ○ | ○ | | | | | | | | | ● |
| `Tool.swift` | | ○ | ○ | ○ | ○³ | ○ | ○ | | | | ○ | | | | | |
| `ContentView.swift` | | | | | | | | | ●⁴ | ● | ● | ● | ● | ●⁵ | ● | |
| `LibreCADApp.swift` | | | | | | | | | ●⁴ | | ● | | | | ● | ● |
| `CADCanvasView.swift` | | ●⁶ | ○ | | | | | | | | | ● | ● | | | ●⁷ |
| `CanvasModel.swift` | | ●⁶ | ○ | | ○ | ○ | ○ | | ●⁴ | ● | ○ | ● | ● | ○ | ○ | |
| `Package.swift` | | ● | | | | | | | | | | | | | ● | |
| (new) `Tools/*Tool.swift` | | ● | ● | ● | ● | ● | ● | | | | | | | ●⁵ | | |

Notes:
1. **blocks-insert** is the heaviest cross-cut: it adds `.insert` EntityKind (Entity/Resolve/
   Transform/DXFReader) AND needs C-bridge `LC_ENT_INSERT` import AND block-table wiring. Per ADR
   sequencing it is a **SINGLE owner**, not the wide pool — and its EntityKind add must be its own
   serialized step (see "EntityKind isolation").
2. dim-entity edits `DXFReader.swift` only to add a no-op skip arm for the new `.dimension` import
   case (or it can rely on the existing `default:` — see S1 detail). The full dimension *read*
   import is a follow-up, not in this plan's critical path.
3. array/divide adds NO EntityKind; it emits `.add`/`.replace` `ToolEdit`s only — pure tool files.
4. **DocumentGroup (docgroup)** rewrites the app shell: `LibreCADApp.swift` (`WindowGroup` →
   `DocumentGroup`), `ContentView.swift` (drops the on-appear sample load; takes the document),
   `CanvasModel.swift` (built from the document's Sendable parsed data). It collides with EVERY
   other `ContentView`/`LibreCADApp`/`CanvasModel` task → it is **serialized first** in its wave and
   nothing else in the UX theme runs concurrently with it.
5. fillet-ui adds a parameter sheet that lives in `ContentView.swift` AND reads tool params; the
   tool files (`FilletTool.swift`/`ChamferTool.swift`) gain a settable radius/distance. It touches
   `ContentView` → serialize vs inspector/palette/gizmos/snapgrid-ui.
6. text-tool needs interactive text entry over the Metal canvas → an `NSTextField`/`NSTextView`
   overlay added in `CADCanvasView.swift` + state in `CanvasModel.swift` (see Design Decision D2).
7. wire-wave3 only edits `CADCanvasView.handleKey` for new tool keys + `ToolKind` + the two app
   files; it is the LAST serialized step (mirrors wire-wave2).

**Hard serialization conclusions from the map:**
- `ContentView.swift` is touched by **docgroup, inspector, palette, gizmos, snapgrid-ui, fillet-ui,
  export** → these 7 cannot run concurrently with each other. They are spread across UX waves with
  ≤1 ContentView-editor per batch (or split: see waves).
- `CanvasModel.swift` is touched by docgroup, inspector, gizmos, snapgrid-ui, text-tool → same.
- `Entity.swift`+`Resolve.swift`+`EntityTransform.swift`+`DXFReader.swift` are the EntityKind quartet
  → only dim-entity (S1) and blocks-insert (S2) touch them, and **each is its own serialized step.**
- `DXFWriter.swift`+C-bridge → dim-write (S3) serializes after the in-flight `ws/dxf-write-fidelity`.

---

## EntityKind-change isolation (the recurring foot-gun)

Adding an `EntityKind` case has bitten this project repeatedly. **Every EntityKind add is its own
serialized step, owned by one builder, and must add an arm to EVERY exhaustive switch** or the build
breaks (and some breaks are only visible in the test target, invisible to source review).

### Complete list of switches that need a new arm per added EntityKind

Verified by reading every file. **Exhaustive (NO `default:` — compile breaks without an arm):**

| File | Switch | Line |
|---|---|---|
| `CADEngine/Resolve.swift` | `resolve(ctx:)` | ~592 |
| `CADEngine/Resolve.swift` | `boundingBox()` | ~948 |
| `CADEngine/EntityTransform.swift` | `transformed(by:)` | ~227 |
| `CADEngine/Snapping.swift` | snap-points switch | ~242 |
| `CADEngine/Snapping.swift` | on-entity / nearest switch | ~308 |
| `CADEngine/Tools/ExtendTool.swift` | `isSupportedTarget` (enumerates all cases) | ~147 |
| `CADEngine/Tools/ExtendTool.swift` | `extend(_:near:boundaries:)` (all cases) | ~164 |
| `CADEngine/Tools/ExtendTool.swift` | `infiniteLineHits` boundary switch (all cases) | ~217 |
| `CADEngine/Tools/ExtendTool.swift` | `fullCircleHits` boundary switch (all cases) | ~293 |
| `CADEngine/Tools/OffsetTool.swift` | offset-geometry switch (all cases) | ~193 |
| **TESTS** `DXFReaderTests.swift` | per-kind count tally | ~49 |
| **TESTS** `DXFWriterTests.swift` | per-kind count tally | ~53 |
| **TESTS** `DXFWriterTests.swift` | `isWriterSupported`-style switch | ~289 |

**Protected by `default:` (no arm strictly required, but add one if the new kind needs behavior):**
`Snapping.swift:294,381`, `Selection.swift:323`, `DXFWriter.swift:203` (PODBuilder.makeEntity — has
explicit display/spline arms + you SHOULD add a skip arm), `DXFReader.swift:151` (mapKind has
`default:`), `TrimTool.swift` (multiple, all `default:`-guarded), `ChamferTool.swift`/
`FilletTool.swift` (filter on `.line` with `default:`), `DXFReaderTests.swift:102`,
`DXFWriterTests.swift:175`.

**Not affected:** `RendererGeometry.swift` / `LineRenderer.swift` do NOT switch on `EntityKind` —
they consume `ResolvedGeometry.polylines`/`.fills` only. **This is the key win: once an EntityKind's
`resolve()` arm emits polylines (dimension lines + arrowheads + measurement text strokes) and/or
fills, the renderer draws it with ZERO renderer changes.** Same for selection-highlight and culling
(they use `boundingBox()`).

### Serialized EntityKind steps in this plan
- **S1 — `ws/dim-entity`**: add `case dimension(DimData)`. Owns Entity/Resolve/EntityTransform/
  Snapping + the ExtendTool/OffsetTool all-cases switches + the two test tallies. Emits the dimension
  graphic from `resolve()` (lines + arrowhead triangles-as-fills + measurement `.text` strokes via
  `ctx.fontProvider`). Adds `// var dimStyleProvider` hook on `ResolveContext` (already reserved in
  Resolve.swift:126). `boundingBox()` derives from the resolved graphic. DXFReader gets a skip arm
  (full dim import is a follow-up). **Done:** build+tests green with the new case; a unit test
  asserts `resolve()` of a linear dim produces the expected extension lines + text; bbox is analytic.
- **S2 — `ws/blocks-insert`**: add `case insert(InsertData)` (block name ref + transform).
  `resolve()` expands block contents through the existing `ResolveContext.currentBlockPen`/
  `blockAttributes` hooks (already wired) using the document's `BlockTable`. Same exhaustive-switch
  checklist as S1. Also needs C-bridge `LC_ENT_INSERT` import. **Single owner, not the wide pool**
  (ADR sequencing). Serialize **after S1** (both touch the EntityKind quartet).

> These two are the ONLY EntityKind adds in this plan. Everything else (text-tool, hatch-tool,
> spline-tool, array, divide, explode) reuses EXISTING kinds (`.text`, `.hatch`, `.spline`,
> `.polyline`, etc.) and emits `ToolEdit`s — so they are pure new-tool-file work, parallel-safe.

---

## Waves

Each task: **name** · one-line goal · **owns** (files) · **deps** · **done** criterion.
Rule for every brief (carry verbatim): disjoint ownership; namespaced test suites
(`<Domain>Tests` to avoid the redeclaration trap); build+test green (`swift test --disable-sandbox`);
commit to `ws/<name>`, NO merge/push; coordinator merges (overlap-checked) + rebuilds green + wires
registries; user GUI-verifies.

### Wave 0 — gate (serial, coordinator)
Merge / confirm-abandoned the three in-flight worktrees (`ws/dxf-write-fidelity`,
`ws/coord-consistency-test`, `ws/app-icon-theme`). Rebuild green. This unblocks S3 (dim-write) and
the `ContentView` UX tasks.

### Wave 1 — EntityKind foundations (SERIAL, one at a time)
- **S1 `ws/dim-entity`** — add `.dimension` EntityKind + resolve graphic + all exhaustive arms.
  *Owns:* `Entity.swift`, `Resolve.swift`, `EntityTransform.swift`, `Snapping.swift`,
  `Tools/ExtendTool.swift`, `Tools/OffsetTool.swift`, `DXFReader.swift` (skip arm),
  `DXFWriterTests.swift`/`DXFReaderTests.swift` (tally arms). *Deps:* Wave 0. *Done:* new case
  compiles across all switches; linear-dim `resolve()` + analytic bbox tests green.
- **S2 `ws/blocks-insert`** — add `.insert` EntityKind + block-expansion resolve + C-bridge import.
  *Owns:* same EntityKind quartet + `DxfBridge/lcdxf.{cpp,h}` (import side) + `Block.swift`-adjacent.
  *Deps:* **S1 merged** (shares the quartet). *Done:* an Insert of a 2-entity block resolves to both
  members transformed by the insert; round-trips a block fixture.

> S1 and S2 are serial vs each other. **They run concurrently with Waves 2 and the UX waves below**,
> which touch NONE of the EntityKind quartet (verified in the overlap map).

### Wave 2 — authoring tools (parallel pool, ≤4; NONE touch a hotspot the others touch)
All are new `Tools/*Tool.swift` files emitting `ToolEdit`s against existing kinds. None edit
`ToolKind` (coordinator wires in wire-wave3). All disjoint.
- **`ws/tool-hatch`** — hatch from selected boundary entities → `.add(.hatch(HatchData(loops:…)))`.
  *Owns:* `Tools/HatchTool.swift` + tests. *Deps:* none (uses existing `.hatch` kind + fill render).
  *Done:* picking N closed boundaries produces a hatch whose `resolve()` fills the region; test
  drives `.click` on a closed polyline → one `.add(.hatch)`.  (Seed-point flood-fill boundary
  detection = Design Decision D3 — recommend boundary-from-selection first.)
- **`ws/tool-spline`** — interactive spline: click control points → `.add(.spline(SplineData))`.
  *Owns:* `Tools/SplineTool.swift` + tests. *Deps:* none (`.spline` kind + NURBS resolve exist).
  *Done:* clicking ≥`degree+1` points then `.commit` adds a spline whose `resolve()` interpolates;
  Esc/⌫ behavior tested. (Spline is the known bug-farm — port with tests, treat higher-risk.)
- **`ws/tool-array`** — rectangular + polar array of the selection → many `.add`.
  *Owns:* `Tools/ArrayTool.swift` + tests. *Deps:* none (uses `EntityTransform`/`Affine2D`). *Done:*
  array of a line by 3×2 emits 5 `.add` copies at the right offsets (1 original kept).
- **`ws/tool-divide-explode`** — Divide (split entity at point) + Explode (polyline/insert →
  primitives). *Owns:* `Tools/DivideTool.swift`, `Tools/ExplodeTool.swift` + tests. *Deps:* explode
  of `.insert` needs S2 merged for the insert case; explode of `.polyline` does not. Split into two
  tools if S2 lags. *Done:* exploding a closed polyline emits N `.add(.line)` + 1 `.remove`.

> **text-tool is NOT in this pool** — it needs `CADCanvasView`/`CanvasModel` for the on-canvas text
> entry overlay, which collides with the UX waves' canvas edits. It is placed in Wave 3b alone.

### Wave 3 — modern UX (ContentView/CanvasModel are the bottleneck → serialize the editors)
Because `ContentView.swift` + `CanvasModel.swift` are touched by almost every UX task, split into
sub-batches where **at most ONE task edits ContentView and at most ONE edits CanvasModel** per batch.

**Wave 3a — DocumentGroup FIRST, ALONE (serial).**
- **`ws/docgroup`** — reintroduce `DocumentGroup` with an OFF-MAIN-SAFE `ReferenceFileDocument`.
  Store **Sendable parsed data** (the value `[EntityRecord]` + `LayerTable`, or raw bytes) in
  `init(configuration:)` / `snapshot(contentType:)` / `fileWrapper(snapshot:configuration:)` (these
  run off-main) and build the `@MainActor CanvasModel`/`CADDrawing` **in the view** (`.onAppear` or
  the document-binding init) — **NO `MainActor.assumeIsolated` anywhere on the document path**
  (CONVENTIONS: the exact trap that crashed launch before; that's why the app is `WindowGroup` today).
  Brings recents + autosave + versions for free; adds the dirty-indicator (close-box dot) via the
  document's change tracking. *Owns:* `LibreCADApp.swift`, `ContentView.swift`, `CanvasModel.swift`,
  a new `CADReferenceDocument.swift`, `LibreCADUTType.swift`. *Deps:* Wave 0 (+ ideally S3 so Save
  emits dims). *Done:* a USER-confirmed launch (CONVENTIONS GUI rule — headless ≠ verified) that
  opens, edits (dirty dot appears), saves, and appears in Recents WITHOUT a crash. This is the
  riskiest UX item; it gates the others that touch the shell.

**Wave 3b — parallel, disjoint canvas/app surfaces (≤4; each owns a DIFFERENT shell file).**
After docgroup merges. Partition so no two edit the same file:
- **`ws/inspector`** (owns `ContentView.swift` inspector pane + new `Inspector/*.swift`) — a
  trailing `.inspector` pane / NavigationSplitView inspector showing the selected entity's
  properties; geometry/layer/pen edits map to `ToolEdit.replace` (and a `.replaceRecord` sibling for
  layer/pen — note `Tool.swift:88` explicitly reserves adding `.replaceRecord(EntityRecord)` for
  exactly this; recommend adding it now). *Reads* `CanvasModel.selection`. *Deps:* docgroup. *Done:*
  selecting a line shows its endpoints; editing one and committing moves the line (undoable).
- **`ws/palette`** (owns `LibreCADApp.swift` ⌘K command + new `CommandPalette/*.swift`) — fuzzy
  tool/command search overlay; activates a `ToolKind` or runs a command via the existing
  `activateTool` focused value. *Deps:* docgroup (shell stable). *Done:* ⌘K opens, typing "circ"
  ranks Circle first, Enter activates it.
- **`ws/gizmos`** (owns `CADCanvasView.swift` overlay + `CanvasModel.swift` gizmo state) — on-canvas
  move/rotate/scale handles on the selection; dragging a handle emits the matching modify
  `ToolEdit.replace` via the existing `EntityTransform`. *Deps:* docgroup. *Done:* dragging the move
  handle on a selected entity translates it live + commits one undoable edit.

> inspector (ContentView) + palette (LibreCADApp) + gizmos (CADCanvasView + CanvasModel) — these
> three are disjoint at the file level **except CanvasModel** (inspector reads it, gizmos edits it).
> If strict-disjoint is required, run gizmos in its own batch and inspector+palette together.

**Wave 3c — parameter/toggle UI (serial vs 3b on ContentView/CanvasModel).**
- **`ws/snapgrid-ui`** (owns `ContentView.swift` toolbar + `CanvasModel.swift` snap/grid flags) —
  snap-mode popover + grid toggle button driving `CanvasModel.snapModes` / grid spacing. *Done:*
  toggling endpoint-snap off stops endpoint snapping; grid toggle hides the grid.
- **`ws/fillet-ui`** (owns `ContentView.swift` param sheet + `Tools/FilletTool.swift`/
  `ChamferTool.swift` settable params) — radius/distance input replacing the hard-coded 10 / 10·10.
  *Done:* setting radius 5 then filleting two lines produces a 5-radius arc.

**Wave 3b/3c text-tool placement:**
- **`ws/tool-text`** (owns `CADCanvasView.swift` text-entry overlay + `CanvasModel.swift` text state
  + `Tools/TextTool.swift`) — interactive text creation. See Design Decision **D2** for HOW text
  entry works over Metal (recommend a transient `NSTextField` overlay positioned at the click point;
  on commit emit `.add(.text(TextData))`). *Deps:* docgroup; serialize vs gizmos (both edit
  CADCanvasView + CanvasModel). *Done:* clicking, typing "ABC", Enter adds a `.text` entity that
  renders via the existing `.lff` stroke path.

### Wave 4 — output & scale
- **`ws/dim-write` (S3)** — DXF dimension WRITE. *Owns:* `DXFWriter.swift` + `DxfBridge/lcdxf.{cpp,h}`
  write side + writer tests. *Deps:* **S1 merged** (needs `.dimension`) AND **`ws/dxf-write-fidelity`
  merged** (shares `DXFWriter.swift` + C bridge). Serial vs anything else touching those. *Done:*
  a drawing with a linear dim round-trips (write → re-read → dim count preserved).
- **`ws/export`** (owns new `Export/*.swift` + `ContentView.swift` menu items + `LibreCADApp.swift`
  command + maybe `Package.swift`) — Print + PDF/PNG/SVG export via a **render-to-context path
  distinct from the Metal screen path** (Design Decision **D4**: a `ResolvedGeometry → CGContext`
  renderer, shared by PDF/PNG/print; SVG is a separate text emitter over the same `ResolvedGeometry`).
  *Deps:* none on the engine (consumes `resolve()`); serialize vs other ContentView editors. *Done:*
  exporting `dim_sample.dxf` to PDF produces a vector PDF matching the on-screen drawing; PNG at 2×;
  SVG opens in a browser.
- **`ws/ci-signing`** (owns `.github/workflows/*.yml` + `scripts/make-app.sh` + entitlements) — CI
  build/test + code-signing + notarization for a shareable build. *Deps:* none (infra-only, fully
  disjoint). *Done:* CI runs `swift test` green on push; a signed+notarized `.app` artifact is
  produced (gated on Design Decision **D5** — signing identity availability).
- **`ws/perf` (PLACEHOLDER)** — gated on the separate profiling agent's report. Do NOT dispatch until
  that report lands; leave this wave empty. The likely targets (from backlog) are: zoom-bucketed LOD
  for curve tessellation, cache resolved geometry on entity/quadtree, selection-highlight geometry
  cache, best-first `nearest()` heap, and grouped snap filter passes — but **confirm against the
  report, don't pre-build.**

### Wave 5 — wire-wave3 (SERIAL, coordinator, LAST)
- **`ws/wire-wave3`** — register EVERY new tool from Waves 2 + 3b/c in the central registry in ONE
  step (mirrors wire-wave2). *Owns:* `ToolKind.swift` (case + title arm + `makeTool()` arm),
  `ContentView.swift` toolbar buttons, `LibreCADApp.swift` Tools-menu items + shortcuts,
  `CADCanvasView.swift` `handleKey` key cases, `ToolKindWiringTests.swift`. Tools to wire: Hatch,
  Spline, Array, Divide, Explode, Text, Dimension(×variants). *Done:* every new tool appears in
  toolbar + Tools menu + keymap; wiring tests green; `.app` reassembles; no new crash.

---

## Tool-wiring convention (recommendation: ONE serialized wire-wave at the end)

Every new tool needs the SAME 5-point wiring, all in central files multiple builders would collide on:
1. `ToolKind` enum **case** (Tools/ToolKind.swift:32-73, append-only)
2. `ToolKind.title` **arm** (Tools/ToolKind.swift:77-100)
3. `ToolKind.makeTool()` **arm** (Tools/ToolKind.swift:105-128)
4. **toolbar button** (`ContentView.swift` `toolbarContent`, lines 117-155)
5. **Tools-menu item + shortcut** (`LibreCADApp.swift` `CommandMenu("Tools")`, lines 116-186)
   — plus the matching key case in `CADCanvasView.handleKey`.

**Recommendation: batch ALL new tools' wiring into ONE serialized `wire-wave3` at the end** (Wave 5),
exactly as the project did `wire-wave1`/`wire-wave2`. Rationale: steps 1-5 all live in 3-4 central
files (`ToolKind.swift`, `ContentView.swift`, `LibreCADApp.swift`, `CADCanvasView.swift`); if N tool
builders each edited them in parallel, every merge would conflict on the same lines. Keeping tool
LOGIC in each tool's own `Tools/*Tool.swift` file (parallel-safe) and deferring wiring to one owner
is the proven pattern (654 tests, zero wiring-merge conflicts to date).

**Shortcut budget note for wire-wave3:** the letter keys are getting crowded (V/L/C/A/R/P/O/E/G +
shift-twins M/⇧C/⇧O/⇧R/⇧S/⇧M + T/X/F/⇧F). New tools (Hatch/Spline/Array/Divide/Explode/Text/Dim)
will need shift-twins or a second modifier — wire-wave3 owner allocates them; the ⌘K palette
(`ws/palette`) is the pressure-relief valve for tools without a dedicated key.

---

## Design decisions needing a human call (crisp either/or + recommendation)

- **D1 — Dimension entity model: (A) new `.dimension` EntityKind with `DimData` + a `resolve()` that
  produces lines + arrowheads + measurement text, vs (B) explode dimensions to primitives at create
  time.**
  **Recommend A.** It matches ADR-001 (composite entities are value structs with computed geometry;
  the ADR explicitly names "all dimensions" as resolve-not-stored), keeps DXF round-trip fidelity
  (a DIMENSION stays a DIMENSION), makes the dim style live-editable, and the renderer needs ZERO
  changes (resolve emits polylines+fills). B loses round-trip + editability and litters the model.
  Cost of A: one serialized EntityKind step (S1) + a `dimStyleProvider` hook (already reserved at
  Resolve.swift:126). This is the single biggest call — it gates S1, S3, and dimension tools.

- **D2 — Interactive text entry over the Metal canvas: (A) a transient AppKit `NSTextField`/
  `NSTextView` overlay positioned at the click point (commit on Enter → `.add(.text)`), vs (B) a
  SwiftUI sheet/popover for text input, vs (C) in-canvas synthesized glyph echo (handle key events
  directly in `CADCanvasView`).**
  **Recommend A.** `CADCanvasView` is already an `NSViewRepresentable` over a flipped `MTKView`, so
  adding a sibling `NSTextField` subview at the screen point of the click is native, gives free IME/
  cursor/selection, and avoids reimplementing text editing. B is clunky (modal, loses the in-place
  feel); C is a lot of work to redo what NSTextField gives free. A confines the change to
  `CADCanvasView.swift` + a little `CanvasModel` state.

- **D3 — Hatch boundary source: (A) hatch from SELECTED boundary entities (pick closed loops first),
  vs (B) seed-point flood-fill (click inside a region; auto-detect the enclosing boundary).**
  **Recommend A first, B as a follow-up.** A reuses the existing selection + `.hatch` kind + fill
  render with no new geometry kernel; it ships in one tool file. B needs a planar-arrangement /
  boundary-trace kernel (LibreCAD's `RS_ActionDrawHatch` + the boundary detection) — real work,
  higher risk, do it after A proves the fill pipeline end-to-end.

- **D4 — Export render path: (A) a SHARED `ResolvedGeometry → CGContext` abstraction reused by PDF +
  PNG + Print (with SVG as a separate text emitter over the same `ResolvedGeometry`), vs (B) a
  bespoke path per output format.**
  **Recommend A.** All raster/vector-via-CG outputs (PDF, PNG, print) are the same draw calls into
  different `CGContext`s; building one `CGContextRenderer` over the existing `resolve()` output keeps
  the Metal screen path untouched (CONVENTIONS perf rule) and is far less code. SVG can't use
  CGContext (it's an XML emitter) but reads the same `ResolvedGeometry`, so the abstraction is
  "render against `ResolvedGeometry`," with two backends (CG + SVG-text). Needs your nod because it
  introduces a small new rendering abstraction layer.

- **D5 — CI + code-signing/notarization identity: is a Developer ID signing identity / Apple notary
  credential available in this environment, or is CI build+test-only for now (sign/notarize
  deferred)?**
  **Recommend: ship CI build+test immediately (no secret needed); gate signing+notarization on you
  confirming an identity + App Store Connect API key exists.** The environment has been
  network-blocked all session (no push/brew/web), so notarization (which needs Apple's servers) may
  not be runnable here at all — confirm before `ws/ci-signing` attempts the sign/notarize half.

- **D6 (minor) — DocumentGroup vs the current WindowGroup, given the launch-crash history.** Not
  really optional (it's theme #1), but flag the residual risk: DocumentGroup is the exact path that
  SIGTRAP-crashed before via off-main `MainActor.assumeIsolated`. The plan's mitigation (Sendable
  data in the document, `@MainActor` build in the view, zero `assumeIsolated`) is the documented fix
  — but **this MUST get a real user GUI launch** before it's called done (headless ≠ verified). Worth
  a heads-up that this is the highest-risk item and may need a follow-up if SwiftUI's NSDocument
  machinery surprises us again.

---

## Suggested execution order (for the coordinator)
1. **Wave 0** (merge in-flight). Then launch in parallel: **S1** (dim-entity) ‖ **Wave 2 pool**
   (hatch/spline/array/divide-explode) ‖ **Wave 3a docgroup** — these three streams touch disjoint
   files (EntityKind quartet vs new Tool files vs app shell).
2. After S1 merges → **S2** (blocks-insert). After docgroup merges → **Wave 3b** (inspector ‖ palette
   ‖ gizmos) then **Wave 3c** (snapgrid-ui, fillet-ui, tool-text) respecting the ContentView/
   CanvasModel single-editor rule.
3. After `ws/dxf-write-fidelity` + S1 merge → **S3 dim-write**. **Export** + **CI-signing** run
   whenever (export serializes vs other ContentView editors; CI is fully disjoint).
4. **Perf** only after the profiling report.
5. **wire-wave3** LAST, then a consolidated user GUI verification pass.
