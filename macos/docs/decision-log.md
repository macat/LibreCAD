# Decision Log — autonomous decision points (for owner traceability)

This log records judgment calls made while the owner (macatt) is away, so they can be
traced/reversed later. Each entry: date, decision, the options considered, why, and how to revisit.
Newest first. (Reversible code lives behind small diffs on `native-macos`; cite the commit/wave.)

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
