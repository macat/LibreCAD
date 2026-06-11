# LibreCAD Native macOS — Dev Log

A native macOS reimplementation of LibreCAD in Swift, built on the latest macOS APIs.
Mac-only; no cross-platform concern. Work happens on the `native-macos` git branch and is
committed/pushed incrementally after testing.

Upstream LibreCAD (C++/Qt, ~400K LOC) remains in the repo as the **reference + algorithm source**
and as the home of `libraries/libdxfrw` (DXF/DWG), which we bridge via Swift/C++ interop.

---

## Locked decisions (2026-06-11)

| Decision | Choice | Rationale |
|---|---|---|
| First milestone | **Foundation first, then broad tool parity** | "Broad parity" is the destination; the spine (canvas + model + file bridge) must exist before tools fan out in parallel |
| Canvas rendering | **Metal (MetalKit/MTKView) from the start** | Highest performance ceiling; large drawings stay smooth |
| DXF/DWG I/O | **Bridge C++ `libdxfrw` via Swift/C++ interop** | Reuse battle-tested DXF *and* DWG read/write; engine stays pure-Swift |
| UI direction | **Modern Mac-native reimagining** | Unified toolbar, SwiftUI inspectors, sidebar, native menus/shortcuts, dark mode; familiar CAD concepts, fresh UX |
| App model | SwiftUI `DocumentGroup` (document-based) | Native open/save/recents/autosave/versions for free |
| Source control | git, branch `native-macos`, commit after testing | Per user; this is NOT fbsource — no Sapling/Phabricator/internal tooling |

## Environment (verified)
- macOS 26.5.1 · Xcode 26.2 · Swift 6.2.3 · Apple Silicon (arm64) · Homebrew at /opt/homebrew
- SDK target: macosx26.0 → "latest macOS APIs" = macOS 26 SDK

## Repo facts
- Upstream LibreCAD clone at repo root; fork remote `git@github.com:macat/LibreCAD.git`
- CAD engine to port: `librecad/src/lib/` (engine, math, creation, modification, fileio, filters, gui, printing, information, actions)
- C++ libs to bridge: `libraries/libdxfrw` (DXF/DWG), `libraries/jwwlib` (JWW), `libraries/muparser` (cmd-line math)
- New Swift app lives under `macos/`

---

## Dispatch log

- [2026-06-11 14:12] 📋 coordinator — created branch `native-macos`, `macos/docs/`. Outcome: ok.
- [2026-06-11 14:13] 🔬 engine-mapper (general-purpose) — map LibreCAD CAD engine → Swift-port reference. Outcome: DONE. Findings: RS_Entity → atomic(struct) vs container(class); *Data POD structs map 1:1; RS_Vector is 3D+valid (pervasive optional); RS2:: enums; RS_Graphic owns Layer/Block/VarDict; headless LC_GraphicViewport transform (Qt-separable); tools = RS_ActionInterface state machine + RS_Snapper. Design calls: value-struct atomics + final-class containers; snapshot/UndoManager undo; decouple snapping; port math kernels first w/ existing tests. Receipts: macos/docs/engine-architecture.md.
- [2026-06-11 14:30] 📋 coordinator — added CONVENTIONS.md (user's 7 directives: parallelize, worktrees, review-all, test-before-commit, incremental commits, docs-in-repo, perf-first).
- [2026-06-11 14:31] 🔬 ui-inventory (general-purpose) — full LibreCAD tool/command/UI inventory + P0/P1/P2 + modern-Mac take. Outcome: DONE. Findings: ~220 live actions (RS2::ActionType in rs.h); ~110 draw tools, ~30 modify, ~14 select, 12 snap+4 restrictions, ~21 layer ops, ~13 block, ~95 .ui dialogs. P0 wave: Line/Polyline/Rect/Circle/Arc/Point + Move/Copy/Rotate/Scale/Trim/Offset/Delete/Props + select(single/window/all/none) + snap(free/grid/endpoint/center/on-entity)+ortho + coord HUD/typed entry + Layers panel + drawing-opts + zoom/pan/grid + File(new/open/save) + DXF r/w + Inspector. UX wins: collapse 110 draw variants→~12 tools+variant pickers; modal dialogs+floating option-toolbars→one Inspector+on-canvas gizmos; snapping/cmdline→toolbar popover+⌘K palette+at-cursor @dx,dy. Receipts: macos/docs/feature-inventory.md.

## Environment gotchas (recorded)
- `git push` / `brew install` / any network op: sandbox blocks them ("port 22: Operation not permitted") → run with sandbox disabled.
- `swift build` / `swift test`: need `--disable-sandbox` in this env (nested-sandbox error otherwise).
- Don't name the C++ interop target `CxxShim` (collides with toolchain `libcxxshim`) → use `DxfBridge`.
- [2026-06-11 14:31] 🔬 metal-perf-research (general-purpose) — high-perf Metal 2D CAD rendering architecture. Outcome: running. Receipts: macos/docs/rendering-performance.md (pending).
- [2026-06-11 14:13] 🔬 dxf-bridge-planner (general-purpose) — plan Swift/C++ interop bridge to libdxfrw. Outcome: DONE. Findings: libdxfrw is std-only (no Qt/deps), C++14→build c++20; bridge = C ABI shim in ObjC++/C++ (Swift can't subclass pure-virtual DRW_Interface); 23 .cpp files; ref impl rs_filterdxfrw.cpp; DWG-write R2000-only; GPLv2-or-later (static link ⇒ GPL derivative). Receipts: macos/docs/dxf-bridge-plan.md.
- [2026-06-11 14:13] 🔬 scaffold-researcher (general-purpose) — macOS 26 scaffold (DocumentGroup+Metal+C++ interop). Outcome: DONE (validated vs live SDK + working C++ interop build probe). Findings: XcodeGen (app, brew v2.45.4) + SwiftPM (engine: DxfBridge C++ module + CADEngine Swift facade + tests); ReferenceFileDocument + DocumentGroup(free UndoManager); exported UTIs org.librecad.dxf/.dwg; MTKView via NSViewRepresentable (enableSetNeedsDisplay+isPaused, matrix uniform for zoom/pan); interop via .interoperabilityMode(.Cxx) + C++ types non-Sendable → confine behind CADEngine actor. GOTCHAS: `swift build --disable-sandbox` here; `brew install` outside sandbox; don't name C++ target "CxxShim". Receipts: macos/docs/scaffold-plan.md.
