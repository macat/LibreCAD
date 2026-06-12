# Features v2 — 4 directions (text/dims/fills · save · trim/extend · layers sidebar)

User picked all four (2026-06-12). Orchestrated as dependency-ordered waves with **disjoint file ownership**
(no two concurrent agents touch the same file) and **controlled batches** (≤4 concurrent, given the prior
infra watchdog stall). Coordinator merges + wires central registries (ToolKind/toolbar) between waves.

## Hot files (serialize owners across waves)
- `Entity.swift` + `Resolve.swift` (entity kinds + resolve) → one owner per wave.
- `DxfBridge/lcdxf.{cpp,h}` (read + write share the C shim) → writer (wave 1) then reader-extend (wave 2).
- `ContentView.swift`/`LibreCADApp.swift` (app shell) → sidebar (wave 1) then save-menu (wave 2).
- `Tool.swift`/`ToolKind.swift` → ToolContext widening (wave 1); tool registration = coordinator step.

## Wave 1 — foundational + disjoint (4 parallel builders)
| WS | Branch | OWNS | Deliverable | Task |
|----|--------|------|-------------|------|
| W1a ToolContext widen | `ws/toolctx` | `Tool.swift`, `CanvasModel.swift` | Add boundary/other-entity access to ToolContext (+ makeToolContext) so Trim/Extend/Fillet can find intersections. Keep existing tools compiling. | #10 |
| W1b DXF writer | `ws/dxfwrite` | `DxfBridge/{lcdxf.cpp,lcdxf.h}`, `CADEngine/DXFWriter.swift`(new) + tests | libdxfrw write side (write* callbacks) + `DXFWriter` (CADDrawing→.dxf, R2000+); round-trip test (read dim_sample → write → re-read, counts match). | #9 |
| W1c entity kinds (display) | `ws/displaykinds` | `Entity.swift`, `Resolve.swift`, `CADDrawing.swift` + tests | Add `text/hatch/solid` to EntityKind + resolve (text→.lff strokes via ResolveContext.fontProvider; hatch/solid→ResolvedFill loops); wire a default fontProvider in `makeResolveContext` (bundled .lff). | #8 |
| W1d Layers sidebar | `ws/sidebar` | `ContentView.swift`, `Sidebar/*.swift`(new) | NavigationSplitView sidebar: layers visible/lock/active/color/rename/add/remove via CADDrawing undoable methods; Blocks/Views stub. | #11 |

(W1a/W1b/W1c/W1d touch disjoint files — verified.)

## Wave 2 — after wave 1 merges (controlled batches)
- **W2a Trim + Extend** (`Tools/{TrimTool,ExtendTool}.swift`) — use widened ToolContext (W1a) + Intersections. [after W1a]
- **W2b Fillet + Chamfer** (`Tools/{FilletTool,ChamferTool}.swift`) — widened context. [after W1a]
- **W2c Renderer fills** (`Renderer/{LineRenderer,Shaders,OverlayGeometry}.swift`) — earcut-triangulate ResolvedFill → triangle pipeline. [after W1c for data; pipeline can start vs existing ResolvedFill shape]
- **W2d Reader import text/hatch/solid** (`DxfBridge/lcdxf.*`, `DXFReader.swift`) — map DXF TEXT/MTEXT/HATCH/SOLID → new kinds. [after W1b (shares lcdxf) + W1c (kinds)]
- **W2e Save/Open panels** (`ContentView.swift`, `LibreCADApp.swift`) — NSSavePanel/fileImporter + ⌘S/⇧⌘S using DXFWriter. [after W1b + W1d (shares ContentView)]
- Coordinator: wire Trim/Extend/Fillet/Chamfer into ToolKind/toolbar/keys (one step, after they merge).

## Rules (every brief)
Disjoint ownership; namespaced test suites; build+test green (`--disable-sandbox`); commit to `ws/<name>`,
no merge/push; coordinator merges (overlap-checked) + rebuilds green + wires registries. User GUI-verifies.
