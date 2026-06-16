# Backlog Wave Plan — UI-redesign §6 (#1–#8)

Engine/state-first phase, then region-partitioned parallel UI wire-waves. **Every file has exactly
one owner per phase** (verified disjoint by a critic pass). Worktrees branch off `native-macos`
(`git reset --hard native-macos`); build UNWIRED; serial gate; merge by hash.

_Produced by the `backlog-wave-plan` workflow (5 investigators → synthesis → disjointness critic),
2026-06-16. Critic verdict: APPROVE WITH FIXES (3 fixes applied below)._

## Critic fixes applied
1. **W4 #7 canvas hook made explicit** — W4 calls `model.polarConstrained` next to `orthoConstrained`
   at `CADCanvasView.swift:841` (move) and `:899` (click), else POLAR is a dead toggle.
2. **W3 folded into W1** — the App-side `@FocusedValue` (#2) depends on key structs defined alongside
   the ContentView publishers; one wave owns `ContentView.swift` + `LibreCADApp.swift` to avoid the
   cross-wave compile dep. (Phase 1 is now W1, W2, W4, W5.)
3. Reduced scopes (critic-approved): POLAR fixed 15° + ortho/polar mutually exclusive + no tracking
   ray/config UI; ~10–12 programmatic symbols; Page Setup editor deferred (Rename/Delete/Duplicate ship).

---

## Phase 0 — engine/state-first (UNWIRED). P0-A/B/C/E parallel; P0-D after A,B,E.

| Agent | Owned files | Adds (backlog#) |
|---|---|---|
| **P0-A** | `CADEngine/CoordinateDisplayMode.swift` (new), `CADEngine/CoordinateFormatter.swift`, `…Tests/CoordinateDisplayModeTests.swift` (new) | `enum CoordinateDisplayMode{absolute,relative,polar}`+cycle; engine angle formatter + `polarPair` "dist<angle" (#5) |
| **P0-B** | `CADEngine/PolarConstraint.swift` (new), `…Tests/PolarConstraintTests.swift` (new) | pure `PolarConstraint.constrain(point,relativeTo:,incrementRadians:)` cloned from `OrthoConstraint`. NO SnapKind/SnapMode case (#7) |
| **P0-C** | `macos/assets/symbols/` (new ~10-12 `.dxf`), `CADBench/` (offline generator), `CADEngine/BlockLibrary.swift` (+`bundledSymbolsDirectory()`), `macos/scripts/make-app.sh` (symbols copy block), `…Tests/BlockLibraryTests.swift` | generate symbols via `BlockExport.writeRecords` (serial); `Bundle.main.resourceURL` loader (NOT Bundle.module) (#6) |
| **P0-E** | `CADEngine/CADDrawing.swift`, `…Tests/PaperSpaceModelTests.swift` | `duplicateLayout(name:)` (deep-copy incl. viewports + re-tag entities' layoutName, 1 undo group), `setLayoutPage(name:_:)` via `mutateLayouts`. No EntityKind case (#4c) |
| **P0-D** (after A,B,E) | `CADEngine`/`LibreCADmacOS/Canvas/CanvasModel.swift`, **extend** existing `…Tests/StatusBarToggleTests.swift` (via existing `_SharedCanvasModel` symlink) | `coordinateDisplayMode`+`cycleCoordinateDisplayMode()` (reworks `cursorReadout`); `polarEnabled`+`polarAngleIncrement`(15°)+`togglePolar()`+`polarConstrained(_:shiftHeld:)` (ortho/polar mutually exclusive); layout wrappers `renameLayout/deleteLayout/duplicateLayout/setLayoutPage` w/ `setActiveSpace` fixup. All UNWIRED (#4c,#5,#7) |

---

## Phase 1 — parallel UI wire-waves (after all Phase 0 merged + green). W1,W2,W4,W5 fully parallel.

| Wave | Owned files | Delivers (backlog#) |
|---|---|---|
| **W1** (toolbar + App) | `ContentView.swift`, `LibreCADApp.swift`, `…Tests/ToolKindWiringTests.swift` (if flyout static added) | #1 toolbar flyouts (Line▸{ray,xline}, Rect▸{polygon} via `activate`; Circle/Arc set `circleConstructionMode`/`arcMode` then `activate`); #2 Match Properties (FocusedValueKeys + publishers + toolbar `eyedropper` button + App Cmd-Shift-C/V chords); #4a call-site `docStatus:` arg; #4c tab `.contextMenu` Rename/Delete/Duplicate/Page-Setup(stub→Document Settings) → P0-D wrappers; #6 canvas `.dropDestination(PartLibraryDragItem)` → `insertBlock` (mind `isFlipped`); #8 View-menu "Show Grid" + F7 key-equivalent (menu half) |
| **W2** (status bar) | `StatusBar.swift`, `Sidebar/SnapGridPopover.swift` (new) | #7 OSNAP chip (`objectSnapEnabled`) + POLAR chip (`polarEnabled`/`togglePolar`); #3 gear `.popover` (SnapGridPopover: object-snap master + per-mode grid + show-grid + grid-spacing, View-layer only); #4a `docStatus` segment (relocated "New drawing (mm)"); #5 coord segment → `Button{cycleCoordinateDisplayMode}` + a11y label |
| **W4** (canvas overlay) | `Canvas/CADCanvasView.swift`, `Canvas/UCSAxisOverlay.swift` (new) | #4b UCS axis L-gizmo at world origin (clone `CrosshairOverlayView`: isFlipped, hitTest→nil, `worldToScreen(0,0)`, refresh in `redraw`); #7 **canvas hook: `model.polarConstrained` next to `orthoConstrained` at :841/:899**; #8 responder half (`@objc toggleGridAction`, keyCode-98 branch, `validateUserInterfaceItem` checkmark) |
| **W5** (parts library) | `Sidebar/PartsLibraryPanel.swift`, `App/Info.plist` | #6 default panel source = `bundledSymbolsDirectory()` (non-empty first launch via existing import path) + optional Finder URL drop; UTI `UTExportedTypeDeclaration` for the part-library drag item |

**Cross-region joint deliveries (whole only after both merge):** #2=W1; #4a=W1+W2; #4c=P0-{D,E}+W1; #5=P0-{A,D}+W2; #6=P0-C+W1+W5; #7=P0-{B,D}+W2(chip)+W4(hook); #8=W1(menu)+W4(responder).

**`InspectorView.swift` is touched by NO wave** — keep its Match-Props + Snap&Grid sections (W2's popover duplicates the bindings to avoid contention; a later cleanup can remove the inspector dupes).

## Traps (all verified in source)
- No `EntityKind`/`ToolKind`/`SnapKind`/`SnapMode` case anywhere (variants resolve to existing kinds; polar is a constraint; viewports live in `Layout.viewports`).
- Never open the `LineInstance`/`Shaders.swift` byte-match or `LineRenderer` overlay (UCS gizmo is an AppKit NSView overlay, not Metal).
- `CADEngine` stays app-free (P0-A/B/C/E pure Foundation; model state in P0-D/app).
- Headless-modal: all sheets/popovers/context-menus View-layer only; gear popover = toggles/number fields (no NSOpenPanel).
- P0-D **extends** the existing `StatusBarToggleTests.swift` via the existing `_SharedCanvasModel` symlink (don't create a 2nd); `--no-parallel`.
- #6 bundling: `Bundle.main.resourceURL` + make-app copy (NOT Bundle.module); generator serial (libdxfrw non-reentrant); commit `.dxf` at author-time.
- #6 drop: map through flipped/AppKit coords before `viewport.screenToWorld`.
- #4c: `Page Setup ≠` Document-Settings Paper tab (doc-wide ≠ per-layout `Layout.page`); use `setLayoutPage` or stub.

## Critical path
P0-{A,B,C,E} (parallel) → P0-D → gate → {W1,W2,W4,W5} (parallel) → gate → `.app`.
