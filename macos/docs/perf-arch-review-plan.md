# Perf & Architecture Deep Review — native macOS port

**Date:** 2026-08-06 · **Branch:** `native-macos` @ `ecc62f1e5` · **Scope:** `macos/engine/` (96k lines, Swift 6, macOS 26) · **Gate:** `swift build/test --disable-sandbox --no-parallel` (4071 tests)

## 1. TL;DR

Engine is value-type, `CADEngine ⊥ app`, instanced-line Metal + loose quadtree — correct foundations. At 1M synthetic entities the hot path is **already under budget**: cull 0.8ms, line rebuild 1.25ms, hitTest 0.8ms, resolveAll 233ms (perf-report §2). Perf is not burning, architecture is: `CanvasModel` 8449 lines + `ContentView` 3021 lines are MainActor god objects, `EntityKind` is switched in 85 places, and `Resolve`/`ConstraintSolver` have no incremental cache. Next gains come from **decomposing the god objects, caching resolve, and using the quadtree for snap/solver** — not from micro-optimizing the renderer.

---

## 2. Performance — where time goes

### Baseline (CADBench, release, fixed seed 0x1BCDEF, 1400×900 typical viewport ≈2% world)

| N | quadtree build | cull | visible | hitTest | nearest | line rebuild | instances | resolveAll | RSS |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
|100k|14.5ms|0.07ms|90|0.08ms|0.15ms|0.11ms|2.4k|23.7ms|93 MiB|
|500k|90ms|0.41ms|441|0.40ms|0.77ms|0.60ms|10k|120ms|393 MiB|
|1M|197ms|0.82ms|902|0.80ms|1.45ms|1.25ms|20k|233ms|766 MiB|
~0.23µs/entity `resolveAll`, linear. Pan/zoom is matrix-only (no rebuild).

### Hot spots (confirmed, file:line)

1. **Resolve — no memoization** [`Resolve.swift:1` 3151 lines]. Every `lineRebuild` re-calls `resolve()` for each visible entity (tessellates arcs/ellipses/splines with sagitta, triangulates hatch). No per-entity cache; `resolveAll` at 1M is 233ms. Tessellated point arrays are transient allocs. Text: `TextShaper` builds CoreText glyph paths per `resolve` — no atlas, SDF still CPU.
2. **Quadtree — correct but rebuild-heavy** [`Spatial/Quadtree.swift:1`]. Loose, 2× looseness, auto-grows. Per-entity update is cheap, but `undo()`/`redo()` in `CanvasModel.swift:406` **rebuilds whole tree** (comment: “undo closures don't touch quadtree”). At 1M, a ⌘Z = 197ms hitch. Snap's `nearbyEntities` fallback in `CanvasModel:makeToolContext()` captures a CoW snapshot and linear-scans `snapshot.filter { HitTesting.worldDistance ≤ tol }` — O(N) when the closure is used (editing tools), not quadtree-accelerated. Constraint `nearestExistingLineEndpoint` also linear (perf TODO in `ConstraintAuto`).
3. **Constraint solver** [`ConstraintSolver.swift:1` 990 lines]. LM with **dense numeric Jacobian** (finite diff, O(D²) per iter, D = free DOFs). Under-constrained case adds Tikhonov regularizer, still dense. No sparsity, no analytic Jacobian, no warm-start, no incremental re-solve (touch-whole-component). 4-point rectangle (8 DOFs, ~5 residuals) is fine; 10k-line network will be heavy.
4. **Metal upload** [`Renderer/RendererGeometry.swift:1` 838 lines, `LineRenderer.swift` 1229]. Rebuild packs `LineInstance` (p0/p1 Float offset from `renderOrigin`, color, halfWidthPx, dash) + `FilledVertex` per visible. No dirty-set: any model change rebuilds **all visible** instances (902 at 1M — fine, but at 100k visible it scales). `MTLBuffer` memcpy is the only omitted step in CADBench — at 20k instances (~1.2 MiB) the memcpy + `encode` is ~0.2ms but grows with visible count.
5. **SwiftUI — ContentView / CanvasModel god objects** [`ContentView.swift` 3021, `CanvasModel.swift` 8449]. Single `ContentView.body` decomposition risk (historical type-check blow-up), single `@MainActor` `CanvasModel` holds `CADDrawing` + `Viewport` + `Quadtree` + `Selection` + `SnapResult` + `Tool` + `Constraint` + layout. Observation churn on any `@Observable` field re-evaluates large bodies. No `View` identity stability (no `EquatableView`), no `task` cancellation on tool switch.
6. **DxfBridge** [`DxfBridge/lcdxf.cpp:1` ~2700 lines]. Intern strings via `std::deque` (good), but per-entity `fillCommon` copies, per-DXF handle alloc string, no streaming — `DXFReader` reads entire file via `libdxfrw` then converts to `LCEntity` array → second copy into `CADDrawing`. No incremental save (whole file rewritten).
7. **Undo** [`CADDrawing.swift:1` 2616 lines]. Value-snapshot UndoManager groups (correct), but snapshot is **whole `entities` array** (CoW — cheap until mutated, then O(N) copy). `LayerTable`/`TextStyleTable` manual snapshot in `CanvasModel:registerTextStylesUndo` — extra alloc.

### Perf opportunities (impact × effort)

| # | Idea | Impact | Effort | Files |
|---|---:|---|---:|---|
| P1 | **Per-entity resolve cache** (hash of `kind+pen+transform`, invalidated on `replace`, used by `lineRebuild` and hit-test) | -80% resolve on rebuild | S | `Resolve.swift`, `CADDrawing`, `RendererGeometry` |
| P2 | **Incremental quadtree** (no full rebuild on undo; tombstone + lazy reinsert; quadtree for `nearbyEntities`) | ⌘Z hitch → <5ms | M | `Quadtree`, `CanvasModel:undo/redo`, `Snapping` |
| P3 | **Snap fast path** — `nearbyEntities` via `quadtree.query(aabbAroundCursor)` → analytic filter, not snapshot scan | O(N) → O(log N + k) | S | `CanvasModel:makeToolContext`, `Snapping` |
| P4 | **Constraint sparse Jacobian + incremental** (analytic residuals for line, warm-start, dirty-component only) | 10× on large nets | L | `ConstraintSolver`, `ConstraintTable` |
| P5 | **Renderer dirty-set + indirect** (per-entity `modelVersion`, rebuild only dirty visibles; one `drawPrimitivesIndirect`) | half upload at small edits | M | `RendererGeometry`, `LineRenderer`, `CanvasModel:applyCommit` |
| P6 | **Text atlas** (SDF glyph cache, one `MTLTexture` per style, not per `resolve`) | text-heavy draw 3× | M | `Text/*`, `Shaders`, `LineRenderer` |
| P7 | **DXF streaming read** (SAX → `CADDrawing` builder, no `LCEntity` intermediate) | -50% read alloc, -30% time | M | `lcdxf.cpp`, `DXFReader.swift` |

---

## 3. Architecture — shape and debt

### Module graph (correct, strict)

```
DxfBridge (C++ libdxfrw, C ABI, cxx20)  ←  symlink libdxfrw/src
   ↓ OpaquePointer + LCStatus, no Swift C++ interop (good)
CADEngine (pure Swift, f64 world, Sendable, value types)
   ↓ one-way, no import of app (enforced; _Shared*.swift symlinks for tests only)
LibreCADmacOS (SwiftUI + Metal, @MainActor, Observation)
```

Pinned `swiftLanguageMode(.v6)` — frozen concurrency contract. Good.

### Strengths
- Value `EntityRecord` (id/layer/pen/flags/kind/space) + `CADDrawing` indexByID — CoW, Sendable, testable headlessly (`LCShot`, `CADBench`).
- F64 world → F32 floating-origin (`renderOrigin`) — pan/zoom stable at large coords (ADR-003).
- Loose quadtree shared by cull + hit-test (single source of truth).
- Tool `handle(_:_:) -> ToolOutcome(.commit([.add/.replace/.remove]))` — pure value tools, single undoable funnel.

### Pain points (measured)

| Debt | Size / fan-out | Why it hurts |
|---|---:|---|
| **CanvasModel god object** | 8449 lines, holds drawing+viewport+quadtree+selection+snap+tool+constraints+layouts+undo | Change in one area rebuilds whole object, MainActor serialization, hard to test incremental paths, merge hotspot (every wave touches it) |
| **ContentView monolith** | 3021 lines, hosts sidebar/inspector/canvas/overlays | Type-check fragile, re-renders on unrelated state, wire-wave contention (`ToolKind`/`LibreCADApp`/`CommandPalette`/`ToolOptionsBar` same wave) |
| **EntityKind enum** | 85 `switch kind` sites (`grep -rn "switch.*kind" --include="*.swift" CADEngine`) — `Entity.swift` 1886 lines, `Resolve` 3151 | Adding a kind is a 22-file atomic arm (serialized critical section); violates OCP, high coupling |
| **CADDrawing** | 2616 lines, owns entities+layers+blocks+tables+constraints+undo | Mixed concerns (model + index + undo + persistence), no repository seam for persistence/versioning |
| **ToolKind central registry** | ~30 tools via exhaustive switch in `ToolKind.swift` + `CommandPalette` | Same atomic-wiring debt as EntityKind |
| **Resolve as free functions** | 3151 lines in one file, no protocol dispatch | No per-kind cache, hard to add LOD or GPU tessellation |
| **DxfBridge monolith** | 2700 lines `lcdxf.cpp` + 1500-line `DXFReader/Writer` | Handle alloc, error mapping (`LCStatus`), ATTDEF/ATTRIB dual hooks (`addAttdef` vs `addAttDef`) already drifted in rebase |
| **State churn** | `CanvasModel` Observed, many `modelVersion` bumps | SwiftUI diff does O(views) work on any `modelVersion` change; no `Equatable` gating |
| **Persistence lossy** | `DXFPayload` (in-session) carries constraints/params, but `DXFWriter` drops them (`writeAttdef` separate, dimstyle fallback) | Cross-session `⌘S` loses parametric model — must choose a durable format |
| **Tests bending module boundary** | `_Shared*.swift` symlinks (6 files) to reach `CanvasModel`/`AppSettings` from `CADEngineTests` | Leaky boundary; pure logic not extracted, symlink proliferation |
| **Error handling** | `LCStatus` int + `DRW_DBG` vs Swift `throws`/`Result` | Typed errors lost at ABI, hard to surface to UI |

### Architecture opportunities

| # | Idea | Impact | Effort | Files |
|---|---:|---|---:|---|
| A1 | **Decompose CanvasModel** → `DocumentModel` (drawing+undo) + `ViewportModel` (viewport+quadtree) + `InteractionModel` (selection/snap/tool) + `ConstraintModel`. `CanvasModel` becomes facade. | Testable, less contention, fixes undo rebuild | L | `CanvasModel` → `DocumentModel.swift` etc., `ContentView` |
| A2 | **Decompose ContentView** → `CanvasContainerView`, `SidebarHost`, `InspectorHost`, `ToolBarHost` with `@ViewBuilder` sub-views + `EquatableView` | Type-check, fewer re-renders | M | `ContentView`, `LibreCADApp` |
| A3 | **EntityKind open registry** — keep enum for now, but dispatch via `EntityKindResolver` protocol + per-kind `Resolver` structs (or `any EntityKindProtocol`), exhaustive switch only in factory | New kind = add file, not 22-file arm | M | `Entity.swift`, `Resolve`, `EntityTransform`, `Snapping`, etc. |
| A4 | **Tool registry DI** — `ToolRegistry: [ToolKind: any Tool]` injected, `ToolKind` stays enum but wiring is registration, not switch | Wire-wave no longer serialized | S | `ToolKind`, `CommandPalette`, `ToolOptionsBar` |
| A5 | **Persistence seam** — `DrawingRepository` protocol (`load/save` for DXF/DWG + native `.lcad` JSON with constraints/params/tables) | No more payload-vs-file divergence | M | `CADDrawing`, `DXFReader/Writer`, `LibreCADDocument` |
| A6 | **Undo as event log** — `DrawingEdit` enum + `UndoLog` (structural sharing via persistent array, not CoW whole-array copy) | Large drawing undo O(log N) | M | `CADDrawing`, `CanvasModel` |
| A7 | **Bridge typed errors** — `LCStatus` → `Swift Error` with `DRW::DRWError`, streaming callbacks | Better UI diagnostics | S | `lcdxf.{cpp,h}`, `DXFReader` |
| A8 | **Extract pure logic from CanvasModel** — `PaperSpaceLayout`, `SelectionPolicy`, `ConstraintListModel` already pure; do same for `SnapState`, `ToolContext` builder | Remove 2 `_Shared` symlinks | S | `CanvasModel`, `CADEngine` |

---

## 4. Planned waves (disjoint, gated)

> **Pre-condition:** `planner` → `critic` → `builder` → `code-reviewer` → `acceptance-tester` per wave; ≤4 concurrent, disjoint owned files; `swift build` + `swift test --no-parallel` green each wave (4071).

### Wave 0 — Baseline & guardrails (S, 1 builder)

*Owned:* `macos/docs/perf-report.md`, `CADBench/main.swift` (add `resolveCacheHit`/`quadtreeRebuild` counters), `CADDrawing.swift` (add `modelVersion` trace)
*Do:* extend CADBench to record cache-hit ratio, per-frame heap, MTL capture; add `os_signpost` around `resolve`, `quadtree.query`, `lineRebuild`. *Gate:* numbers reproduce.

### Wave 1 — Resolve cache + renderer dirty-set (M, 2 builders parallel)

*Builder 1 — Resolve cache* *Owned:* `Resolve.swift`, `Entity.swift` (add `resolveVersion`), `CADDrawing.swift` (bump per-entity version on `replace`)
*Do:* `NSCache<EntityID, ResolvedGeometry>` keyed by `(id, resolveVersion, pen)`; `RendererGeometry` reads cache, tessellation LOD bucketed by `worldPerPixel`.
*Builder 2 — Dirty-set* *Owned:* `RendererGeometry.swift`, `LineRenderer.swift`, `CanvasModel:applyCommit`
*Do:* `Set<EntityID>` dirty from `applyCommit`; rebuild only `quadtree.query` ∩ dirty (or full visible on first frame).
*Serialize with Wave 0, parallel with each other. Gate: CADBench lineRebuild -60% on single-entity edit.*

### Wave 2 — Snap & quadtree fast paths (S, 1 solo)

*Owned:* `Quadtree.swift`, `Snapping.swift`, `CanvasModel:makeToolContext` + `undo/redo`
*Do:* `nearbyEntities` → `quadtree.query(aabbAround(cursor,tol))` then analytic distance; `undo/redo` → incremental `quadtree.remove/insert` from `UndoLog` diff, not full rebuild. Gate: `CADBench hitTest` at 1M <0.3ms, ⌘Z no 197ms hitch.

### Wave 3 — Constraint solver sparsity (L, solo critical section)

*Owned:* `ConstraintSolver.swift`, `ConstraintTable.swift`, `ConstraintListModel.swift` (read-only)
*Do:* analytic Jacobian for line/circle/point residuals (sin/cos table), sparse LM (LDLT on `JᵀJ`), warm-start from prior `x`, dirty-component only. Gate: 100-constraint net solves <20ms.

### Wave 4 — God-object decomposition (L, 3 builders, serialized)

*Builder 1* *Owned:* `CanvasModel.swift` → `DocumentModel.swift`, `ViewportModel.swift` (new)
*Builder 2* *Owned:* `ContentView.swift` → `CanvasContainerView.swift`, `SidebarHost.swift` (new)
*Builder 3* *Owned:* `LibreCADApp.swift`, `DocumentSettingsView.swift` (extract)
*Do:* Facade keeps `CanvasModel` API for 402 tests (deprecated forwarding), new models are `Observable` slices. No EntityKind/ToolKind touch. Gate: `swift build` type-check <15s, no view body >150 lines.*

### Wave 5 — EntityKind extensibility (M, 1 solo, after Wave 4)

*Owned:* `Entity.swift`, `Resolve.swift`, `EntityTransform.swift`, `Snapping.swift`, `Selection.swift`, `Intersections.swift`, `DXFReader/Writer.swift` (many, but solo)
*Do:* `protocol EntityResolver { func resolve(_ data: Self.Data, ctx: ResolveContext) -> ResolvedGeometry }` + `EntityKindResolver` registry; exhaustive switch remains only in `EntityKind.init(kind:)` factory. New kind = add `MyKind.swift` + register. Gate: add a stub `.testKind` with no other file touch and suite green.

### Wave 6 — Persistence & undo (M, 2 builders)

*Builder 1 — Repository* *Owned:* `CADDrawing.swift`, `DXFReader/Writer.swift`, `LibreCADDocument.swift` (new `DrawingRepository.swift`)
*Builder 2 — Undo log* *Owned:* `CADDrawing.swift` (undo), `CanvasModel:registerTextStylesUndo`
*Do:* native `.lcad` (versioned JSON with entities+constraints+params) + DXF/DWG remains lossy but explicit; `UndoLog` persistent array.

### Wave 7 — Bridge & tool registry (S, 1 builder)

*Owned:* `DxfBridge/lcdxf.cpp`, `DxfBridge/include/lcdxf.h`, `Tools/ToolKind.swift`, `CommandPalette.swift`
*Do:* typed `LCError`, streaming read, `ToolRegistry` DI.

**Sequencing:** 0 → (1+2) → 3 → 4 → 5 → 6 → 7. Waves 4+5 are the only serialized critical sections (hot files); 0–3 are low-conflict and can run parallel after 0.

**Risks / cuts:** Wave 4 is the highest-risk (touches most app state) — run as a single builder, behind a `CanvasModel` facade, with LCShot 7 scenes as acceptance. Cutting P6 (SDF atlas) and P7 (streaming) saves 2 waves with negligible regression at current 1M budget.

---

*Next step:* run `planner` on Wave 1 (resolve cache) for a file-grounded brief, then dispatch. All waves reuse the serial gate and keep `CADEngine ⊥ app` (additive, no new `EntityKind` in 0–4).
