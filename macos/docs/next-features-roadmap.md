# Next Features Roadmap — 2026-06-18

The app is now far past table-stakes: **3999 tests**, `EntityKind` ~16 (incl. insert / xline / ray / leader / multileader / image / wipeout / mline), `ToolKind` ~58, `DimKind` 8, and **all 14 original P0s shipped**. The frontier is no longer new drawing features — it is (a) **interop-fidelity VERIFICATION** (we have never opened a real third-party CAD file), (b) **test-infra to autonomously see GUI chrome** (LCShot only renders committed geometry), and (c) **closing residual data-loss plus a few capabilities stranded behind missing UI**. This roadmap supersedes the old `feature-catalog.md` "next 10" list (all done).

## Ranked next steps

1. **Foreign-AutoCAD DWG/DXF fidelity verification** — P0, M. The single biggest CONFIRMED unknown: every DWG/DXF round-trip test is self-generated (our writer ↔ our reader, e.g. `DWGReadWriteTests`); the repo ships NO real third-party `.dwg`/`.dxf`. Flagged twice in the decision-log (2026-06-18 DWG entry; backlog DWG known-gaps). Acquire a real AutoCAD/ODA-produced sample, open it through `CADEngine`'s read path, and add a fidelity-assertion harness (entity / layer / dimstyle / insert / dimension presence). Until then, default-R2000 is the only externally-blessed tier.

2. **GUI-chrome screenshot tier (per-view SwiftUI `ImageRenderer` / AppKit-bitmap snapshot)** — P1, M. LCShot renders committed geometry only, fit-to-page (`gui-test-harness.md` coverage ceiling): it cannot see grid, selection, snap, in-flight preview, crosshair, grips, the constraint glyph, the live-dimension chip, or any SwiftUI chrome. The harness doc itself names this as THE recommended next step (autonomous — no TCC, no window server). Retroactively makes every overlay/chrome feature of the last ~10 entries verifiable.

3. **Insert-a-block tool: wire the block-name picker + drag-drop** — P1, S. The interactive Insert tool is engine+DXF complete but UNWIRED for block selection: `InsertTool` is inert without a `blockName` (`InsertTool.swift:53,94,108-111`); `CanvasModel.beginInsert(name:)` (`CanvasModel.swift:3899-3908`) has zero View callers; there is no picker in the Insert `ToolOptionsBar`; and `BlocksSidebar`'s `.draggable(BlockDragItem)` (`BlocksSidebar.swift:94`) has no canvas drop handler. So ⇧I → click does nothing, and blocks are only placeable via sidebar/menu at the view center. Small, high-value wiring fix.

4. **Non-modal save-loss notice** — P1, S. No View-layer hook fires when `DocumentGroup` saves (off-main `fileWrapper`; a modal there hangs the headless suite), so saving to a lossy format gives no per-save warning. A non-modal banner/toast converts silent data-loss (tables exploded, parametric model dropped, multileader geometry-light) into an informed choice. Highest value-per-effort guardrail; should precede investing in durable persistence.

5. **Multileader (MLEADER) full CONTEXT_DATA DXF write** — P1, M. MLEADER is a first-class `EntityKind`+tool but its DXF write is geometry-light (`lcdxf.cpp:1442-1474`): the CONTEXT_DATA leg points + inline text are not written, and foreign MULTILEADER imports come in empty. Drawn callouts don't survive round-trip. Needs a vendored libdxfrw CONTEXT_DATA writer/parser (precedented by the `writeExtData` dim patch).

6. **Test hygiene: XCTest → swift-testing + dead-code tidy** — P2, S. The tables / constraints / parameters tests still `import XCTest` against the project's swift-testing standard; `PaperSize` still lives in `DocumentSettingsView.swift` (SwiftUI) with a test shim; there is no `CADRender` library target (the `_Shared*` symlinks remain). Cheap, low-risk, keeps the suite consistent before deeper work.

7. **Durable cross-session persistence of tables + parametric constraints/parameters** — P2, L. ACAD_TABLE writes EXPLODED to LINE+TEXT, and the constraint/parameter model rides only the in-session `DXFPayload`; both are lost as editable objects on a pure-file reopen. Needs a sidecar (companion JSON next to the `.dxf`, or XDATA re-import). Sequence after #1 (what other tools tolerate) and #4 (make the loss visible).

8. **Parametric ergonomics + DWG-write fidelity** — P3, M. Parameter RENAME with reference-repoint, dimensional auto-naming (d1/d2), bare-literal binding, and mid-draw `a=22`; plus the DWG writer's empty-blocks + `writeDimstyles` no-op (`lcdxf.cpp:2345` `if(m_dwg) return;`). Lower urgency — additive polish on already-working subsystems.

## Remaining gaps (reference table)

| Gap | Priority | Effort | Status / Note |
|---|---|---|---|
| Foreign-AutoCAD DWG/DXF fidelity verification (#1) | P0 | M | No real third-party file ever opened; all round-trips self-generated |
| GUI-chrome screenshot tier (#2) | P1 | M | LCShot sees committed geometry only; chrome/overlays unverifiable |
| Insert-a-block tool wiring (#3) | P1 | S | Engine/DXF done; picker + drag-drop drop-handler missing |
| Non-modal save-loss notice (#4) | P1 | S | No per-save warning on lossy export; modal would hang headless suite |
| Multileader full CONTEXT_DATA DXF write (#5) | P1 | M | Geometry-light write; foreign MLEADER imports empty |
| Test hygiene: XCTest → swift-testing + dead-code tidy (#6) | P2 | S | Mixed test frameworks; `PaperSize` in SwiftUI; no `CADRender` target |
| Durable persistence of tables + constraints/parameters (#7) | P2 | L | Tables explode; parametric model lives only in-session payload |
| Parametric ergonomics + DWG-write fidelity (#8) | P3 | M | Rename/auto-name/bare-literal; DWG empty-blocks + dimstyle no-op |
| Per-type inline inspector geometry editors (G1) | P1 | M | Partial — some types editable, not all |
| Scale-aware print preview / page-setup / layout PDF (G2) | P1 | M | No scaled print preview or page-setup; layout-to-PDF gap |
| Distance-along-entity + manual middle/intersection snap overrides (G4) | P1 | S | Snap override verbs absent |
| Hatch ellipse/spline boundary tessellated on write | P3 | S | Arcs preserved; ellipse/spline boundaries flattened |
| Long-tail deferred: named views, UCS DXF persistence, GD&T/tolerance, SVG/PDF import | P3 | L | Out of near-term scope; track only |

## Note

This roadmap reflects the 2026-06-18 audit. The decision-log is the authoritative shipped-record; update this file as items land or priorities shift.
