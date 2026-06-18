# Paper Space / Layouts — Implementation Plan

Read-only architecture pass (2026-06-15, design agent). The app is **model-space-implicit end to end**; paper space is additive but threads through one hot enum (`EntityKind`), one hot model (`CADDrawing`), the renderer, and the DXF bridge. All paths under `/Users/macatt/w/LibreCAD/macos/engine/Sources/`.

## 1. Current state (no "space" concept exists)
- `CADDrawing.swift:534` `entities: [EntityRecord]` — one flat model-space array; layers/blocks/dimStyles/graphicVariables hang off the single `@MainActor @Observable CADDrawing`. No layout table, no per-entity space partition.
- `EntityRecord` (`Entity.swift:1171`) has `id/layer/pen/flags/kind`, **no space tag**. `EntityFlags` (`:1149`) has spare bits. `EntityKind` (`:1081`) is closed, **no viewport case**.
- **`EntityKind` is switched exhaustively in ~28 files with essentially no `@unknown default`** (Resolve/EntityTransform/DXFReader/DXFWriter/Selection/Snapping/Intersections/GizmoTransform/InspectorEdits/~18 Tools). Adding a `.viewport` case breaks-compile all 28 → the biggest design fork.
- **`Viewport` name is taken** (`Viewport.swift:59` = the screen camera). New entity must be `ViewportData`/`PaperViewport`.
- Renderer (`LineRenderer.swift:419`) iterates `model.drawing.entities`; `CanvasModel` owns one drawing/viewport/quadtree — no "which space is on screen."
- DXF bridge seam: `lcdxf.cpp:179 fillCommon` **drops code 67 (space)** though libdxfrw parses+writes it; `:325 addBlock` discards `*Paper_Space` blocks (merges to model); `:592 addViewport` → `addUnsupportedEntity` (THE "skipped N VIEWPORT" source — `DRW_Viewport` has the fields); `:612 addPlotSettings` is a no-op; libdxfrw's DXF reader **does NOT parse the ACAD_LAYOUT dictionary** (`processObjects` handles only IMAGEDEF/PLOTSETTINGS), and there is **no writeLayout API** + only ONE hard-coded `*Paper_Space` block on write.
- Persistence: native = DXF/DWG via bridge; carrier `DXFPayload` (`LibreCADDocument.swift:52`). Add `layouts` there + `CADDrawing.load`.
- **Reusable plot substrate already exists:** `Export/PrintLayout.swift` (`PlotScale`/`PageSetup`/`makeLayout`) + `PaperSize` (`DocumentSettingsView.swift:578`).
- UI seam: `ContentView.swift:170+` detail pane (StatusBar+ToolOptionsBar+canvas); a Model/Layout tab strip attaches at the bottom.

## 2. Proposed architecture (minimal-yet-correct)
- **Layout model on `CADDrawing`:** `struct Layout { name; pageSetup: PrintLayout.PageSetup; tabOrder }`, `layouts: [Layout]` (model space implicit).
- **Per-entity space = additive `EntityRecord` struct field** (NOT an enum case): `enum EntitySpace { model, paper }` + `layoutName: String?`, back-compat `decodeIfPresent` default `.model`. Maps 1:1 to DXF code 67 / `*Paper_Space` block / LAYOUT.
- **Viewport-into-model = a separate `Layout.viewports: [ViewportRecord]` list, NOT an `EntityKind` case** (recommended → zero blast on the 28 switches). `ViewportData { paperRect: AABB; viewCenter; viewHeight; twist }`; render = build a child `Viewport` camera over the model region, clip to `paperRect`, draw offset on the sheet (reuses `Viewport` math + `Resolve` unchanged).
- **DXF round-trip reality:** code 67 (space), PLOTSETTINGS (paper size), single built-in `*Paper_Space` block, and `writeViewport` all work on **stock vendored libdxfrw** → single-layout round-trips with bridge-only changes. **LIMITATIONS:** reading the named LAYOUT dictionary and writing >1 paper-space block need a **vendored libdxfrw patch** (follow-up); first deliverable reconstructs a single Layout1 from the `*Paper_Space` block + PLOTSETTINGS.

## 3. Phased plan (independently shippable; owned files; HOT=serialize)
| Phase | Scope | Effort | Owned files | Hot/serialize |
|---|---|---|---|---|
| **P0** | Layout model + per-entity space + persistence (no UI/DXF) | M | `CADDrawing.swift`, `Entity.swift` (additive struct fields), `LibreCADDocument.swift` (`DXFPayload.layouts`) | CADDrawing, Entity |
| **P1** | DXF/DWG read+write of paper space (code 67, single layout, PLOTSETTINGS, VIEWPORT flatten) | L | `DxfBridge/lcdxf.{cpp,h}`, `DXFReader.swift`, `DXFWriter.swift` | bridge |
| **P2** | Layout tab UI + render the sheet (margins/border), scope snap/selection to active space | L | `ContentView.swift`, `CanvasModel.swift`, `LineRenderer.swift` | ContentView, CanvasModel, LineRenderer |
| **P3** | Viewport entities (clipped model window on the sheet) + `ViewportTool` | L | new `ViewportEntity.swift`, `CADDrawing.swift`, `LineRenderer.swift`, new `Tools/ViewportTool.swift`, bridge VIEWPORT | CADDrawing, LineRenderer, lcdxf |
| **P4** | Per-layout plot (sheet-accurate PDF/print at plot scale) | S–M | `Export/DrawingPrinter.swift`, `DrawingExporter.swift`, `PrintLayout.swift` | isolated (can run with P3) |
| **FU** | Multi-layout DXF write + LAYOUT dict read | M–L | vendored `libdxfrw/*` patch | vendored lib |

Sequence: P0 → P1 → P2 → P3 → P4. P0 + bridge-half of P1 can parallelize (disjoint files) once P0 types are stubbed. **P2 and P3 serialize** (both edit CanvasModel+LineRenderer). P4 isolated.

## 4. Risks + scope cuts
- **EntityKind blast (28 files)** → mitigate by keeping viewports OFF the enum (separate list) + space as a struct field. (Biggest risk, mitigated.)
- **Viewport clipping/nested resolve** → v1: rectangular clip only, fixed scale set at creation, no per-viewport frozen layers / UCS / twist.
- **DXF LAYOUT fidelity** → v1 single layout on stock libdxfrw; multi-layout + tab names = libdxfrw patch follow-up.
- **Quadtree/selection global today** → per-space index or filter by space, rebuild on tab switch.
- **Naming** → never reuse `Viewport`; use `ViewportData`/`PaperViewport`.

## 5. Recommended MINIMAL first deliverable (concept proof, low risk, stock libdxfrw)
**P0 + thin P1 (read code 67 + reconstruct a single Layout1 from `*Paper_Space` block + PLOTSETTINGS) + thin P2 (Model/Layout tab that renders the sheet rect + shows loaded paper-space annotation).**
Demonstrates: import a real AutoCAD drawing → see its Layout1 sheet with paper-space text/lines → switch to model space → save → code 67 preserved. No viewports, no multi-layout, no plot yet.
