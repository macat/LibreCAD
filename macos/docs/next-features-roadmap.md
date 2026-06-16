<!-- Synthesized 2026-06-16 by the next-features-survey workflow (6 area investigators + planner synthesis), verified against code. -->

# Next-Features Roadmap — native macOS LibreCAD

Synthesized from 6 area surveys (draw-entities, modify-select, dim-annotation, file-interop, view-nav-space, ux-macos-perf), deduped and re-ranked by **daily value × independence × low risk**, grouped into parallelizable waves under the project's `≤4-concurrent-disjoint-files`, `build-unwired + wire-wave`, and `no-new-EntityKind-without-serialized-solo-phase` rules. All cited claims verified against code at `native-macos @ 5291ae797`.

## Headline

- **Single highest-value "do next":** **Quick Select / Select-Similar UI** (modify-select #1). The entire engine (`QuickSelect.swift`, 11 KB, tested — replace/add/remove/intersect modes) is **DONE and 100% unwired** (verified: zero references in `LibreCADmacOS/`). It's a pure new-file panel + one `CanvasModel` method. Highest value-per-effort in the whole port.
- **Recommended first wave:** four "engine-done, UI-absent" items that are each a clean new file or a 1-line read-site — **Wave 1** below. Maximum shipped value, near-zero merge risk, no hot-file contention.
- **Catalog is badly stale across all six areas** — many "missing/P0" rows are DONE and wired. Correcting `macos/docs/feature-catalog.md` is a parallel cleanup task (not a build).

## Recurring theme: the cheap wins are "wire the finished engine"

The strongest pattern across surveys: **the engine is consistently ahead of the UI.** QuickSelect, DXF version picker, SHX font selection, named-view persistence, annotation-scale, and 3 dead Preferences keys are all engine-complete and just need a surface. These dominate the early waves precisely because they're high-value, low-risk, and touch disjoint files.

---

## WAVE 1 — "Wire the finished engine" (4 disjoint, all clean/additive, ship first)

Highest ROI, lowest risk. Each agent owns separate files; no EntityKind, no hot-file collision.

| # | Item | State (cited) | Effort | Value | Owned files (hint) |
|---|------|---------------|--------|-------|--------------------|
| **1.1** ⭐ | **Quick Select / Select-Similar / Select-by-Property panel** | Engine 100% done & tested (`CADEngine/QuickSelect.swift`); **zero** app refs (verified). | **S** | **HIGH** | NEW `LibreCADmacOS/Sidebar/QuickSelectPanel.swift` + 1 method on `CanvasModel` (`selection.ids = QuickSelect.combine(...)`) + 1 palette/menu entry → defer that 1 line to Wave-W |
| **1.2** | **DXF version picker in Save** | Engine supports r12–r2018 (`DXFWriter.swift:59`); codec hardcodes `.r2000`, **zero** `DXFVersion` in app (verified). | **S** | **HIGH** | `LibreCADmacOS/LibreCADDocument.swift` (export accessory / Settings field + thread `version` param). HOT file but surgical — **solo owner** |
| **1.3** | **Named-view on-disk persistence** | `NamedViewTable` is session-only on `CanvasModel:1407`; **not** on `CADDrawing` (verified). Type already `Codable`. | **S** | **HIGH** | One additive field on `CADDrawing.swift` + `DXFPayload` codec. `CADDrawing` is HOT → **solo owner this wave** (no other Wave-1 item touches it). Payload-only; **defer DXF VIEW-table** to a later DXF wave |
| **1.4** | **Wire the 3 dead Preferences keys** | `defaultSnapMask`, `snapAperturePx`, `crosshairStyle` appear **only** in `AppSettingsView.swift` (verified — no read-sites). | **S** | **MED** (credibility: Settings currently lie) | Crosshair-style read in `Canvas/CrosshairOverlay.swift` (isolated). Snap-mask/aperture seed touches `CanvasModel` init → **coordinate with 1.1's CanvasModel method** or split: do crosshair here, snap-seed in Wave 2 |

> **Disjointness note:** 1.1 and 1.4 both want `CanvasModel`. Resolution: 1.1 owns `CanvasModel` (its new method); 1.4 ships **only the crosshair read** in Wave 1 (fully isolated in `CrosshairOverlay.swift`) and the snap-seed slice moves to Wave 2. This keeps all four Wave-1 agents on disjoint files.

**Wave-1 done-criterion (each):** committed on `native-macos`; serial suite green (`swift test … --no-parallel`); `.app` rebuilt so the user can verify the new surface.

---

## WAVE 2 — Daily-workflow drawing/modify wins (4 disjoint, mostly clean new tool files)

These are the "feels like real CAD every day" tool additions. All build **UNWIRED** — their `ToolKind`/options-bar/menu hookup batches into **Wave-W**.

| # | Item | State (cited) | Effort | Value | Owned files (hint) |
|---|------|---------------|--------|-------|--------------------|
| **2.1** | **Circle tangent variants** (Tan-1/2-pt, Tan-2-1pt, Tan-3, Tan-2, inscribe, from-arc) | `CircleTool` has only `.centerRadius/.twoPoint/.threePoint` (verified). Tangent kernel exists (`SnapGeometry.swift:113`). | **M** | **HIGH** | `Tools/CircleTool.swift` (add modes) + `CanvasModel` mode var. Output is plain `.circle` — **no EntityKind/Resolve/CADDrawing** |
| **2.2** | **Line construction variants** (bisector / parallel-through / tangent-1/2 / orth-tangent / perpendicular) | `LineTool` has only angle modes (verified). Snap kernels exist. | **M** | **HIGH** | NEW `Tools/LineConstructionTool.swift` (or per-variant files). Output plain `.line` — no hot churn beyond Wave-W `ToolKind` append |
| **2.3** | **Move-copy / Rotate-copy / Move+Rotate** | `MirrorTool.swift:186 TODO mirror-COPY`; no copy branch in Rotate; no `moveRotate` (verified). `ScaleTool` reference mode already DONE. | **S–M** | **MED-HIGH** | Additive `keepOriginal` flag in `Tools/{Rotate,Mirror,Move}Tool.swift` (emit `.add` not `.replace`) + new `moveRotate` tool. Per-tool files disjoint |
| **2.4** | **Select-Entities-on-Layer verb** | Layer-row menu (`LayersSidebar.swift:189`) has Set Active / Move / Isolate but **no select-on-layer** (verified). `QuickSelect.onLayer` exists. | **S** | **HIGH** | One `Button` in `LayersSidebar.swift` + `CanvasModel.selectEntitiesOnLayer(_:)`. **Pairs with 1.1** — if 1.1 still in flight, hold its `CanvasModel` ownership; otherwise sequence after Wave 1 |

> **Contention flag:** 2.1 and 2.3 both touch `CanvasModel` (mode var / nothing-major) and 2.4 touches `CanvasModel`. If running all four concurrently, route every `CanvasModel` edit through **Wave-W** instead and keep Wave-2 agents purely in their `Tools/*.swift` files. Recommended: 2.1+2.2 (pure Tools files) parallel; 2.3+2.4 sequenced or via Wave-W.

---

## WAVE-W — Batched wire-wave (ONE serialized agent)

Per the project convention, all UI wiring for Waves 1–2's unwired tools lands here, owned by a single agent holding the hot wiring files: `ToolKind` · `ContentView` · `LibreCADApp` · `CommandPalette` · `CanvasModel` · `ToolOptionsBar`. Feature agents never touch these.

- Append `ToolKind` cases for circle-tangent modes, line-construction tool, `moveRotate`.
- Add `ToolOptionsBar` Picker arms (circle mode, line mode, copy toggles).
- Add palette/menu entries for Quick Select (1.1) + Select-on-Layer (2.4).
- Wire snap-mask/aperture seed (1.4 deferred slice) into `CanvasModel` init.

**Done-criterion:** all new tools reachable from UI; serial suite green; `.app` rebuilt.

---

## WAVE 3 — Text-style fidelity + annotation-scale + iso grid (mixed: 1 hot-bridge, 2 clean)

| # | Item | State (cited) | Effort | Value | Owned files (hint) |
|---|------|---------------|--------|-------|--------------------|
| **3.1** | **Text Style Manager + STYLE-table DXF round-trip** | Engine model done (`Text/TextStyle.swift`); but bridge `addTextStyle` is a no-op (`lcdxf.cpp:418 (void)data;`) and writer emits only hardcoded "Standard" (`lcdxf.cpp:1568`). **Named styles silently dropped on save.** | **M** | **HIGH** (real data-loss fix) | HOT `DxfBridge/lcdxf.cpp` + `DXFReader/Writer.swift` (serialized, mirrors proven DIMSTYLE/ATTRIB bridge pattern) + NEW clean manager view (parallels `DocumentSettingsView`). **Solo owner of the bridge** |
| **3.2** | **Annotation-scale UI** | Mechanism engine-wired (`Resolve.swift:283 annotationScale`); every UI call uses default `1.0` (`CanvasModel.swift:706,973,3419`). No picker/list/toggle (verified empty). | **M** | **MED** (rises with paper-space viewports) | Small status-bar/document control feeding `makeResolveContext(annotationScale:)`. Touches hot `CanvasModel`/renderer call sites → **coordinate / route through Wave-W if concurrent** |
| **3.3** | **Isometric grid + iso ortho/snap planes** | Grid is rectangular only (`OverlayGeometry.grid:84`); `OrthoConstraint:27` is H/V only. No iso anywhere. | **M** | **MED-HIGH** | NEW iso branch in `Renderer/OverlayGeometry.swift` + additive `OrthoConstraint` mode + `CanvasModel` flag + F5 plane-cycle. No schema/EntityKind churn |
| **3.4** | **SHX + LFF/CXF user-font picker** | SHX renders (`CADDrawing.swift:1804`) but inspector reseeds `.shx`→native (`InspectorEditors.swift:623`); no user-font-dir UI. | **S–M** | **MED** | `Sidebar/InspectorEditors.swift` + `InspectorView.swift` (add `.shx` rows) + a Settings pane registering search dirs to `CADFonts`. Isolated |

> 3.1 (bridge) and 3.2/3.3 are disjoint; 3.2's renderer touches may collide with 3.3's `OverlayGeometry` only if both edit the renderer — they don't (3.2 = resolve call-sites, 3.3 = grid geometry). Safe to parallelize 3.1/3.3/3.4; hold 3.2 if `CanvasModel` is contended.

---

## WAVE 4 — Bigger isolated builds + the L-effort grip system

| # | Item | State (cited) | Effort | Value | Owned files (hint) |
|---|------|---------------|--------|-------|--------------------|
| **4.1** | **CLI converters (dxf2pdf / dxf2png)** | No executable target beyond `LibreCADmacOS`/`CADBench` (verified `Package.swift`). Engine `readEntities(dxfPath:)` + exporter exist to reuse. | **M** | **MED** (headless batch) | **Fully isolated** NEW SPM executable target. Note: `DrawingExporter` is `@MainActor` app-side → converter calls engine `SVGExporter`/`CGSceneRenderer` directly, or lift CG render into `CADEngine`. **Module boundary: keep engine-only** |
| **4.2** | **AutoCAD-style hover grips** (line endpoints + circle/arc radius + arc endpoints — the 80% case) | No engine grip type at all (`grep Grip CADEngine/` → 0, verified). Only AABB gizmo + modal poly/spline edit exist. | **L** | **HIGH** (biggest daily modify gap) | NEW `CADEngine/EntityGrips.swift` (grip-per-`EntityKind` = exhaustive switch → **serialize like an EntityKind addition**) + new overlay sibling to `GizmoOverlay` + drag→commit in `CanvasModel`/`CADCanvasView` (hot). **Minimal first deliverable: line/circle/arc only**, defer polyline/spline (have modal tools) + dimensions |
| **4.3** | **Command-line tool-name dispatch** (`L⏎`/`LINE⏎`/`C⏎`) | `submitCommandText` hard-errors "Start a tool first" when no tool active (verified `CanvasModel.swift:2195`); `CommandMatcher` exists but wired only to ⌘K (verified). | **M** | **HIGH** (AutoCAD muscle memory) | Routing inside `submitCommandText` + small name→`ToolKind` map in `CADEngine`. Touches hot `CanvasModel` (one method) → **serialize; pairs naturally with Wave-W ownership** |
| **4.4** | **Offset variants** (numeric distance / both-sides / erase-source) + **fillet/chamfer polyline-wide** | `OffsetTool` is through-point only; `Fillet/ChamferTool` pick exactly two lines (`FilletTool.swift:235`). | **S** (offset) / **M** (fillet-poly) | **MED** | Additive per-tool `Tools/{Offset,Fillet,Chamfer}Tool.swift` + Wave-W options entries. Clean isolated |

> 4.2 (grip exhaustive switch) and 4.3 (`CanvasModel` method) both want serialized hot files — **run sequentially**, not concurrently. 4.1 and 4.4 are clean → parallel with whichever of 4.2/4.3 holds the hot lock.

---

## WAVE 5 — Multi-layout DXF fidelity (one serialized libdxfrw deliverable) + the known small follow-ups

These share the **vendored-libdxfrw patch** and the **hot DXF read/write seam** — bundle into ONE serialized agent. Pinned by known-loss tests (flip them when fixed).

| # | Item | State (cited) | Effort | Value |
|---|------|---------------|--------|-------|
| **5.1** | **PLOTSETTINGS write** (margin/paper fidelity) | Writer emits none → A4 fallback. Test `PaperSpaceDXFRoundTripTests.swift:162 plotSettingsMarginIsLost`. | M | MED |
| **5.2** | **Per-entity layoutName reattach on read** + **multi-layout LAYOUT-dict write** | stock libdxfrw collapses paper entities (`DXFReader.swift:391`); writer one `*Paper_Space` only (`DXFWriter.swift:516,928`). Tests pin both losses. | M-L | MED |
| **5.3** | **DXF VIEW-table round-trip** (extends Wave-1.3 named views to disk-interchange) | follow-up flagged in `NamedView.swift:29`. | M | MED |

**Owned files (all serialized, ONE agent):** `DxfBridge/lcdxf.{cpp,h}` + vendored `libdxfrw` + `DXFReader.swift` + `DXFWriter.swift`. Done-criterion includes **flipping the pinned known-loss tests**.

### Known small follow-ups (slot into nearby waves)

- **Sidebar layer keyboard arrow-nav** — regression NIT1 (`decision-log.md:11,25`): nested `List(selection:)` can't nest under `SidebarPanelStack`. Fix = restructure to a single `List` with movable Sections (`Sidebar/LayersSidebar.swift` + `SidebarPanelStack.swift`). **M**, contended sidebar files → solo. Slot when LayersSidebar is otherwise idle (after Wave 2's 2.4).
- **Prompt-on-insert attributes** — (ATTDEF/ATTRIB prompt at block insert) — additive; pairs with text-style work in Wave 3.
- **Library thumbnails** — block-library preview rendering; clean new-file render-to-thumbnail, isolated. Slot in Wave 3/4.
- **Paper-space DXF fidelity** — IS Wave 5 (5.1–5.2).
- **Repeat-last-command (Enter/Space)** — **S**, new last-`ToolKind` tracker + key handler in `CADCanvasView` (hot, small). Slot into Wave-W or alongside 4.3.

---

## Infra debt (track, schedule one focused attempt)

**Core-Text parallel-test deadlock** — `CADFonts.provider` makes first `CTFont*` calls inside a `swift_once` static-init that lock-inverts with `@MainActor` tests under the parallel runner (~2–3/30 hang at 0% CPU). Open in `backlog.md:154`, `decision-log.md:230-234`; prior fix reduced but didn't eliminate it. **All done-criteria assume `--no-parallel`** (the serial test gate). Effort **M**: audit every font static-init path, move first CT touch to lazy per-call + deterministic main-thread warm-up; **verification requires a 30× stress loop**. Isolated to `CADEngine/CADDrawing.swift` (`CADFonts`). Schedule as a standalone focused phase — not blocking, but the only thing keeping the test gate serial.

---

## Defer / skip (out of scope for a LibreCAD-parity port)

Confirmed **not in upstream LibreCAD** (`git ls-files src/` empty) — AutoCAD-only, all high-effort / new-EntityKind / low-daily-value:

- **MLINE, TABLE/ACAD_TABLE, REGION/boolean ops, revision cloud, wipeout-as-tool, gradient hatch, text-on-path, fields** — defer all; none belongs in top tier.
- **Tables/BOM** (dim-annotation #5) — greenfield vs AutoCAD, new EntityKind, L — lowest-priority big item.
- **JWW / DXF1 / DGN / SVG-PDF import / MakerCAM** (file-interop #6–10) — not parity gaps (upstream lacks them too); pursue only as differentiators.
- **View cube / 3D ortho presets** (view-nav #9) — out of scope for a 2D engine; iso grid (3.3) covers the real "isometric look" need.
- **DWG block-member round-trip** (file-interop #4) — honest gap but L, hot libdxfrw C++, low-med daily value → defer unless DWG-block fidelity is demanded.
- **UCS** (view-nav #8) — L, highest blast radius. **But ship the S slice now:** apply already-stored ANGBASE/ANGDIR in `CoordinateFormatter`+`CommandParser` (`CADDrawing.swift:254` stores them; they're never read). Good isolated win — slot into Wave 3 or 4.

---

## New-EntityKind serialized solo phases (the only true 28-switch critical sections)

Per project rule, each is its own isolated phase (verified 23 files switch on `case .line(`):

- **MLEADER** (dim-annotation #2) — L, HIGH value but heavy. Do as one EntityKind-addition step + a follow-up wire-wave. (Note: basic LEADER already DONE — the gap is the *multileader* upgrade. The draw-entities survey's "MLEADER round-trip" item #1 can ship cheaper as **additive `MLeaderData`/standalone-LEADER polish without a new case** — recommend that first, defer the true `mleader` EntityKind.)
- **GD&T / TOLERANCE entity** (dim-annotation #3b) — M, MED (HIGH for mech). The ± tolerance-text sub-feature (#3a) is **cheaper as additive `DimData` fields, NO new EntityKind** — do that arm first.
- **Tables** — deferred (above).

---

## Recommended sequencing (summary)

1. **Wave 1** (4 disjoint engine-wiring wins) — start now. ⭐ **1.1 Quick Select is the single do-next.**
2. **Wave 2** (drawing/modify tools, unwired) → **Wave-W** (batched wiring).
3. **Wave 3** (text-style round-trip + annotation-scale + iso grid + font picker).
4. **Wave 4** (CLI converters ∥ grips ∥ command-line dispatch ∥ offset/fillet).
5. **Wave 5** (multi-layout DXF fidelity — one serialized libdxfrw agent) + slot the small follow-ups.
6. **Infra**: schedule the Core-Text deadlock attempt as a standalone phase whenever the team has slack.

**Effort totals:** Wave 1 ≈ 4×S, Wave 2 ≈ 2×M+2×S, Wave 3 ≈ M+M+M+S, Wave 4 ≈ M+L+M+S, Wave 5 ≈ M-L (serialized).

---

## Open questions for the user (resolve before building)

1. **MLEADER scope:** ship the cheap additive-`MLeaderData`/LEADER-polish first (no new EntityKind), or commit to the full `mleader` EntityKind + MLEADERSTYLE + collect/align (L, serialized solo phase)?
2. **Grips minimal scope:** confirm line/circle/arc-only first deliverable (defer polyline/spline/dimensions)?
3. **CLI converters module placement:** OK to lift the CG render path into `CADEngine` (so the converter stays engine-only, respecting the module boundary), or keep converters out until the exporter is de-`@MainActor`'d?
4. **Core-Text deadlock priority:** schedule a focused fix attempt now, or keep `--no-parallel` indefinitely and defer?
5. **Catalog correction:** want a parallel non-build task to fix the stale `feature-catalog.md` rows (all six areas have confirmed-stale DONE rows), or fold corrections into each feature's commit?

Roadmap file paths referenced: `/Users/macatt/w/LibreCAD/macos/engine/Sources/CADEngine/QuickSelect.swift`, `/Users/macatt/w/LibreCAD/macos/engine/Sources/CADEngine/Tools/CircleTool.swift`, `/Users/macatt/w/LibreCAD/macos/engine/Sources/CADEngine/Math/SnapGeometry.swift`, `/Users/macatt/w/LibreCAD/macos/engine/Sources/CADEngine/Text/TextStyle.swift`, `/Users/macatt/w/LibreCAD/macos/engine/Sources/CADEngine/DxfBridge/lcdxf.cpp`, `/Users/macatt/w/LibreCAD/macos/engine/Sources/CADEngine/CADDrawing.swift`, `/Users/macatt/w/LibreCAD/macos/engine/Sources/CADEngine/NamedView.swift`, `/Users/macatt/w/LibreCAD/macos/engine/Sources/LibreCADmacOS/Canvas/CanvasModel.swift`, `/Users/macatt/w/LibreCAD/macos/engine/Sources/LibreCADmacOS/LibreCADDocument.swift`, `/Users/macatt/w/LibreCAD/macos/engine/Sources/LibreCADmacOS/AppSettingsView.swift`, `/Users/macatt/w/LibreCAD/macos/engine/Sources/LibreCADmacOS/Sidebar/LayersSidebar.swift`, `/Users/macatt/w/LibreCAD/macos/engine/Tests/CADEngineTests/PaperSpaceDXFRoundTripTests.swift`, `/Users/macatt/w/LibreCAD/macos/docs/feature-catalog.md` (stale — correction task).