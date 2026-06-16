# LibreCAD macOS — Architecture Health Report

> Produced by the `architecture-review` workflow (13 read-only subsystem/cross-cutting reviewers →
> synthesis → adversarial pressure-test). _2026-06-16, `native-macos @ 856618e9d`, 2614 tests._
> **Overall grade: B.** The adversarial critic's verdict: **trustworthy with corrections** — the four
> most consequential findings (R1, R2, R4, R10) were independently re-verified against the code.

---

## 0. Adversarial corrections applied (AUTHORITATIVE — override the body where they conflict)

The pressure-test caught these; they're folded into the findings below but listed here for traceability:

1. **R9 (Core Text deadlock) was OVERSTATED → downgrade HIGH → MEDIUM.** The project's own
   backlog/decision-log already root-caused it as an **intermittent ~7% test-infra flake** (2/30
   parallel, 0/12 serial), consciously deferred as a test-infra artifact, **not a product bug**. And
   the stated *mechanism* is imprecise: `CoreTextFontProvider.init()` is empty; the first
   `CTFontCreateWithName` is lazy in `CoreTextFont.init?` at resolve time, **not** in a `static let`
   `swift_once`. The static-inits that do real work are `strokeProvider`/`shxProvider` directory scans.
2. **R2 INACCURATE about `Inspect/InspectorEdits.swift` ("77-arm EntityKind switch").** Those are
   **non-exhaustive** `guard case .line(var d) = kind` per-field setters — adding an EntityKind case
   does **not** break them. It is NOT a mandatory-edit blast-radius site. The genuine exhaustive
   hotspots are **`Snapping.swift` (~48 arms / 9 switch-on-kind sites)** and **`Resolve.swift` (~37)**,
   plus transform + DXF-write — those parts of R2 stand.
3. **R5 undercount:** `modelVersion` has **8** external write sites, not 6 (DocumentSettingsView,
   BlockVisibilityStatesPanel, ContentView ×2, PartsLibraryPanel, InspectorView, LayersSidebar,
   BlockDynamicParametersPanel). The 72 internal bumps figure is exact.
4. **R4b is worse than written (both ends):** `DXFReader.mapGraphicVariables` ALSO drops the 8 vars,
   so the round-trip is broken on **read AND write AND the C bridge** — a 6-site lockstep, so the
   generic-`$VAR`-bag fix is **L→M effort**, not L. (Strengthens the case for the generic bag.)
5. **Counts:** EntityKind has **17 cases** (Entity.swift); `_Shared*` symlinks = **25 test + 3 bench**.
6. **Grade reconciliations:** *Persistence* is graded **B but behaves like a C** on the data-loss axis
   (8 settings + all dynamic-block authoring silently dropped, with falsely-reassuring doc-comments) —
   the B is a weighted average masking a product-level hole. *Test architecture* is the weakest **A →
   read as A−** (propped up by the symlink fiction R8 + the serial-only gate R9).
7. **Under-weighted:** no automated test asserts screen-vs-export parity even for solid/dashed/dotted
   (compounds R7); and the EntityKind category-layer cure (#14) itself touches the enum — sequence it
   strictly standalone (the cure shares the disease's change-amplification).

---

## 1. Executive Summary

**Overall grade: B** (sound, deliberately-architected, with named structural debts all addressable
without re-architecting).

This is a **value-type, derive-don't-store CAD engine** (ADR-001) cleanly split across three modules —
`DxfBridge` (C++/libdxfrw behind a pure C ABI) → `CADEngine` (Sendable value model + pure
resolve/tools/snap) → `LibreCADmacOS` (SwiftUI + Metal). The core architectural bet is excellent and
consistently honored: entities are frozen `Sendable` structs holding only defining data, geometry is a
pure function (`resolve()`), mutation funnels through value-snapshot undo, and the whole package
compiles clean under Swift 6 strict concurrency with a single serializing actor over the non-reentrant
C library. That foundation pays off as a fast (~1.1s / 2614-test) headless suite and a correct
floating-origin renderer.

The through-line: **a strong engine core wrapped by an app layer that has not kept pace with the
engine's discipline.** The engine's seams are clean and testable; the app layer has accreted two
god-objects (`CanvasModel` 4543 lines, `CADDrawing` 2173 lines), a hand-maintained `modelVersion`
change-bus, and several spec-vs-reality gaps where a feature is *fully built but not wired or not
persisted*. The most serious issues are not crashes — they are **silent data loss / fidelity gaps**
(dynamic blocks and ~8 document settings don't survive save; viewport contents render on-screen but
don't plot; perpendicular/tangent/parallel snaps are toggleable but dead) and **change-amplification
hotspots** (EntityKind fan-out; the god-objects as the #1 merge surface). Every one is fixable
incrementally within the wire-wave discipline.

## 2. Strengths (genuine, load-bearing wins)

- **Value-type + computed-geometry model (ADR-001)** implemented cleanly across the engine; `Entity`
  is data-only, behavior in `Resolve`/`EntityTransform`. The keystone that makes everything cheap.
- **Snapshot undo via `UndoManager` re-registration** (`CADDrawing.swift:1840`) — correct + elegant;
  redo for free; `working != prior` no-op guards; multi-step ops reverse atomically by construction.
- **Module dependency direction is clean (grep-verified):** `CADEngine` has zero
  `import LibreCADmacOS`/SwiftUI/Metal/AppKit; `DxfBridge` quarantines all C++ behind a narrow C ABI.
- **The DXF C++ bridge is exemplary (A):** `std::deque`-pooled ownership, airtight `try/catch(...)` at
  every C-ABI entry, zero file-scope mutable state so the single-actor contract holds by construction.
- **Resolve-by-name block expansion (ADR-001):** stores only ordered `EntityID`s → editing a member
  updates every insert with zero invalidation logic.
- **Additive-extension discipline that dodges the EntityKind trap on purpose:** dynamic blocks +
  paper-space + viewports all landed as optional fields with their own enums, touching ZERO EntityKind
  switch sites.
- **Single geometric source of truth for screen + export** (A): both consume the same
  `ResolvedGeometry`/`ExportScene` — no parallel tessellation.
- **Floating-origin renderer (ADR-003) done right:** f32 buffers store `world − renderOrigin`; pan/zoom
  is matrix-only; GPU-free packing/cull math is pure + headlessly tested.
- **Test rigor + concurrency model (A−):** 2614 tests/~1.1s serial; Swift 6 strict-concurrency clean;
  the two hardest GPU seams (shader compile, Swift↔MSL byte-match) closed headlessly; the
  headless-modal-hang trap structurally enforced.

## 3. Top Risks (merged across reviewers, ranked)

- **R1 — `CanvasModel` god-object (CRITICAL).** 4543 lines, ~161 stored props, ~157 methods, ~15
  responsibilities; 44 files reference it; every UI wave lands here — the #1 merge-contention surface,
  fighting the project's own wire-wave discipline. **Direction:** decompose into composed `@MainActor`
  sub-controllers that already exist as MARK clusters — `BlockEditSessionController` (~320),
  `DynamicBlockController` (~500), `CameraController`, `ToolConfigApplier` — one additive wave each. *(XL)*
- **R2 — EntityKind exhaustive-switch fan-out (HIGH).** Adding a kind historically touched 17–19 files;
  17 enum cases, no central `category`/`isAtomic`/`displayName`. Genuine exhaustive hotspots:
  `Snapping.swift` (~48 arms/9 sites), `Resolve.swift` (~37), transform, DXF-write. **Compounding
  safety risk:** ~14 hot switches carry `default:` arms that **silently swallow a future kind** (no
  snap points / not selectable / dropped from export) instead of failing the build.
  *(Correction §0.2: `InspectorEdits.swift` is NOT an exhaustive hotspot.)* **Direction:** add a
  centralized capability layer on `Entity.swift`; branch incidental consumers on category; audit the
  `default:` arms (shared `isTrimmable` predicate, convert lazy ones to exhaustive). Keep
  resolve/transform/DXF-write exhaustive. **Update CLAUDE.md's "~28 files" to reality.** *(L; single deliberate serialized wave)*
- **R3 — The ADR-001 per-entity geometry cache does not exist (HIGH, but see §0.7).**
  `rebuildLineInstancesIfNeeded` re-runs `e.resolve(ctx)` over the entire culled visible set on every
  `modelVersion` bump (`LineRenderer.swift:583-588`) — O(visible)/edit, not the promised O(touched).
  Same root: the Quadtree is owned by `CanvasModel` above the data, so undo resyncs it with a full O(n)
  `rebuildIndex()` per ⌘Z. *(Caveat: resolve is ~233 ns/entity / ~0.23s @ 1M, so absolute cost today
  is modest — this is a spec-divergence more than a live perf fire.)* **Direction:** add the
  `[EntityID:(version,geo)]` cache the design already calls for, invalidated per-entity by the funnels;
  optionally move quadtree ownership into `CADDrawing`. *(L)*
- **R4 — Silent data loss with falsely-reassuring doc-comments (CRITICAL/HIGH).** (a) Dynamic-block
  data has full Codable scaffolding + tests but **no wired encoder** (DXFWriter/Reader have zero
  references) → author→save→reopen loses everything. (b) ~8 per-doc settings (`$LC_SNAPMODE`,
  `$GRIDMODE`, `$GRIDUNIT`, `$PDMODE`, `$PDSIZE`, `$ANGBASE`, `$ANGDIR`, `$PINSBASE`) are
  editable+dirty+undoable then **dropped on write** (fixed POD whitelist `lcdxf.h:450-479` +
  `DXFWriter.makeHeader:868-890`) — **and `DXFReader.mapGraphicVariables` also drops them (§0.4: broken
  on BOTH ends)** — while the doc-comments falsely claim "Round-trips through the header bridge."
  `SaveRoundTripTests` only checks 3 vars → 2600 tests give false confidence. **Direction:** generic
  `$VAR` pass-through bag in the bridge (read+write+C, 6-site lockstep) so all `graphicVariables`
  round-trip; for dynamic blocks, the documented bake-to-static export or XDATA/sidecar persistence.
  **Fix the false doc-comments first; add save→reopen tests.** *(L→M each)*
- **R5 — `modelVersion` is a hand-maintained, externally-writable change-bus (HIGH).** 72 internal
  bumps + **8 external write sites** (§0.3); read by autosave + renderer + sidebar; overloaded as 3
  signals (render-refresh + content-dirty + menu-refresh), so view-only ops force full-payload
  deep-copies via `syncPayloadToDocument`. A single forgotten bump silently breaks autosave/render.
  **Direction:** `private(set)` + intent methods (`markDocumentDirty()`); split a `contentVersion` only
  the edit funnels bump. *(L)*
- **R6 — `var drawing` is publicly mutable; the View layer bypasses the index/undo contract (HIGH).**
  Sidebars call `model.drawing.removeLayer/.remove(insertID)/.addBlockAttributeDef` then hand-bump
  version, **skipping the quadtree rebuild** → a removed insert lingers in the spatial index (real
  desync bug). **Direction:** `private(set) var drawing` + the missing CanvasModel funnels; pairs with R5. *(L)*
- **R7 — Viewport content: screen ≠ plot (WYSIWYG broken) (HIGH).** Model-through-viewport renders
  on-screen (`LineRenderer.packViewportContents:617`) but export/print **omits it**
  (`layoutExportScene:1021`, `DrawingPrinter:108`) → a layout with viewports prints as an empty frame.
  **Direction:** one engine-side pure `LayoutViewport.projectedDrawables(...)` consumed by both. *(L)*
- **R8 — Test/bench pierce the module boundary via 25(+3) `_Shared*` symlinks into the app module
  (HIGH).** The declared `Package.swift` graph is a fiction; SwiftUI/AppKit views get recompiled into
  the test target (contributes to R9). **Direction:** extract a `CADRender`/`CADAppCore` library of the
  GPU-free/UI-free logic and depend on it for real; stop symlinking *views* — test their view-models. *(L)*
- **R9 — Core Text static-init flake (MEDIUM — downgraded, §0.1).** Intermittent ~7% parallel-test
  hang; already root-caused + deferred as test-infra. **Direction:** lazy first Core Text touch +
  deterministic launch warm-up; verify 30× parallel; keep `--no-parallel` until then. *(M)*
- **R10 — Dead-wired snap modes (HIGH severity, S fix — best value/effort).** perpendicular / tangent /
  parallel / distance-along are toggleable in 4 UI places and rendered, but the only live call site
  `CanvasModel.updateSnap:1728` passes neither `referencePoint` nor `distanceAlong` nor `ctx` → they
  contribute zero candidates. **Direction:** pass `referencePoint: relativeZero` + the tool-options
  distance + the resolve `ctx`; add a live-path test. *(S)*

## 4. Per-Area Scorecard

| Area | Grade | Headline |
|---|---|---|
| DXF C++ bridge / C-ABI / libdxfrw | **A** | Textbook non-reentrant-C++→value-Swift seam; disciplined ownership, airtight exceptions. |
| CG export + thumbnails (PDF/PNG/SVG/Print) | **A** | One `ResolvedGeometry`→`ExportScene` feeds every format; zero geometry duplication. |
| Test architecture + concurrency / @MainActor | **A−** | Sound Swift 6 model + fast headless suite; held back by the symlink fiction + serial-only gate. |
| Engine value-type model + undo | **B** | Clean value model + elegant snapshot undo; spatial index lives outside the funnel it should own. |
| Resolve layer | **B** | Pure transform, clean injection seam — but the spec'd per-entity geometry cache is missing. |
| Tool system + constraints + snapping | **B** | Pure, testable tools; `applyToolConfig` is the central registry the protocol claimed to abolish. |
| Metal renderer pipeline | **B** | Floating-origin done right; Swift↔MSL byte contract & overlay draw-order are compiler-invisible. |
| Blocks + dynamic blocks + attributes | **B** | Excellent resolve-by-name core; dynamic-block data has no persistence path (silent loss). |
| Paper space / layouts / viewports | **B** | Off-EntityKind & single transform kernel; viewport contents render on screen but don't plot. |
| SwiftUI app layer (ContentView + Sidebar) | **B** | Exemplary sidebar abstraction; everything mortgaged against the CanvasModel god-object. |
| Persistence / document / settings | **B− (data-loss: C)** | Excellent launch-safety split; ~8 doc settings + dynamic blocks silently dropped despite "round-trips" claims. |
| Cross-cutting: boundaries + EntityKind hot-switch | **B** | Clean dependency direction; EntityKind fan-out + `default:` arms defeat the exhaustiveness guard. |
| CanvasModel (central app-model) | **C** | Textbook god object: 4543 lines, ~161 props, ~15 responsibilities — the app's #1 contention surface. |

## 5. Prioritized Refactor Roadmap

### Phase 0 — Quick wins (high payoff / low risk)
1. **Wire the dead snap modes** (R10) + live-path test. *(S)*
2. **Fix `resolveInsert` O(n²)** — append-in-place vs repeated `merged(with:)` (`Resolve.swift:1360`). *(S)*
3. **Correct the false doc-comments** (dropped settings + dynamic-block "lossless") + update CLAUDE.md's EntityKind count. *(S)*
4. **Hoist `mmPerPoint` to one engine constant** (×3) + add a **CG/Metal dash-parity test** (closes §0.7's untested WYSIWYG surface). *(S)*
5. **Batch `remove([EntityID])`/`replace([EntityRecord])`** — one reindex + one grouped undo (kills O(n·m) multi-delete). *(M)*
6. **Delete dead `DocumentState.swift`** + symlink (or mark unused). *(S)*

### Phase 1 — Targeted structural fixes
7. **Per-entity version-keyed geometry cache** (R3). *(L)*
8. **Generic `$VAR` pass-through bag** in the bridge — read+write+C (R4b, §0.4) + save→reopen tests. *(L→M)*
9. **Unify viewport-content projection** into one engine-side pure fn for screen + plot (R7). *(L)*
10. **`private(set) var drawing` + missing funnels** (R6) + model-owned `modelVersion`/`contentVersion` split (R5). *(L)*
11. **Fix the Core Text flake** (R9) — lazy first-touch + launch warm-up; verify 30× parallel. *(M)*
12. **Extract `CADRender`/`CADAppCore` library target** (R8) — delete the view symlinks. *(L)*

### Phase 2 — Big structural bets (additive wire-waves; after Phase 1)
13. **Decompose `CanvasModel`** into composed sub-controllers (R1), one MARK-cluster per wave, green between each. *(XL)*
14. **EntityKind capability layer** (R2) — computed `category`/`isAtomic`/`displayName`; rewrite incidental switches; audit `default:` arms. **Single deliberate serialized wave** — the cure touches the enum it's de-risking (§0.7). *(L)*
15. **Tool-config ownership to the tools** (`mutating func applyConfig`) — delete the 22-arm `applyToolConfig` + `ToolOptions` struct. Pairs with #13. *(L)*
16. **Multi-layout DXF persistence** (needs a vendored-libdxfrw LAYOUT-dict patch); until then make lossy multi-layout save **warn loudly** instead of silently collapsing. *(L; do the loud-warning S-fix now)*

**Sequencing:** Phase 0 is parallelizable. #10 follows #7. #13 precedes #15. #14 and the C-ABI item (#8) each touch a serialized critical section — single-owner waves, never blended. Worktrees branch off `master` + `reset --hard native-macos`; serial tests until #11.

## 6. What NOT To Do
- **Don't merge the CG and Metal renderers** — different media/unit systems; the two-renderer split over one shared `ResolvedGeometry` is correct. Share only the dash/stroke *descriptor*, not the paint loop.
- **Don't replace the EntityKind enum with a class hierarchy/protocol-witness table** — the exhaustive switch is a *feature* for resolve/transform/DXF-write. Add a categorization layer to blunt incidental fan-out; don't dismantle the sum type.
- **Don't churn the EntityKind switch casually** — touch it only as a deliberate single-owner wave (#14).
- **Don't "fix" export to match the screen's intentional transforms** (light-mode auto-invert, LOD coarsening are correctly export-absent). The viewport-content omission (R7) IS a bug; those are not.
- **Don't over-narrow the table-funnel undo snapshots** — reconcile ADR-002's "touched-only" doc to the (fine) whole-table-snapshot code instead of adding dirty-set machinery (except `BlockTable` if huge blocks appear).
- **Don't drop the `_Shared*` symlinks before the library target exists** — disciplined zero-drift debt; make it unnecessary (R8), don't fork divergent test copies.
- **Don't add a richer `Tool.preview` type or generalize the 2 out-of-band tools preemptively** — wait for the documented trigger (a 3rd non-entity tool / 2nd raster tool).
