# Decision Log — autonomous decision points (for owner traceability)

This log records judgment calls made while the owner (macatt) is away, so they can be
traced/reversed later. Each entry: date, decision, the options considered, why, and how to revisit.
Newest first. (Reversible code lives behind small diffs on `native-macos`; cite the commit/wave.)

---

## 2026-06-16 — ARCHITECTURE REMEDIATION (R4 + R10) + visible resize/rotate gizmo (`native-macos @ 0e98b2be7`, **2634 tests**, `.app` rebuilt)

Acting on the architecture review (`macos/docs/architecture-review.md`), the owner chose R4 (silent data loss) + R10 (dead snaps) + "keep CanvasModel big / keep it simple." Planned via the `r4-r10-fix-plan` workflow (probe → disjoint build plan); the gizmo via `gizmo-transform-probe`. All reviewed + serial-gated + merged by hash.

- **R10 — dead snaps** `bade42618` (+4): `CanvasModel.updateSnap` now forwards `referencePoint: relativeZero` + `ctx` to `Snapping.snap`, so perpendicular/tangent/parallel produce candidates on the live path (were gated behind an always-nil referencePoint). New live-path test through `updateSnap` (the existing tests called `Snapping.snap` directly + couldn't catch it). `distanceAlong` left inert (no spacing field) — tiny follow-up.
- **R4b — document-settings $VAR round-trip** `5c2960349` (review APPROVE, C-ABI memory safety re-verified): generic `$VAR` pass-through bag through the 6-site C bridge (new additive `LCHeaderVar` + read accessors + write params); the 7 standard settings ($GRIDMODE/$GRIDUNIT/$PDMODE/$PDSIZE/$ANGBASE/$ANGDIR/$PINSBASE) now survive a `.dxf` save→reopen (coord vars preserved as vectors) via libdxfrw's existing curated emit list (drw_header.cpp UNTOUCHED). $LC_SNAPMODE in-memory-only; DWG gap pinned. False "round-trips" doc-comments corrected; SaveRoundTripTests extended through the real codec (fail-before/pass-after).
- **R4a — lossless dynamic-block persistence** `0e98b2be7` (+10; owner chose lossless-now; review APPROVE-WITH-NITS, both fixes applied): dynamic-block data now survives DXF save→reopen. **Mechanism deviation (accepted):** the brief said XDATA, but stock libdxfrw can't round-trip entity/block extData on INSERT/BLOCK and we don't patch the vendored lib — so the JSON rides a **reserved-tag `LIBRECAD$DYN` ATTDEF (block) + ATTRIB (insert)** that the bridge filters out on read (verified leak-proof in-app at the single C-boundary chokepoint; coexists with real user attributes — pinned by a regression test). The load-bearing **EntityID↔member-INDEX remap** (reader mints fresh ids; references persist by index) is unit-tested across renumbering. C-ABI string lifetimes safe. **KNOWN interop wart:** other CAD apps show the hidden `LIBRECAD$DYN` attribute on dynamic inserts — acceptable for a personal fork, reversible behind the same `dynamicJSON` ABI (swap to XDATA + a ~3-line libdxfrw emit if interop ever matters).
- **Rotate-knob keeps its edge (task #18)** `3fb70382d` (+2): after a rotate, the gizmo rotate-knob "reset to the top" because `OrientedBounds` folded the angle to mod-π/2 and swapped width↔height at 45° (the knob's anchored edge re-labeled). Fix: report the LONG axis as primary, normalized to mod-π `(−π/2, π/2]`, so a rotated rectangle's orientation (hence the knob) is continuous through a full 0–180° turn. Hug invariant preserved; square/circle/degenerate stay upright (direction-free by geometry — owner-accepted; the durable session/persisted options were costed + deferred as not worth the invalidation/round-trip cost for a cosmetic knob). Single consumer (`gizmoOrientation`); self-contained value-type change. _The root limit: a baked rectangle has no stored "up", so only a STORED orientation (session-cache or XDATA) could hold a true square's knob — deferred._
- **Oriented RESTING gizmo (task #17)** `44d19016d` (+33, review APPROVE-WITH-NITS [doc-only]): the idle gizmo was reverting to an axis-aligned box after a rotate (task #13 only oriented the active drag). Owner chose the GENERAL fix: new pure `OrientedBounds.minAreaRect` (convex hull + per-hull-edge min-area scan) recovers a rotated rectangle/line/polyline's angle from geometry (survives reselect/reopen); single insert/text/mtext/ellipse/image/linear-dim use their STORED intrinsic angle (read-only switch, no EntityKind case); multi-select/square/circle/degenerate → upright. `CanvasModel.gizmoOrientation` + `gizmoOrientedBaseFrame` (extents in the rotated basis) additive; GizmoOverlay draws the oriented resting quad + oriented hit-testing (pointInConvexQuad) via additive point-based cornerScale/rotate overloads. Idle-when-0 byte-identical; GizmoFrame.min/max + selectionWorldBounds/AABB untouched; AppKit-only. (NIT deferred: a normalize-band doc-comment says (−π/2,π/2] but is [−π/4,π/4].)
- **Visible resize/rotate gizmo (task #13)** `9b4bdb9d5` (+6, review APPROVE): the selection frame now rotates+scales WITH the object during a drag. Root cause: `previewFrame` transformed the 4 corners then collapsed them back to an AABB (dropping rotation). Fix: draw the frame as a transformed QUAD from `model.gizmoPreviewTransform` × the mouse-down base (the SAME `Affine2D` the object preview uses → can't drift); corner squares + rotate stalk track the oriented quad (self-correcting knob normal, 360°). Pure `transformedQuad`/`transformedKnobAnchor` helpers unit-tested; `GizmoFrame` stored shape untouched (DynamicGripOverlay clone safe); AppKit overlay only (no Metal/CanvasModel touch).

**`.app` rebuilt for GUI verification:** dynamic block save→reopen (+ confirm no stray attribute in-app), constructive snaps firing, and the gizmo frame rotating/scaling with the object. **Remaining architecture-review backlog (not requested):** R1 CanvasModel decomposition (owner deferred — keep it big), R3 geometry cache, R5/R6 modelVersion/encapsulation, R7 viewport plot, R8 library-target/symlinks, R9 Core-Text flake, + the R10 `.distanceAlong` + R4b $LC_SNAPMODE-over-DXF follow-ups.

---

## 2026-06-16 — UI-redesign §6 BACKLOG shipped (8 items, phased parallel) (`native-macos @ 3bd268100`, **2614 tests**, `.app` rebuilt)

**Owner:** "do the backlog, parallel." Ran the `backlog-wave-plan` workflow (5 investigators → synthesis → disjointness critic, APPROVE-WITH-FIXES) → `macos/docs/backlog-wave-plan.md`. Executed engine/state-first then region-partitioned parallel UI waves (every file single-owner per phase; merge by hash; serial gate each). Critic fixes applied: W4 polar-canvas-hook made explicit; W3 folded into W1 (App+toolbar one owner) to kill a cross-wave compile dep; reduced scopes (POLAR fixed 15°/ortho-exclusive/no tracking-ray, ~12 generated symbols, Page-Setup editor deferred).

**Phase 0 (engine/state, UNWIRED), all reviewed/merged:**
- P0-A `ca1df5c6f` — `CoordinateDisplayMode{absolute,relative,polar}` + engine angle/polar formatter (#5).
- P0-B `0d8704750` — pure `PolarConstraint` kernel (cloned from ortho; no SnapKind case) (#7).
- P0-C `b53efc8e8` — 12 generated DXF starter symbols (`macos/assets/symbols/`) + `CADBench gen-symbols` generator + `BlockLibrary.bundledSymbolsDirectory()` + make-app copy (#6).
- P0-E `b520796b7` — `CADDrawing.duplicateLayout`/`setLayoutPage` (undoable; re-tags entities; no EntityKind) (#4c).
- P0-D `68f6aa161` (after A/B/E; reviewed APPROVE) — `CanvasModel` arms: coord-mode + `cycleCoordinateDisplayMode` (cursorReadout switch, absolute byte-identical), `polarEnabled`/`togglePolar`/`polarConstrained` (ortho/polar mutually exclusive), layout wrappers w/ active-tab fixup.

**Phase 1 (parallel UI wire-waves), all reviewed/merged:**
- W2 `fc0e73a83` — status-bar OSNAP+POLAR chips, coord click-to-cycle (a11y), Snap&Grid gear popover, doc-unit segment (#3,#5,#7,#4a).
- W4 `242b72bfb` (reviewed REVISE→fixed) — UCS axis L-gizmo overlay (click-through), POLAR canvas hook at both input sites, F7 grid responder. **Fixed a ⇧-hijack:** polar applies only when `polarEnabled && !shiftHeld` (SHIFT forces ortho); `contextToggleGrid`→`model.toggleGrid()` for live chip refresh (#4b,#7,#8).
- W5 `7365a454c` — Parts Library shows the 12 bundled symbols on first launch ("Built-in") + Finder .dxf drop + exported drag UTI (#6).
- W1 `3bd268100` (reviewed APPROVE) — Draw toolbar flyouts (Line▸{XLine,Ray}, Rect▸{Polygon}, Circle/Arc construction-mode flyouts; no new kind), Match Properties eyedropper toolbar button + ⌘⇧C/⌘⇧V chords, layout-tab context menu (Rename sheet/Duplicate/Page-Setup stub/Delete), removed the canvas "New drawing (mm)" label, View▸Show-Grid+F7 menu, canvas `.dropDestination` for parts (#1,#2,#4a,#4c,#6,#8).

**Deferred (noted):** per-layout Page Setup editor (engine `setLayoutPage` ready; menu stubs to Document Settings) · POLAR configurable increments + on-screen tracking ray · engine `duplicateLayout` returning the new name (wrapper replicates the naming rule — lockstep comment + test). **`.app` rebuilt for GUI verification** — toolbar flyouts (hold to open), Match-Props chords, OSNAP/POLAR chips + the 15° polar lock, UCS gizmo, F7, the Built-in symbol library + drag-to-canvas. **Next:** owner-requested whole-system architecture review.

---

## 2026-06-16 — UI REDESIGN ("seamless & beautiful") shipped end-to-end + move/scale dashed guide (`native-macos @ 30b4903f2`, **2527 tests**, `.app` rebuilt)

**Owner:** "make the color picker smaller" + "analyze the UI and create a plan to make it seamless & beautiful (modern macOS + AutoCAD)." Ran an 11-agent design workflow (5 source readers → 4 critique lenses [HIG/CAD/tokens/interaction] → synthesis → hardening audit) → `macos/docs/ui-redesign-plan.md`. A 2nd independent review (owner-supplied) corroborated the conclusions; its new ideas folded into the plan §6 (drawing-level inspector empty state taken now; flyouts/Match-Properties-as-command/canvas-chrome/starter-library backlogged). Owner chose: keep the two-tone (intentional) · drop the bottom chip mirror · demote layer printer/construction flags · build Waves 1–4.

**Landed (all code-reviewed; merged by hash; serial-gated):**
- **P0 ColorSwatch** `8c9d53c42` — `NSColorWell` pill (ignores `.frame(width:)`) → reusable 16pt `ColorSwatchPicker` (popover-hosted system picker) at the 2 dense sites (layer rows + current-properties bar); computed binding kills the `.green` flash; inspector Form wells intentionally kept.
- **Wave 1 Foundation** `25748c99c` — `DesignTokens.swift` (`enum DS`: Space/Radius/Size/Field/Font/Palette + `.barStrip()`), the single source of truth all regions now reference; + reusable `SidebarEmptyState`.
- **Wave 2 Sidebar** `52b1b5e34` — name-first layer rows (printer/construction → context menu; name no longer truncates), `LinetypePreview`/`LineweightPreview` (new `PenPreviews.swift`), Parts-Library truncation fix, unified empty states, token sweep. + **SidebarPolish** `0b813112a` (review S1): zero-visible-panel floor in `reconciled` so a persisted all-hidden config can't orphan the Customize menu.
- **Wave 4 Bottom chrome** `a01ea4ad4` — real command line (CommandBar de-mirror; tool chips only on type, labeled Recent), clickable GRID/SNAP/ORTHO status toggles wired to existing flags + a redraw closure, command-hint de-dup, LayoutTabStrip hidden until a paper-space layout exists, token/barStrip sweep. (POLAR/OSNAP status chips deferred — need new engine state; F7 key-equivalent unwired.)
- **Wave 3 Inspector + properties bar** `b5fdc17b9` — empty inspector → **drawing-level properties** (Units/Scale[$DIMSCALE]/Entities/Layers/Extents via pure `DrawingSummary`), the **"Spaci ng"** grid-spacing wrap fixed + systemic `.lineLimit(1)`, field-width tokens, 2-col snap grid, **"Match Properties"** (was Property Painter), 3 disambiguated pen controls (swatch/dash/weight previews + captions). + **SnapMaster** `c026c9683` (review SHOULD-FIX): the inspector object-snap master toggle was inert (flipped the always-on `.free` bit the pipeline never gates on) → now a real master (`CanvasModel.objectSnapEnabled`/`setObjectSnapEnabled`: off = stash+clear positive osnap bits, on = restore; `Snapping.snap` already returns free with no positive bits). Relabeled "Object Snap" (F3).

**Move/Scale dashed reference line** `30b4903f2` (owner request — "see the object being moved/scaled + a dashed line back to where we started"): the live transformed ghost ALREADY existed (MoveTool/ScaleTool `preview`); net-new was the dashed guide — new append-only `Tool.referenceSegments` (default `[]`), Move → base→cursor, Scale → center→original-reference (stored `refPoint` in `pickingTarget`); drawn via new `OverlayGeometry.dashedSegments` (screen-fixed 5pt/3pt, dim `referenceColor`) packed LAST in the overlay buffer (storage==draw order). Flat overlay pipeline only — `LineInstance` byte-match untouched; exports unaffected. Reviewed APPROVE.

**Open backlog (plan §6, not built):** toolbar flyouts for tool variants (kills `>>`), Match-Properties→toolbar+⌘⇧C/⌘⇧V, Snap&Grid→status popover, canvas chrome (relocate "New drawing (mm)", tab context menu, UCS axis), coordinate click-to-toggle abs/rel/polar, starter symbol library, POLAR/OSNAP status chips (need engine state), F7 grid key. **`.app` rebuilt for owner GUI-verification** — esp. the status toggles repaint instantly, and the move/scale dashed guide (GPU not headless-testable).

---

## 2026-06-16 — LINE WIDTH + STYLE in two places (per-layer defaults + top-bar current props) + dashes now RENDER (`native-macos @ 2b973eb55`, **2445 tests**, `.app` rebuilt)

**Owner:** "add line width and style settings to 2 places: (1) default layer line (AutoCAD's way) and (2) the top bar when actually drawing." Investigation (PenPropsInvestigate) found a gating prerequisite — **linetype/dashes did NOT render at all** (both the Metal canvas and the CG export discarded `pen.lineType`, always stroking solid; same bug class as the just-fixed line-width-not-rendering issue) — plus a latent bug: **drawn entities always landed on layer "0"** regardless of the active layer (no current-pen/active-layer stamp existed). Built as two disjoint parallel waves, both reviewed:

- **DashRender** `5f45395db` (+19, review APPROVE-WITH-NITS — `LineInstance` byte-match independently re-derived as stride 48/align 16, MSL byte-identical): linetype dashes now render. **CG export** (`CGSceneRenderer.drawPolyline`): `setLineDash` from a pure, unit-tested `dashLengths(for:scale:strokeWorld:)` — full multi-element compound patterns (dashDot/center/border/divide) in PDF/PNG/Print, world-unit (fixed paper size). **Metal canvas**: +3 trailing floats on `LineInstance` (fill the struct's existing 12-byte trailing padding → **stride stays 48, byte-match preserved**, pinned by a `MemoryLayout` contract test); `appendInstances` packs `(dashPeriodPx, dashOnPx, startOffsetWorld)` screen-space/**fixed-on-zoom** with arc-length continuity across segment joins (sound under the project's isotropic viewport); `line_fragment` discards OFF gaps; **solid path unchanged** (`dashPeriodPx==0`). v1 cut: on-screen compound styles render as a single dash+gap rhythm (CG export is exact) — documented, fast-follow possible via a per-instance pattern index.
- **PenPropsUI** `4e3a84d43` (+12, review APPROVE-WITH-NITS): **`CanvasModel.currentPen`** (the CECOLOR/CELTYPE/CELWEIGHT trio, ByLayer default); `applyCommit`'s `.add` arm **stamps freshly-drawn records** (init-default layer/pen) with the active layer + currentPen — **fixes the layer-0 bug**. **Per-layer controls**: each `LayerRow` gained a compact linetype + width menu → `mutateLayers{setLineType/setLineWidth}` + `syncRenderAfterLayerEdit` (undoable). **Top bar**: new persistent `CurrentPropertiesBar` (a `safeAreaInset` above the contextual `ToolOptionsBar`) — active-layer picker + pen color/type/width bound to `currentPen`; new geometry adopts it. Reusable `PenPickers` (LineType/LineWidth pickers, shared by both surfaces).

**Both render paths read the RESOLVED pen** (`Pen.resolved(layer:in:)`), so per-layer linetype/width defaults flow through ByLayer.

**— CloneStampFix LANDED** `55900a7ca` (+3, **2448 tests**, review APPROVE — classification completeness verified across all 56 `ToolKind` cases): the prior stamp gate keyed off record CONTENTS, so a **clone** (Copy/Array/Offset) of a source on layer "0" with a ByLayer pen was wrongly re-stamped onto the active layer (AutoCAD's COPY preserves source layer). Fixed by threading an explicit `adoptsCurrentProperties: Bool` into `applyCommit` (no default → a missed call site is a compile error) classified app-side from the originating `ToolKind` (new `deriveToolKinds` set + `toolAdoptsCurrentProperties`), AND-ed with the content sub-gate. Draw tools adopt current props; the Copy/Array/ArrayPath/Offset/Divide/Explode*/Join/Break/Chamfer/Fillet/Hatch derive family preserves source pen/layer. App-module only (no engine `Tool`/`ToolEdit` flag). **The line-width+style feature is complete + correct.**

---

## 2026-06-16 — Left sidebar → REARRANGEABLE panel stack + block-parity audit (`native-macos @ 36ebbe51c`, **2290 tests**, `.app` rebuilt)

**Owner:** the 3 stacked sidebar sections + bottom-pinned ＋/− were clunky; "rethink it, ergonomic + modern macOS." Chose **#1: reorderable + collapsible + show/hide panels** (over full floating docks — less macOS-idiomatic). LANDED `36ebbe51c` (+16): `SidebarPanelStack` renders `SidebarPanel` descriptors as collapsible disclosure sections, each with controls in its OWN header (Layers ＋/− [gated name!="0" && count>1] + ⋯ freeze/lock-all; Layer States ＋; Blocks ＋ Create-Block via closure→ContentView's `BlockNamePrompt`). Drag-to-reorder (`.onMove`), show/hide via ⋯ Customize, order/collapsed/hidden persisted in one `@AppStorage` `SidebarLayoutConfig` JSON. **Extensible** — a new panel = one `SidebarPanelID` case + descriptor (Parts Library/Attributes drop in later). All prior behavior preserved (toggles/color/rename/active/layer-states/block thumbnail+edit+drag/context-menus/render-sync + selectedLayer↔active mirror). Reviewed APPROVE-WITH-NITS. **Follow-up (NIT1):** layer-list keyboard arrow-nav lost (nested `List(selection:)` can't nest) → restore via a single-`List`-with-movable-Sections restructure.

**Block parity audit (owner: "do we support everything from LibreCAD?"):** the block ENGINE is **at or BEYOND upstream LibreCAD**. We EXCEED it where upstream has nothing: **dynamic blocks** (visibility/stretch/flip), **real ATTDEF/ATTRIB** DXF round-trip (upstream's "Block Attributes" is just a rename dialog — no attribute entities), **block thumbnails**. Remaining gaps are UI-surfacing of built engine capability (prioritized):
1. **Insert options** — scale/rotation/MINSERT array (engine `InsertTool` + DXF round-trip done; UI throws them away → every insert 1×). S, UI-only.
2. **Per-block freeze/visibility toggle** in the sidebar (`isFrozen` honored at resolve; need a `CADDrawing.setBlockFrozen` op + an eye toggle). S.
3. **Block attribute authoring + value-edit UI** (EATTEDIT) — data+DXF done; no UI. M (biggest net-new).
4. **WBLOCK** — save a block/selection to `.dxf` (absent on BOTH sides — we can import a block but not export). M.
5. **Parts Library panel + "Insert Block from File"** — `BlockLibrary` engine built but unwired; slots into the new sidebar framework. M.
Minors: base-point marker render, block list search, insert-time cyclic-insert guard. **NEXT:** engine wave (WBLOCK + block-freeze ops, UNWIRED) → UI wire-wave (insert-options + freeze-toggle + Parts Library panel + WBLOCK/from-file menus); attribute UI after.

**— BLOCK-PARITY WAVES LANDED** (`native-macos @ 6a1270e3b`, **2339 tests**, `.app` rebuilt; all code-reviewed APPROVE):
- Engine (UNWIRED): **WBLOCK** `BlockExport.writeBlock/writeRecords` (`29ad8267a`, re-based to origin, nested inserts emitted) + **block freeze/visibility ops** `CADDrawing.setBlockFrozen/toggleBlockFrozen/freezeAll/thawAll` (`2bca8bfc8`, undoable; resolve hides frozen).
- UI wave A (`20728b9c1`): **insert scale/rotation/MINSERT array** options in the tool-options bar (config flows onto `InsertTool`, survives chained placement) + **per-block eye/freeze toggle** + Freeze-All/Thaw-All.
- UI wave B (`49e8216`): **Insert Block from File** + **Save Block to File (WBLOCK)** menus (View-layer panels → `BlockLibrary.importDXF`/`BlockExport.writeBlock`); freeze menu moved to the Blocks panel header; **Parts Library panel** (new `SidebarPanelID.partsLibrary` in the rearrangeable framework — choose folder → scan `.dxf` → click/drag to place; last folder persisted).
**LibreCAD block-dock parity reached at the UI level.** Remaining block items (for owner to prioritize): **block-attribute editing UI (EATTEDIT)** — M, the biggest, engine round-trip done; Parts Library per-file thumbnails; the canvas DROP handler for `PartLibraryDragItem` + its Info.plist UTI (small canvas wave); sidebar keyboard arrow-nav (single-`List` restructure); minors (base-point marker, block-list search, insert-time cyclic guard).

---

## 2026-06-16 — BLOCK-EDITING FLOW rebuilt (owner: "editing a block doesn't edit it; open in a tab") (`native-macos @ 128f7c7f2`, **2274 tests**, `.app` rebuilt)

Owner reported the in-place Block Editor was wrong: (1) drawing in it added LOOSE document objects instead of block members ("editing a block doesn't change the block"); (2) it replaced the document view instead of opening a TAB. Owner directed: **plan the whole flow first** (don't point-fix). Did: full-flow design (`block-edit-flow-plan.md`) → **critic GO-WITH-FIXES** (caught: `applyCommit` mints+discards the new id so the add-to-block needs an explicit seam; tab "active" coupled to `activeSpace`; tab-switch doesn't auto-finish; paste/delete are separate funnels; a small engine helper is required) → owner decisions (auto Save&Close on switch · **support nested now** · per-edit undo · base-point marker deferred) → built in 3 staged commits.

**Landed** (`128f7c7f2`; two review rounds each found + drove a fix):
- **Correctness:** new undoable `CADDrawing.addEntityToBlock`/`removeEntityFromBlock`; `applyCommit` `.add` + `paste(records:)` thread the minted id INTO the editing block (same undo group, before the `modelVersion` bump); `.remove` drops it. Drawing/pasting/deleting in the editor now mutates the BLOCK — no loose document objects, all inserts update live, Discard reverts added members. **This is the owner's #1 fix.**
- **Tab UX:** the editor is a distinct "✎ <Block>" tab in `LayoutTabStrip` (Model/Layout `isActive` gated on `editingBlock == nil` → exactly one active tab; document tabs intact); `activate*` call `finishBlockEditingIfNeeded()` so switching auto-Saves&Closes and the tab pick sticks.
- **Nested editing:** single `editingBlock` → a `BlockEditSession` STACK; double-click a nested insert pushes; exit pops; per-level entry snapshot + undo group; cyclic-open rejected; breadcrumb "A ▸ B".
- **Review caught 2 data-loss-class bugs** (both fixed + pinned): Save-inner→Discard-outer reverted inner's saved edits (depth-2); then a depth-≥3 case (Save C→Discard B→Discard A). Final fix = INDUCTIVE `hasSavedNestedWork` propagation on any pop carrying saved subtree work (correct at arbitrary depth; load-bearing-verified by revert→fail→restore). Tests cover depths 1/2/3 × all save/discard combos.

**Known v1 cut:** the block base point is framed but not rendered/editable (deferred). **Acceptance pass on the nested data-loss + `.app` smoke in flight; owner to GUI-verify** (draw-in-block-stays-in-block, tab open, nested drill, Discard).

---

## 2026-06-16 — "Move beyond blocks" wave: block-member-editability FIX + utility tools (`native-macos @ HEAD`, **2221 tests**)

Owner: "blocks should be edited only when OPENED, not loose in the document." Plus owner chose to move beyond blocks → a fresh code-grounded gap audit (catalog is **~entirely stale**: measure/hatch-engine/construction-lines/all-dim-subtypes/image/stretch-break-join-align/polyline-node-edit/advanced-snaps/ortho/multi-select-edit/MTEXT-write are all already DONE). The genuinely-remaining gaps are persistence/fidelity/power-editing follow-ups.

Landed (all reviewed, serial-gated):
- **FIX — block members editable/double-rendered in model space** `b4b02238e` (+11). Root cause (investigator): create-block is correct (removes originals + drops INSERT), but there was NO "is this a block member?" exclusion → members were selectable/marquee/⌘A/snappable AND drawn twice (directly + via the insert). Fix: `CADDrawing.blockMemberIDs` (union of all blocks' `entityIDs`, frozen incl.) excludes members from `CanvasModel.activeSpaceEntities` (→ render/quadtree/marquee/hit-test/snap), the `LineRenderer` model-arm pack guard (kills double-render), and `SelectionPolicy.selectableIDs`/`invertedIDs` (kills ⌘A/Invert). Members stay editable INSIDE the Block Editor (`editingBlock != nil` short-circuits); resolve/inserts/thumbnails/DXF untouched (read `entityIDs` directly). Investigator re-verified the fix matches the recommendation exactly.
- **Hatch pattern picker** `8146b5329` (+13) — the pattern ENGINE was already complete; added `HatchTool.Fill` config (default solid, back-compat) + 20 bundled ANSI/ISO/generic `.pat` patterns (25 total). UNWIRED.
- **Purge + QuickSelect** `ca79c165c` (+32) — pure engine: `Purge.plan` (transitive unused layers/blocks/dim-styles, protects 0/active/Standard) + `Purge.apply` (undoable via removeLayer/removeBlock/**mutateDimStyles** — review SHOULD-FIX applied: the dim-style undo funnel DID exist) + `QuickSelect.matches` (by kind/layer/color/width). UNWIRED.

**NEXT:** wire-wave to surface hatch-pattern picker + Purge + QuickSelect (+ A3 Layer-Isolate / A4 Spline-node-edit, currently HELD) in the UI; QuickSelect should also exclude `blockMemberIDs`. `.app` rebuilt for owner to verify the block-member fix (no doubled lines, members unclickable in the document, editable only via open-in-editor).

---

## 2026-06-16 — DYNAMIC BLOCKS: Stretch + Flip LANDED end-to-end (`native-macos @ b6831f83e`, **2165 tests**, `.app` rebuilt)

Owner picked **Stretch + Flip** as the first DB-2 bite (the two most common dynamic behaviors). Both reviewed APPROVE/-WITH-NITS, fixes folded:
- **DB-2-ENGINE** `2c677a5b3` (+32) — Linear/Flip `BlockParameter` + Stretch/Flip `BlockAction` (additive on `DynamicBlockDef`); `BlockEvaluator` applies them PURE, after the visibility filter, in definition order (flip = mirror via `Affine2D.mirror`; stretch = move members' defining-points inside the frame by the param delta × multiplier, rotated by offset). v1 member-kind cut: line/polyline(bulges)/point/circle/arc(center) + whole-entity bbox fallback. Undoable `CADDrawing` mutators. No `EntityKind` case.
- **DB-2-WIRE** `b6831f83e` (+28; staged-commit retry after a startup stall lost the first attempt) — on a selected dynamic insert (gizmo suppressed): **square stretch grip** (live DRAG → `insertEvaluationPreview` re-resolve → one undoable `parameterValues` commit; **scale-correct** via `directionScale`; **Esc cancels**) + **triangle flip grip** (click → toggle `flipStates`, undoable) + DB-1's visibility dropdown, all coexisting. Block Editor `BlockDynamicParametersPanel` authors Linear-Stretch / Flip (geometry derived from the selection bbox — a documented v1 simplification; richer guided-pick authoring is a fast-follow).

**Dynamic-block status:** the **3 highest-frequency behaviors — visibility states, stretch, flip — are DONE end-to-end** (author in the Block Editor + manipulate per-insert via grips). Remaining per Appendix B (lower-frequency): DB-3 value-sets/lookup, DB-4 polar/XY/array/chain, DB-5 extended (scale/alignment/base-point/multiplier). DXF interop still v1 = native Codable round-trip (AutoCAD `*U##` eval-graph deferred). Milestone checkpoint with owner on whether to go deeper vs. attribute-UI/library-browser (BW2) vs. polish.

---

## 2026-06-16 — DYNAMIC-BLOCK program critic-clean GO + building (visibility states first)

Block UX (asks #1–4) **acceptance GO** (`90633e3d0`/`be4db5e23`): edit-propagation verified (1 member edit → all 3 inserts re-resolve on Save&Close; Discard reverts, undo coherent), ATTRIB DXF round-trip, thumbnails, collision-safe import, `dim_sample.dxf` sane, `.app` smoke clean. GUI-only bits (name sheet, double-click-edit, BlockEditBar, viewport drag, thumbnail render) await owner GUI verification.

Dynamic-block program (`dynamic-blocks-plan.md`) planned → **critic GO-WITH-FIXES, all 6 folded**: dual-overlay arbitration (single dynamic insert → suppress gizmo, show dynamic-grip overlay only); bake export uses a **regular non-`*` name** (`<Block>_eval_<n>`) so `DXFWriter.swift:263`'s `*`-skip doesn't drop it; `evaluate` purity contract + isolation tests; DB-0 = one solo engine agent; `parameterValues: [String: Double]` keyed by `BlockParameterID.raw`.

**Architecture (no `EntityKind` case):** `Block.dynamic: DynamicBlockDef?` + `InsertData.dynamic: InsertDynamicState?` (both additive, `decodeIfPresent`); union enums in NEW files; a pure `BlockEvaluator.evaluate(def, members, instanceState) -> [EntityRecord]` threaded into `resolveInsert` (returns the same shape → MINSERT/recursion-guard/byBlock/ATTRIB unchanged); dynamic grips clone `GizmoTransform`/`GizmoOverlayView`.

**Owner sign-off items — adopted best-guess (owner said "keep going"; reversible):** (1) **DB-1 = visibility states FIRST** (cheapest, self-contained, click-dropdown grip — de-risks the instance-aware-resolve seam before the live-drag layer); (2) v1 grip scope = Point/Linear/Rotation/Flip + Visibility; (3) v1 DXF export = **bake to static** (regular name) — native Codable round-trip is lossless; AutoCAD `*U##`/eval-graph DXF interop is a deferred subproject.

**NUMBERING RECONCILIATION:** the authoritative order is now `dynamic-blocks-plan.md`'s — **DB-1 visibility · DB-2 params/actions/grips · DB-3 value-sets/lookup · DB-4 polar/XY/array/chain · DB-5 extended** (this supersedes `block-ux-plan.md` §7's earlier DB-1=params labeling). Building **DB-VIS-ENGINE** now (DB-0 data model + DB-1 evaluator + visibility resolve, combined, UNWIRED), then DB-VIS-WIRE (state authoring in the Block Editor + instance dropdown).

**— DB-1 VISIBILITY STATES LANDED end-to-end** (`native-macos @ dd86c2476`, **2105 tests**, `.app` rebuilt). Both code-reviewed APPROVE/-WITH-NITS:
- **DB-VIS-ENGINE** `f562a9b79` (+20) — `Block.dynamic`/`InsertData.dynamic` additive (back-compat), pure `BlockEvaluator.evaluate` threaded into `resolveInsert` (MINSERT/recursion/byBlock/ATTRIB byte-for-byte unchanged), undoable `CADDrawing` mutators. Purity/isolation tests per the critic. No `EntityKind` case.
- **DB-VIS-WIRE** `dd86c2476` (+16) — Block Editor **Visibility States panel** (add/rename/delete, set-current, show/hide selected members per state) + on-canvas **dropdown grip** (`DynamicGripOverlay`, cloned from `GizmoOverlay`; **gizmo suppressed for a single dynamic insert** via the pure `shouldSuppressGizmoForSelection`) + Inspector picker → switches an insert's variant (undoable `applyInspectorEdits`). Reviewer verified no modal-in-test + no double-input overlay state.
First concrete dynamic block: e.g. one valve block with Gate/Ball/Check variants switched per-insert. **NEXT: DB-2** (parameters/actions + live-drag grips — the large phase) — coordinator to checkpoint scope with owner before committing the fleet.

---

## 2026-06-16 — BLOCK UX + paper-space WIRE-WAVES LANDED + owner's AutoCAD spec adopted (`native-macos @ 90633e3d0`, **2069 tests**)

Owner feedback: "blocks don't work as well as AutoCAD — convert selection→block, edit a block + reinsert, and show the block as visual content (a text name is hard to see)"; then authored `macos/docs/block-features.md` (1798-line AutoCAD-LT block spec w/ an Appendix-B P0–P7 matrix) — now the authoritative reference; `block-ux-plan.md` aligned to it. Owner decisions (AskUserQuestion): Create-Block uses a **name sheet**; dynamic blocks = **full authoring** (params/actions/grips), sequenced DB-1..DB-5 per Appendix B (P6 constraints/BTABLE deferred = full-AutoCAD-only).

Landed this push (all code-reviewed, serial-gated):
- **Block thumbnails** `4e509fe78` (+8) — sidebar rows render each block's actual geometry (engine-pure `blockThumbnailScene` block-subset `ExportScene` → bitmap `NSImage` via shared `CGSceneRenderer`, `(name,modelVersion,size)` cache auto-invalidated on edit). Directly answers "hard to see what it is." (Review nits: inert min-stroke param, stale-tile prune, test name — non-blocking follow-ups.)
- **WIRE-WAVE 1** `1a113aaf6` (+17) — paper-space made usable in the GUI: **⌥V viewport tool** (2-click → `addViewport` on active layout, paper-space only), **Export Layout PDF (⌥⌘E) / Print Layout (⇧⌘P)** menus (panels View-layer only), **Circle 2P/3P · Arc tangential · Line by-angle** mode pickers in the options bar. *(Salvaged: built on a stale base; a 3-way `--no-ff` merge preserved the interim block suites — verified 2056 incl. BlockAttributeTests.)*
- **Block UI wire-wave (BW)** `90633e3d0` (+13) — the owner's top 3: **Create Block from Selection** (right-click verb gated on selection + Blocks menu ⌥B + ⌘K → **name sheet** prefilled `Block-N`, existing-name→redefine warning per spec §20 → base-point pick), **double-click an insert / sidebar "Edit"** → in-place **Block Editor** with a **BlockEditBar** (Save & Close updates ALL references via live-member resolve / Discard reverts; document-close auto-saves via `ContentView.onDisappear`), and **reinsert** (sidebar primary + now-functional `InsertTool` via `beginInsert(name:)`). No new `EntityKind`/`ToolKind` case. Reviewer APPROVE; the close-hook is best-effort (edits land live in `CADDrawing` immediately, so no data-loss path).

**Block status vs spec Appendix B:** P0 (foundation) + P1 (editor/attributes/nested/explode) DONE incl. UI; thumbnails + library/import DONE (engine; library browser UI = BW2). **Acceptance pass in flight** (block create/edit-propagation/reinsert/attributes round-trip + `.app` smoke).

**NEXT:** BW2 (attributes UI — EATTEDIT double-click value editor + ATTSYNC + prompt-on-insert; library browser gallery + WBLOCK; additive `Block` metadata: description/unit/flags) → then the **dynamic-block authoring program** DB-1 (params/actions/grips) → DB-2 (visibility states) → DB-3 (value-sets/lookup) → DB-4 (polar/XY/array/chain) → DB-5 (extended). GUI-only interactions (name sheet, double-click-edit, BlockEditBar, viewport drag) need owner verification in the rebuilt `.app`.

---

## 2026-06-15 — PAPER SPACE P3/P4 WAVE dispatched (owner: "find the gaps, parallel-implement next steps, commit + merge worktrees")

**Baseline at start:** `native-macos @ 5291ae797`, **1887 tests** green, build clean, tree clean. Gap audit (this session): paper space P0 (model) + P1 (DXF code-67 r/w, single Layout1) + P2 (Model/Layout tab + sheet render, pure helpers) are LANDED; **P3 (viewport entities) + P4 (per-layout plot) remain**, and P1/P2 (salvaged "tests follow") had **zero dedicated tests**.

**Gating (read-only, parallel):** planner (P3 deep design), investigator (exact P1/P2/bridge state + missing-test map), critic (wave disjointness). Critic verdict **GO-WITH-FIXES** — all folded in:
- `LineRenderer.swift` is in the APP module (`LibreCADmacOS/Renderer/`) and is dual-compiled into the test target via `_SharedLineRenderer.swift` → Agent 1 keeps it test-target-clean; **merge Agent 1 before the test-backfill agent**.
- The render-transform name `Viewport` is taken → the new paper-space entity is **`LayoutViewport`** (off `EntityKind`, in `Layout.viewports`); don't touch `Viewport.swift` or its 3 tests.
- Agent 4 rescoped: ArcTool `.threePoint` is ALREADY DONE → tangential-only; Circle 2P/3P genuinely new.

**Confirmed bug (investigator):** `LibreCADDocument.swift:~282` `DXFDocumentCodec.payload(from:)` drops `result.layouts` → opened paper-space DXFs show **zero layout tabs + invisible paper entities**. One-line fix folded into Agent 1 (paper-space read-path owner).

**Owner decisions (away, best-guess):** **Q1** stock libdxfrw HAS `dxfRW::writeViewport` (`libdxfrw.cpp:1552`) → P3 does FULL VIEWPORT read+write round-trip (no lib patch); writer takes layouts via an ADDITIVE/defaulted param (zero blast on other call sites). **Q2** v1 viewport contents are draw-only (not snap/select-through-the-sheet). **Q3** `ViewportTool` is a standalone 2-click value type (no `ToolEdit` contract change). All built UNWIRED (a later wire-wave surfaces them).

**Wave (4 concurrent builders, disjoint worktrees off `native-macos`):**
- **A1 — P3 viewports**: `Layout.swift`, new `LayoutViewport.swift`, `CADDrawing.swift`, `DXFReader/Writer.swift`, new `Tools/ViewportTool.swift`, `DxfBridge/lcdxf.{cpp,h}`, `Renderer/LineRenderer.swift`, `LibreCADDocument.swift`, new `LayoutViewportTests.swift`.
- **A2 — P4 plot**: `Export/{PrintLayout,DrawingPrinter,DrawingExporter}.swift` + new `LayoutPlotTests.swift` (pure math, no NSPrintOperation).
- **A3 — P1/P2 test backfill**: new `PaperSpaceDXFRoundTripTests.swift` + `PaperSpaceLayoutHelperTests.swift` (read-only on source; pure `PaperSpaceLayout` helpers via existing `_SharedCanvasModel` symlink).
- **A4 — draw variants**: `Tools/{CircleTool,ArcTool,LineTool}.swift` (Circle 2P/3P, Arc tangential, Line by-angle) + tests, additive Mode enums, UNWIRED.

**Merge order:** A4 → A2 → A1 → A3, batch-merge by hash + ONE serial-gate. Then code-reviewer per non-trivial diff, acceptance-tester, then a wire-wave to surface viewports/plot/variants.

**— LANDED** (`native-macos @ 135346d72`, **1989 tests** green, build clean, 4 worktrees pruned). All 4 reviewed (A2/A4/A1 APPROVE-WITH-NITS; A3 tests-only). Merged commits:
- **A4 variants** `ec06a4328` (+34) — `CircleConstructionMode{.centerRadius/.twoPoint/.threePoint}` (circumcircle via perpendicular-bisector determinant), `ArcCreationMode.tangential` (start-tangent-to-pick, through end), `LineAngleMode{.free/.absolute/.relative}`. Additive, UNWIRED. Reviewer numerically verified the tangential-arc sense.
- **A2 P4 plot** `994b1242e` (+21) — per-layout sheet-accurate PDF/print at plot scale; engine`PageDescriptor`/`LayoutPlotScale`→app`PrintLayout` converters; pure `layoutPDFData`/`makeLayout(for:)` (panel-free, test-reachable). UNWIRED. Review SHOULD-FIX applied (print job binds the LAYOUT's sheet, not the printer default). *Known cut:* the sheet plots 1:1 for a fixed `.ratio`; scaling model-behind-a-viewport at resolve time is a follow-up.
- **A1 P3 viewports** `449a33f52` (+27) — `LayoutViewport`(paperRect/viewCenter/viewHeight, off `EntityKind`, in `Layout.viewports`); pure child-camera/affine/Cohen–Sutherland-clip math; `CADDrawing.add/remove/updateViewport` via `mutateLayouts` (undoable); DXF read+write round-trip via new `LC_ENT_VIEWPORT` bridge POD + **two 1-line vendored libdxfrw patches** (code-45 `viewHeight` write in `dxfRW::writeViewport` + parse in `DRW_Viewport::parseCode`; reviewer confirmed minimal/scoped/no-regression) + a 3rd polish patch (`DRW_Viewport()` ctor inits `viewHeight` for foreign DXFs); clipped viewport-content render pass; `ViewportTool` 2-click value type (UNWIRED). **Also fixed a real bug:** `LibreCADDocument` was dropping `result.layouts` on DXF open → opened paper-space DXFs now show their layout tabs + paper entities; Save now persists layouts+viewports to disk.
- **A3 P1/P2 test backfill** `be2367a7c` (+20) — live DXF/DWG code-67 round-trip + single-Layout1 reconstruction + pure `PaperSpaceLayout` helpers (filter/sheetRect/marginRect) + CanvasModel space-switching. Documented 3 real losses with flip-when-fixed asserts: per-entity `layoutName` not reattached (needs LAYOUT-dict patch), PLOTSETTINGS margin/size not written, DWG drops paper space entirely.
- **polish** `135346d72` — libdxfrw ctor init + comment fix + `block-editing-plan.md`.

**Infra note:** A4 (variants) died once on an infra socket error very early (only a partial untested `CircleTool` edit) → discarded the worktree + re-dispatched fresh (`16c62e50f`), which landed clean. A1 ran ~14 min (the wave's long pole).

**REMAINING follow-ups (paper space):** wire-wave (surface `ViewportTool` + the plot menu + the new draw-tool variant modes in `ToolKind`/`ToolOptionsBar`/`CommandPalette`); the 3 documented DXF losses (LAYOUT-dict + PLOTSETTINGS write = multi-layout fidelity); viewport-content plot scaling; per-viewport render cull (perf). Tracked.

---

## 2026-06-16 — BLOCK EDITING project APPROVED (owner: "AutoCAD opens & edits blocks well — essential") → full scope

**Owner answers (AskUserQuestion):** scope = **Everything (Block Editor MVP + attributes ATTDEF/ATTRIB + parts library/import)**; save model = **Save & Close + Discard** (BCLOSE-style; a whole edit session is one undoable step).

**Design (planner `block-editing-plan.md` + investigator):** the keystone is DONE — `EntityKind.insert`, `CreateBlockTool`/`ExplodeInsertTool`/`InsertTool`, and a LIVE blocks sidebar all exist + are wired (the catalog "stub" rows are STALE). **Crux confirmed:** block members are SHARED — a `Block` holds `entityIDs` into `CADDrawing.entities`, and `resolve(.insert)` looks the block up by name + transforms the live members each resolve → **editing a member instantly updates every insert; the edit IS the save-back** (no per-insert copy). So the Block Editor = a transient edit SCOPE reusing the proven paper-space active-space machinery (`CanvasModel.setActiveSpace`-style enter/re-frame/re-index/exit) + the existing undoable `applyCommit`/`mutateBlocks` funnels. Genuinely missing: in-place editor, ATTDEF/ATTRIB (not read/written; model as an additive `InsertData` field + `Block` attr-defs, **no new `EntityKind` case**), DWG block-member round-trip (intentionally lossy), and a parts library/import.

**Planned wave (block project is mostly serial on hot files — fan out only the disjoint engine halves, then a wire-wave):**
- **B0 editor scope (engine)** — `CanvasModel.swift` + `CADDrawing.swift` (`editingBlock` scope, enter/Save&Close/Discard snapshot, `setBlockMembers` convenience). SOLO hot.
- **B-ATTR attributes (engine)** — `Entity.swift` (additive `InsertData` attributes field, NOT a new EntityKind case), `Block.swift` (attr-defs), `Resolve.swift` (render ATTRIB text), `lcdxf.{cpp,h}` + `DXFReader/Writer.swift` (ATTDEF/ATTRIB round-trip). Disjoint from B0.
- **B-LIB library (engine)** — new `BlockLibrary.swift` + import-block-from-`.dxf` (reuse existing `readEntities` + `makeBlockFromEntities`). New files only.
- **B-WIRE wire-wave** — `ContentView`/`CADCanvasView`/`BlocksSidebar`/`ToolKind` etc.: BlockEditBar + double-click-insert-to-edit + sidebar "Edit", attribute display/edit UI, library browser panel. After the 3 engine waves merge.
Critic-gating the disjointness before dispatch; launches as the paper-space hot files are now free.

**Critic verdict GO-WITH-FIXES — folded in:** B-ATTR's DXF work needs VENDORED libdxfrw patches (there is NO `addAttrib` callback — ATTRIB rides in `DRW_Insert.attlist`, which stock libdxfrw neither parses nor writes); attributes modeled as ADDITIVE `InsertData`/`Block` fields (NO new `EntityKind` case) with back-compat `decodeIfPresent`; B0 Discard must drop the net-identity undo group; B-LIB import must always route `makeBlockFromEntities`/`newName` (no in-place overwrite → data loss); `setBlockMembers` on `CADDrawing` not `Block.swift`. (`DxfBridge/libdxfrw` is a symlink → the real files are `libraries/libdxfrw/src/`.)

**— ENGINE WAVES LANDED** (`native-macos @ fb622c5ea`, **2031 tests** green; 3 worktrees pruned; each code-reviewed APPROVE/APPROVE-WITH-NITS, fixes applied):
- **B-LIB** `f3fd50067` (+14) — engine-pure `BlockLibrary` (`BlockLibraryItem`/`scan(directory:)`) + import-block-from-`.dxf` (`importRecords`/`importDXF`/`importItem`) reusing `readEntities` + `makeBlockFromEntities`; collision-safe via `newName` (both blocks survive, proven). UNWIRED. *Cuts:* no `$INSUNITS` unit-scaling on import; unflattened nested-INSERT symbols import supported geometry only.
- **B0** `e726ea4c2` (+14) — in-place Block Editor SCOPE on `CanvasModel` (`enterBlockEditing`/`exitBlockEditing(save:)`/`finishBlockEditingIfNeeded`) reusing the paper-space active-space pattern; `CADDrawing.setBlockMembers` undoable via `mutateBlocks`. **Save&Close/Discard** is one undo group; Discard restores the entry snapshot AND drops the net-identity group so `canUndo` returns to pre-enter (tested). Single-block (no nested REFEDIT); re-enter-while-open rejected. UNWIRED.
- **B-ATTR** `fb622c5ea` (+13) — block attributes: `InsertData.attributes` (ATTRIB values) + `Block.attributeDefs` (ATTDEF templates), additive + back-compat; `resolveInsert` emits ATTRIB via the shared `.text` arm (once per MINSERT cell, guards intact); full DXF round-trip via **vendored libdxfrw reader+writer patch** (`processInsert` consumes ATTRIB→attlist + swallows SEQEND; `processEntities` ATTDEF→new `addAttdef` interface hook; `writeInsert` emits code-66+ATTRIB+SEQEND; `writeBlock` emits ATTDEFs) — reviewer APPROVE, patch safe to carry. Flagged + carried one non-owned 1-line `drw_interface.h` defaulted-no-op virtual. **DXF only** (no DWG attribute fidelity). UNWIRED.

**REMAINING:** WIRE-WAVE 1 (paper-space viewport tool + per-layout plot menu + draw-variant mode pickers) — IN FLIGHT; then WIRE-WAVE BLOCK (double-click-insert→edit, BlockEditBar Save&Close/Discard, sidebar "Edit", attribute display/edit + prompt-on-insert, library browser gallery + drag-to-place + file picker); then final acceptance + `.app`.

---

---

## 2026-06-15 — PARITY WAVE 3 landed + PAPER SPACE approved (full P0–P4) + P0 in progress

**Landed** (`native-macos @ 025ba14bc`, **1870 tests**):
- **Named Views** `154d7d917` (+24) — View ▸ Save/Restore/Delete named viewports (center+scale; rotation carried for parity but Viewport has no rotation yet). **Session-scoped** (table on CanvasModel); on-disk + DXF persistence is a documented FOLLOW-UP.
- **Prefs read-site wiring** `fc22683b0` (+22) — the Preferences window now DRIVES behavior: Appearance canvas/grid colors → CanvasTheme; Rendering AA/LOD/line-width → LineRenderer; Text font/height → TextTool; new-doc units/template/autosave → ContentView/LibreCADDocument seeding. All fall back to today's defaults when unset. *Follow-up:* Snapping pref (read-site is CanvasModel) still unwired.
- **Exact-bulge hatch read-back** `177d413a1` — DXF hatch boundary arc edges now read back as a single bulged vertex (geometry-stable inverse of the writer), not tessellated; flipped 2 tests (incl. an authorized 5th-file edit) to resolve-based bow checks.

**Owner decision (DC.17):** **Full paper space (P0–P4)** approved — model + DXF + Model/Layout tab + per-layout plot + P3 model-space VIEWPORT entities. Multi-layout DXF write (libdxfrw patch) stays a follow-up. Plan: `macos/docs/paperspace-plan.md`. Technical calls: viewports OFF `EntityKind` (separate `Layout.viewports` list → avoids the 28-switch blast); engine-level page descriptor on `Layout` (CADEngine can't depend on the app module's `PrintLayout.PageSetup`); single-layout fidelity on stock libdxfrw first.

**P0 in progress** (`ps-p0-model`): `EntitySpace` + additive `EntityRecord.space`/`layoutName` (back-compat Codable) + `CADDrawing.layouts` + undoable mutators + `DXFPayload` persistence. No UI/DXF/viewports yet. Then P1 (DXF read/write) → P2 (tab+sheet render) → P3 (viewports) → P4 (plot); P2/P3 serialize on CanvasModel+LineRenderer.

---

## 2026-06-15 — PARITY WAVE 2 landed + NAVIGATION/Esc in progress

**Parity wave 2 LANDED** (`native-macos @ 3ce54129b`, **1816 tests**):
- **G6** `a52d930ba` — leader annotation now authored to DXF as an independent entity (other CAD sees the text; libdxfrw can't write the 340 hard-ref → standalone, documented+test-pinned); hatch boundary-arc WRITE confirmed already emitting real `DRW_Arc` (regression test added, stale comments fixed). *Follow-up:* exact-bulge hatch READ-back (currently tessellates) is blocked by a locked test's old assertions — flip them to enable.
- **G4** `eedffae77` — distance-along-entity snap (line/arc-by-arc-length/polyline) + manual middle/intersection primitives, additive (no new `SnapKind` to avoid non-owned renderer-switch edits). *Follow-up:* UI for the snap-distance field + two-pick manual arming.
- **G7** `4554a55` — application **Preferences window (⌘,)** (General/Appearance/Snapping/Rendering/Text, `@AppStorage`). Only theme drives behavior live; other keys stored with `// READ-SITE:` markers. *Follow-up:* wire each pref to its read-site (new-doc seeding, CanvasTheme, snap defaults, renderer, text tool).

**NAVIGATION + Esc-deselect — LANDED** `8f04c02f2` (merged `424ef1d5a`, 1824 tests). Device-aware scroll: mouse wheel → zoom-to-cursor; trackpad two-finger → pan; pinch → zoom; middle-drag → pan (`NSEvent.hasPreciseScrollingDeltas`; `⌥+scroll` always zooms — escape hatch for high-res mice that report precise deltas). Pinch + middle-drag were already wired; the wheel path was fixed (old `1+delta*0.01` ≈ imperceptible → new ~10%/notch via pure `ViewportNav`). Zoom-about-cursor anchors via pure `Viewport.zoom(by:about:)` (world point under cursor stays fixed). **Esc** unwinds progressively: cancel zoom-box → cancel marquee → cancel in-progress tool (selection preserved) → when idle, `deselectAll()`. zoom-window/fit/previous/space-drag/marquee all intact.

---

## 2026-06-15 — QUEUED NEXT (owner-directed): viewport navigation — scroll-zoom + middle-drag-pan

Owner: "after all of that [parity wave G6/G4/G7] is done, work on zoom and movement — scroll should zoom, middle mouse should drag, etc." Priority: **after the current parity wave merges, BEFORE the big-ticket projects.**

Scope (modern CAD navigation, in the canvas input layer — `Canvas/CADCanvasView.swift` mouse/scroll/gesture handling + `CanvasModel`/`Viewport` zoom-pan state):
- **Mouse wheel scroll → zoom to cursor** (anchor the zoom at the pointer, not the center).
- **Middle-mouse-button drag → pan** (AutoCAD/standard convention).
- Keep existing zoom-window (drag-box) + zoom-fit/previous + the current pan affordance working.
- macOS niceties to consider: trackpad **pinch/magnify → zoom**, two-finger scroll, momentum.

**DESIGN QUESTION to resolve when we start it** (trackpad vs mouse conflict): on a Mac, a mouse wheel and a trackpad two-finger swipe BOTH arrive as scroll events. Owner wants "scroll → zoom" (mouse-centric). But trackpad users usually expect two-finger = pan, pinch = zoom. Decide: (a) ALL scroll → zoom (mouse-first), (b) detect device — wheel→zoom, trackpad two-finger→pan + pinch→zoom (best of both, `NSEvent.hasPreciseScrollingDeltas`), or (c) modifier-based. Recommend (b). Ask the owner at kickoff.

This is a GUI-feel task → build it, rebuild `.app`, owner verifies.

---

## 2026-06-15 — PARITY WAVE 1 (post-audit): inspector editors + scale printing + relative-zero (`native-macos @ afb4e671d`, 1771 tests)

Catalog audit (prior entry) showed most P0/P1 already done; this wave closed the next real gaps. 4 agents, disjoint files, serial-gated:
- **G1 inspector editors** `b40ea8127` (+21) — every `EntityKind` now has an inline geometry editor (ellipse/spline/splinePoints/polyline/hatch/solid/dimension/insert/xline/ray/leader); pure clamping setters in `InspectorEdits.swift`; reusable `IndexedPointEditor`.
- **G2 scale printing** `b83923d08` (+18) — Fit / **1:1** (ruler-accurate) / custom ratio plotting + page setup (Paper tab) + scale-correct PDF via a pure unit-aware `PrintLayout` transform.
- **G5 relative-zero** `5d1b1e25d` (+15) — Set Relative Origin (⌥⌘R, one-shot snapped pick), Lock/Unlock (⌥⌘L, pins datum vs auto-follow), Reset (⌥⌘0); responder-chain wiring, no `CADCanvasView` edit.
- **save-roundtrip-fix** `a441a28dc` (+2) — VERIFY-then-fix: proved the **DXF save path was ALREADY correct** (blocks+graphicVariables+dimstyles+layers round-trip); my acceptance-flagged "gap" was a stale-doc false alarm (`dwg-render-diagnosis.md:40`, now corrected). DWG-write limitation (libdxfrw) pinned by the test. No product code changed. (Validates investigate-before-implement.)

**Incident (working-copy safety, no damage):** the G1 merge first aborted because an agent had leaked an *intermediate* `InspectorEditorsTests.swift` (untracked) into the MAIN checkout — the cwd-gotcha (running file-writing ops in `/Users/macatt/w/LibreCAD` instead of the worktree). Main checkout's TRACKED state was intact; moved the stray to `/tmp/STRAY-InspectorEditorsTests.swift` and the batch merged clean. Reinforces: agents must operate only in their worktree path, never the shared checkout.

**Follow-ups:** (a) relocate `enum PaperSize` out of the SwiftUI `DocumentSettingsView.swift` into a non-SwiftUI model file so the `_SharedCanvasModel` test symlink resolves without G5's test-only `PaperSize` shim (backlog). (b) Next wave: G6a hatch boundary-arc bulge write, G6c DXF version picker, G4 distance-along/manual snaps, G7 application Preferences window.

---

## 2026-06-15 — v5 CONTINUATION CLOSED — acceptance GO on real data (`native-macos @ 4afae0e0f`, 1715 tests)

Acceptance pass (real `mechanical_example-imperial.dwg` + a DXF + new engine APIs + `.app` smoke) → **GO**:
- Real DWG parses exactly per diagnosis (line 59 / dim 17 / circle 8 / arc 7 / 1 block; header inch, `$DIMTXT=0.125`, `$DIMSCALE=1.0`). **23× dim-text bug stays fixed** — all 17 dims resolve ≤0.18 glyph height (named `MEP` DIMSTYLE), nowhere near old ~2.5.
- DXF clean; new APIs (trim amount/mutual, duplicate, ellipse foci/4-pt, rounded rect, star polygon, ToolSuggester) all sane. `.app` launches/stays up/quits clean.

**Landed this push** (all merged, serial-gate green): wired 7 tools; trim modes (amount/mutual); rectangle/polygon/ellipse variants; **raster image** (model + Metal texture + DXF IMAGE r/w, reviewed SAFE); **⌘D Duplicate**; **W6** grouped toolbar + Tools menu + `ToolCatalog`; **command bar** (bottom fuzzy launcher, adaptive set + MRU + selection-context) — KEPT the grouped toolbar (DC.16 reversed), command bar is ADDITIVE; flaky test hang → serial-gate workaround.

**Known gap (pre-existing, NOT a regression, tracked):** DXF/DWG **write/save** path (`data(from:)`) drops blocks + graphicVariables (writes entities+layers only) — a SAVE round-trip fidelity limitation (the READ/open path fix that cured the dim-text bug is fine). Acceptance flagged it citing `dwg-render-diagnosis.md:40`; needs a quick re-verify against the read-path fix. Backlog: "Real DXF read/write in CADDocument."

**Next (owner's call):** (a) owner GUI spot-check of toolbar + command bar; (b) **Phase 2** command-bar coordinate/param/alias parsing (`L`, `10,10`, `@5<90`); (c) fix the save round-trip fidelity gap.

---

## 2026-06-15 — Flaky test hang RESOLVED via serial gate; production font fix deferred

Investigator root-caused the intermittent `swift test` hang: a **Core Text first-touch lock-inversion** — `CADFonts.provider` (CADDrawing.swift) makes its first `CTFont*` calls inside a `swift_once` static-init critical section; under Swift Testing's PARALLEL runner a worker holds the `swift_once` lock while blocked in Core Text init, while a `@MainActor` test holds the main actor waiting on that same lock → deadlock. Reproduced 2/30 parallel, **0/12 serial**.

A `font-deadlock-fix` agent attempted a production fix (defer CT out of static-init) but it did NOT clear the bar (still ~3/30 hangs) and the agent then **wedged** (38 min idle, no process) — stopped via TaskStop; its attempt saved at `/tmp/font-fix-attempt.diff` (discarded, unproven). Its own last note concluded the trigger is the **`swift test` parallel-runner wrapper**, not the test code.

**DECISION (forward-operating):** run the verification gate with **`swift test … --no-parallel`** (proven 0 hangs, <1s, zero product-code risk). The hang is a TEST-INFRA artifact, not a product bug, so it does NOT block the user-facing work. The robust production fix (ensure NO `CTFont*` call happens during any `static let`/`swift_once` init; warm Core Text deterministically) is a **tracked follow-up** in `backlog.md`, not done now.

---

## 2026-06-15 — UX PIVOT: command bar replaces the button toolbar (owner-directed, answered 4 design Qs)

Owner: "the toolbar is now a long list of buttons; make it part of the prompt line — ~8-10 always-relevant tools, and as the user types, narrow to the tools we could be using." Confirmed design via AskUserQuestion:
- **DC.13 Placement:** **bottom command bar** (AutoCAD/LibreCAD convention), full-width: prompt input on the left + tool chips that narrow as you type.
- **DC.14 Scope (phased):** **Phase 1** = tool launcher (fuzzy-filter the ~50 `ToolKind`s to matching chips; ⏎/click activates). **Phase 2 (fast follow)** = full CAD command line — parse coordinates/params/aliases (`L`, `10,10`, `@5<90`) into the active tool (extends `CommandParser`). Ships the visible win first, grows into the pro command line ("compete with AutoCAD").
- **DC.15 Default set:** **adaptive** — curated core blended with most-recently-used + context (selection-aware: Trim/Extend/Fillet when something's selected, dim tools when measuring). Persist MRU.
- **DC.16 Toolbar fate:** ~~the command bar REPLACES the grouped button toolbar~~ **REVERSED same day** → **KEEP BOTH.** After seeing the W6 grouped Draw/Modify/Annotate toolbar in action the owner said it's "amazing" and "keep it but still implement the command bar." So: the **grouped toolbar stays as the primary visual surface**, and the **command bar is an ADDITIVE keyboard-driven complement** (bottom strip), not a replacement (VS Code activity-bar + ⌘P pattern). Tools menu + ⌘K also remain. The running command-bar agent was redirected mid-build (keep the toolbar; insert the bar alongside → smaller/safer ContentView diff).

**W6 still merges** — it is the FOUNDATION, not waste: its `ToolCatalog` (every tool + group + metadata), grouped Tools menu, ⌘D Duplicate wiring, customizable-set scaffold, and no-orphan test all feed the command bar. Only W6's *button-toolbar rendering* in `ContentView` is superseded by the command bar.

**Sequence:** font-deadlock-fix (in flight, 30×-stress acceptance) → merge → W6 merge (hang-free base) → **command-bar build** (Phase 1: bottom bar replacing the toolbar, adaptive set, fuzzy chips; reuse `ToolCatalog` + `CommandPalette` matcher) → build `.app` + acceptance + USER GUI verify → Phase 2 command-line parsing.

---

## 2026-06-15 — v5 CONTINUATION: wire-down + raster image + parity-gap fill (owner: "continue reimplementing LibreCAD features and improving for macOS; good trajectory")

State at start: `native-macos @ dfb2c4928`, **1554 tests** green, clean (pointstyle W5/F19 landed). Survey confirmed **7 tools built-but-UNWIRED** (xline, ray, align, arrayPath, leader, baselineDim, continueDim) and **no `EntityKind.image`** yet.

**Round-1 plan — 4 concurrent agents, fully DISJOINT files (watchdog-safe ≤4):**
- **R1.a wire-backlog** — integration debt is large, so pay it down NOW: wire the 7 already-built tools into `ToolKind.swift`/`ContentView.swift`/`LibreCADApp.swift`/`CanvasModel.swift`/`ToolOptionsBar.swift` + wiring tests. Owns the app-shell trio exclusively this round (no other agent touches them).
- **R1.b w5b-image** (DC.9, the last v5 EK) — `EntityKind.image` + `ImageData` + Resolve textured-quad + GPU texture pipeline + DxfBridge IMAGE/IMAGEDEF read/write + `Tools/ImageTool.swift` (UNWIRED). Owns engine-core (Entity/Resolve/EntityTransform/Snapping/InspectorEdits/DXFWriter/bridge/renderer).
- **R1.c modify-trim2** (catalog P1) — trim-by-amount + mutual trim-2; `Tools/TrimTool.swift` only, UNWIRED.
- **R1.d draw-variants** (catalog P2) — typed W×H + rounded/chamfer Rectangle, corner-corner + star Polygon; `Tools/RectangleTool.swift`+`Tools/PolygonTool.swift` only, UNWIRED.

Disjoint: a=app-shell+wiring-tests; b=engine/renderer/bridge+new ImageTool; c=TrimTool; d=Rect/PolyTool. Built UNWIRED (b/c/d add NO ToolKind case — that's the next wire-wave's job). After merge: wire-wave for image/trim2/variants, then **W6 toolbar reorg**, then **FINAL acceptance pass** on the real DWG + a DXF. Discipline unchanged: harden agents (`git reset --hard native-macos`, never `git switch -C`), merge-by-hash + branch-assert guard, verify-test-count-before-cleanup.

**Infra note (this session):** the harness creates agent worktrees off `master` (which lacks `macos/engine/`), NOT off the current `native-macos`. Agents correctly recovered via `git reset --hard native-macos` (or a fast-forward `git merge native-macos`) on their OWN branch — no `switch`/`branch -f`, `native-macos`/`master` untouched. Briefs now state this up front.

**— RESULT: Round-1 LANDED** (`native-macos` advanced `dfb2c4928` → `24223f6b4`, **1628 tests** green, build clean, 4 worktrees pruned):
- R1.a wire-backlog `afabbcf11` — 7 tools wired (toolbar+Tools-menu+⌘K palette+options bar+Inspector). Final shortcuts: xline ⌥I, ray ⌥Y, align ⌥A, array-path ⌥P, leader ⌥L, baseline-dim ⌥D, continue-dim ⌥C (⌥X/⌥B/⌥N collided with Explode/Create-Block/Angular-3p → reassigned). Canvas letter-keys not added (handleKey not owned) → menu-level chords fire app-wide regardless of focus.
- R1.b modify-trim2 `315e9dff1` — `TrimTool.Mode{.boundary/.amount/.mutual}`; `trimAmount`/`trimAmountBoth` (signed shorten/lengthen along entity, `byTotalLength` reinterprets) + `mutualTrim`→`MutualTrim(a:b:)` (both entities to mutual carrier intersection). UNWIRED.
- R1.c rect/poly variants `06d56c2e2` — `RectangleTool.corner{.square/.rounded(radius:)/.chamfer(distance:)}` + typed W×H via `fixedWidth/Height`; `PolygonTool.mode{.centerCorner/.edge/.star(ratio:)}`. UNWIRED.
- R1.d ellipse variants `ac122a692` — `EllipseTool.Mode{.axis/.fociPoint/.fourPoint/.inscribeQuad/.arc}` (4-point = axis-aligned conic LSQ; inscribe = Steiner inellipse of a parallelogram). UNWIRED.
- NEXT: w5b-image (solo, in flight) → wire-wave-2 (image + trim/rect/poly/ellipse modes into options bar + menu) → W6 toolbar reorg → FINAL acceptance pass.

**— RESULT: Round-2 LANDED** (`native-macos` → `78592416a`, **1676 tests** green):
- **w5b-image** `1368952f2` (merged `726dc575b`) — `EntityKind.image(ImageData)` (insertion + per-pixel u/v + inline IMAGEDEF + display params), `ResolvedImage` + frame polyline, Metal textured-quad pass (`image_vertex/fragment`, path-keyed `MTLTexture` cache, missing→placeholder frame), CG export parity, bridge IMAGE↔IMAGEDEF read (handle-linked) + best-effort `writeImage`, `ImageTool` (unwired). Reviewed by a dedicated agent → **SAFE TO MERGE, no blockers**; applied its SHOULD-FIX (export draw-order now fills→images→strokes to match screen) + NITs (`bc07440ad`).
- **wire-wave-2** `6f8702c49` (merged `78592416a`) — Image tool wired with View-layer `NSOpenPanel` file-picker → 2-click placement (shortcut ⇧Y); options-bar controls for Rectangle (Square/Rounded/Chamfer + size), Polygon (Center/Edge/Star + ratio), Ellipse (Axis/Foci/4-Point/Inscribe/Arc), Trim (Boundary/Amount/Mutual + amount). **Hit a headless-test hang** — a test reached the modal `NSOpenPanel`; coordinator killed the stuck test + messaged the fix (panel View-layer only); agent corrected → green.
- **modify-duplicate** `a3f0266ce` (merged `ee3a59303`) — `Duplicate.duplicate(_:offset:)` static + `DuplicateTool` (new ids, preserved layer/pen), unwired (⌘D wired in W6).
- **Gap flagged + being closed now (trim-dispatch agent):** `TrimTool.handle` only drove `.boundary`; `.amount`/`.mutual` existed only as static funcs. Adding `mode`+`amount` fields + handle dispatch + `applyToolConfig` wiring so the options-bar selection works end-to-end.
- NEXT: trim-dispatch → **W6 toolbar reorg** (Draw▾/Modify▾/Annotate▾ + wire ⌘D Duplicate + customizable default set) → **FINAL acceptance pass** on the real DWG + a DXF.

---

## 2026-06-12 — v5 FEATURE-COMPLETION PUSH (owner: "tackle most remaining LibreCAD features, parallelize, INTEGRATION is key")

Plan: `macos/docs/v5-plan.md` — wave-by-wave, **file-ownership matrix** (no two concurrent agents touch the same file), **EntityKind additions serialized** (each its own step updating all exhaustive switches: Resolve×3, EntityTransform, Snapping×2, InspectorEdits, bridge enum, DXFReader/Writer), **batched wire-waves** for UI surfacing, **build+test+real-file integration gate after every wave** + a FINAL cross-feature acceptance pass on `mechanical_example-imperial.dwg` + a DXF. ≤4 concurrent agents (watchdog-safe). Owner emphasis: features must work together (consistency conventions in §7 — every new entity resolves+bbox+transform+snaps+selectable+DXF round-trips; every new tool follows the Tool pattern + options bar + Inspector).

**§8 owner decisions — ACCEPT the planner's recommended defaults (owner away, best-guess):**
- **DC.6** Do all 3 dimension subtypes (ordinate / arc / angular-3p) now (W2) — supersedes the earlier "stage on demand" DC.4 (the real-file completeness push demands them).
- **DC.7** Ship **hatch patterns** (.pat) (W4a). **DC.8** Defer **MLINE** (low value/high effort, W5c optional). **DC.9** **Raster image LAST** (W5b — isolates the only new GPU texture pipeline). **DC.10** Paper-space/UCS OUT of v5 (separate large effort). **DC.11** Toolbar reorg (U4) AFTER features (W6). **DC.12** Multi-select property edit is already partly done (Inspector common fields) — W3 enhances rather than builds from scratch.
- Waves: **W1** DIMSTYLE table + measure/join/explode-text tools · **W2** dim subtypes + create-block/explode-insert + select-traversal · **W3** construction lines + UI (blocks sidebar/layer states/property-painter/multi-edit) · **W4** hatch patterns + align/array-path + leader + baseline/continue dims · **W5** point styles + view/order tools + raster image + templates · **W6** toolbar reorg · **FINAL** acceptance pass.
- **Sequencing note:** the dimension-text-height fix (in flight) touches `Resolve.swift`; v5 W1+ also touch Resolve → v5 execution starts only AFTER that fix merges.

---

## 2026-06-12 — DWG RENDER DIAGNOSIS + FIX (owner reported a real .dwg rendering wrong)

Owner opened `mechanical_example-imperial.dwg`: **DWG parse WORKS + it opened** (validation!), but dimension text/arrows are huge + dims dominate. Investigated → `macos/docs/dwg-render-diagnosis.md` (data from the real file via the engine read path).

**CONFIRMED root causes (data-backed):**
- **RC1 (dominant):** bridge `addDimStyle` + `addHeader` are NO-OPS (`lcdxf.cpp`) → `$DIMTXT/$DIMASZ/$DIMSCALE` discarded → every dimension uses the engine default **2.5** (≈23× too big in this ~1″-feature imperial drawing). Causes "text too big" AND the sparse/dominated look. libdxfrw parses these; the bridge just drops them.
- **RC2:** `$INSUNITS`/`$LUNITS` not read → imperial treated as mm.
- "Missing entities" **REFUTED** — all geometry imported (line 59 / dim 17 / circle 8 / arc 7 / 1 block; only 2 paper-space VIEWPORTs skipped). Dims just dominate. Vertical-dim overlap is a consequence of the oversized height.

**DC.5 — ABI route (best-guess, owner away):** implement **explicit `lc_header()` / `lc_dimstyles()` bridge accessors** (the investigator's recommended route) over the "resolve-in-C++-and-stamp-on-LCEntity" smaller cut. Why: cleaner + reaches the EXISTING `graphicVariables` ($DIMTXT/$INSUNITS accessors already exist) + `dimStyleProvider` plumbing, and enables dim-style/unit DXF/DWG **write round-trip** too.
**Executing now:** P1 (addDimStyle+addHeader → DIMTXT/DIMASZ/DIMSCALE) + P2 ($INSUNITS/$LUNITS/$LUPREC) + P3 (per-dimension overrides). P4 (DIMEXO/DIMEXE/DIMGAP) if cheap; P5 (paper-space viewports) deferred (not the cause).

---

## 2026-06-12 — v4 SUBSTANTIALLY COMPLETE (autonomous summary for owner's return)

**State:** native-macos @ 12009621d, **1179 tests, 262 commits** (still local — `git push -u origin native-macos` when on an open network). App reassembled green.

**All three owner asks delivered:**
1. **UI polish to macOS HIG** (#19): command/coordinate input line (type `@dx,dy` / `dist<angle`), contextual **tool-options bar**, persistent **status bar + crosshair + step hints**, **marquee select** (window/crossing) + hover highlight + **right-click context menus** + **entity clipboard** (cut/copy/paste/duplicate), Select All/Deselect/Invert, **ortho** (F8/⇧), toggleable advanced snaps, deduped toolbar icons, ⌘K Document-Settings entry.
2. **Document settings page** (#20): Units / Grid & Snap / Dimensions / Layers / Paper sheet (⌥⌘,), live-apply + per-field undo, round-tripped via DXF header vars.
3. **Missing LibreCAD features** (#21, from feature-catalog.md): **DocumentGroup** (native recents/autosave/versions/dirty) · **INSERT/blocks keystone** (place + DXF round-trip) · **Stretch/Lengthen/Break** · **PolylineEdit** · **perpendicular/tangent/nearest/parallel** snaps · **spline-DXF-write + layer-visibility** fixes (data-loss closed) · **DWG read+write** surfaced (open/save .dwg).

**KNOWN GAPS / FOLLOW-UPS (for the owner — not yet done):**
- **U4 toolbar reorg** (Draw/Modify/Annotate menu grouping + customizable default set, decision D6) — deferred.
- **DWG limits:** write is R2000-only, and **block-member geometry doesn't round-trip to DWG** (DXF is full) — libdxfrw-phase gap, in backlog.md.
- **Blocks:** create-block-from-selection + a live blocks sidebar (catalog #7) — not done; InsertTool needs a block-picker UI (currently inert with no blocks).
- **Dimensions:** only document-default dim style (no named **DIMSTYLE** table); ordinate/angular-3p dim subtypes deferred (DC.4).
- **Not built:** construction lines (xline/ray), leader/multileader, image/table entities, **hatch patterns** (solid only, DC.3), **PointData.style** rendering (marker styles surfaced but not rendered).
- **NEEDS REAL-FILE / GUI VERIFICATION (owner):** all interactive UX is unverified headlessly (text authoring, inspector, dimensions, marquee, gizmos, context menus, ortho/snaps); plus an AutoCAD-authored **.dwg** and a licensed **.shx** to confirm those readers against real third-party files; and confirm DocumentGroup launch/recents/autosave in a real window.

**HOW TO TRACE:** every decision is in this log (DC.* catalog forks, D1–D8 UX defaults, execution-progress + minor calls). Per-batch detail in DEVLOG.md; the gap backlog in feature-catalog.md + backlog.md.

---

## 2026-06-12 — v4 EXECUTION PROGRESS (autonomous; owner away)

Merged so far (native-macos @ 55f9f7b65, **1113 tests, 246 commits**): DocumentGroup (passed launch gate) · U1 coordinate/command input line · spline-DXF-write + layer-visibility fixes (data-loss closed) · Stretch/Lengthen/Break tools · Document Settings sheet · U2 tool-options bar · U3 status bar + crosshair · **INSERT block-reference entity (keystone)**.

Minor execution calls (best-guess, reversible):
- **U2**: kept the Inspector's tool-config section AND added the options bar (both bind the same `CanvasModel` state → stay in sync; lower risk than removing one).
- **PointTool** marker-style param is surfaced in the options bar but full render-honoring is gated on a future `PointData.style` field — logged follow-up.
- **U3** replaced the transient corner HUD chips with the persistent status bar (coords/snap/zoom/step).
- **INSERT**: named blocks read into a block table + emitted in the BLOCKS section; anonymous `*`-blocks stay inline (preserves dim_sample entity counts); `InsertTool` built UNWIRED (wired in wire-wave-C). Block recursion depth-guarded at 32.
- New tools are built UNWIRED and surfaced together in periodic **wire-waves** (avoids N agents fighting over ToolKind/ContentView).

Next: **wire-wave-C** (surface Stretch/Lengthen/Break/Insert) + **snap-modes-2** (perpendicular/tangent/nearest) in parallel; then select-all/ortho, full dim styles, DWG (revisit DC.2).

---

## 2026-06-12 — v4 PLANNING DECISIONS RESOLVED (best-guess; owner away)

Planning docs landed: `feature-catalog.md` (~99 gaps, prioritized) + `ux-plan.md` (HIG audit + settings spec).

### From feature-catalog.md (owner-flagged forks)
- **DC.1 DocumentGroup** — ✅ DONE: built off-main-safe (Sendable `DXFPayload`, no `MainActor.assumeIsolated`), merged `0d0c17331`, **passed the launch gate** (bare binary alive, no new crash). Owner: please GUI-confirm Open Recent / autosave / dirty-dot when back.
- **DC.2 DWG read/write** — **DEFER.** The C bridge gained DWG (upstream `5315f0ce8`/`47972ec25`) but it's unsurfaced in Swift. High-value but NOT the stated pain (usability) and needs real-file testing. Schedule AFTER P0 usability + core-feature waves. Revisit once U1–U3 + INSERT land.
- **DC.3 Hatch patterns** — **Ship SOLID now**; a real `.pat` pattern generator is a later P2. Solid covers the common case.
- **DC.4 Dimension model scope (ordinate/arc/angular3p)** — **STAGE.** Add a `DimKind` case only when a tool/feature needs it; don't churn the cross-cutting enum + all switches without demand. Existing 5 cover the vast majority.

### From ux-plan.md (D1–D8) — ACCEPT the recommended defaults (HIG-aligned, reversible)
- **D1** command line: always-present field, focus on Space/click, Esc→canvas. **D2** empty-space drag = marquee select in select mode (Space/middle-drag pans). **D3** settings: live-apply + Done, one undo step per field. **D4** dim style: per-entity wins, document default fills via the resolve hook. **D5** persist snap modes via private `$LC_SNAPMODE` header var. **D6** default toolbar Select/Line/Circle/Arc/Rectangle/Move/Trim/Linear-Dim + Draw▾/Modify▾/Annotate▾, rest via menu+⌘K, customizable. **D7** extend `ToolInput` append-only with `.value(Vector)`. **D8** Document Settings = ⌥⌘, (reserve ⌘, for future app Preferences).

### v4 execution order (best-guess)
1. **U1 coordinate/command input line** (the #1 usability fix) + **P0 bug fixes** (spline DXF write = data loss; layer-visibility render filter) — parallel, disjoint files.
2. **Document Settings sheet** + **U2 tool options bar** (after U1 frees ContentView).
3. **INSERT entity + block insert/sidebar** (keystone gap) + **U3 status bar / crosshair**.
4. Catalog long tail: select-all/ortho/relative-zero (some fold into U1), stretch/lengthen/break, dim styles; then DWG (revisit DC.2), hatch patterns (DC.3).

---

## 2026-06-12 — V4 PHASE KICKOFF (owner directive)

**Owner directive (verbatim intent):** After DocumentGroup, start the next phase:
(1) polish the UI — tools are currently difficult to use; follow modern macOS HIG;
(2) add a **document settings page**; (3) **catalog the missing features from LibreCAD and tackle the list**.
"Keep going, I won't be here for a while. If you have questions, pick your best guess and proceed,
and note decision points so I can trace them."

### D-V4.1 — Run v4 planning in parallel with DocumentGroup
- **Decision:** Kick off the two v4 planning agents (feature-catalog, UX+settings plan) NOW, in parallel
  with the in-flight DocumentGroup build. Execute v4 build waves only AFTER DocumentGroup merges + is launch-verified.
- **Why:** Planning is read-only on code + writes docs → zero conflict with DocumentGroup's code. Maximizes
  autonomous progress per "keep going." Owner said "after this is done, schedule the next phase" — scheduling now, executing after.
- **Revisit:** if DocumentGroup needs a re-plan, the v4 plans are still valid (independent surface).

### D-V4.2 — v4 sub-streams + sequencing (best guess)
- **Decision:** Three workstreams: **(A) UX polish** (HIG audit → fix tool usability: contextual options bar,
  numeric input during drawing, clearer mode/affordance feedback, toolbar/menubar organization, etc.),
  **(B) Document settings page** (units, precision, grid/snap defaults, dimension style, layer defaults…),
  **(C) Missing-feature catalog → prioritized implementation**. Order: land planning docs → tackle (A)+(B)
  first (directly address the stated pain), then (C) in priority order.
- **Why:** The owner led with usability ("tools are difficult to use") → prioritize A/B; C is the long tail.
- **Revisit:** owner can reprioritize C's list (see feature-catalog.md once written).

### D-V4.3 — Autonomy guardrails while away
- **Decision:** Proceed without check-ins; on any fork, pick the most HIG-aligned / least-risky / most-reversible
  option and log it here. Keep the merge discipline used in v3 (isolated worktree per agent, merge-by-reported-hash,
  verify test count + green build before deleting branches, ≤~4 concurrent agents). No `jf`/external publish; no
  `git push` (network blocked — owner pushes). Don't repeat the launch-path risk class without a verify gate.
- **Why:** matches owner's "best guess + proceed + trace" + the v3 process that worked.

### D-V4.4 — Decision-log location
- **Decision:** This file, `macos/docs/decision-log.md`. Also cross-referenced from DEVLOG.md.
- **Why:** discoverable next to the other living docs.
