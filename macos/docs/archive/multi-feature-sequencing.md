# Multi-Feature Sequencing — snap tracking + gradient hatch + UCS + MLEADER + transcript

> Coordinator-owned DAG for the parallel build of all four requested features (+ the queued
> command transcript). Re-derived from the `cad-features-plan` workflow (`wabzschr8`), whose global
> matrix was built on a STALE snapshot of snap tracking — corrected here against the real in-flight
> state. Individual feature plans in `wabzschr8` are sound; the corrections are (a) the real snap
> chokepoints and (b) the MLEADER ML-W1 file list (critic-supplied). _2026-06-17._

## Coordinator refinement (changes the contention picture)
Snap-tracking's polar/OTRACK visuals are drawn in a **CG overlay (`TrackingOverlay.swift`)**, NOT via
the Metal `dashedSegments` path. So **snap tracking does NOT own `Renderer/OverlayGeometry.swift` or
`LineRenderer.swift`** → gradient GH-W2 + UCS-W3 renderer work no longer collide with snap tracking.

## Real chokepoint groups (single-owner-per-wave; serialize within each group)
- **CanvasModel.swift:** snap-W2 (polar) → snap-W5 (OTRACK) → UCS-W2 → ML-W4 → TR-1. (strictly serial)
- **Entity/Resolve/EntityTransform.swift:** GH-W1 then ML-W1 (both edit them) → serial.
- **Snapping.swift:** ML-W1, UCS-W3 → serial (snap OTRACK only READS it).
- **Renderer (RendererGeometry+LineRenderer):** GH-W2. **OverlayGeometry:** UCS-W3. (disjoint files → parallel)
- **DXF (lcdxf.{h,cpp} + DXFReader/Writer):** GH-W3, ML-W3, UCS-W4 → serial.
- **CADCanvasView.swift:** snap-W3, snap-W6 (snap-internal serial). **ToolKind.swift:** ML-W2 (solo).
- **EntityKind sum-type (new case):** ML-W1 only — SOLO, no other entity-switch work concurrent.

## Per-feature waves (detail in `wabzschr8` output)
- **Snap tracking:** W1 PolarTracking✅, W4 Tracking✅ (merged `d18822424`). W2 CanvasModel polar (building) → W3 TrackingOverlay polar-visible (CG overlay+CADCanvasView) ∥ W5 CanvasModel OTRACK → W6 overlay guides+dwell+constraint → W7 OTRACK chip/pref.
- **Gradient hatch:** GH-W1 engine (Entity/Resolve/EntityTransform/HatchTool + transformHatch bug-fix) → GH-W2 Metal CPU ramp (RendererGeometry+LineRenderer) ∥ GH-W3 DXF (libdxfrw already round-trips gradient; bridge POD only) → GH-W4 inspector. NO new EntityKind.
- **UCS:** UCS-W1 pure `UCS.swift` (building) ∥ UCS-W0 `$ANGBASE/$ANGDIR` in CoordinateFormatter → UCS-W2 CanvasModel UCS-aware boundary (coord readout/typed-coord/grid/ortho) + UCSAxisOverlay (EXISTS — update its test in lockstep) → UCS-W3 OverlayGeometry+Snapping → UCS-W4 (opt) $UCS DXF. NO new EntityKind.

## MLEADER — corrected ML-W1 (new EntityKind, SOLO; runs AFTER GH-W1 merges)
Clone `.leader`/`LeaderData` (`Entity.swift:1236`/`:757`) → `case multileader(MultiLeaderData)` (`indirect`).
**ML-W1 atomic-commit owned files (compiler-mandatory no-default `.leader` arms — critic-corrected, do NOT miss any):**
`Entity.swift` (the case + struct), `Resolve.swift` (resolve@:886 + boundingBox@:870 → `resolveMultiLeader` clone `resolveLeader`@:1183), `EntityTransform.swift` (transform@:226 → clone `transformLeader`@:277), `Snapping.swift` (vertex/mid arms @:475/:592), `Inspect/InspectorEdits.swift` (@:375), **`Tools/StretchTool.swift:434`**, **`Purge.swift:178`**, and **`QuickSelect.swift` (separate `QuickSelectKind` enum @:54 — add `.multileader` case + its no-default arm, OR explicitly defer MLEADER from Quick-Select v1)** + tests. (EntityGrips.swift uses `default:` → no arm needed.) Renderer needs NO change (kind-agnostic).
- **ML-W2:** `ToolKind.multileader` (own ToolKind-switch) + `MultiLeaderTool` (clone LeaderTool). Unwired.
- **ML-W3 (DXF):** bridge `LC_ENT_MLEADER` POD + `addMLeader` read + `writeMultiLeader` call; `DXFReader`/`DXFWriter` arms + the **`leaderAnnotationPOD`@DXFWriter:843 + `.leader` annotation hook@:237** fan-out (mirror for MTEXT content) OR scope annotation-emit out of v1. **libdxfrw WRITE emits structurally-valid-but-geometry-LIGHT MULTILEADER (CONTEXT_DATA{} not emitted, `libdxfrw.cpp:1688`)** → finishing it = a vendored-lib edit → **HARD precondition: explicit user sign-off** before ML-W3 write. READ is complete.
- **ML-W4 (app):** InspectorEditors/InspectorView/QuickSelectPanel/CanvasModel/ContentView/CommandPalette leader-arm clones. Touches CanvasModel → serialize.
- **Scope v1:** single-root leg + landing/dogleg + arrowhead + MTEXT; defer block content + multi-root.

## Order (maximize parallelism)
NOW (parallel): snap-W2 ∥ GH-W1 ∥ UCS-W1(+W0). Then as each merges: snap W3∥W5→W6→W7; GH-W2∥GH-W3→GH-W4; UCS-W2 (after snap CanvasModel waves)→UCS-W3→UCS-W4. **MLEADER last big push:** ML-W1 (SOLO, after GH-W1 merged so Entity.swift is free) → ML-W2∥ML-W3(gated on sign-off) → ML-W4. Transcript TR-1 slots into the CanvasModel chain when free.
