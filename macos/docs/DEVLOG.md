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

- [2026-06-11 15:00] 🔨 scaffold-builder (general-purpose, worktree) — Phase 0 spine. Outcome: DONE/GREEN. ALL 23 libdxfrw .cpp compiled clean under c++20 (biggest risk retired, no patches); swift build green 0 warnings; swift test 13/13 (9 Vector + 4 DXF); dim_sample.dxf = 103 entities via C-ABI bridge; .app assembles + ad-hoc signs; binary runs >3s no crash (GUI unverifiable headless). Pure C-ABI (not Swift C++ interop); runtime-compiled Metal shaders; world-coord geom + matrix uniform. FLAG for 0.5: CADDocument uses nonisolated(unsafe) placeholder → needs real actor-isolated model. Receipts: ws/scaffold @ fae5e6350, 243d2c78a (17 files, +8761). Merge verified CLEAN (zero overlap w/ native doc changes).
- [2026-06-11 15:40] 🔍 scaffold-reviewer (general-purpose) — review ws/scaffold before merge. Outcome: DONE — verdict APPROVE w/ follow-ups (no must-fix; no races/UB/ADR violations; GPLv2 headers OK; C-ABI exception-safe; Vector faithful; Metal canvas has ADR-003 seam). Phase-0.5 punch list: (1) swift-tools 6.0→6.2 + .swiftLanguageMode(.v6) pin; (2) drop nonisolated(unsafe) CADDocument → real @MainActor/actor model; (3) lc_dxf_last_error global → out-param/thread_local + "one shared engine actor" rule; (4) canvas line is clip-space → wire world→clip + f32(world-renderOrigin) floating-origin path. Receipts: inline.
- [2026-06-11 16:00] 📋 coordinator — MERGED ws/scaffold → native-macos (--no-ff, clean, zero overlap; ADR.md preserved). Verified merged tree: swift build green (7.5s) + swift test 13/13. Phase 0 DONE. Receipts: merge commit on native-macos.
- [2026-06-11 15:02] 📋 coordinator — wrote macos/docs/PLAN.md (synthesized phased roadmap from all 5 investigations).
- [2026-06-11 15:02] 🧐 plan-critic (general-purpose) — pressure-test PLAN.md architecture+roadmap before heavy fan-out. Outcome: DONE — verdict REVISE. Critical: (1) don't fan out until Phase 0 actually merged; (2) entity-model contradiction (final-class containers vs value+resolve) — pick value+resolve; (3) snapshot-undo false for reference graph — follows from (2); (4) CAD text uses .lff stroke fonts not SDF/system → LFF is P1. Important: (5) render+interaction are serial deps of tool fan-out → consolidate into one gate; (6) f64/f32 floating-origin is a frozen buffer contract not an optimization; (7) mine rs_filterdxfrw.cpp as required bridge ref; (8) hatch/dim/blocks span all layers → single owner. Receipts: inline.
- [2026-06-11 15:20] 📋 coordinator — acted on REVISE: wrote macos/docs/ADR.md (ADR-001 value+resolve entity model; ADR-002 COW snapshot undo; ADR-003 f64/f32 floating-origin contract; ADR-004 .lff stroke-font text + sequencing contract). Revised PLAN.md (entity/undo/text/precision lines; added Phase 0.5 ADR-freeze; consolidated render+interaction gate; hatch/dim/blocks single owner). Verified: 92 .lff fonts in librecad/support/fonts/; math tests at librecad/src/lib/math/tests/; ws/scaffold branch live.

- [2026-06-11 16:10] 📋 coordinator — cleaned merged worktree + branches (only main checkout remains).
- [2026-06-11 16:12] 🔨 foundation-builder (general-purpose, worktree) — Phase 0.5 frozen type contract. Outcome: DONE/GREEN. Built EntityRecord{id,layer,pen,flags,kind}+enum EntityKind(point/line/circle/arc/polyline) value model; ResolvedGeometry{polylines,fills}+resolve(ctx)+boundingBox()+sagitta tessellation (ADR-001); Pen byLayer/byBlock; @MainActor @Observable CADDrawing + UndoManager value-snapshot add/remove/replace (ADR-002, dropped nonisolated(unsafe)→MainActor.assumeIsolated); bridge LCStatus+out-param ABI (no global); MetalCanvasView world→clip ortho + f32(world-renderOrigin) floating-origin path rendering resolved line+circle (ADR-003). swift build 0 warnings; 41/41 tests (undo/redo, resolve, bbox, bridge-status, angle). No ADR deviations (Vector stays 3D; LayerID=String — both allowed). Receipts: ws/foundation @ 9a321b87f,da8c5d264,44f868076,a8ba970ea. Merge = clean fast-forward.
- [2026-06-11 16:40] 🔍 foundation-reviewer (general-purpose) — gate ws/foundation before merge; emphasis FORWARD-FIT (can EntityKind/resolve carry Insert/Dimension/Hatch/.lff-Text without non-additive redesign?) + undo correctness + Swift6 concurrency + render seam + C ABI. Outcome: running. Receipts: verdict inline (pending).

## Environment gotchas (recorded)
- `git push` / `brew install` / any network op: sandbox blocks them ("port 22: Operation not permitted") → run with sandbox disabled.
- `swift build` / `swift test`: need `--disable-sandbox` in this env (nested-sandbox error otherwise).
- Don't name the C++ interop target `CxxShim` (collides with toolchain `libcxxshim`) → use `DxfBridge`.
- [2026-06-11 14:31] 🔬 metal-perf-research (general-purpose) — high-perf Metal 2D CAD rendering architecture. Outcome: DONE (caveat: live web retrieval gated this session → leaned on canonical refs, flagged for re-verify before renderer build). Findings: instanced screen-space line quads (constant px width + analytic AA) for lines/polylines/curves; CPU sagitta tessellation + zoom-bucketed LOD for arcs/ellipses/splines; earcut triangulation for fills/hatches; SDF glyph atlas for text/dims; world-coord persistent .shared MTLBuffers + single world→clip float4x4 uniform (pan=translate, zoom=scale, never rebuild buffers); loose quadtree shared by viewport culling + CPU snapping; on-demand draw (enableSetNeedsDisplay+isPaused, continuous only during gestures) + triple-buffered uniforms; CPU hit-test/snap vs exact RS_Information kernels (no GPU readback). Budget ~6ms of 8.3ms/frame @120Hz; single-entity edit <1ms via dirty-region patching. Receipts: macos/docs/rendering-performance.md.
- [2026-06-11 14:13] 🔬 dxf-bridge-planner (general-purpose) — plan Swift/C++ interop bridge to libdxfrw. Outcome: DONE. Findings: libdxfrw is std-only (no Qt/deps), C++14→build c++20; bridge = C ABI shim in ObjC++/C++ (Swift can't subclass pure-virtual DRW_Interface); 23 .cpp files; ref impl rs_filterdxfrw.cpp; DWG-write R2000-only; GPLv2-or-later (static link ⇒ GPL derivative). Receipts: macos/docs/dxf-bridge-plan.md.
- [2026-06-11 14:13] 🔬 scaffold-researcher (general-purpose) — macOS 26 scaffold (DocumentGroup+Metal+C++ interop). Outcome: DONE (validated vs live SDK + working C++ interop build probe). Findings: XcodeGen (app, brew v2.45.4) + SwiftPM (engine: DxfBridge C++ module + CADEngine Swift facade + tests); ReferenceFileDocument + DocumentGroup(free UndoManager); exported UTIs org.librecad.dxf/.dwg; MTKView via NSViewRepresentable (enableSetNeedsDisplay+isPaused, matrix uniform for zoom/pan); interop via .interoperabilityMode(.Cxx) + C++ types non-Sendable → confine behind CADEngine actor. GOTCHAS: `swift build --disable-sandbox` here; `brew install` outside sandbox; don't name C++ target "CxxShim". Receipts: macos/docs/scaffold-plan.md.
