# UX Polish Plan + Document Settings Page Spec

Owner directive (V4): *"The UI needs polishing — currently the tools are difficult to use.
Follow more modern macOS guidelines. Also add a document settings page."*

This doc is grounded in the **actual** native-macOS Swift code (read 2026-06-12) and Apple's
macOS Human Interface Guidelines (HIG). It drives the V4 build waves. Where a fork needs an
owner call, it is flagged in **Part 4 — Decision points** with a recommended default (logged
so the coordinator can copy into `decision-log.md`).

**Concurrent change:** a `DocumentGroup` (native documents) change is landing. This plan assumes
the app becomes document-based; the settings surface is therefore specified as **per-document**
(stored on the drawing, round-tripped via DXF), NOT app `Settings`/Preferences. See Part 3.

**Files referenced (all under `macos/engine/Sources/`):**
- App shell / menus: `LibreCADmacOS/LibreCADApp.swift`
- Window + toolbar + HUD chips + inspector host: `LibreCADmacOS/ContentView.swift`
- Canvas event/key handling + inline text editor + gizmo: `LibreCADmacOS/Canvas/CADCanvasView.swift`
- Canvas state (tools, snap, grid, tool config): `LibreCADmacOS/Canvas/CanvasModel.swift`
- Inspector: `LibreCADmacOS/Sidebar/InspectorView.swift`, `LibreCADmacOS/Sidebar/InspectorEditors.swift`
- Layers sidebar: `LibreCADmacOS/Sidebar/LayersSidebar.swift`
- Command palette: `LibreCADmacOS/CommandPalette.swift`
- Tool contract / kinds: `CADEngine/Tools/Tool.swift`, `CADEngine/Tools/ToolKind.swift`
- Document model (units/format/header vars/dim/layers/styles): `CADEngine/CADDrawing.swift`,
  `CADEngine/Entity.swift` (DimData), `CADEngine/Layer.swift`, `CADEngine/Text/TextStyle.swift`

---

## Part 1 — Why are the tools "difficult to use"? (diagnosis vs HIG)

The codebase is in good architectural shape — tools are pure value types, there's a Tools menu,
toolbar, ⌘K palette, an Inspector, a Layers sidebar, dark-mode-adaptive HUD chips, and undo.
The usability problems are **interaction-model gaps**, not missing plumbing. Enumerated, each
against the relevant HIG pattern and what the code does today.

### G1 (BIGGEST) — No numeric / coordinate / command input during drawing
**Evidence:** Tools only ever receive **snapped mouse points**. `CADCanvasController.mouseClick`
/ `mouseMoved` feed `model.handleToolInput(.click(p))` / `.move(p)` where `p` comes from
`model.snappedWorldPoint(atScreenPoint:)` (CADCanvasView.swift). `ToolInput` (Tool.swift) has
only `.move/.click/.commit/.cancel/.backspace` — there is **no `.value`/coordinate event**. The
canvas `keyDown` (CADCanvasView.handleKey) consumes bare letters as tool shortcuts, so you
*cannot even type a number* on the canvas — pressing `5` would fall through, and `L` would switch
tools mid-line.
**Why it's the #1 pain:** CAD is precision drawing. In LibreCAD (and AutoCAD) you draw a line,
then **type `100` + Enter** for a 100-unit segment, or type `@50,30` / `@100<45` for relative
polar input. Today the only way to get an exact length/angle/coordinate is to draw approximately
then fix it in the Inspector — which only works for already-committed line/circle/arc/point/text
(GeometryEditor covers a subset of kinds). For most real drawing this makes the tools feel
"difficult."
**HIG:** No single HIG widget, but the precedent is a persistent **command/coordinate input
field** (Terminal-like / Xcode's jump bar). It must be **focusable without stealing tool
shortcut keys**, and echo the active prompt.

### G2 — Contextual tool options are buried in the Inspector, and only 4 tools have any
**Evidence:** Tool parameters live in `InspectorView.toolOptionsSection` (fillet radius, chamfer
distances, array rows/cols/spacing/polar, divide count) backed by `CanvasModel.filletRadius`
etc. They only appear when the Inspector pane is open AND that exact tool is active. Most tools
have **no options at all**: Polygon has no side-count field (so you can't pick a hexagon vs a
pentagon), Rectangle has no width/height, Circle/Arc have no radius entry, Offset has no distance,
Rotate/Scale no angle/factor, the dimension tools no text-height/precision. The `LibreCADApp`
comment literally says Array uses "sensible DEFAULTS (Array: 2×3 grid; Divide: 2 parts) — a
config UI is a later wave."
**HIG:** The Mac pattern for "settings for the thing you're doing right now" is a **contextual
options bar** directly under the unified toolbar (cf. the formatting bar in Pages/Keynote, the
options strip in Preview/Photos). It should be **inline, always visible while the tool is active**,
and show only that tool's parameters.

### G3 — Active-tool + current-step feedback is weak and easy to miss
**Evidence:** The active tool is shown three ways, all subtle: a `.tint.opacity(0.25)`
rounded-rect *behind* the toolbar button (`activeBadge` in ContentView), and a top-center
`toolPromptHUD` capsule that only renders `if model.isToolActive && !model.toolStatus.isEmpty`.
The **cursor itself never changes** — there's no crosshair, no per-tool cursor, no "you are in
Line mode" change to the pointer (the canvas uses the default arrow). The prompt capsule is at
the top, far from where the user's eyes are (the cursor). There's no persistent always-on
status bar.
**HIG:** Modes must be **obvious and reversible** (HIG: "Make the current mode obvious"). A
**crosshair cursor** in draw mode + a **persistent bottom status bar** carrying the step prompt
and live coordinates is the CAD-native, HIG-consistent answer (matches how every CAD app and
how the Mac status-bar pattern works).

### G4 — Esc / Undo / Backspace discoverability is poor
**Evidence:** The keymap is rich and correct (Esc cancels+returns to select, Return commits,
⌫ backspaces the run — CADCanvasView.handleKey), but **none of it is surfaced**. The prompt HUD
shows `"Line: Specify next point"` but never `"…  ⮐ commit · ⌫ undo point · esc cancel"`. There's
no Tools-menu item for "Cancel/Finish current command." A new user has no way to learn the
verbs. Edit ▸ Delete exists (LibreCADApp) but the cancel/commit verbs do not.
**HIG:** Discoverability — affordances and keyboard equivalents should be visible. The status
bar (G3) should carry the contextual verb hints; menu items make verbs discoverable + shortcut-labeled.

### G5 — Toolbar is one giant flat strip in `.principal`, with non-standard organization
**Evidence:** `toolbarContent` puts **~30 tool buttons** in a single `ToolbarItemGroup(placement:
.principal)` separated by `Divider()`s. That's Select + 12 draw + 9 modify + 4 edit + 5 dimension
crammed into the window's center title area. Problems vs HIG:
- **`.principal` is the wrong placement** — that slot is for a small centered title accessory, not
  the app's entire tool set. On a narrow window the overflow chevron will hide half the tools.
- **Labels are hidden** (icon-only by default) — many SF Symbols are ambiguous for CAD verbs
  (`angle` is used for BOTH Chamfer and Angular-dimension; `arrow.up.left.and.arrow.down.right`
  for BOTH Scale and Aligned-dimension — duplicate icons).
- **Not customizable** — no `.toolbar(id:)` / no `ToolbarItem`s the user can rearrange or
  show/hide; HIG says let users customize the toolbar.
- **No grouping into menus** — 30 flat buttons vs. the HIG pattern of a few grouped controls
  (e.g. a "Draw" menu-button, a "Modify" menu-button) keeps the bar scannable.
**HIG:** Unified toolbar with a **small set of frequently-used items**, **menu/popover groups**
for the rest, **labels under icons** (or label+icon), and **user-customizable** via the standard
"Customize Toolbar…" affordance. Less-used tools live in the menu bar + ⌘K palette (both already exist).

### G6 — No status bar; coordinate + snap readout floats as a transient chip
**Evidence:** Coordinates show in `coordinateHUD` (bottom-leading chip) only `if model.cursorWorld
!= nil`, and snap kind appends as " · end/center/…". There's no persistent footer, no **relative
(@) coordinate**, no **distance/angle from last point** while drawing, no grid-spacing readout, no
unit suffix (the chip shows raw `x %.3f y %.3f` with no `mm`/`"`). When the mouse leaves the view
the readout vanishes entirely.
**HIG:** A persistent bottom **status bar** is the standard home for document-state telemetry
(cf. Preview's page/zoom bar). CAD apps show absolute X/Y, relative @X/Y, distance/angle, and the
active snap there.

### G7 — No "relative zero" / last-point indicator
**Evidence:** Snapping (`Snapping.snap` via `model.updateSnap`) snaps to geometry + grid, but there
is no concept of a **relative origin** (LibreCAD's "relative zero", the small cross at the last
committed point that @-coordinates are measured from). The coordinate HUD is absolute only.
**HIG:** N/A (CAD-domain), but it's a core precision affordance that pairs with G1's relative input.

### G8 — Selection affordances are thin
**Evidence:** Click toggles selection (`toggleSelection`), and there's a transform gizmo
(GizmoOverlayView) for move/scale/rotate. But there is **no rubber-band / marquee selection**
(drag selects nothing — a drag is always a pan, per `mouseDragged` → `panDrag`), **no window vs
crossing selection**, **no Select All / Deselect All** (not in Edit menu), **no hover highlight**
of the entity under the cursor before clicking, and **no right-click context menu** anywhere on
the canvas.
**HIG:** Direct manipulation expectations — marquee selection, Select All (⌘A), and a context
menu (right-click) are baseline Mac behaviors. ⌘A is conspicuously absent from `LibreCADApp`.

### G9 — No contextual (right-click) menus
**Evidence:** Neither `FlippedMTKView` nor any SwiftUI view defines `menu(for:)` /
`.contextMenu`. Right-clicking the canvas or a layer row does nothing.
**HIG:** Context menus are expected for selections (Cut/Copy/Delete/Properties) and list rows
(rename/delete/duplicate layer). The Layers sidebar footer has +/− buttons but no row context menu.

### G10 — Empty-state / first-run guidance is minimal
**Evidence:** On launch the app loads `dim_sample.dxf` (ContentView.loadSample). With
DocumentGroup landing, a *new blank document* will show an empty canvas with no guidance. The
Inspector's no-selection state is good (`ContentUnavailableView "No Selection"`), but the **canvas
empty state** has none — no "Press L to draw a line, ⌘K for commands" hint.
**HIG:** Provide a helpful empty state. SwiftUI `ContentUnavailableView` is the sanctioned widget;
use it as a canvas overlay when the drawing is empty.

### G11 — Menu completeness gaps + a few non-standard shortcuts
**Evidence (LibreCADApp.swift):**
- **No View menu items** for the sidebar toggle, grid toggle, snap toggles, or zoom in/out
  (only Zoom-to-Fit ⌘0 exists; no ⌘+ / ⌘− zoom).
- **No Edit ▸ Select All (⌘A) / Deselect / Cut / Copy / Paste / Duplicate.** Delete exists.
- **Tool shortcuts are bare single letters** (L, C, A…) handled both by menu `keyboardShortcut`
  and by the canvas `keyDown`. This is a deliberate CAD convention and is fine, but it means the
  letters are unavailable for anything else and **a bare letter can't be typed** (ties into G1).
- The **No `Settings`/per-doc settings** entry point (the whole reason for Part 3).
**HIG:** Standard Edit menu (Select All ⌘A, Duplicate ⌘D — note D currently = Linear Dimension,
collision), standard View menu with zoom + sidebar/inspector toggles.

### G12 — Accessibility / Dynamic Type / VoiceOver are unaddressed
**Evidence:** HUD chips use fixed `.caption`/`.callout` and a custom Metal canvas with no
accessibility elements. Toolbar buttons have `.help(...)` (good — that's the tooltip *and* the
a11y hint) but the **canvas content is invisible to VoiceOver** (no `accessibilityElement`s for
entities), and HUD text doesn't scale with Dynamic Type (monospaced fixed sizes). Dark mode is
handled well (CanvasTheme + adaptive `.ultraThinMaterial` chips — good).
**HIG:** Support Dynamic Type, VoiceOver, and full keyboard access. Canvas a11y is a large effort;
the chrome (toolbar/inspector/menus) is mostly there via standard controls.

### G13 — Window chrome is solid but the toolbar style is default
**Evidence:** `NavigationSplitView` (leading Layers, detail canvas, trailing `.inspector`) is the
modern HIG layout — good. Sidebar + inspector toggles exist (inspector via the trailing toolbar
button; sidebar via the system control). Gaps: no **unified compact toolbar** style chosen
(`.toolbar(.unifiedCompact)` / window `toolbarStyle`), the title uses `navigationDocument` (good,
shows proxy icon), but there's no toolbar **title menu** and no **subtitle** (e.g. units/scale).
**HIG:** Pick a unified toolbar style; consider a subtitle with the document's units/scale.

---

### Top 5 usability gaps (the headline)
1. **G1 — Can't type precise coordinates/lengths/angles while drawing** (no command/coordinate line).
2. **G2 — Tool options are buried/absent** (no contextual options bar; most tools un-parameterizable).
3. **G3 — Active-tool/step feedback is weak** (no crosshair, no persistent status bar; prompt is a faint capsule).
4. **G5 — Toolbar is a 30-button flat strip in the wrong slot** (`.principal`, icon-only, ambiguous/duplicate icons, not customizable).
5. **G8/G9 — Thin selection + no context menus** (no marquee, no ⌘A, no right-click).

---

## Part 2 — Prioritized UX polish plan

Priority key: **P0** = directly fixes "tools are hard to use"; **P1** = strong HIG/usability win;
**P2** = polish. Effort: **S** ≈ ≤1 day, **M** ≈ 2–4 days, **L** ≈ ≥1 week.

**Shared-file hotspots (serialize edits to these; everything else parallelizes):**
- `ContentView.swift` — toolbar, HUD overlays, inspector host, focused-scene-value wiring. *Most contended.*
- `LibreCADApp.swift` — menus + commands + focused values. *Second-most contended.*
- `CADCanvasView.swift` — mouse/key handling, cursor, overlays. *Contended for any input/feedback work.*
- `CanvasModel.swift` — tool/snap/grid state. *Contended for any new tool-state.*
- `Tool.swift` / `ToolKind.swift` (engine) — the frozen contract; `ToolInput` lives here.

> Recommended wave order so hotspots don't thrash: **U1 (input line) → U2 (options bar) →
> U3 (status bar+crosshair)** touch the same 5 files and should run **sequentially** (one builder,
> back-to-back). **U4 (toolbar reorg), U5 (context menus + selection), U6 (menu completeness),
> U7 (empty state), U8 (a11y)** are largely independent and can run in **parallel** once U1–U3 land.

---

### P0 — directly fixes "tools are difficult to use"

#### U1 — Command / coordinate input line  *(the #1 fix — gap G1, G7)*
**Problem:** No way to type exact coordinates / lengths / angles while drawing (G1); no relative
zero (G7).
**HIG-aligned solution:** Add a persistent, single-line **command/coordinate input** at the bottom
of the window (a `TextField` styled like a command line), focusable with a dedicated key (propose
**Space** or the colon `:` — both are LibreCAD-ish and don't collide with tool letters; or a
toolbar field). While a tool is active it accepts:
- absolute `x,y` (e.g. `100,50`),
- relative `@dx,dy` (e.g. `@50,30`), measured from the **relative-zero** (last committed point),
- relative polar `@dist<angle` (e.g. `@100<45`),
- a bare scalar `100` → distance along the current rubber-band direction (the common "type the length" flow).
It echoes the tool's current `status` prompt as placeholder text.
**Engine work (FROZEN-contract change — coordinate with the tools owner):** extend `ToolInput`
(Tool.swift) with a `case value(Vector)` (and/or `case distance(Double)`) so a typed coordinate is
a first-class tool event — every existing draw tool already has a "next point" state that can
consume it. Add a `relativeZero: Vector?` to `CanvasModel` (set on each `.commit`), parse the input
with a new pure `CommandParser` in CADEngine (unit-tested, no GUI). The bottom field maps parsed
input → `model.handleToolInput(.value(p))`.
**Files:** `CADEngine/Tools/Tool.swift` (add `ToolInput` case — append-only, see the contract note),
new `CADEngine/CommandParser.swift` (+ tests), `CanvasModel.swift` (relative zero + a
`submitCommandText(_:)` entry), `ContentView.swift` (the bottom field + focus routing),
`CADCanvasView.swift` (set relative zero on commit; don't steal the field's keystrokes).
**Effort:** **L.** **Parallelizable:** No — it's the keystone; touches all 5 hotspots. Do first.

#### U2 — Contextual tool options bar  *(gap G2)*
**Problem:** Tool parameters are Inspector-only and mostly absent.
**HIG-aligned solution:** A slim **options bar** directly under the toolbar (a `.safeAreaInset(edge:
.top)` on the canvas, or a second toolbar row) that shows ONLY the active tool's parameters, always
visible while that tool runs. Reuse the existing `numberRow`/`intRow` patterns. Migrate the four
existing option sets (fillet/chamfer/array/divide) out of the Inspector into this bar, and ADD the
missing ones: Polygon sides, Rectangle width/height, Circle radius, Arc radius/angles, Offset
distance + side, Rotate angle, Scale factor, dimension text-height/precision, Point style.
**Engine work:** the parameterized tools already expose public `var`s; add the same pattern to
Polygon/Rectangle/Offset/Rotate/Scale where missing (each in its own `Tools/<Name>Tool.swift` — no
shared-file churn). `CanvasModel.applyToolConfig()` is the single place to push options onto a
fresh tool (extend the `switch`).
**Files:** new `LibreCADmacOS/ToolOptionsBar.swift`, `ContentView.swift` (host the inset),
`CanvasModel.swift` (store the new option values + extend `applyToolConfig`), per-tool engine files
(parallel, independent). Remove the Inspector `toolOptionsSection` (InspectorView.swift) once moved.
**Effort:** **M** (the bar + migration) + **S each** for the per-tool param additions.
**Parallelizable:** The bar shell is contended (ContentView/CanvasModel — sequence after U1). The
**per-tool param additions parallelize freely** (separate engine files).

#### U3 — Persistent status bar + crosshair cursor + verb hints  *(gaps G3, G4, G6)*
**Problem:** Mode/step feedback weak; no crosshair; coordinate chip is transient; verbs hidden.
**HIG-aligned solution:**
- Replace the floating `coordinateHUD`/`toolPromptHUD` chips with a **persistent bottom status
  bar** (`.safeAreaInset(edge: .bottom)`): left = active-tool + step prompt + verb hints
  (`⮐ Finish · ⌫ Undo point · esc Cancel`); center = absolute `X / Y` **with unit suffix** (from
  `drawing.drawingUnit.sign`) + relative `@dx,dy` + distance/angle while drawing; right = current
  snap mode + grid spacing + zoom %.
- Add a **crosshair cursor** in any draw/edit tool mode (an `NSCursor` swap in
  `CADCanvasController.activateTool`, or a full-canvas crosshair overlay), reverting to the arrow in
  select mode — makes the mode unmistakable (G3).
- Draw the **relative-zero marker** (small cross at the last committed point) from U1.
**Files:** new `LibreCADmacOS/StatusBar.swift`, `ContentView.swift` (host inset; remove the two
chips), `CADCanvasView.swift` (cursor swap + relative-zero overlay), `CanvasModel.swift` (expose
distance/angle-from-relative-zero derived values for the bar). Unit display reads
`model.drawing.graphicVariables.linearFormat`/`linearPrecision` + `drawingUnit.sign`.
**Effort:** **M.** **Parallelizable:** Partly — status-bar view is independent, but its host
(ContentView) + cursor (CADCanvasView) overlap U1/U2; sequence the ContentView edits.

---

### P1 — strong HIG / usability wins

#### U4 — Toolbar reorganization (labels, grouping, customizable, fixed icons)  *(gap G5, G13)*
**Problem:** 30-button flat strip in `.principal`, icon-only, ambiguous/duplicate icons, not customizable.
**HIG-aligned solution:**
- Move tools out of `.principal` into a proper **customizable toolbar** (`.toolbar(id:)` with
  `ToolbarItem(id:placement:)`, `customizationBehavior`). Keep a **small default set** on the bar
  (Select, Line, Circle, Arc, Rectangle, Move, Trim, the most-used ~8) and group the rest into
  **menu-style toolbar buttons**: a "Draw ▾", "Modify ▾", "Annotate ▾" `Menu` each. Everything
  stays reachable via the Tools menu + ⌘K palette (already complete).
- **Show labels** (`.labelStyle` / let the user choose icon+label via Customize). Pick the
  **unified toolbar style** on the window (`.toolbarStyle(.unified)` or `.unifiedCompact`).
- **Fix duplicate/ambiguous SF Symbols:** Chamfer vs Angular-dim both use `angle`; Scale vs
  Aligned-dim both use `arrow.up.left.and.arrow.down.right`. Assign distinct symbols
  (e.g. Chamfer → `scissors`-adjacent or a custom asset; Aligned-dim → `ruler` variant). Audit all
  ~30 against SF Symbols for CAD clarity.
**Files:** `ContentView.swift` (toolbar rebuild — large, single-owner edit), `CommandPalette.swift`
(keep the `glyph(for:)` map as the single source of truth for symbols; share it with the toolbar so
they can't drift). Possibly extract a `ToolGlyph` helper to CADEngine/LibreCADmacOS so toolbar +
palette + options-bar all read one symbol table.
**Effort:** **M.** **Parallelizable:** No vs other ContentView work (it *is* the ContentView toolbar);
run after U1–U3. The **symbol audit** (a data change to the glyph map) can be prepped in parallel.

#### U5 — Selection upgrades + context menus  *(gaps G8, G9)*
**Problem:** No marquee select, no hover highlight, no ⌘A, no right-click menus.
**HIG-aligned solution:**
- **Rubber-band marquee:** in select mode, a drag that *starts on empty space* draws a selection
  rectangle (window = fully-enclosed, crossing = touched), instead of always panning. (Keep
  space-drag or middle-drag = pan to preserve panning.) Needs a select-mode branch in
  `FlippedMTKView.mouseDragged`/`mouseUp` and a `Selection.hitTest(rect:)` in the engine.
- **Hover highlight:** on `mouseMoved` in select mode, hit-test under the cursor and draw a faint
  highlight on that entity (pre-selection affordance).
- **Canvas context menu** (right-click): with a selection → Cut/Copy/Delete/Duplicate/Properties;
  empty → Paste/Select All/Zoom to Fit. Via SwiftUI `.contextMenu` on the canvas representable
  wrapper or AppKit `menu(for:)`.
- **Layer-row context menu** (LayersSidebar `LayerRow`): Rename/Delete/Duplicate/Set Active/Toggle
  visibility/lock.
**Files:** `CADCanvasView.swift` (marquee + hover + context menu), `CanvasModel.swift`
(rect-select + hover state), engine `Selection`/hit-test (rect query), `LayersSidebar.swift` (row
context menu — independent file), `LibreCADApp.swift` (Edit ▸ Select All ⌘A, Deselect).
**Effort:** **M.** **Parallelizable:** The Layers context menu is fully independent. Canvas marquee
+ hover contend CADCanvasView/CanvasModel with U1/U3 — sequence those.

#### U6 — Menu completeness + standard shortcuts  *(gap G11)*
**Problem:** Missing View menu (zoom in/out, grid/snap/sidebar toggles), Edit ▸ Select All/Cut/
Copy/Paste/Duplicate, and the Settings entry point (Part 3).
**HIG-aligned solution:** Fill out the menu bar:
- **View menu:** Zoom In (⌘+), Zoom Out (⌘−), Actual Size, Zoom to Fit (⌘0, exists), Show/Hide
  Grid, Snap submenu (mirror the Inspector toggles), Show/Hide Sidebar, Show/Hide Inspector
  (⌥⌘I), Show/Hide Command Line (toggles U1's field).
- **Edit menu:** Select All (⌘A), Deselect All, Cut/Copy/Paste/Duplicate (need a clipboard for
  entities — engine work), Delete (exists).
- **Resolve the ⌘D / ⌘A collisions:** today `D` = Linear Dimension, `A` = Arc as *bare canvas*
  keys; the *menu* ⌘-versions (⌘A Select All, ⌘D Duplicate) don't collide with bare letters, so
  this is safe — but document it.
- **Settings:** wire the per-document settings surface (Part 3).
**Files:** `LibreCADApp.swift` (menus + commands — single-owner), `ContentView.swift`
(focused-scene-values for the new actions), `CanvasModel.swift` (selectAll/clipboard),
engine (entity clipboard copy/paste as value records).
**Effort:** **M** (S for the toggles/zoom; the clipboard is the M). **Parallelizable:** Contends
LibreCADApp with U4's menu changes — sequence those two. Zoom-in/out + toggles are quick wins.

---

### P2 — polish

#### U7 — Canvas empty-state guidance  *(gap G10)*
**Problem:** A blank new document (post-DocumentGroup) shows nothing.
**Solution:** A centered `ContentUnavailableView` overlay on the canvas when `model.entityCount ==
0` and no tool is mid-run: "Start drawing — press **L** for a line, or **⌘K** for all commands."
Fades out on first geometry.
**Files:** `ContentView.swift` (one overlay). **Effort:** **S.** **Parallelizable:** Yes (additive
overlay) — but it edits ContentView, so land it in the same pass as another ContentView change to
avoid a separate merge.

#### U8 — Accessibility + Dynamic Type pass  *(gap G12)*
**Problem:** HUD/status text fixed-size; canvas invisible to VoiceOver.
**Solution (chrome first, canvas later):** Make the status bar + options bar honor Dynamic Type
(drop fixed `.caption`/`.callout` where possible, or use `.font(.body)`); add
`accessibilityLabel`s to toolbar menu-buttons; add a VoiceOver rotor over the entity list as a
later effort (large). Keep the existing good dark-mode handling.
**Files:** the new StatusBar/ToolOptionsBar views, `ContentView.swift`, `LayersSidebar.swift`.
**Effort:** **S** (chrome) / **L** (canvas VoiceOver, defer). **Parallelizable:** Yes for the
chrome pass (mostly independent view tweaks).

#### U9 — Window toolbar style + subtitle  *(gap G13)*
**Solution:** Choose `.toolbarStyle(.unified)`; add a window subtitle showing units + scale
(e.g. "mm · 1:1"). Reads `drawing.drawingUnit.sign`.
**Files:** `ContentView.swift` / the document scene. **Effort:** **S.** **Parallelizable:** folds
into U4.

---

### Parallelization summary

| Wave | Effort | Touches | Run with |
|---|---|---|---|
| U1 command/coord line | L | Tool.swift, CommandParser(new), CanvasModel, ContentView, CADCanvasView | **First, alone** |
| U2 options bar | M (+S×N) | ToolOptionsBar(new), ContentView, CanvasModel, per-tool engine files | After U1; **per-tool params parallel** |
| U3 status bar + crosshair | M | StatusBar(new), ContentView, CADCanvasView, CanvasModel | After U2 |
| U4 toolbar reorg | M | ContentView (toolbar), shared glyph map | After U3 (ContentView freed) |
| U5 selection + context menus | M | CADCanvasView, CanvasModel, Selection(engine), LayersSidebar, LibreCADApp | LayersSidebar menu **parallel anytime**; canvas part after U3 |
| U6 menu completeness | M | LibreCADApp, ContentView, CanvasModel, clipboard(engine) | After U4/U5 (LibreCADApp freed); toggles/zoom = quick wins |
| U7 empty state | S | ContentView | fold into a ContentView pass |
| U8 a11y/Dynamic Type | S/L | new bars, ContentView, LayersSidebar | chrome pass parallel; canvas VoiceOver deferred |
| U9 toolbar style/subtitle | S | ContentView/scene | fold into U4 |

---

## Part 3 — Document Settings page spec

### Surface recommendation: **a sheet** (modal `.sheet`), titled "Document Settings", reached from
**File ▸ Document Settings… (⌥⌘,)** and the toolbar/⌘K.

**Why a sheet, not an Inspector tab and not app Settings:**
- These are **per-document** values (units, precision, dim style, paper) — they belong to the
  drawing, not the app. App `Settings`/Preferences is the wrong home (those are global). With the
  DocumentGroup change landing, the natural model is "settings stored on `CADDrawing`, edited per
  window." **(Owner directive explicitly says "a document settings page" — per-document.)**
- An **Inspector tab** competes with the selection/snap/tool-options content already in the
  trailing inspector and would only be visible when the inspector is open; these are
  occasionally-changed, document-scoped values that warrant a **focused, organized, dismissible**
  surface — the HIG use-case for a **sheet** (a self-contained task attached to the document).
- A sheet also matches LibreCAD's own "Drawing Preferences" dialog (familiar to users migrating).
- Use **tabs *inside* the sheet** (`TabView` with `.tabViewStyle(.automatic)` / a segmented
  picker) to organize the sections: **Units · Grid & Snap · Dimensions · Layers · Paper**.
  Bottom-right Cancel / Apply / OK (or live-apply with a "Done" — see Decision D3).

> Note: ⌘, is reserved by HIG for app Settings. Since this is *document* settings, use **⌥⌘,**
> (or put it under File). If the app ever adds true app-level preferences, they get ⌘,.

### Storage model — a `DrawingSettings` value type on `CADDrawing`, backed by `GraphicVariables`

**The engine already has almost everything** — this is mostly *surfacing* existing model state, not
new infrastructure. `CADDrawing.graphicVariables` (`GraphicVariables`, CADDrawing.swift) already
exposes typed, **DXF-round-tripping** accessors:

| Setting | Already in engine? | Backing / DXF header var |
|---|---|---|
| Drawing units | **Yes** — `graphicVariables.unit` / `drawing.drawingUnit` (`DrawingUnit`) | `$INSUNITS` |
| Linear format | **Yes** — `graphicVariables.linearFormat` (`LinearFormat`) | `$LUNITS` |
| Linear precision | **Yes** — `graphicVariables.linearPrecision` | `$LUPREC` |
| Angle format | **Yes** — `graphicVariables.angleFormat` (`AngleFormat`) | `$AUNITS` |
| Angle precision | **Yes** — `graphicVariables.anglePrecision` | `$AUPREC` |
| Angle base | **Yes** — `graphicVariables.anglesBase` (radians) | `$ANGBASE` |
| Angle direction | **Yes** — `graphicVariables.anglesCounterClockwise` | `$ANGDIR` |
| Grid on/off | **Yes** — `graphicVariables.gridOn` (also app-side `model.gridVisible`) | `$GRIDMODE` |
| Paper insertion base | **Yes** — `graphicVariables.paperInsertionBase` | `$PINSBASE` |
| Grid spacing | **App-side only** — `model.preferredGridSpacing` (not yet a header var) | needs `$GRIDUNIT` |
| Snap modes | **App-side only** — `model.snapModes` (`SnapMode`) | LibreCAD-private, persist as app/header var |
| Dim text height / arrow size | **Per-entity only** — `DimData.textHeight`/`.arrowSize` (Entity.swift, default 2.5); reserved `dimStyleProvider` hook on `ResolveContext` (commented) | `$DIMTXT` / `$DIMASZ`; `$DIMSCALE` overall |
| Dim units/precision | **Not yet** (dims format their own text) | `$DIMLUNIT`/`$DIMDEC` |
| Layer defaults | **Partial** — `Layer` has color/lineType/lineWidth (Layer.swift); active layer in `LayerTable` | new-entity defaults are app policy |

**Recommended shape:** introduce a thin `DrawingSettings` **view/facade** over
`graphicVariables` (a computed wrapper, NOT a parallel store) so the sheet binds to typed
properties while the *source of truth stays the DXF-round-tripping `GraphicVariables`*. For the
values without a header var yet (grid spacing, snap modes, dim defaults), **add the corresponding
DXF header vars** (`$GRIDUNIT`, `$DIMTXT`, `$DIMASZ`, `$DIMSCALE`, `$DIMLUNIT`, `$DIMDEC`) via the
same typed-accessor pattern already in `GraphicVariables` so they persist + round-trip too.

```
// CADEngine — facade over the existing graphicVariables (no new store).
public struct DrawingSettings {            // a struct view; reads/writes drawing.graphicVariables
    // Units
    var unit: DrawingUnit                   // $INSUNITS  (exists)
    var linearFormat: LinearFormat          // $LUNITS    (exists)
    var linearPrecision: Int                // $LUPREC    (exists)
    var angleFormat: AngleFormat            // $AUNITS    (exists)
    var anglePrecision: Int                 // $AUPREC    (exists)
    var angleBase: Double                    // $ANGBASE   (exists)
    var anglesCounterClockwise: Bool         // $ANGDIR    (exists)
    // Grid & snap
    var gridOn: Bool                         // $GRIDMODE  (exists)
    var gridSpacing: Double                  // $GRIDUNIT  (ADD)  — replaces app-only preferredGridSpacing
    var snapModes: SnapMode                  // persist (ADD a header/app var)
    // Dimensions (document dim-style defaults)
    var dimTextHeight: Double                // $DIMTXT    (ADD)
    var dimArrowSize: Double                 // $DIMASZ    (ADD)
    var dimScale: Double                     // $DIMSCALE  (ADD)
    var dimLinearPrecision: Int              // $DIMDEC    (ADD)
    // Paper / print
    var paperInsertionBase: Vector           // $PINSBASE  (exists)
    var paperSize: PaperSize                 // ADD (or store via print settings)
    // Layer defaults (new-entity policy)
    var defaultLayerColor: RGBAColor         // app policy → seed new Layer()
    var defaultLineWidth: PenLineWidth
    var defaultLineType: PenLineType
}
```

### Section-by-section spec

**1. Units**
- *Drawing unit* — `Picker` over `DrawingUnit.allCases` (mm/cm/m/inch/foot/… — the enum already
  lists all 21). → `graphicVariables.unit` (`$INSUNITS`).
- *Linear format* — `Picker` over `LinearFormat` (Decimal/Scientific/Engineering/Architectural/
  Fractional). → `$LUNITS`.
- *Linear precision* — Stepper/field 0–8. → `$LUPREC`.
- *Angle format* — `Picker` over `AngleFormat` (Decimal°/DMS/Gradians/Radians/Surveyor's). → `$AUNITS`.
- *Angle precision* — Stepper/field. → `$AUPREC`.
- **Flow-in:** the **status bar (U3)** and the **command-line echo (U1)** format coordinates with
  `unit.sign` + `linearFormat`/`linearPrecision`; the Inspector's angle fields (currently raw
  degrees) should honor `angleFormat`.

**2. Grid & Snap defaults**
- *Show grid* — `Toggle` → `$GRIDMODE` (`graphicVariables.gridOn`) **and** `model.gridVisible`
  (keep the two in sync; the model flag is the live render toggle).
- *Grid spacing* — field (world units) → **new `$GRIDUNIT`**; replaces today's app-only
  `model.preferredGridSpacing` (the renderer's adaptive spacing still applies; this is the user's
  preferred base — see the existing note in CanvasModel that "full renderer adoption is owned by
  the canvas agent").
- *Default snap modes* — the same toggle set the Inspector shows (`SnapModeOption.all`:
  Endpoint/Midpoint/Center/Intersection/On-entity/Grid/Free) → `model.snapModes`, persisted.
- **Flow-in:** `model.updateSnap` already reads `model.snapModes` + the per-event grid spacing;
  this section just makes the *defaults* document-scoped + persistent.

**3. Dimension style (document default)**
- *Text height* — field → **`$DIMTXT`** (seeds new dimension tools' `DimData.textHeight`; today
  it's hard-coded 2.5 in Resolve.swift `dimDefaultTextHeight`).
- *Arrow size* — field → **`$DIMASZ`** (seeds `DimData.arrowSize`; default 2.5).
- *Overall scale* — field → **`$DIMSCALE`** (multiplies text/arrow at draw time;
  pairs with `ResolveContext.annotationScale`, which already exists).
- *Units / precision* — `Picker` + Stepper → **`$DIMLUNIT` / `$DIMDEC`** (how the measurement text
  is formatted; default to the drawing's linear format/precision).
- **Flow-in:** the dimension tools (`LinearDimTool`/`AlignedDimTool`/`RadialDimTool`/
  `AngularDimTool`, ToolKind.swift) should read these as **defaults** when minted (via
  `CanvasModel.applyToolConfig` — extend the `switch`), so a new dimension uses the document style.
  For *existing* dimensions, wire the **reserved `dimStyleProvider` hook** on `ResolveContext`
  (currently commented in Resolve.swift) so dims without an explicit per-entity value fall back to
  the document style at resolve time. **(See Decision D4 — per-entity vs document-default precedence.)**

**4. Layer defaults**
- *Default new-layer color* — `ColorPicker` → app policy; today `LayersSidebar.addLayer` inherits
  the active layer's color. Make the *initial* default a document setting.
- *Default line width / line type* — `Picker`s over `PenLineWidth` / `PenLineType`. Seed new
  entities' pens (`.byLayer` stays the norm; this is the fallback for explicit pens).
- *Active layer* — read-only here (it's set in the sidebar), but show it for orientation.
- **Flow-in:** `LayersSidebar.addLayer` + new-entity creation read these defaults.

**5. Angle base / direction**
- *Angle base* — field (degrees in UI, store radians) → `$ANGBASE` (`anglesBase`).
- *Direction* — segmented `CCW / CW` → `$ANGDIR` (`anglesCounterClockwise`).
- **Flow-in:** angle display in the status bar + Inspector + dimension text.

**6. Paper / print defaults**
- *Paper size* — `Picker` (A4/A3/Letter/…); *orientation* (portrait/landscape); *margins*; *print
  scale* (e.g. 1:1, 1:100). Today `DrawingPrinter`/`DrawingExporter` exist
  (`LibreCADmacOS/Export/`) but use system defaults. Persist these so Print/Export pre-fill.
- *Paper insertion base* — field → `$PINSBASE` (`paperInsertionBase`, exists).
- **Flow-in:** `DrawingPrinter.print` / `DrawingExporter.export` read the persisted paper/scale.

### Persistence + round-trip
- **Already round-tripping:** every `$`-prefixed value above that "exists" today is read/written by
  `GraphicVariables` and (per the DXF bridge) serialized in the header — so units/format/precision/
  angle/grid-on/paper-base persist **for free** the moment the sheet writes them.
- **New header vars** (`$GRIDUNIT`, `$DIMTXT`, `$DIMASZ`, `$DIMSCALE`, `$DIMLUNIT`, `$DIMDEC`):
  add typed accessors to `GraphicVariables` (same one-line pattern) and ensure the DXF reader/writer
  (`DxfBridge` / `DXFReader`) carry them. These are standard AutoCAD header vars, so they round-trip
  to/from real DXF.
- **App-only values** (snap modes) that have no clean DXF header var: persist as a LibreCAD-private
  header var (LibreCAD stores some app state as custom `$`-vars) or in the document's user-data —
  **(Decision D5)**.
- **Undo:** the sheet's edits should be undoable. `graphicVariables` is a plain `var` on the
  `@Observable CADDrawing` (no dedicated undoable mutator yet — same situation as `textStyles`).
  Mirror the **`registerTextStylesUndo` value-snapshot pattern** already in CanvasModel.swift:
  snapshot `graphicVariables` before applying, register an undo that restores it. **(Decision D3** —
  live-apply vs OK/Cancel governs whether each field is one undo step or the whole sheet is one.)

### Wiring summary (how a setting flows to behavior)
```
Settings sheet (binds DrawingSettings facade)
   → writes drawing.graphicVariables.<var>      (source of truth; DXF round-trips)
   → DXF read/write carries the header var       (persist)
   → CanvasModel reads for: snap defaults, grid spacing, relative/abs coordinate formatting
   → applyToolConfig() seeds new dimension tools with dim text height / arrow / scale
   → ResolveContext.annotationScale + (wired) dimStyleProvider apply doc dim style at resolve time
   → StatusBar (U3) + CommandLine (U1) format X/Y/angle per unit + linear/angle format/precision
   → DrawingPrinter/DrawingExporter read paper/scale defaults
```

---

## Part 4 — Decision points (owner is away — recommended defaults logged)

> Copy these into `decision-log.md`. Each picks the most HIG-aligned / least-risky / most-reversible
> option per the V4 autonomy guardrails (D-V4.3).

- **D1 — Command-line focus key.** How do you focus the command/coordinate input (U1) without
  colliding with bare tool letters (which the canvas consumes)?
  **Recommended default:** make the bottom **command field always present** and focus it on
  **Space** (LibreCAD-familiar) *and* on click; while the field has focus, keystrokes go to it (not
  tool activation), and Esc returns focus to the canvas. Add View ▸ Show/Hide Command Line to make
  it discoverable. *Reversible:* it's an additive field + one focus rule.

- **D2 — Drag-in-empty-space = marquee vs pan.** Today any left-drag pans (CADCanvasView.mouseDragged).
  Adding marquee (U5) repurposes empty-space drag.
  **Recommended default:** in **select mode**, left-drag on **empty space = marquee select**
  (window/crossing by direction); left-drag **on a selected entity = move**; **Space-drag or
  middle-drag = pan** (so panning is preserved). In **draw/edit mode**, drag still pans. *This
  matches Mac direct-manipulation + every CAD app.*

- **D3 — Settings sheet apply model: live vs OK/Cancel.**
  **Recommended default:** **live-apply** (each control writes immediately, like macOS System
  Settings and the existing Inspector), with the sheet dismissed by **Done**. Each field is one
  undoable step (value-snapshot pattern). Rationale: matches the rest of this app's Inspector/
  sidebar (which all live-apply + undo), and is the modern macOS pattern. *If the owner prefers a
  transactional dialog (Cancel discards), switch to a draft copy + Apply — more work, less
  consistent with the app.*

- **D4 — Dimension style precedence: per-entity vs document default.** `DimData` carries per-entity
  `textHeight`/`arrowSize`; the doc settings add a document default.
  **Recommended default:** **per-entity wins when set (>0); document default fills in otherwise.**
  Implement by wiring the reserved `dimStyleProvider` hook so a dimension with default/zero values
  resolves against the document style; new dimensions are *born* with the document default copied in
  (so they're self-describing in DXF). *Reversible:* it's resolve-time fallback logic.

- **D5 — Where to persist app-only state (snap modes) that has no standard DXF header var.**
  **Recommended default:** persist snap modes as a **LibreCAD-private `$`-header var** (e.g.
  `$LC_SNAPMODE`) via the same `GraphicVariables` typed-accessor pattern, so it round-trips with the
  document and stays per-document. *Falls back gracefully:* other CAD apps ignore unknown header
  vars. *Alternative (rejected):* a sidecar/UserDefaults — breaks "settings travel with the document."

- **D6 — Toolbar default set + customization.** Which ~8 tools stay on the bar by default (U4)?
  **Recommended default:** Select, Line, Circle, Arc, Rectangle, Move, Trim, Linear-Dimension —
  plus the Draw▾ / Modify▾ / Annotate▾ group menus, the Inspector toggle, and the command palette.
  Everything else reachable via menus + ⌘K. Users can add more via Customize Toolbar. *Reversible:*
  it's the default item set; customization makes it user-overridable.

- **D7 — `ToolInput` contract extension.** U1 needs a typed-coordinate event; `Tool.swift` is the
  "FROZEN contract."
  **Recommended default:** extend it **append-only** with `case value(Vector)` (and optionally
  `case distance(Double)`), following the file's own collision/append guidance. Every existing tool
  ignores unknown inputs safely (their `handle` switches on the cases they care about), so the
  addition is backward-compatible; add the consuming arms tool-by-tool. *Coordinate with the tools
  owner before landing the contract change.*

- **D8 — Settings entry point + shortcut.** ⌘, is reserved for app Settings (none exists yet).
  **Recommended default:** **File ▸ Document Settings… at ⌥⌘,** (and in ⌘K). Reserve plain ⌘, for a
  future app-level Preferences. *Reversible:* a single menu item.

---

## Appendix — What already exists (don't rebuild)
- **Dark mode:** handled well — `CanvasTheme` swaps clear color + overlay palette on appearance
  change (CADCanvasView.viewDidChangeEffectiveAppearance); HUD chips use `.ultraThinMaterial` +
  semantic colors so they invert correctly. Keep.
- **Command palette (⌘K):** complete — fuzzy `CommandMatcher`, every tool + app action
  (CommandPalette.swift). The new options-bar/toolbar should **share its `glyph(for:)` symbol map**.
- **Inspector:** good entity property editing + multi-select + font/style + snap toggles
  (InspectorView/InspectorEditors). Tool options will **move out** of it into the options bar (U2).
- **Layers sidebar:** live, undoable, with visibility/lock/color/rename (LayersSidebar). Add a
  row context menu (U5); Blocks is a read-only stub (out of scope here).
- **Undo:** the window owns an `UndoManager` injected into the drawing; value-snapshot pattern for
  tables (`registerTextStylesUndo`) is the template for the settings-undo (D3).
- **Units/format model:** `DrawingUnit`/`LinearFormat`/`AngleFormat`/`GraphicVariables` already
  exist and round-trip DXF — the settings page is mostly *surfacing* this, not building it.
