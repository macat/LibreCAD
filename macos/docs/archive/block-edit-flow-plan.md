# Block-Editing Flow — End-to-End Design (BEDIT-style)

Authored by the coordinator 2026-06-16 after the owner reported two defects: (1) **editing a block
doesn't change the block — drawing in the editor adds loose objects to the document**; (2) **the
editor replaces the document view — it should open in its own TAB** (AutoCAD BEDIT). This designs the
WHOLE flow so we stop patching. Spec: `block-features.md` §2/§4/§16/§20.

## Architecture we build on (established + merged)
- A **block definition** `Block{name, basePoint, entityIDs:[EntityID]}` — members are `EntityRecord`s
  in `CADDrawing.entities` referenced by `entityIDs`. An **INSERT** references a block by name;
  `resolveInsert` looks members up **by name** and transforms them → **editing a member updates ALL
  inserts live** (no copy).
- **Member exclusion (merged):** `CADDrawing.blockMemberIDs` excludes definition members from
  model-space render/select/marquee/⌘A/snap — members are only drawn via their insert + only editable
  in the Block Editor.
- **Editor scope (merged, B0):** `CanvasModel.editingBlock`/`editingBlockEntities`/`enterBlockEditing`/
  `exitBlockEditing(save:)`/`finishBlockEditingIfNeeded`; `BlockEditBar` (Save&Close/Discard). Today it
  **swaps the active-space view in place** (defect 2) and the **add path doesn't append to the block**
  (defect 1).
- **Tab strip:** `ContentView.LayoutTabStrip` sourced from `CanvasModel.orderedLayouts`/`activeSpace`/
  `activeLayout`; `setBlockMembers(name:ids:)` is the undoable member-list mutator.

## The flow (step → behavior → why)
1. **Create block from selection** — *correct today, keep.* Select → "Create Block from Selection"
   (right-click / Blocks menu / ⌘K) → name sheet → pick base point → `makeBlockFromEntities` removes the
   originals, mints members, drops one INSERT. Selection becomes an insert; members go block-only.
2. **Open for editing → ITS OWN TAB (fixes defect 2).** Entry: double-click an insert, or sidebar
   "Edit". A transient, visually-distinct tab **"✎ <BlockName>"** is appended to the tab strip and
   activated; **Model/Layout tabs stay** (document NOT replaced). Camera frames the members around the
   base point (show a base-point marker); index/selection/snap scope to the members.
3. **Editing in the tab — EVERY edit mutates the BLOCK:**
   - **Move/modify a member** → `.replace` (works; inserts update live).
   - **Draw NEW geometry** → `.add` adds the entity AND **appends its id to the editing block's
     `entityIDs`** via `setBlockMembers` (undoable) — **the fix for defect 1.** New entity becomes a
     member (excluded from model space, drawn via inserts).
   - **Delete a member** → remove the entity + drop its id from `entityIDs`.
   - **Paste / duplicate** → into the block.
   Nothing leaks to the document.
4. **Save & Close vs Discard.** Edits are live (shared members), so Save&Close = commit + close the
   tab + return to the prior tab. Discard = restore the block's entry snapshot (members + `entityIDs`
   captured on open) + close. Undo: per-edit while in the session (⌘Z individual edits); Discard reverts
   the whole session incl. newly-added/removed members.
5. **Tab lifecycle.** One block-edit tab at a time; re-opening the same block reuses it. Switching to a
   Model/Layout tab mid-edit → **auto Save&Close** then switch (see FORK 1). Document-close while editing
   → auto Save&Close.
6. **Edge cases.** Nested block (members include an insert): the nested insert renders; opening the
   nested block from within the editor → **v1 defer** (FORK 2). Attributes/dynamic params on the edited
   block: preserved (they live on `Block`, untouched by member edits). Empty block / delete-all-members:
   allowed, crash-guarded. Rename: via sidebar when not editing. Redefine (existing name on create):
   keep the current warn→redefine path.
7. **Reconciliation:** member-exclusion, resolve-by-name inserts, thumbnails, and DXF round-trip all
   keep working (they read `entityIDs`/the block table directly; the flow only changes WHERE new adds go
   + how the session is surfaced as a tab).

## Build plan (phased)
Mostly UI/CanvasModel + the add-path; ONE serialized wave on the hot UI files (no engine change needed —
`setBlockMembers` exists). Owned: `CanvasModel.swift` (add-path routes `.add`→block; tab/scope state),
`ContentView.swift` (`LayoutTabStrip` block-edit tab + host `BlockEditBar`), `CADCanvasView.swift`
(double-click-insert→open; in-editor input), `Sidebar/BlockEditBar.swift`, + new tests. If a clean
single-append undoable mutator is wanted, a tiny `CADDrawing.addEntityToBlock` is a small engine prep
(else use `setBlockMembers`).
**Done-criteria / tests:** draw-in-editor → entity in `block.entityIDs`, NOT loose model-space; inserts
update; exit → no loose object; move-member → inserts update (regression); delete-member → dropped from
block; tab appears/distinct/active on open with document tabs intact; Save&Close/Discard closes + returns;
switch-away auto-finishes; Discard reverts added+moved+removed.

## Owner decision forks
1. **Switch-away mid-edit:** auto Save&Close (recommended) · prompt Save/Discard · disallow until closed.
2. **Open a nested block from inside the editor:** v1 defer (recommended) · support now.
3. **Undo granularity:** per-edit during the session (recommended) · whole-session-as-one-⌘Z.

## Biggest risk + mitigation
The block-edit context becoming a true third "tab scope" without destabilizing the model/paper active-
space machinery + the merged member-exclusion. Mitigation: model it as the existing `editingBlock`
state DRIVING a tab descriptor (don't invent a new EntitySpace case); reuse the proven enter/exit
re-scope; gate every new behavior behind `editingBlock != nil`; pin it all with the regression tests above.
