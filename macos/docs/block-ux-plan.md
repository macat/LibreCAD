# Block UX & Dynamic Blocks — Execution Plan (native-macos)

Synthesized 2026-06-16 from a research+design workflow (AutoCAD dynamic-block tutorial digest +
full AutoCAD block-feature research + a code audit). Owner asks, in priority order:
**(1) convert-to-block discoverable → (2) edit a block → (3) reinsert → (4) thumbnail in the side
panel → (5) dynamic blocks.**

## 0. The one hard sequencing fact
The engine is already DONE for (1)(2)(3) and most of the thumbnail data path for (4); the remaining
work is almost entirely **UI wiring**, which lives in the hot/contended files. **WIRE-WAVE 1**
(paper-space viewport tool + plot menu + draw-variant pickers) is **IN FLIGHT** and owns the exact
hot files block-UI needs: `ContentView.swift`, `CanvasModel.swift`, `ToolKind.swift`,
`ToolOptionsBar.swift`, `CommandPalette.swift`, `LibreCADApp.swift`. **Every block-UI wave that
touches those must serialize after WireWave1 merges.** The *one* genuinely parallel slice — the
thumbnail — touches none of them and starts immediately.

## 1. Current state (confirmed against code)
| Ask | Engine | UI | Gap |
|---|---|---|---|
| (1) Convert-to-block | DONE — `CreateBlockTool` (ctor takes `blockName`) → `CADDrawing.makeBlockFromEntities:1081` | Wired but weak (Blocks menu ⌥B, palette, Modify toolbar) | **No name prompt** (every GUI block is `Block-N`); **no selection context-menu verb** |
| (2) Edit a block | DONE — `CanvasModel.enterBlockEditing/exitBlockEditing(save:)/finishBlockEditingIfNeeded` (:834/889/949) | **ZERO callers** | Pure wiring; double-click seam `CADCanvasView.handleDoubleClick:144` (text-only today) |
| (3) Reinsert | DONE — sidebar `insertBlockAtViewCenter` + drag-to-place | Works | Insert *tool* (`ToolKind.insert:284`) inert (no picker) — sidebar covers it |
| (4) Thumbnail | Data path DONE — `resolve`, `ExportSceneBuilder.build` (SVGExporter:190), `CGSceneRenderer.draw`, `writePNG` | Generic `square.on.square` icon (BlocksSidebar:117) | Need a **block-subset** scene builder + bitmap→NSImage + cache |
| (5) Dynamic blocks | none | none | Greenfield; model additively, **no `EntityKind` case** |

**Why this is cheap:** resolve-by-name is the rule — `Block.entityIDs` → live members; `resolveInsert`
looks the block up each resolve → **editing a member auto-updates every insert; the edit IS the
save-back.** Attributes (`InsertData.attributes`, `Block.attributeDefs`) + `BlockLibrary` already
round-trip in the engine, unwired. **No new `EntityKind` case is needed for anything here.**

## 2. Waves (near-term, asks 1–4)

### WAVE T — Thumbnails (START NOW, fully parallel to WireWave1)
The only block slice with zero contention. Ships end-to-end without waiting.
- **Owned (exclusive):** NEW `CADEngine/Export/BlockThumbnailScene.swift` (engine-pure
  `blockThumbnailScene(_:blockName:context:) -> ExportScene?`, resolves `block.entityIDs` over the
  member subset via `makeResolveContext`, unit-testable, no AppKit); NEW
  `LibreCADmacOS/Sidebar/BlockThumbnailRenderer.swift` (bitmap `CGContext` → `NSImage`, fit-to-page
  `ExportTransform`, clear bg, min-stroke clamp); `LibreCADmacOS/Export/CGSceneRenderer.swift`
  (additive defaulted `minStrokeDevicePx` param — tiny tiles render sub-pixel otherwise);
  `LibreCADmacOS/Sidebar/BlocksSidebar.swift` (swap the generic icon for the rendered thumbnail +
  a `(blockName, modelVersion)`-keyed cache); + tests.
- **Disjoint from WireWave1** (none of those files are in WW1's set). **Done:** sidebar shows a
  rendered preview of each block; engine test asserts a known block yields non-empty geometry/bounds.

### WAVE BW — Block wire-wave (SERIALIZED, after WireWave1 + WAVE T merge)
One solo agent owns the contended files; lands asks (1)+(2)+(3).
- **Owned (all hot):** `ContentView.swift`, `CanvasModel.swift`, `ToolKind.swift`,
  `CommandPalette.swift`, `LibreCADApp.swift`, `CADCanvasView.swift`, `BlocksSidebar.swift`, NEW
  `BlockEditBar.swift`, NEW `BlockNamePrompt.swift`, `LibreCADDocument.swift` (close hook).
- **Scope:** (1) "Create Block from Selection…" in the canvas context menu (gated on selection) +
  a View-layer name sheet → `CreateBlockTool(blockName:)`; (2) double-click an insert → `enterBlockEditing`
  (extend `handleDoubleClick` after the text check), sidebar **"Edit"** action, a **BlockEditBar**
  (Save & Close / Discard) shown when `isEditingBlock`, "Editing block: <name>" affordance, document-close
  hook → `finishBlockEditingIfNeeded`; (3) sidebar reinsert as primary, optional Insert-tool picker.
- **EntityKind NOT touched.** Modals stay in the View layer (test-hang rule).

### WAVE BW2 — Attributes + Library UI (SERIALIZED, after BW)
Display/edit `InsertData.attributes` on selection; prompt-on-insert sheet; ATTSYNC-style reconcile;
a parts-library gallery over `BlockLibrary.scan(directory:)` with thumbnails (reuses WAVE T) +
file picker + drag-to-place.

## 3. Dynamic blocks — phased (ask 5), additive, NO `EntityKind` case
Data model: on `Block` add `visibilityStates`/`parameters`/`actions`; on `InsertData` add
`parameterValues`/`activeVisibilityState`/flip flags (all `decodeIfPresent` back-compat). `resolveInsert`
drops non-state members + applies each action's transform per the instance's parameter values — pure
value transformation, no aliasing.
- **D1 Visibility states** (M) — highest value, lowest risk: named member sets; instance carries the
  active state; resolve hides non-state members; dropdown grip/inspector picker. Consume from imported
  DXF first.
- **D2 Flip + linear parameter w/ Move/Stretch action + grips** (L) — the grip-interaction layer is the cost.
- **D3 Lookup table** (M) — once D2's parameter machinery exists.
- **Deferred:** rotation/polar/XY/array actions, parametric constraints + solver (separate subproject), REFEDIT.

## 4. Risk + minimal first deliverable
**Biggest risk:** serialization contention with WireWave1 stalls the block-UI program. **Mitigation:**
start WAVE T now (zero contention); gate BW strictly on WireWave1 merge; keep BW a single solo agent
(fan-out only creates conflicts on the shared files).
**Recommended minimal first deliverable:** WAVE T end-to-end — it directly answers "if it's a text,
it's hard to see what it is," needs none of WireWave1's files, and is independently testable.

## 5. Order + open questions
**Order:** T (now) → BW (after WW1) → BW2 → D1 → D2 → D3.
**Open questions:** (1) Create-Block name UX: modal sheet (recommended) vs auto-name+inline-rename.
(2) Insert-tool picker needed, or is sidebar reinsert enough? (3) Dynamic-blocks depth: consume-from-DXF
vs author (D1 visibility states first) vs full authoring+constraints (multi-month).
