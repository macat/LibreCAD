# Tool fan-out — draw + modify (Phase 4 "broad parity")

Built on the merged Tool framework (`Tools/Tool.swift`): pure value-type tools, per-tool `enum State`,
`handle(ToolInput, ToolContext) -> ToolOutcome`, emitting `.commit([ToolEdit])` (add/replace/remove).
LineTool is the canonical draw example; the contract is modify-ready (ToolEdit + ToolContext.selected).

## Collision rule (key)
Each tool builder creates ONLY `Tools/<X>Tool.swift` + `Tests/.../<X>ToolTests.swift`. **No builder edits
`ToolKind.swift`** (the central registry) — the **coordinator** wires every new tool into ToolKind +
the toolbar/keys in one integration step after merge. → fan-out files are fully disjoint, zero conflict.
Tools mirror LineTool's EntityRecord layer/pen/flags field values for consistency.

## Wave A (parallel, dispatched 2026-06-11) — draw tools + shared deps
| Agent | Branch | Deliverable |
|---|---|---|
| app-fix | `ws/appfix` | Fix cursor↔world offset (screen→world transform / inset / snap) + ⌫ Delete-selection command. App layer. |
| entity-transform | `ws/transform` | Shared `Affine2D` + `EntityKind.transformed(by:)` (translate/rotate/scale/mirror per kind) — needed by modify tools. |
| tool-circle | `ws/tool-circle` | Circle (center+radius) |
| tool-arc | `ws/tool-arc` | Arc (center→start→end, CCW) |
| tool-rect | `ws/tool-rect` | Rectangle (2 corners → closed polyline) |
| tool-polyline | `ws/tool-polyline` | Polyline (multi-vertex → one polyline) |
| tool-point | `ws/tool-point` | Point (click places a point) |

## Wave B (after entity-transform merges) — modify tools
Move, Copy, Rotate, Scale, Mirror — each reads `ToolContext.selected`, uses `EntityKind.transformed(by:)`,
emits `.replace(id, kind)` (move/rotate/scale/mirror) or `.add` (copy). Delete = ⌫ command (Wave A).

## Wave C (later) — geometry-heavy modify
Trim, Extend, Offset, Fillet, Chamfer (use Intersections + offset geometry). Higher complexity.

## Coordinator integration (after each wave)
1. Review each tool (logic + contract adherence + tests — GUI-free, headlessly verifiable).
2. Merge disjoint tool branches; rebuild+test green after each.
3. Wire ToolKind (case + title + makeTool arm) + toolbar buttons + keyboard shortcuts for the new tools.
4. User verifies the GUI (the part that can't be checked headlessly).
