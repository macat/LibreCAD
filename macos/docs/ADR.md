# Architecture Decision Records — LibreCAD Native macOS

**FROZEN foundation decisions.** Every engine/render builder MUST read this before writing code.
These resolve the contradictions the plan-critic flagged (2026-06-11) and are the shared contracts
the entire parallel fan-out compiles against. Do not deviate without a new ADR + coordinator sign-off.

---

## ADR-001 — Entity model: value `struct` + computed geometry (NO stored child graph)
**Decision.** Every entity — atomic (Point/Line/Circle/Arc/Ellipse/Spline) AND composite
(Polyline/Text/MText/Insert/Hatch/all Dimensions) — is a Swift **value `struct`** holding only its
**defining data** (the `RS_*Data` equivalent). Derived geometry (dimension lines/arrowheads, text
letter strokes, hatch fill triangles, block-insert expansion) is **NOT stored**; it is produced on
demand by a `func resolve(_ ctx: ResolveContext) -> ResolvedGeometry` and kept in a separate,
invalidatable **render/geometry cache** keyed by `EntityID` + style/version — never inside the entity.

- The document stores entities in an ordered collection with **stable `EntityID`s**. Layers, blocks,
  and parent/child (block contents) relationships are **ID references in the document store**, not
  object pointers. No parent back-pointers, no shared mutable child lists, no reference cycles.
- `EntityType` etc. → Swift enums; `Flags`/`SnapMode` → `OptionSet`. Pen `LineType`/`LineWidth`
  carry `.byLayer`/`.byBlock` sentinels; resolution happens at resolve()-time against layer/block.

**Why.** Resolves the PLAN-vs-engine-doc contradiction; makes undo cheap (ADR-002); kills aliasing
and cycles; matches the engine-mapper's mapping note. Containers-as-classes is **rejected**.

**Consequences.** Bounding boxes derive from resolved geometry (cached). The quadtree (Phase 1)
indexes AABBs keyed by `EntityID`. Dimension/Text `resolve()` ports `RS_Dimension::update()` /
`RS_Text::update()` logic as a PURE function (no `clear();addEntity()` mutation).

---

## ADR-002 — Undo: copy-on-write value snapshots via `UndoManager`
**Decision.** Edits register with the document's `UndoManager` (free from `DocumentGroup`) and
restore state by **value snapshot of the touched entities only** (the dirty set), not the whole
drawing. Because entities are value types (ADR-001), snapshots are O(touched) with structural
sharing — target **single-entity edit < 1 ms** even at 100k+ entities.

- Command objects MAY be used as the registration mechanism, but state is restored by value, not by
  hand-written inverse mutations. The LibreCAD flag-based "mark-don't-delete" `RS_Undo` scheme is
  **not ported**.

**Why.** The "cheap snapshot" claim is only true with value types — which ADR-001 now guarantees.

---

## ADR-003 — Coordinate precision: f64 engine, f32 GPU via floating-origin (FROZEN buffer contract)
**Decision.** Engine geometry is **`Double` (f64) everywhere** (matches `RS_TOLERANCE` 1e-10).
GPU vertex buffers store **`Float` (f32) offsets from a per-view f64 `renderOrigin`**. The
buffer-fill step ALWAYS computes `f32(worldPoint - renderOrigin)`; the `world→clip` matrix folds in
`renderOrigin`. This subtraction path **exists from day one** (origin may be `(0,0)` initially), so
floating-origin at extreme zoom is **not a retrofit**.

- Hit-testing/snapping run in **f64** against ported engine kernels (`RS_Information`). **No GPU
  readback** — snaps stay exact regardless of render LOD.

**Why.** The f64↔f32 seam is a foundation API; retrofitting the buffer format later would churn every
tessellation cache. Cheap to bake in now, expensive later.

---

## ADR-004 — CAD text: LibreCAD stroke fonts (`.lff`) rendered as polylines (NOT SDF/system fonts)
**Decision.** In-drawing CAD text (`RS_Text`/`RS_MText`) and dimension text render as **stroked
polylines** using LibreCAD's shipped **`.lff` stroke fonts** (92 fonts in `librecad/support/fonts/`),
through the same instanced-line pipeline. Port the `.lff` font loader + glyph layout. A DXF text
style names a stroke font; we honor it for fidelity + round-trip.

- The **SDF/Core-Text glyph atlas is reserved for UI chrome only** (HUD, labels), NOT core CAD text.
- Therefore **`.lff`/`.cxf` font support is P1** (a dependency of P1 Text/Dimensions), not P2.

**Why.** SDF-from-system-fonts renders the wrong typeface and breaks DXF geometry round-trip.

### REVISION (2026-06-12) — add nice NATIVE fonts as the default (user directive)
> User: "LibreCAD does not support nice fonts. I want the Mac app to support nice, native ones."

In-drawing text now supports **two glyph sources behind ONE `FontProvider`/glyph abstraction** in `ResolveContext` — chosen per text by the style's font name:

1. **Stroke fonts (`.lff`)** — RETAINED for DXF fidelity, round-trip of stroke-font styles, and the classic single-stroke CAD look. Resolve → polyline strokes (unchanged).
2. **Native outline fonts — the DEFAULT for newly created text.** Any installed macOS font via **Core Text glyph PATHS** (`CTFontCreatePathForGlyph` → `CGPath`) → flattened → **tessellated to FILLS** through the existing fill pipeline (earcut / `ResolvedFill`).

**Why this is correct (and not a contradiction of the original "no system fonts"):**
- It is **vector outline tessellation, NOT an SDF atlas** — so text stays **crisp at any zoom** and **exports to PDF/SVG perfectly** (vector). The original ADR only rejected the *SDF atlas* approach; that rejection stands.
- It renders the **actual chosen typeface** (the "wrong typeface" concern was specific to SDF-from-system; outlines render the true font).
- **Round-trip is preserved**: the chosen font family name is stored on the text style; DXF TEXT/MTEXT already carries an arbitrary style/font name, so we remember it and re-render native on reopen. Stroke (`.lff`/SHX) styles still resolve via the stroke provider.

**Implications (build for this NOW):**
- `ResolvedGeometry` for text MAY contain **fills** (outline glyphs) in addition to / instead of strokes. The renderer already draws fills → **no renderer change needed**.
- `.text` AND `.dimension` measurement text both go through the same provider abstraction (do not fork a second text path).
- New TEXT / DIMENSION text defaults to a clean native font (e.g. a system sans); `.lff` "standard" remains selectable (font picker lands with the Inspector / text tool).
- The SDF path stays OUT — outline tessellation supersedes the need for it for CAD text.

---

## Sequencing contract (supersedes PLAN phase order where they differ)
1. **Phase 0 (serial, single agent):** scaffold + libdxfrw compiling + one-line Metal canvas + green
   tests, MERGED to `native-macos`. Gate for everything.
2. **Phase 0.5 (serial):** these ADRs frozen + a concrete `Entity`/`Document`/`ResolvedGeometry`
   skeleton landed & reviewed. **No parallel builder starts before this.**
3. **Phase 1 (parallel):** math/intersection kernels (port `librecad/src/lib/math/tests/`), atomic
   entities, document model, quadtree — fan out ONLY after Phase 0.5.
4. **Consolidated gate (replaces separate render/interaction phases):** real geometry on screen +
   selection + snapping + preview overlay must be green before tool fan-out.
5. **Phase 4 (broad tool fan-out):** P0 wave first. **Hatch, Dimensions, Blocks/Inserts cross
   engine+render+interaction → assigned to a SINGLE owner**, not the wide pool.

## Watch-items (from critique; not blocking)
- Pin **macOS 26 / Swift 6.2** consistently in `Package.swift` (no `.v14`/Swift 6.0 drift).
- **Spline** (NURBS + interpolation) is a known bug-farm; port with tests, treat as higher-risk P1.
- Budget selection-highlight overdraw + dash-pattern arc-length continuity across tessellated joins.
- Rendering doc web refs flagged "re-verify when online" — canonical enough to proceed; don't treat
  cited blog math as copy-paste-ready.
