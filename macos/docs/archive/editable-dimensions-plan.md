# Editable Live Dimensions (Dynamic Input) — Build Plan (corrected)

> From the `editable-dynamic-input-probe` workflow (3 probes → plan → critic, verdict
> **APPROVE-WITH-FIXES**; all 9 critic fixes applied below). Builds AFTER command-line redesign
> Wave 3 (merged `b85c59f38`); the held redesign Wave 4 runs AFTER this. Additive only, no new
> `EntityKind`/`ToolKind`/`ToolInput`. Worktrees branch off `native-macos`; merge by hash; serial tests.

**User ask:** make the live dimensions editable (type a value into the active field), Tab between the
two fields when there are two, keep the existing dotted-line + chip style. **Bug:** rectangle shows one
`.size` line — it should show **two** dimension lines (width + height).

v1 tools: Line (length+angle), Rectangle (width+height), Circle (radius/diameter), Polygon (radius).

## Design (critic-corrected)

### Data model — `Tools/Tool.swift` (additive only; `.size` kept but unused by v1 tools)
```swift
public enum LiveDimensionField: String, Sendable, Equatable, Hashable { case length, angle, width, height, radius, diameter }
public enum LiveDimensionEditState: Sendable, Equatable { case idle, active, locked }
// LiveDimension gains (all defaulted → every existing emit site compiles unchanged):
public let field: LiveDimensionField?     // nil = not editable
public let isEditable: Bool               // default false
public let editState: LiveDimensionEditState   // default .idle (set by the model, not the tool)
public let typedString: String?           // default nil  (the raw buffer to echo when typed/active)
// + a copy helper so the model can re-stamp display state on a tool-emitted dim:
func withEditing(editState:typedString:) -> LiveDimension
```
The raw numeric value already lives in `Kind` (`.linear/.radius/.diameter/.angle` carry it). Tools set
only `field` + `isEditable`; the **model** sets `editState`/`typedString` while editing.

### Engine commit — `Tool.applyDynamicInput` (member + default-nil extension, mirrors `liveDimensions`)
```swift
func applyDynamicInput(_ values: [LiveDimensionField: Double], cursor: Vector, reference: Vector) -> Vector?  // default nil
```
Returns the world point fed to `handleToolInput(.value(point))` — reuses the proven coordinate-commit
seam; **no new `ToolInput` case**. Per-tool (critic-corrected):
- **Line** (reference = running endpoint `last`): free mode → `reference + Vector(angle: values[.angle] ?? liveAngle) * (values[.length] ?? liveLen)`. **Constrained** (`.absolute`/`.relative`, `constraintAngle != nil`): `.angle` is read-only; point = `reference + Vector(angle: constraintAngle!) * (values[.length] ?? liveLen)` (lands on the locked ray — must go through the same constraint the commit uses).
- **Rectangle** (reference = `firstCorner`; preserve cursor-quadrant signs, corners are NOT min/max-reordered): `Vector(reference.x + signX*(values[.width] ?? liveW), reference.y + signY*(values[.height] ?? liveH))`.
- **Circle** (editable ONLY in the `.settingRadius(center:)` state; reference = center; zero-safe dir): `r = values[.radius] ?? values[.diameter].map{$0/2} ?? liveR`; `reference + unit(cursor-reference) * r`.
- **Polygon** (editable ONLY in `.settingVertex(center:)` center modes; reference = center): same radius form, returns the vertex point.

### Rectangle fix — one diagonal `.size` → two edge `.linear` dims (`RectangleTool.liveDimensions`)
With `first` = corner, `c` = cursor:
- WIDTH (bottom edge): `from=first`, `to=(c.x,first.y)`, `.linear(|c.x-first.x|)`, anchor=`((first.x+c.x)/2, first.y)`, `field:.width`, `isEditable:true`.
- HEIGHT (right edge): `from=(c.x,first.y)`, `to=(c.x,c.y)`, `.linear(|c.y-first.y|)`, anchor=`(c.x,(first.y+c.y)/2)`, `field:.height`, `isEditable:true`.
Existing `.linear` witness-tick rendering already handles arbitrary orientation — no overlay change for the lines. Tab order = array order `[width, height]`.

### Model — `Canvas/CanvasModel.swift` (additive; the synthetic-cursor refinement)
State (`@ObservationIgnored`, like `tool`): `dynEditing: Bool`, `dynActiveField: LiveDimensionField?`,
`dynBuffers: [LiveDimensionField: String]`. A field is **locked** ⟺ it is non-active AND its buffer
parses to a Double. `var hasEditableLiveField: Bool { currentLiveDimensions().contains{ $0.isEditable } }`
(replaces the non-existent `hasStartedOperation`).
- `effectiveCursor()` = `tool.applyDynamicInput(parsedBuffers, cursor: cursorWorld, reference: anchor) ?? cursorWorld`.
- While editing, the model drives the tool with `.move(effectiveCursor())` so the **preview + dims reflect typed values live**; on real mouse move it recomputes from the new real cursor.
- Methods: `beginDynInput(firstChar:)` (active = first editable field, seed buffer) · `dynAppend(_:)` (digit/`.`/`-`) · `dynBackspace()` · `dynCycleField(reverse:)` (Tab/Shift-Tab over editable fields) · `dynCommit()` (`handleToolInput(.value(effectiveCursor()))`, reset) · `cancelDynInput()` (clear buffers, keep cursor tracking — does NOT cancel the tool).
- `currentLiveDimensions()` re-stamps each editable dim via `withEditing`: active field → `.active` + buffer; locked field → `.locked` + buffer; else `.idle`.
- Reset dyn state in `activateTool` and in `handleToolInput`'s commit/finished/cancel arms; clamp `dynActiveField` when the editable-field set changes.

### View — `Canvas/CADCanvasView.swift` + `Canvas/LiveDimensionOverlay.swift`
- **keyDown** (`handleKey`): a guarded block placed **before the `isEscape` ladder and the `isReturn` commit**, after F8/F7, before Space. Gate on `!command && !option` AND `charactersIgnoringModifiers` ∈ digit/`.`/`-` (pure static `firstEditableChar(event) -> Character?`). While `dynEditing`: digit/`.`/`-`→`dynAppend`; Tab(keyCode 48)→`dynCycleField(reverse: shift)` (consume, return true); Return→`dynCommit`; Esc→`cancelDynInput`; ⌫→`dynBackspace`. Not editing + `dynamicInputEnabled && isToolActive && hasEditableLiveField` + first editable char → `beginDynInput`. Else fall through (Tab returns false when not editing → normal focus traversal).
- **Overlay** stays `hitTest→nil` click-through; one new `activeFieldProvider` not needed (state is stamped on the dims). `drawLabel` branches: `.active` → draw `typedString` + caret in accent chip (`labelBoxFillActive`/`StrokeActive`); `.locked` → draw `typedString` in a pinned tint; `.idle` → draw `label` (unchanged). Pure static `caretX(prefix:attributes:) -> CGFloat` (headless-tested via the `_SharedLiveDimensionOverlay.swift` symlink). `labelBox` math unchanged. **Keep dash `[2,3]`, rounded translucent chip, monospaced-digit 11pt.**

## Waves (all AFTER redesign Wave 3 = merged; each single-owner, sequential on shared files)
- **Wave EE (engine, one owner)** — `Tools/Tool.swift` (the two enums + the 4 additive `LiveDimension` fields + `withEditing` + `applyDynamicInput` member/default) + `Tools/RectangleTool.swift` (two `.linear` dims + `applyDynamicInput`) + `Tools/LineTool.swift` + `Tools/CircleTool.swift` (editable only in `.settingRadius`; pass `editable:` into the shared `radiusDimension` helper, default false so 2P/3P stay non-editable) + `Tools/PolygonTool.swift` + tests: update `LiveDimensionTests.swift:290-319` (the 3 rectangle tests → 2 `.linear` dims) + new `applyDynamicInput` per-tool tests. **Ships the rectangle visual fix.**
- **Wave M (model, one owner)** — `Canvas/CanvasModel.swift` (dyn state + methods + `effectiveCursor`/synthetic-cursor + `currentLiveDimensions()` re-stamp + `hasEditableLiveField` + reset hooks) + headless tests.
- **Wave V (view, one owner)** — `Canvas/CADCanvasView.swift` (keyDown block + Tab decode) + `Canvas/LiveDimensionOverlay.swift` (active/locked/caret rendering + colors + `caretX`) + `LiveDimensionOverlayTests.swift` (caretX). Then `.app` rebuilt.

## Owner decisions (defaults taken)
1. Esc while editing = revert typed entry to cursor tracking (not cancel tool). 2. No mirror to command line (shared commit path). 3. Circle: one editable field (`.diameter` in diameter size-mode else `.radius`), no Tab. 4. Keep `.size` (dead-but-retained; referenced by the overlay switch). 5. Constrained Line angle read-only, length editable via `constraintAngle`. 6. Tab locks current field (buffer) + advances; locked + active buffers feed the synthetic cursor so the preview is constrained live. 7. First digit/`.`/`-` auto-begins editing the first editable field.

## Traps
Additive Tool members only (no `ToolInput` case) · no new EntityKind/ToolKind · CADEngine UI-free (enums/fields/`applyDynamicInput` pure value types) · overlay stays click-through + NO NSTextView/first-responder (headless hang) · keep the style · serial tests · Tab keyCode 48 consumed only while editing · gate keyDown on `!command && !option` + digit/`.`/`-` so menu chords + bare-letter tool switch survive · clamp `dynActiveField` on field-set change · redesign Wave 4 runs AFTER Wave V (shared CADCanvasView).
