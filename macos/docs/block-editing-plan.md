# AutoCAD-grade Block Editing — execution plan

Status: PLAN (read-only analysis, 2026-06-15). Headline feature: a **Block Editor** —
open a block definition, edit its member geometry, save back so EVERY insert updates.

## TL;DR for the coordinator

The keystone is ALREADY DONE. `EntityKind.insert` exists and round-trips DXF; create-block,
explode-insert, and insert tools are built AND wired into `ToolKind`; the blocks sidebar is LIVE
(insert/rename/delete/drag-to-place), not a stub. The genuine gap is the **Block Editor scope**
itself (feature-catalog G8: "in-place block editing"). And the architecture makes it cheap: block
members are ordinary `EntityRecord`s in `drawing.entities` referenced by `Block.entityIDs`, and
`resolve(.insert)` pulls members via `blockProvider` (name → entityIDs → entities). So editing a
member through the normal undoable edit path updates every insert automatically on next resolve.
The Block Editor is therefore a **transient VIEW SCOPE** (which entities the canvas shows / indexes /
selects), directly modeled on the existing `activeSpace`/`activeLayout` paper-space machinery.

## Current-state findings (cited)

### The block model is the ideal centralized-store design (ADR-001)
- `Block` carries `name`, `basePoint`, ordered `entityIDs: [EntityID]`, `isFrozen`
  (`Block.swift:44-63`). Members are id-refs into `CADDrawing.entities` — NO nested child graph,
  NO anonymous `*`-block for storage (`Block.swift:5-15, 39-49`).
- `BlockTable` has full member mutators: `setEntityIDs`/`addEntityID`/`removeEntityID`/
  `removeEntityIDEverywhere` (`Block.swift:227-253`) — but the editor mostly will NOT need these
  (see below).
- `CADDrawing.blocks` is the table; member entities live in `CADDrawing.entities`
  (`CADDrawing.swift:534, 542-544`).

### Editing a member updates all inserts automatically — confirmed
- `resolve(.insert)` → `resolveInsert` looks the block up via `ctx.blockProvider(d.blockName)`,
  transforms each member by the insert placement, resolves recursively, depth-guarded
  (`Resolve.swift:1313-1339`).
- `blockProvider` is wired by `CADDrawing.makeResolveContext` from `blockMembersSnapshot()`, which
  is literally `block.entityIDs.compactMap { entity($0) }` (`CADDrawing.swift:1331-1344, 1353-1360`).
- THEREFORE: changing a member `EntityRecord` (via the normal undoable `replace`/`add`/`remove`
  path) changes what `blockProvider` returns, so every insert re-resolves with the edit. No special
  "save back" entity-graph copy is needed — the edit IS the save-back. This is the crux the owner
  asked us to confirm: **yes, members are centrally stored and all inserts update for free.**

### `InsertData` fields (Entity.swift:811-852)
`blockName` (code 2), `insertionPoint` (10), `scale` (41/42/43, mirror via negative), `rotation`
(50, radians), MINSERT `rows`/`cols`/`rowSpacing`/`colSpacing` (70/71/44/45). `isArray` helper.
Back-compat decode tolerates missing MINSERT fields. `EntityKind.insert` is already a case
(`Entity.swift:1115`) — **no EntityKind change needed for any of this work.**

### Tools already exist AND are wired
- `CreateBlockTool` (`CreateBlockTool.swift`) — produces a `CreateBlockRequest`; applied via the
  undoable model op `CADDrawing.makeBlockFromEntities(name:basePoint:ids:)`
  (`CADDrawing.swift:1065-1122`). Re-authors members RELATIVE to the base point (`toLocal` translate)
  and drops one INSERT at the base point so geometry redraws in place.
- `ExplodeInsertTool` (`ExplodeInsertTool.swift`) — exact inverse; emits transformed member records.
- `InsertTool` (`InsertTool.swift`) — places `.insert` with scale/rotation/MINSERT + rubber-band.
- All three are wired: `ToolKind` has `.createBlock` (line 148), `.explodeInsert` (151),
  `.insert` (111); CanvasModel wires their construction-injection (`CanvasModel.swift:1241-1257`,
  `applyPendingBlockCreationIfAny` 1382-1390). Decision log R1.a confirms shortcuts (⌥B/⌥X/⇧I).

### Blocks sidebar is LIVE (not a stub)
- `BlocksSidebar.swift` (`BlocksSection`/`BlockRow`) lists definitions; per-block insert / inline
  rename / delete + drag-to-place via `BlockDragItem`. Routes to `CanvasModel.insertBlock` /
  `insertBlockAtViewCenter` / `renameBlock` / `deleteBlock` (`CanvasModel.swift:1776-1859`), all
  undoable and index-synced. (Feature-catalog §7 line 168 still SAYS "stub" — stale; the live
  panel exists. Plan should fix the catalog.)

### The active-space machinery is the editor-scope template
- `CanvasModel.activeSpace`/`activeLayout` (`CanvasModel.swift:149-154`); `activeSpaceEntities` is
  the single filtered subset that drives BOTH the index rebuild AND the renderer pack
  (`CanvasModel.swift:621-643`). `setActiveSpace` re-frames the camera, rebuilds the index over only
  the active subset, clears selection/snap/hover, bumps `modelDirty`/`modelVersion`
  (`CanvasModel.swift:670-709`). `LayoutTabStrip` (`ContentView.swift:1442-1546`) is the context-bar
  UI model; its call site is `ContentView.swift:225-239`.
- A Block Editor scope is the SAME shape: a third "scope" alongside model/paper that filters the
  canvas to one block's member ids.

### Double-click entry point already exists
- `CADCanvasView.handleDoubleClick(at:)` (`CADCanvasView.swift:1029-1053`) hit-tests under the
  cursor and currently opens the inline text editor for `.text`/`.mtext`. Adding an `.insert` arm
  that enters the block editor is a small, localized change in a wiring-owned file.

### Edit plumbing the editor reuses unchanged
- `applyCommit` (`CanvasModel.swift:1623-1669`) and `applyInspectorEdits`/`replaceEntityKind`
  (1697-1724) edit entity records by id, undoable + index-synced. Member ids ARE entity ids, so
  EVERY existing tool + the inspector already edit block members with zero changes — once the
  selection/index scope is the member set.

### DXF round-trip of block definitions is DONE
- Reader builds `BlockTable` + appends members to `records` with minted ids
  (`DXFReader.swift:161-201`). Writer emits non-anonymous block definitions + their member geometry
  (`DXFWriter.swift:241-251`). So an edited block (edited members) saves + reloads correctly with
  NO new DXF work. ATTDEF/ATTRIB are NOT handled by the bridge (grep empty) — attributes are a
  later phase that DOES need bridge work.

## In-flight dependency (BLOCKING)

Four locked worktrees (`git worktree list`) are the **paper-space P3/P4** agents (decision log
`776797bc9`). They hold `CADDrawing.swift`, `DXFReader.swift`, `DXFWriter.swift`, `lcdxf.cpp`,
`CanvasModel.swift`, `ContentView.swift`. The block BUILD wave must start AFTER P3 merges. First
step of every build agent: `git reset --hard native-macos` (worktrees branch off master).

## Recommended architecture

**Block Editor = a transient VIEW SCOPE in `CanvasModel`, plus an entry/exit context bar.** This is
fork (A) from the brief (a dedicated transient edit scope reusing the active-space/tab machinery) —
recommended over (B) a separate window (heavy; duplicates renderer/model wiring) and (C) REFEDIT
in-place isolation (more complex selection masking for little gain at this stage).

Design:
1. **Scope state** (`CanvasModel`): `editingBlockName: String?` (nil = not editing). When set, a new
   `editScopeEntities` computed property returns the block's member records (`drawing.blocks
   .entityIDs(of: name).compactMap { drawing.entity($0) }`). `activeSpaceEntities` (the index/render
   subset) returns `editScopeEntities` when editing, else the existing model/paper filter — so the
   canvas, quadtree, snapping, and selection all scope to the block's members WITHOUT touching the
   renderer or quadtree code. The members are authored in the block's LOCAL frame (base at origin),
   so the editor draws them around (0,0) — re-home the floating origin like a space switch.
2. **Members ARE live entities** → every existing tool (move/copy/line/trim/inspector…) edits them
   through `applyCommit`/`applyInspectorEdits` unchanged. No tool changes. This is the whole win.
3. **Save-back is implicit** — because members are the real records `blockProvider` reads, an edit
   is immediately reflected by every insert on the next resolve. "Save and close" just exits the
   scope (clears `editingBlockName`, re-frames to model). "Discard" needs an undo-to-checkpoint
   (snapshot `undoManager` group or record the member set on entry and revert) — see Risks.
4. **Entry points**: (a) double-click an `.insert` → open its `blockName`; (b) sidebar "Edit"
   button → open that block; (c) optional: while a single `.insert` is selected, an Edit Block menu
   item. Exit via the context bar ("Editing block: NAME · Save & Close / Discard").
5. **Base point**: members are stored local-to-base, so the editor shows them around origin and the
   base point is just the origin marker; no transform juggling needed for the MVP (creation already
   folded the base offset into member coords — `makeBlockFromEntities` `toLocal`).

Why this is minimal-yet-correct: it adds ONE optional scope variable + one filter branch + one
context bar, reuses the proven active-space pattern, and inherits all editing/undo/index/render for
free. No `EntityKind` change, no resolve change, no DXF change.

## Phased waves

Convention: every build agent first runs `git reset --hard native-macos`; build UNWIRED then a
serialized wire-wave; serial test gate (`swift test --package-path macos/engine --disable-sandbox
--no-parallel`). ≤4 concurrent agents on DISJOINT files. **All build waves BLOCKED until paper-space
P3/P4 merges** (they hold CADDrawing/DXF/CanvasModel/ContentView).

### Wave 0 — Scope model + entry/exit (the MVP core). Effort: M. BLOCKED on P3.
Serialized solo (touches the hot `CanvasModel.swift`).
- Owned (exclusive): `CanvasModel.swift` (add `editingBlockName`, `editScopeEntities`, branch
  `activeSpaceEntities` + `setActiveSpace`-style `enterBlockEdit(name:)` / `exitBlockEdit(save:)`
  re-using the camera-reframe + index-rebuild + selection-clear pattern from lines 670-709).
- Deps: P3 merged.
- Done: enter/exit a block edit scope programmatically (unit-tested via a CanvasModel-level test);
  while editing, `activeSpaceEntities` == the block's members; exit restores model space; serial
  suite green. NO UI yet (unwired core).

### Wave 1 — Block-edit context bar + entry wiring. Effort: S–M. Dep: Wave 0.
Serialized solo (wiring files: `ContentView.swift`, `CADCanvasView.swift`, `BlocksSidebar.swift`).
- Owned (exclusive): `ContentView.swift` (a `BlockEditBar` modeled on `LayoutTabStrip`, shown when
  `model.editingBlockName != nil`: "Editing block: NAME" + Save & Close + Discard);
  `CADCanvasView.swift` (add an `.insert` arm to `handleDoubleClick` 1029-1053 → `model
  .enterBlockEdit(name: insert.blockName)`; add a controller hook); `BlocksSidebar.swift` (an "Edit"
  button per `BlockRow` → `model.enterBlockEdit`).
- Deps: Wave 0 merged.
- Done: double-click an insert opens the editor; sidebar Edit opens it; the context bar shows + Save
  & Close / Discard exit; user can move/edit a member and see all inserts update after Save & Close;
  `.app` rebuilt for GUI verification; serial suite green. **This is the MVP deliverable** (see below).

### Wave 2 — Discard (revert-to-checkpoint). Effort: S–M. Dep: Wave 0.
Can run concurrently with Wave 1 ONLY if it owns a different file; realistically fold into Wave 0/1
since it touches `CanvasModel.swift`. Recommend: do it inside Wave 0 (same owner) to avoid a
CanvasModel serialize conflict.
- Approach: on `enterBlockEdit`, capture a checkpoint (either open a named UndoManager group and
  `endUndoGrouping`+`undo` to roll back on Discard, OR snapshot the member records + block.entityIDs
  and restore them as one undoable op). Recommend the snapshot-restore (deterministic, testable).
- Done: edit members, Discard → members revert to entry state in one undoable step; serial suite green.

### Wave 3 (parallel-friendly polish, post-MVP). Each independently shippable.
- **3a — Sidebar catalog fix + Edit affordance polish.** Owned: `BlocksSidebar.swift`,
  `feature-catalog.md` (mark §7 sidebar "live", G8 in-place-editing "done"). Effort: S.
- **3b — New empty block + add-selection-to-open-block.** Owned: a NEW file
  `Tools/...`/`CanvasModel` helper for "create empty block then edit" — but this touches
  `CanvasModel.swift` (hot) → serialize after Wave 0/1. Effort: S–M.
- **3c — Tests.** Owned: NEW `Tests/CADEngineTests/BlockEditScopeTests.swift` (DISJOINT — safe to run
  parallel with any code wave). Covers enter/edit-member/all-inserts-update/exit/discard at the
  CanvasModel + drawing level (no GUI/modal). Effort: S.

### Deferred (separate future projects — NOT in the MVP)
- **Library browser + import-block-from-.dxf** (catalog G8 / §7 lines 169-170). Effort: L. Needs a
  gallery UI + a DXF-as-block import path (reader work — held by P3-class agents). Own files: NEW
  `Sidebar/LibraryBrowser.swift` + a `CADEngine` import helper. Engine import must NOT route through
  app types (module boundary).
- **Block attributes (ATTDEF/ATTRIB)** (catalog G8 / §7 line 167). Effort: L. Genuinely needs:
  (a) a model for attribute defs/values (additive `EntityRecord` fields or a parallel list — do NOT
  add an `EntityKind` case; if a kind is truly unavoidable make it a SOLO serialized phase), and
  (b) bridge work in `lcdxf.cpp`/DXFReader/DXFWriter to read+write ATTDEF/ATTRIB (currently skipped).
  The bridge/DXF files are the same hot set P3 holds — must serialize after all paper-space DXF work.

## Recommended MINIMAL first deliverable (concept proof)

**Waves 0 + 1 + (Discard folded into 0) + a CanvasModel-level test.** That gives the owner exactly
the headline: double-click an INSERT (or click sidebar "Edit") → the canvas scopes to the block's
members → move/edit a member with any existing tool → Save & Close → every insert of that block
updates. Create-block-from-selection and the live Edit sidebar entry come along because the tools +
sidebar already exist. **Defer attributes + library browser.** This is M total effort, mostly in one
serialized `CanvasModel.swift` owner + one wiring owner.

## Risks + mitigations

**Biggest risk: Discard semantics + undo coherence.** Because members are LIVE entities, edits land
in the document immediately (undoable), so "Discard" must reliably revert ALL member edits made
during the session as ONE step, and entering/exiting must not corrupt the global undo stack or leave
a partial edit if the user closes the document mid-edit. Mitigation: implement Discard as a
deterministic snapshot-restore (capture member records + `block.entityIDs` on entry; on Discard,
re-apply that snapshot as one undoable group). Also guard document-close while editing (auto Save &
Close, since edits are already in the doc). Test this explicitly at the CanvasModel level (Wave 3c).

Other risks:
- **CanvasModel.swift is the hottest file** — Waves 0/2/3b all want it → serialize them under one
  owner or run strictly sequentially. Never split CanvasModel across concurrent agents.
- **P3 collision** — CanvasModel/ContentView/CADDrawing/DXF are held by paper-space agents. Do not
  start any build wave until P3/P4 merges; rebase on `native-macos` first.
- **Floating-origin / camera on enter** — reuse `setActiveSpace`'s re-home + `Viewport.fit` exactly
  (members are around origin) so the block fills the view; low risk, proven code.
- **Nested-insert edit** — editing a block whose members include other inserts is fine (resolve is
  recursive + depth-guarded); the editor just shows the nested insert as one entity. No special work.
- **Stale catalog** — §7 still calls the sidebar a stub; fix in Wave 3a so docs match reality.

## Effort summary

| Wave | What | Effort | Concurrency |
|---|---|---|---|
| 0 | Scope model + enter/exit + Discard | M | solo (CanvasModel) |
| 1 | Context bar + double-click/sidebar entry wiring | S–M | solo (wiring files) |
| 3a | Sidebar/catalog polish | S | parallel (own files) |
| 3b | New/empty block + add-to-open-block | S–M | serialize (CanvasModel) |
| 3c | Block-edit scope tests | S | parallel (new test file) |
| Defer | Library browser / import-from-dxf | L | future project |
| Defer | Attributes (ATTDEF/ATTRIB + bridge) | L | future, serialized DXF |

## Open OWNER questions (resolve before building)

1. **Save-on-exit default**: AutoCAD's Block Editor has explicit "Save Block" then "Close". Do you
   want Save & Close as the primary button with a separate Discard (recommended), or auto-save on
   every member edit with no explicit save step?
2. **Base point editing in the MVP**: ship base point as fixed (origin marker only) for the MVP, or
   include a "set base point" affordance in the first deliverable? (Recommend: fixed in MVP, add later.)
3. **Attributes scope**: are block attributes (fill-in-the-blank text fields, e.g. titleblocks)
   in-scope for THIS project, or a separate later project? They are the largest remaining piece and
   need C++ bridge work serialized behind paper-space. (Recommend: separate project.)
4. **Library browser**: in-scope now or later? (Recommend: later — the MVP editor is the headline.)
