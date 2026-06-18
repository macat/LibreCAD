# Parity Program Plan — LibreCAD + AutoCAD-LT (parallel program)

> Produced 2026-06-17 by the `parity-program-plan` workflow (6 feature-cluster probes → sequencing
> DAG → critic) on top of two fresh code-grounded audits (`native-macos @ d110ada28`, 3393 tests).
> Critic verdict: **APPROVE-WITH-FIXES** (scope/ownership corrections, no re-planning). Owner chose
> "do all of it (parallel program)."

## Where we are (audit synthesis)

Practically **at LibreCAD parity** already; the genuine remaining gaps are a handful of finishers +
one **data-loss bug** (text styles dropped on save). The interesting frontier is **AutoCAD-LT-grade
plotting/layout/annotation**, where ~80% of the engine is built and just needs DXF persistence + UI.

55 ToolKind · 22 EntityKind · DXF+DWG(R2000) r/w · DocumentGroup · grips · dynamic input · OTRACK/polar ·
live/editable dims · hatch pattern lines · paper-space layouts+viewports+scale-plot · measure tools ·
stretch/break/join/lengthen · Quick Select · layer states · per-entity transparency (440) · MLEADER.

## Infra fact (resolves the critic's biggest worry)

The vendored **libdxfrw IS git-tracked**: `DxfBridge/libdxfrw` is a tracked **symlink** →
`libraries/libdxfrw/src/` (55 tracked files). `writeWipeout`/`processWipeout`/`writeMLine` +
`DRW_Textstyle` are all present. Worktree resets are safe (the relative symlink resolves inside each
worktree). **No libdxfrw patch is needed anywhere in this program.** The only libdxfrw-gated feature
(multi-layout DXF) is DEFERRED.

## The three genuine serialized critical sections (never overlap)

- **lcdxf.{cpp,h} C-ABI** — exactly three non-concurrent solo touches: **W1-1A** (text-style) →
  **W3-3A** (Wipeout) → **W3b-3bA** (layer-transparency XDATA).
- **EntityKind 28-switch** — only **Wipeout** (W3-3A), solo wave, MLEADER-style 4-sub-phase cadence.
  MLINE's EntityKind add is DEFERRED.
- **ToolKind makeTool-switch + CommandPalette.glyph** — three append-only adds: `.revcloud` (W2-2B),
  `.lineConstruction` (W2-2C, serialized AFTER 2B), `.wipeout` (folded into W3-3A).

## Wave DAG

| Wave | Depends | Lanes (disjoint owned files) |
|---|---|---|
| **W1** | — | **1A** Text STYLE-table DXF round-trip *(data-loss fix; SOLO lcdxf)* · **1B** Rotate-copy · **1C** Mirror-copy · **1D** Per-layer-transparency engine field |
| **W2** | W1 | **2A** Offset bothSides/eraseSource flags · **2B** RevisionCloud tool (UNWIRED)+ToolKind · **2C** LineConstruction tool (UNWIRED)+ToolKind+bisector kernel · **2D** Per-viewport freeze/display/twist fields |
| **W5** | W1, **W2** | **5A** Circle tangent variants engine (TTR/TTT/inscribe/from-arc) — UNWIRED. *(SnapGeometry serialized after 2C.)* |
| **W3** | W1, W2 | **3A** WIPEOUT new EntityKind — SOLO atomic 28-switch (the only new EntityKind) |
| **W3b** | W3 | **3bA** layer-transparency DXF (XDATA 1001/1071) · **3bB** annotation-scale state+UI · **3bC** CXF parser *(optional)* |
| **W4** | W1,W2,W3,W3b,W5 | **4A** WIRE-WAVE (single owner of CanvasModel/ContentView/ToolOptionsBar/LibreCADApp) · **4B** Page Setup sheet *(new file)* · **4C** User font-dir picker |

## Critic fixes to apply (before the relevant wave)

1. **W3b-3bB scope** — annotative-text engine path is ALREADY DONE (`ResolveContext.annotationScale`,
   `makeResolveContext(annotationScale:)`, TextShaper/MTextShaper multiply). Re-scope 3bB to the
   genuinely-missing pieces: `$CANNOSCALE` GraphicVariables accessor, `CanvasModel.annotationScale`
   state, StatusBar control, and threading the scale into the `makeResolveContext` CALL SITES.
2. **W3b-3bB ownership** — to deliver pick-vs-draw consistency, either expand 3bB to own
   Snapping/Selection/OverlayGeometry/MarqueeHoverOverlay/CADCanvasView (all free post-W3) OR
   explicitly document the nil-default-1.0 fallback as the round's limitation.
3. **W2-2C ownership JSON** — add `ToolKind.swift` + `CommandPalette.swift` to 2C's owned set with a
   "serialized-after-2B, append-only" note (its deliverable already edits them).
4. **W5 DAG** — W5 dependsOn **W2** (graph-enforce the SnapGeometry serialization vs 2C), not just W1.

## Deferred (with reasons)

- **Multi-layout DXF round-trip** — policy-gated on off-limits libdxfrw (one hard-coded `*Paper_Space`
  block). Interim no-patch S-fix: a loud one-time WARNING when `layouts.count > 1` on save.
- **MLINE** (double critical section, twice-deferred) · **Isometric grid** (single owner across the
  hottest contended files — schedule solo AFTER W4) · **CXF** (speculative; optional 3bC) ·
  **annotative for dims/leaders/hatch** (scope cut from 3bB; dims carry `ResolvedDimStyle.scale` =
  double-scaling trap).

## Execution status

- [x] **W1 — SHIPPED** `native-macos @ 1d8869087`, **3411 tests**, `.app` rebuilt. Lanes: 1A `ffd49796` (text-style round-trip, review APPROVE-WITH-NITS), 1B `b960a82` (rotate-copy), 1C `9155a3f` (mirror-copy), 1D `53de020` (layer transparency). Infra: auto-isolation flaky → pre-create worktrees going forward.
- [x] **W2 + W5 — SHIPPED** `native-macos @ 50d02792c`, **3490 tests**. 2A `ba8418a` (offset flags), 2B `897a5277` (revcloud), 2C `21ea4e6` (line construction), 2D `6988a4c` (viewport freeze/display/twist), 5A `9f44111` (circle tangents). All UNWIRED. Learnings: each new ToolKind needs 2 coupled arms (`CommandPalette.glyph` + `ContentView.metadata`); switched to in-process agents (background dispatch flaky).
- [x] **W3 — SHIPPED** `4c1147333` Wipeout new EntityKind (review APPROVE-WITH-NITS).
- [x] **W3b — SHIPPED** `e295215` layer-transparency DXF (XDATA 1071) + `5ba46aa` annotation-scale UI. (CXF deferred.)
- [x] **W4 — SHIPPED** `046a7af` wire-wave (all tools surfaced) + `0c6e5fb` page-setup sheet + font-dir picker + layer-opacity slider.

**PROGRAM COMPLETE** — `native-macos @ 99e4dd1fa`, **3564 tests** (3393 → +171), `.app` rebuilt.
