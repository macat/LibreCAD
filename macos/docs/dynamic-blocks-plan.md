# Dynamic Blocks — Full Authoring Program (native-macos)

> **STATUS 2026-06-18:** DB-1 (visibility states) + DB-2 (stretch/flip parameters) SHIPPED (see decision-log 2026-06-16). DB-3/DB-4/DB-5 remain DEFERRED — this doc is kept as the reference for those remaining phases only.

Owner chose **full authoring** (parameters / actions / grips). Authoritative feature spec:
`macos/docs/block-features.md` §5–§13 + Appendix B. This plan refines `block-ux-plan.md` §7
(DB-1..DB-5) into a buildable, file-grounded wave program. Read with `block-ux-plan.md` §0–§6
(near-term asks 1–4; this plan is ask 5).

Synthesized 2026-06-16 from a code audit of the engine value model + the existing on-canvas
live-drag (gizmo) machinery. **Critic-reviewed 2026-06-16 (verdict GO-WITH-FIXES); all six findings
folded in below.**

> **NUMBERING RECONCILIATION (read first).** `decision-log.md` (the "NEXT" line) records the
> sequence as *DB-1 = params/actions/grips → DB-2 = visibility states*. **This plan deliberately
> INVERTS that order on the merits** — visibility states are self-contained (no grip-drag), so they
> are the cheapest slice that de-risks the instance-aware resolve seam + overlay hosting. Here:
> **DB-1 = visibility states; DB-2 = params/actions/grips.** Before DB-0 dispatches, the coordinator
> MUST add a decision-log entry recording this reorder + rationale (so the two DB-1 definitions in
> the repo don't contradict each other). Do not leave the conflict unresolved.

---

## 0. The one architectural decision everything hangs on

`resolveInsert` today is **instance-agnostic**: `blockProvider: (String) -> [EntityRecord]?` looks a
block's members up **by name only** (`CADDrawing.makeResolveContext:1425`, `blockMembersSnapshot:1434`).
Every insert of `"Door"` resolves to the IDENTICAL geometry — there is no per-instance variation
hook. Dynamic blocks REQUIRE per-instance variation (this insert is flipped, that one stretched to
900mm, the third shows visibility state "Ball Valve").

**The seam:** dynamic evaluation must be a PURE function
`(blockDefinition, instanceState) -> [evaluated member EntityRecords]`, threaded into the existing
`resolveInsert` member loop. We add the instance state to `InsertData` (additive) and the
definition state to `Block` (additive), and `resolveInsert` calls a new
`BlockEvaluator.evaluate(...)` BEFORE the existing transform∘resolve member loop. No new
`EntityKind` case; the recursion guard / MINSERT / `.byBlock` threading all stay exactly as-is
because evaluation produces a member `[EntityRecord]` array — the same shape `blockProvider`
already returns.

This keeps the FROZEN-value, resolve-on-demand architecture (ADR-001): the instance stores only
parameter VALUES; the evaluated geometry is derived, never stored.

---

## 1. Current-state findings (cited)

### Engine value model (the additive pattern to mirror)
- `Block` (`Block.swift:97`) — `name`/`basePoint`/`entityIDs`/`isFrozen`/`attributeDefs`.
  `attributeDefs` was added ADDITIVELY with a hand-written `init(from:)` using `decodeIfPresent`
  (`Block.swift:139–148`) — **the exact pattern** dynamic fields follow.
- `InsertData` (`Entity.swift:881`) — `blockName`/`insertionPoint`/`scale`/`rotation` + MINSERT
  (`rows`/`cols`/`colSpacing`/`rowSpacing`) + `attributes: [BlockAttributeValue]`. `attributes`
  was added additively with custom `CodingKeys` + `decodeIfPresent` (`Entity.swift:935–954`) — the
  pattern instance state follows.
- `EntityRecord` (`Entity.swift:1253`) is the unit of value geometry; `EntityKind.transformed(by:)`
  (`EntityTransform.swift:215`) is the pure transform used by resolve, clipboard, gizmo. **All
  action geometry reuses this — no new transform code.**
- **No new `EntityKind` case anywhere.** The enum (`Entity.swift:1163`) is switched exhaustively in
  ~9 engine files; a new case is the serialized critical section we AVOID entirely here.

### Resolve (where evaluation hooks in)
- `resolveInsert` (`Resolve.swift:1313`): guards depth, fetches `members = ctx.blockProvider?(name)`,
  threads `currentBlockPen` + decremented depth, loops MINSERT cells, transforms each member by
  `insertTransform` (`Resolve.swift:1292`) and resolves recursively, then emits ATTRIBs via
  `resolveAttribute` (`Resolve.swift:1357`). **The single insertion point for dynamic evaluation is
  between fetching `members` and the cell loop** (filter + transform the member array first).
- `blockProvider` is wired in `makeResolveContext` (`CADDrawing.swift:1425`) from
  `blockMembersSnapshot` (`CADDrawing.swift:1434`, skips frozen blocks, value copies). To make
  evaluation instance-aware we pass the `Block` definition's dynamic fields (parameters/actions/
  states) alongside the members — either by extending the provider return, or (cleaner) a parallel
  `dynamicBlockProvider: (String) -> DynamicBlockDef?` that `resolveInsert` consults.

### Grip / live-drag machinery (THE reusable seam — cited in full)
There is a complete, production-quality on-canvas direct-manipulation stack already:
- **Pure math, engine:** `GizmoTransform.swift` (`GizmoTransform.swift:144`) — `move`/`cornerScale`/
  `rotate` builders mapping a drag's world endpoints → `Affine2D`, plus `GizmoFrame`
  (`GizmoTransform.swift:53`) and `GizmoHandle` (`GizmoTransform.swift:114`, cases `.move`/
  `.corner(Corner)`/`.rotate`). Unit-tested. **This is exactly the "given a drag from p0→p1 yield a
  transform" abstraction dynamic grips need.**
- **View overlay, app:** `GizmoOverlayView` (`GizmoOverlay.swift:56`) — a transparent flipped
  `NSView` over the Metal canvas. It does screen↔world mapping + `hitTest` (returns self ONLY over a
  handle, `GizmoOverlay.swift:182`), runs the drag lifecycle (`mouseDown`/`mouseDragged`/`mouseUp`,
  `:192–234`), publishes a live preview (`model.setGizmoPreview`, `:214`) and commits ONE undoable
  edit on mouse-up (`model.commitGizmoTransform`, `:230`). Drawn handles: corner squares, rotate
  knob+stalk (`:299–301`, `:326`).
- **Model commit path:** `CanvasModel.setGizmoPreview`/`gizmoPreviewPolylines`/`commitGizmoTransform`
  (`CanvasModel.swift:2636/2621/2654`) — preview resolves the dragged selection through
  `kind.transformed(by:)` (`:2626`); commit routes full-record replacements through
  `applyInspectorEdits` (`:2664`) — the undoable funnel.
- **Hosting:** the overlay is created + added as a subview in the canvas controller
  (`CADCanvasView.swift:616–619`), refreshed on selection/pan/zoom; `requestRedraw`
  (`CADCanvasView.swift:681`) repaints the Metal canvas.

**Implication:** dynamic-block grips are a NEW sibling overlay (`DynamicGripOverlayView`) built to
the SAME contract, OR an extension of the gizmo overlay's hit-test/drag loop. They differ from the
gizmo in WHAT a drag commits: not `transformed(by:)` on the selection, but a write to the selected
insert's `parameterValues` followed by a re-resolve. The drag→world-delta→value mapping reuses
`GizmoTransform`'s primitives (a linear-param grip drag is a constrained `move`; a rotation grip is
`rotateAngle`; a flip grip is a click toggle; a visibility/lookup grip is a dropdown, not a drag).

### Block-edit scope (where authoring UI lives)
- `CanvasModel.enterBlockEditing`/`exitBlockEditing(save:)`/`finishBlockEditingIfNeeded`
  (`CanvasModel.swift:1038/1093/1153`) — a working REFEDIT/BEDIT scope: scopes the index to a
  block's members, frames the camera, opens ONE undo group, snapshots for Discard. `editingBlock`
  (the name) + `editingBlockEntities` (`:1007`) give the authoring palette its target. Authoring
  parameters/actions = editing the `Block`'s dynamic fields while in this scope.

### Selection + insert identification
- `CanvasModel.selection` (`CanvasModel.swift:162`), `selectionWorldBounds` (`:2599`). A grip
  overlay shows when the single selected entity is an `.insert` whose block is dynamic. (Need a
  `singleSelectedInsert` accessor — added in the wire-wave, NOT a feature-agent file.)

---

## 2. The additive data model (concrete structs)

All NEW engine types in **NEW files** so feature agents never touch the hot enum file
(`Entity.swift`) for the type DEFINITIONS. The two ADDITIVE FIELD insertions (`Block` gains a
dynamic bundle; `InsertData` gains instance state) DO touch `Block.swift` / `Entity.swift` — those
are the serialized critical sections (see §4). Bundling all dynamic definition state behind ONE new
optional struct on each side minimizes the hot-file edit to a single field + one `decodeIfPresent`
line each.

### 2a. Definition side — one optional bundle on `Block`
NEW file `CADEngine/DynamicBlock.swift`:

```swift
/// All dynamic-authoring state for a block definition. Optional bundle so a plain
/// block (and every old saved file) carries `nil` and is byte-identical. (block-features §5–§10.)
public struct DynamicBlockDef: Sendable, Hashable, Codable {
    public var parameters: [BlockParameter]
    public var actions: [BlockAction]
    public var visibilityStates: [BlockVisibilityState]   // §9; empty ⇒ no visibility param
    public var lookupTables: [BlockLookupTable]            // §10
    public init(parameters: [BlockParameter] = [], actions: [BlockAction] = [],
                visibilityStates: [BlockVisibilityState] = [], lookupTables: [BlockLookupTable] = []) { … }
    public var isEmpty: Bool { parameters.isEmpty && actions.isEmpty
        && visibilityStates.isEmpty && lookupTables.isEmpty }
}

/// Stable per-parameter id (string key into InsertData.parameterValues, like a layer name keys layers).
public struct BlockParameterID: Sendable, Hashable, Codable { public let raw: String }

public struct BlockParameter: Sendable, Hashable, Codable, Identifiable {
    public var id: BlockParameterID
    public var label: String              // §5.3 Properties-palette name
    public var kind: BlockParameterKind   // the discriminator below
    public var valueSet: BlockValueSet    // §8 (None/List/Increment); .none default
    public var chainActions: Bool         // §13.1; default false
    public var showProperties: Bool       // §5.3 Show; default true
}

/// The param-type union. NOT an EntityKind case — its own enum, switched only inside
/// the new DynamicBlock files (no fan-out). (block-features §5.2.)
public enum BlockParameterKind: Sendable, Hashable, Codable {
    case point(base: Vector)                                   // §5.2.1  1 grip
    case linear(base: Vector, end: Vector)                     // §5.2.2  2 grips; distance+angle derived
    case polar(base: Vector, end: Vector)                      // §5.2.3
    case xy(base: Vector, end: Vector)                         // §5.2.4
    case rotation(center: Vector, baseAngle: Double, defaultAngle: Double)  // §5.2.5
    case alignment(base: Vector, direction: Vector)            // §5.2.6  (DB-5; self-contained)
    case flip(reflectStart: Vector, reflectEnd: Vector)        // §5.2.7  1 toggle grip
    case visibility                                            // §5.2.8  dropdown; one per block
    case lookup(tableID: String)                               // §5.2.9  dropdown
    case basePoint(at: Vector)                                 // §5.2.10 (DB-5)
}

/// Selection set = the member EntityIDs an action moves/stretches/etc. (block-features §6.1, §13.3.)
public struct BlockAction: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var kind: BlockActionKind
    public var parameterID: BlockParameterID  // §6.1 every action is associated with a parameter
    public var memberIDs: [EntityID]          // the action's selection set
    public var keyPoint: BlockKeyPoint        // WHICH parameter key point drives it (start/end/…)
}

public enum BlockKeyPoint: Sendable, Hashable, Codable { case start, end, base, point }

public enum BlockActionKind: Sendable, Hashable, Codable {
    case move(distanceMultiplier: Double, angleOffset: Double)               // §6.2.1, §13.4
    case stretch(frame: StretchFrame, distanceMultiplier: Double, angleOffset: Double) // §6.2.3
    case rotate                                                              // §6.2.5
    case flip                                                                // §6.2.6
    case scale(base: ScaleBase)                                             // §6.2.2 (DB-5)
    case polarStretch(frame: StretchFrame)                                  // §6.2.4 (DB-4)
    case array(columnOffset: Double, rowOffset: Double)                     // §6.2.7 (DB-4)
    case lookup(tableID: String)                                           // §6.2.8 (DB-3)
}

/// A crossing window in block-LOCAL coords; vertices inside move/stretch, vertices outside stay. (§6.2.3.)
public struct StretchFrame: Sendable, Hashable, Codable { public var min: Vector; public var max: Vector }
public enum ScaleBase: Sendable, Hashable, Codable { case dependent; case independent(Vector) }

/// §9 — a named visibility state: which member ids are visible. The DEFAULT state is index 0.
public struct BlockVisibilityState: Sendable, Hashable, Codable, Identifiable {
    public var id: String          // the state NAME (the dropdown label + the instance key)
    public var visibleMemberIDs: Set<EntityID>
}

/// §8 — value-set constraint on a (distance/angle) parameter value.
public enum BlockValueSet: Sendable, Hashable, Codable {
    case none
    case list([Double])
    case increment(min: Double, max: Double, step: Double)
}

/// §10 — lookup table: input parameter columns → an output label, with optional reverse lookup.
public struct BlockLookupTable: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var inputParameterIDs: [BlockParameterID]
    public var rows: [BlockLookupRow]      // each: input values + the output label
    public var allowReverse: Bool          // §10.4
}
public struct BlockLookupRow: Sendable, Hashable, Codable {
    public var inputs: [Double]; public var output: String
}
```

**On `Block` (`Block.swift`) — ONE additive field + ONE decode line:**
```swift
public var dynamic: DynamicBlockDef?      // nil ⇒ a plain (non-dynamic) block
…
dynamic = try c.decodeIfPresent(DynamicBlockDef.self, forKey: .dynamic)   // additive
```
Convenience: `var isDynamic: Bool { dynamic?.isEmpty == false }`.

### 2b. Instance side — one optional bundle on `InsertData`
NEW file holds the type; `InsertData` (`Entity.swift`) gains one field:

```swift
/// Per-instance dynamic state. Optional ⇒ a plain insert (and every old file) carries nil. Additive.
public struct InsertDynamicState: Sendable, Hashable, Codable {
    /// Parameter values keyed by `BlockParameterID.raw` (String — see DECIDED note below). A
    /// linear/polar value is the DISTANCE; rotation is the ANGLE (radians); flip is 0/1; point/xy
    /// store an offset vector as two scalars (".x"/".y" suffixed keys).
    public var parameterValues: [String: Double]
    /// Per-parameter flip flags (param id raw → flipped?). §5.2.7.
    public var flipStates: [String: Bool]
    /// The active visibility state NAME, or nil ⇒ the block's default (state 0). §9.4.
    public var activeVisibilityState: String?
    public init(parameterValues: [String: Double] = [:],
                flipStates: [String: Bool] = [:],
                activeVisibilityState: String? = nil) { … }
}
```
**On `InsertData` (`Entity.swift`) — ONE field + ONE decode line** (mirrors how `attributes` was
added at `Entity.swift:905`/`952`):
```swift
public var dynamic: InsertDynamicState?
…
dynamic = try c.decodeIfPresent(InsertDynamicState.self, forKey: .dynamic)   // additive
```

> **DECIDED (was an open question; the critic flagged that an indecision here risks reworking the
> SERIALIZED hot field): `parameterValues`/`flipStates` are `[String: Double]` / `[String: Bool]`
> keyed by `BlockParameterID.raw`, with a typed accessor.** A dictionary with a struct key needs a
> custom CodingKey form; the raw-String map is the simplest stable JSON and is the one the A1/A2
> agent ships. `BlockParameterID` stays a `String` wrapper (`Codable`/`Hashable`) for typed APIs;
> the on-the-wire instance state uses raw String keys. The struct definitions in §2a/§2b above are
> updated to `[String: Double]` accordingly.

---

## 3. Resolve strategy (pure, instance-aware evaluation)

NEW file `CADEngine/BlockEvaluator.swift` — a pure namespace:

```swift
enum BlockEvaluator {
    /// Evaluates a dynamic block instance to its placed member records (PURE; ADR-001).
    /// 1. VISIBILITY: drop members not in the active visibility state (§9).
    /// 2. ACTIONS: for each action (in deterministic order), build the action's transform from the
    ///    instance's parameter value(s) and apply it to ITS selection-set members via
    ///    EntityKind.transformed(by:). A member in multiple selection sets composes both transforms
    ///    (chain actions §13.1 are resolved by ordering + a chain pass).
    /// Returns evaluated [EntityRecord] — the SAME shape blockProvider returns, so resolveInsert's
    /// MINSERT / recursion-guard / .byBlock loop is UNCHANGED.
    static func evaluate(definition: DynamicBlockDef,
                         members: [EntityRecord],
                         state: InsertDynamicState) -> [EntityRecord]
}
```

**PURITY CONTRACT (critic Fix 3 — testable, not just asserted):** `evaluate` MUST treat `members`
as immutable input and return a FRESH array — `var m = members; m[i].kind = …` is fine (Swift CoW
copies on write), but it must never alias sub-arrays across MINSERT cells or mutate shared state.
Because `blockMembersSnapshot` (`CADDrawing.swift:1434`) value-copies into a by-NAME map, per-instance
isolation depends entirely on `evaluate` being pure: instance identity is carried by `d.dynamic`, not
the provider. This is enforced by a done-criterion test (see DB-1): the SAME dynamic block resolved
at two different `InsertDynamicState` values in ONE drawing yields two correct, independent results
(no cross-contamination), and a MINSERT grid of a dynamic block yields identical, non-mutated cells.

**Where it hooks:** `resolveInsert` (`Resolve.swift:1313`) gains ONE branch — after
`members = ctx.blockProvider?(name) ?? []`, if the block is dynamic (consult a new
`ctx.dynamicBlockProvider?(name)`) and the insert carries `d.dynamic`, replace `members` with
`BlockEvaluator.evaluate(...)`. The rest of `resolveInsert` (cell loop, `transformed(by:)`,
recursive resolve, ATTRIB emission) is byte-for-byte the same. A non-dynamic insert skips the
branch → zero behavior change.

**Evaluation order (deterministic, §13.1 chain actions):**
1. Visibility filter (no geometry transform, just member subset).
2. Non-chained actions in declared order, each transform composed onto its members.
3. Chain pass: if a parameter has `chainActions == true` and an action moved geometry that contains
   another parameter's key point, re-evaluate dependent actions. v1 supports a SINGLE chain level
   (one pass) with cycle detection by visited-set; deep cascades = backlog. (Spec §13.1 warns about
   circular chains — we terminate, never loop.)

**Per-action transform math (all via existing primitives):**
- **Move:** `GizmoTransform.move`-equivalent: `Affine2D.translation(delta)` where `delta` is the
  parameter's displacement vector (current value − default), scaled by `distanceMultiplier`, rotated
  by `angleOffset` (§13.4).
- **Stretch:** translate ONLY the member vertices inside the `StretchFrame` by the same delta;
  vertices outside stay. This needs a per-vertex partial transform → a NEW pure helper
  `EntityKind.stretched(insideFrame:by:)` in the BlockEvaluator file (operates on the same
  `*Data` structs `transformed(by:)` does; e.g. a `LineData` with `start` inside the frame moves
  only `start`). Bounded to the entity kinds that can be block members in v1 (line/polyline/
  arc/circle/point) — others fall back to whole-entity move if any defining point is inside.
- **Rotate:** `Affine2D.rotation(angle:about: center)` with `angle` = the rotation parameter's value.
- **Flip:** a mirror `Affine2D` about the reflection line (a reflection matrix; add
  `Affine2D.reflection(about:through:)` if not present, else compose rotate∘scale(-1,1)∘rotate).
- **Scale (DB-5):** `Affine2D.scale(factor:about: base)`.

All produce an `Affine2D` and route through `EntityKind.transformed(by:)` — **no new geometry
codepath, no renderer change** (resolve emits the same `ResolvedGeometry`).

**`blockMembersSnapshot` / `makeResolveContext` (`CADDrawing.swift`)** gains a parallel
`dynamicBlockProvider` closure capturing a `[name: DynamicBlockDef]` value snapshot. This edit is in
the hot `CADDrawing.swift` — assigned to the wire-wave / a serialized engine slot (see §4).

---

## 4. Hot/serialized files (the contention map)

| File | Why hot | Rule |
|---|---|---|
| `Entity.swift` (`InsertData` field + `EntityKind`) | the enum + InsertData | **One owner at a time.** Only the ONE-LINE additive `InsertData.dynamic` field + decode goes here, in a dedicated slot. **No new enum case — ever.** |
| `Block.swift` (`Block.dynamic` field) | block table | One owner; the ONE-LINE additive field + decode. |
| `Resolve.swift` (`resolveInsert` branch) | resolve core | One owner; the single evaluation branch. |
| `CADDrawing.swift` (`makeResolveContext` / snapshot) | drawing funnel | One owner (pairs with the Resolve edit). |
| `CanvasModel.swift`, `ContentView.swift`, `ToolKind.swift`, `CommandPalette.swift`, `LibreCADApp.swift`, `ToolOptionsBar.swift`, `CADCanvasView.swift` | UI wiring | **Batched into a single serialized WIRE-WAVE per phase.** Feature agents never touch these. |

NEW files (disjoint, parallel-safe): `DynamicBlock.swift`, `InsertDynamicState.swift` (or fold into
DynamicBlock.swift), `BlockEvaluator.swift`, `DynamicGrip.swift` (engine grip-model), tests files,
and app-side `DynamicGripOverlayView.swift`, `BlockAuthoringPalette.swift`.

---

## 5. Phased waves

Each phase = **engine model+resolve UNWIRED** (parallel-safe new logic + the small serialized
hot-file edits) → then a **serialized grip/UI WIRE-WAVE**. Every build agent's first step:
`git reset --hard native-macos`.

### WAVE DB-0 — Dynamic data-model foundation (engine, UNWIRED) — **S/M**
The shared additive scaffolding all later phases build on. Land it FIRST and alone (it touches the
hot field-insertion slots, so nothing else can run concurrently on those files).
- **Agent A1 (NEW files only, parallel-safe):** `DynamicBlock.swift` (`DynamicBlockDef`,
  `BlockParameter*`, `BlockAction*`, `BlockVisibilityState`, `BlockValueSet`, `BlockLookupTable`),
  `InsertDynamicState.swift`, + `Tests/CADEngineTests/DynamicBlockModelTests.swift` (Codable
  round-trip, `isEmpty`, accessors).
- **Agent A2 (SERIALIZED hot fields):** add `Block.dynamic` + decode (`Block.swift`); add
  `InsertData.dynamic` + decode (`Entity.swift`). **Depends on A1's types compiling.**
- **DECIDED (critic Fix 5): run A1 + A2 as ONE solo engine agent**, not two. A2 cannot compile
  without A1's types, and the field edits are ~4 lines total — splitting them forces a merge between
  two agents for zero parallelism gain. One agent owns the new files AND the two hot-field touches in
  a single PR. (Note: DB-0 and DB-1 touch DISJOINT hot files — DB-0 = `Block.swift`/`Entity.swift`;
  DB-1 = `Resolve.swift`/`CADDrawing.swift` — so they stay separate sequential waves, no collision.)
- **Done:** types compile; both additive fields decode `nil` for old files; serial suite green; a
  test proves a plain `Block`/`InsertData` is byte-identical (no `dynamic` key emitted when nil — or
  if emitted, decodes back to nil).
- **No EntityKind case. No resolve change yet** (so inserts still resolve exactly as today).

### WAVE DB-1 — **Visibility states** (RECOMMENDED FIRST FEATURE) — **M**
Self-contained: no grip DRAG, no action transform math. Cheapest path to a shippable dynamic-block
feature + proves the instance-aware resolve seam. (Spec §9.)
- **Agent (engine, after DB-0):** `BlockEvaluator.swift` — implement ONLY the visibility filter
  (`evaluate` step 1; actions are a later phase's `evaluate` step 2). Add the `resolveInsert` branch
  (`Resolve.swift`) + `dynamicBlockProvider` snapshot (`CADDrawing.swift`) — these two hot-file
  edits are this agent's serialized slot. `Tests/.../VisibilityResolveTests.swift`: an insert with
  `activeVisibilityState = "B"` resolves to only state-B members; default state when nil; non-dynamic
  insert unchanged.
- **WIRE-WAVE DB-1W (serialized, owns the UI hot files):** dropdown grip on a selected dynamic
  insert (`DynamicGripOverlayView` — visibility grip is a CLICK→menu, not a drag, so it is the
  simplest overlay); a Properties/Inspector picker for the active state; the Block Editor authoring
  affordance to create/rename/delete states + assign members (`BVSTATE`/`BVSHOW`/`BVHIDE`, spec §9.2).
  Owns: `CanvasModel.swift` (a `setInsertVisibilityState` undoable funnel + `singleSelectedInsert`),
  `CADCanvasView.swift` (host the overlay), `ContentView.swift`/`ToolOptionsBar.swift`/
  authoring-palette files.
- **CRITICAL — dual-overlay arbitration (critic Fix 1):** the existing gizmo shows for ANY non-empty
  selection (`refreshGizmo` → shown iff `!isToolActive && textEditor == nil`,
  `CADCanvasView.swift:651`; `GizmoOverlay.swift:125-127`). A single selected dynamic insert would
  otherwise activate BOTH the gizmo (move/scale/rotate the whole insert) AND the new
  `DynamicGripOverlayView` — both transparent flipped NSViews, so on a spatial handle overlap the
  topmost-non-nil `hitTest` wins (order-dependent, undefined). **DB-1W MUST define the arbitration in
  `CADCanvasView.refreshGizmo` (already a hot wire-wave file — no new collision):** when the single
  selection is a dynamic insert, SUPPRESS the gizmo (`gizmo.isHidden = true` + `clearGizmoPreview`)
  and show ONLY the dynamic-grip overlay. (Rationale: dynamic grips ARE the insert's manipulation
  affordance; the user re-positions the whole insert by dragging the insertion-point grip or via the
  Inspector, not the bounding-box gizmo.) This arbitration is established in DB-1W and reused by
  DB-2W unchanged.
- **Done:** import or author a multi-state block; the dropdown grip switches the visible geometry of
  ONE insert without affecting siblings; round-trips through Codable. Serial suite green; `.app`
  rebuilt. **REQUIRED isolation tests (critic Fix 3):** (a) the SAME dynamic block resolved at two
  different `InsertDynamicState` values in ONE drawing yields two correct, INDEPENDENT results (no
  cross-contamination from the by-name `blockMembersSnapshot`); (b) a MINSERT grid of a dynamic
  block yields identical, non-mutated cells. These prove `evaluate`'s purity contract (§3).

### WAVE DB-2 — **Parameters + actions + grips** (the foundation; biggest) — **L**
The grip live-drag layer is the cost. Point/Linear/Rotation/Flip params; Move/Stretch/Rotate/Flip
actions; param↔action association + per-action selection sets. (Spec §5.2.1–.7, §6.2.1–.6, §6.3,
§13.5.)
- **Agent E1 (engine, NEW + serialized resolve slot):** extend `BlockEvaluator.evaluate` step 2
  (actions): move/stretch/rotate/flip transform math, the `stretched(insideFrame:by:)` helper, value
  application from `InsertDynamicState.parameterValues`. NEW `DynamicGrip.swift` — the engine grip
  model: `enum DynamicGripKind { case square(BlockParameterID, keyPoint), rotation(...), flipArrow(...),
  dropdown(...) }`, world anchor points derived from the param + current values, and the pure
  drag→value mapping (`gripValue(after drag: p0→p1)`) reusing `GizmoTransform.move`/`.rotateAngle`.
  Tests: each action type's evaluated geometry for a known param value; grip drag → expected value
  (incl. value-set snapping is DB-3).
- **WIRE-WAVE DB-2W (serialized):** `DynamicGripOverlayView` — extend the gizmo pattern: hit-test the
  param grips on a selected dynamic insert, live-drag publishes a preview (re-evaluate the insert at
  the trial value), mouse-up commits an undoable `parameterValues` write. The Block Authoring palette
  (Parameters/Actions tabs, `BPARAMETER`/`BACTION`/`BACTIONSET`) inside the existing block-edit
  scope; `BTESTBLOCK`-style test mode (a scratch insert of the block-being-edited). Owns all UI hot
  files + the authoring-palette + `DynamicGripOverlayView`.
- **Done:** author a linear-stretch door + a flip; drag the grip on a placed insert and watch the
  geometry update live; ⌘Z reverts the whole drag. Serial suite green; `.app` rebuilt.
- **Test-plumbing note (critic Fix 6, applies to DB-1W + DB-2W):** any test of the new
  `DynamicGripOverlayView` or new `CanvasModel` methods from `CADEngineTests` needs a `_Shared*`
  symlink into the app sources (the established pattern — e.g.
  `Tests/CADEngineTests/_SharedCanvasModel.swift` → `Sources/LibreCADmacOS/Canvas/CanvasModel.swift`).
  Add `_SharedDynamicGripOverlay.swift` (and any new app file under test) as a symlink so the builder
  doesn't rediscover it. Keep ALL modals (NSOpenPanel/sheets) in the View layer — a test reaching a
  modal hangs the headless suite forever (decision-log: the NSOpenPanel hang).

### WAVE DB-3 — Value sets + lookup tables — **M**
List/increment value sets (grip SNAPPING, spec §8); lookup param + table forward+reverse (§10).
Builds on DB-2's grip + param machinery.
- **Engine:** value-set snapping in `DynamicGrip.gripValue`; lookup evaluation in `BlockEvaluator`
  (forward: selected label → set input params; reverse: current inputs → matched label / `<Unmatched>`).
- **WIRE-WAVE DB-3W:** lookup dropdown grip; the lookup-table editor + value-set editor in the
  authoring palette (`BLOOKUPTABLE`).

### WAVE DB-4 — Polar/XY params + polar-stretch/array/chain actions — **L**
Spec §5.2.3–.4, §6.2.4/.7, §13.1. Extends `BlockParameterKind`/`BlockActionKind` (NEW-file enums, no
fan-out) + the evaluator. Array is the hard one (dynamic copy count = distance ÷ offset) — its
evaluated members are GENERATED copies, still a `[EntityRecord]` array (no model change).

### WAVE DB-5 — Extended — **M**
Scale action, alignment parameter, base-point parameter, distance-multiplier/angle-offset overrides.
Spec §5.2.5/.10, §6.2.2, §13.4. (Distance-multiplier/angle-offset are already FIELDS on
`BlockActionKind.move/.stretch` from DB-2 — DB-5 just exposes them in the palette.)

### Deferred (per spec, full-AutoCAD-only / separate subsystem)
- §11 geometric/dimensional **constraints + solver** + §12 **BTABLE** (explicitly full-AutoCAD-only,
  block-features §22).
- **AutoCAD-dynamic-block DXF read/write** (see §6).

---

## 6. DXF interop — v1 = NATIVE round-trip only (defer AutoCAD dynamic-block DXF)

AutoCAD stores a modified dynamic instance as a `*U##` ANONYMOUS block (block-features §19.3, §23.2)
whose geometry is the BAKED current configuration, with the dynamic DEFINITION living in extension
dictionaries / the `BlockTable` record's `AcDbBlockRepresentation`/`AcDbEvalGraph` objects (§19,
§23). Reverse-engineering that graph (parameters/actions/grips ↔ the eval-graph node/edge encoding)
is a **LARGE separate reverse-engineering effort** well beyond this program and is **not in
libdxfrw's stable surface**.

> **STATUS UPDATE (R4a/R4b — IMPLEMENTED, lossless-now).** The original v1 recommendation below
> assumed the engine had its own native (non-DXF) document format that would round-trip the dynamic
> model "for free" via `Codable`. **That is NOT the case: the document IS DXF** (the only on-disk
> format is `.dxf`/`.dwg` through the DxfBridge), so author→save→reopen previously LOST all dynamic
> behavior — the in-memory `DynamicBlockDef`/`InsertDynamicState` `Codable` never reached disk. R4b
> closes that gap: the dynamic model is now persisted LOSSLESSLY inside the DXF itself. See
> **§6a (IMPLEMENTED)** below for the actual mechanism; the strike-through bullet's premise is wrong.

**Recommendation (v1) — original (superseded by §6a; the first bullet's premise is incorrect):**
- ~~Persist the full dynamic model via the engine's **own Codable** (the `DynamicBlockDef` /
  `InsertDynamicState` fields) — the native document format round-trips losslessly with zero extra
  work (it is just more JSON on `Block`/`InsertData`).~~ **WRONG: there is no native non-DXF document
  format; the in-memory `Codable` does not survive a DXF save→reopen. See §6a.**
- **DXF EXPORT of a dynamic insert = BAKE:** write the EVALUATED member geometry as a plain
  (static) block + a plain INSERT, so other CAD apps see the correct current configuration but not
  the dynamism. This reuses `BlockEvaluator.evaluate`'s output — trivial once evaluation exists.
  **CRITICAL (critic Fix 2): the baked block MUST use a regular NON-`*`-prefixed generated name**
  (e.g. `"<BlockName>_eval_<n>"`). The DXF writer explicitly SKIPS anonymous blocks —
  `for block in blocks.blocks where !block.name.hasPrefix("*")` (`DXFWriter.swift:263`) — so a
  `*U##`-named baked block would be silently dropped and the insert would export empty. AutoCAD's
  own `*U##` convention is internal; on export we use a real name (the alternative — special-casing
  baked blocks past the `*` filter — is NOT chosen, to keep the writer's invariant simple).
- **DXF IMPORT:** read AutoCAD dynamic blocks as their *static current geometry* only (which is what
  libdxfrw already surfaces — the visible block). Do NOT attempt to reconstruct parameters/actions.
- Defer full AutoCAD dynamic-block DXF read/write as an explicit backlog item (its own subproject).

This keeps DXF a first-class round-trip for static blocks (unchanged) and makes dynamic blocks a
native-format feature first — matching how attributes/visibility were sequenced ("consume from
imported DXF first", block-ux-plan §3 D1).

---

## 6a. DXF persistence — IMPLEMENTED (R4b, lossless-now)

The document is DXF-only, so the dynamic model is embedded **inside the DXF** as compact JSON. This
is a LOSSLESS *own-format* round-trip (our save→our reopen recovers the full model); it is NOT the
AutoCAD eval-graph encoding (§6 — still deferred). Other CAD apps simply ignore the embedded JSON and
see the static geometry.

**The carrier — a reserved-tag block ATTRIBUTE (not XDATA).** The natural DXF carrier would be
extended data (XDATA, group 1001/1000). But the (patched-)vendored libdxfrw's DXF writer emits
entity `extData` for only MTEXT/MLINE/UNDERLAY — **NOT for INSERT, and never for the BLOCK record** —
and its appData (code-102) *reader* is broken. So XDATA/appData does **not** round-trip for
INSERT/BLOCK through the unmodified library (and we do not modify libdxfrw). What DOES round-trip
verbatim is the block ATTRIBUTE path (ATTRIB tag/text on an INSERT; ATTDEF tag/text inside a BLOCK).
The dynamic JSON therefore rides a single **reserved-tag** attribute, tag `LIBRECAD$DYN` (the `$` is
disallowed by AutoCAD in a user attribute tag, so a collision is vanishingly unlikely — the engine
does not sanitize tags, so a hand-authored literal `LIBRECAD$DYN` user tag would be swallowed, an
accepted negligible risk):

| Half | Carrier | Content |
|---|---|---|
| per-INSTANCE state (`InsertDynamicState`) | a reserved ATTRIB on each dynamic INSERT | name/string-keyed JSON (no remap) |
| per-DEFINITION authoring (`DynamicBlockDef`) | a reserved ATTDEF inside each dynamic BLOCK | INDEX-keyed JSON (see remap) |

The C bridge (`lcdxf.cpp`) appends the carrier on write and **filters the reserved tag back out** on
read (surfacing the text as `LCEntity.dynamicJSON` / `LCBlock.dynamicJSON`, never a user-visible
attribute), so the Swift entity model is unchanged. The carrier is marked invisible (attribFlags
bit 1).

**The EntityID↔INDEX remap (the load-bearing correctness piece).** `DynamicBlockDef` references
members by `EntityID` (visibility-state + action member sets). The DXF reader MINTS FRESH sequential
`EntityID`s on every read, so a persisted raw id is stale on reopen. Block members are written and
re-read in stable DECLARATION ORDER, so the wire form is keyed by member **INDEX**: on write each
referenced `EntityID` → its index in the block's written member list; on read each index → the fresh
`EntityID` at that position. Implemented as `DynamicBlockDef.encodeIndexKeyedJSON(memberOrder:)` /
`decodeIndexKeyedJSON(_:memberOrder:)` (pure, in `DynamicBlock.swift`); an out-of-range index or an
unknown id is dropped gracefully. `InsertDynamicState` carries no member ids (only state names +
parameter-id strings), so it needs no remap.

**Limitations.** (1) **DWG**: dwgWriter15 makes empty blocks and emits no attributes, so
dynamic-on-DWG does not round-trip — the bridge skips the carrier on DWG (no crash, def lost). Use
DXF for dynamic-block fidelity. (2) The carrier text is a single DXF group-1 string; compact JSON
keeps it well within the line limit, but a pathologically large dynamic block could in theory exceed
it. (3) §6's **bake-on-export** (write evaluated geometry for OTHER apps) remains the recommended
companion once `BlockEvaluator.evaluate` exists — the embedded JSON makes OUR round-trip lossless;
bake makes the geometry legible to AutoCAD/LibreCAD desktop.

---

## 7. Biggest risk + mitigation

**Risk: the grip live-drag interaction layer (DB-2W).** It is the one piece with no existing analog
that maps 1:1 (the gizmo transforms the SELECTION; a dynamic grip writes an INSTANCE VALUE then
re-resolves). Getting the drag→value mapping, the live preview (re-evaluate at trial value without
committing), and the undoable commit right — across square/rotation/flip/dropdown grip types — is the
schedule risk.

**Mitigations:**
1. **Reuse, don't reinvent:** build `DynamicGripOverlayView` as a near-clone of `GizmoOverlayView`
   (`GizmoOverlay.swift`) — same `hitTest`-over-a-handle-only, same `mouseDown/Dragged/Up` lifecycle,
   same preview-then-commit shape. The transform PRIMITIVES are `GizmoTransform.move`/`.rotateAngle`.
2. **Pure-test the math first:** `DynamicGrip.gripValue(after:)` and `BlockEvaluator.evaluate` are
   pure → fully unit-tested in DB-2's engine slot BEFORE any overlay exists. The overlay then only
   does screen↔world + routing (the gizmo proves this split works).
3. **Ship DB-1 (visibility) first** — its grip is a CLICK→dropdown (no drag), so it lands the
   overlay-hosting + instance-resolve plumbing with the EASIEST grip, de-risking the drag work.
4. **Live preview seam:** add an `insertEvaluationPreview` to `CanvasModel` mirroring
   `gizmoPreviewPolylines` (`CanvasModel.swift:2621`) — resolve the dragged insert at the trial
   `InsertDynamicState` to preview polylines; commit writes the value via `applyInspectorEdits`-style
   funnel.

Secondary risk: **stretch's per-vertex partial transform** (only frame-inside vertices move). Bound
v1 to line/polyline/arc/circle/point members; document the fallback (whole-entity move if any
defining point is inside) for unsupported kinds.

---

## 8. Where a new `EntityKind` case would be TEMPTING — and how we avoid it

| Temptation | Avoid by |
|---|---|
| "A parameter/action is a thing on the canvas → make it an entity" | It is NOT geometry — it is authoring metadata on the `Block` (`DynamicBlockDef`). Grips are drawn by an OVERLAY (like the gizmo), not resolved as entities. |
| "A dynamic insert behaves differently → new `.dynamicInsert` case" | It is the SAME `.insert`; the difference is the additive `InsertData.dynamic` field, evaluated inside the existing `resolveInsert`. |
| "Visibility/array generates/hides members → store them" | Evaluation is PURE and on-demand (ADR-001); `BlockEvaluator.evaluate` returns a derived `[EntityRecord]` — nothing new is stored. |
| "An anonymous `*U##` baked block on DXF export" | A plain `Block` + plain `.insert` — no new case. |

**Net: ZERO new `EntityKind` cases across the entire program.** The ~9 exhaustive switches are never
touched.

---

## 9. Recommended sequencing (summary)

`DB-0 (foundation, solo on hot fields)` → `DB-1 visibility (engine + DB-1W wire)` →
`DB-2 params+actions+grips (engine E1 + DB-2W wire)` → `DB-3 value sets+lookup` →
`DB-4 polar/XY/array/chain` → `DB-5 extended`. DXF = native round-trip throughout (R4b: the model is
embedded in the DXF as reserved-tag-attribute JSON — see §6a, NOT a free native-format Codable);
bake-on-export once DB-2 evaluation exists; AutoCAD dynamic-DXF deferred.

**Concurrency:** DB-0 is ONE solo engine agent (A1 new files + A2 hot-field touches — merged per
critic Fix 5). Every resolve/`CADDrawing` edit and each wire-wave is **single-owner, serialized**;
a wire-wave is one solo agent owning all UI hot files for that phase. Never fan out onto
`Entity.swift`/`Block.swift`/`Resolve.swift`/`CADDrawing.swift`/`CanvasModel.swift` concurrently.

---

## 10. Open questions for the owner (resolve before building)

> The critic review settled the two engineering choices (Q2 Codable key form; Q5/Fix-1 overlay
> arbitration) — those are now DECIDED in §2b/§3/§5. The COORDINATOR action (not the owner) is to
> record the DB-1/DB-2 reorder in `decision-log.md` before DB-0 dispatches (see the header note).
> The remaining items below need OWNER sign-off.

1. **First feature: visibility states (DB-1) vs params+grips (DB-2)?** This plan RECOMMENDS DB-1
   first (self-contained, no drag, de-risks the resolve seam + overlay hosting with the easiest
   grip). DB-2 is the bigger "wow" but the bigger risk. **Confirm DB-1-first** (note: this inverts
   the decision-log's prior numbering — see header).
2. **[DECIDED] `parameterValues` Codable key form** — `[String: Double]` keyed by
   `BlockParameterID.raw` (critic Fix 7; simplest stable JSON, avoids reworking the hot field). No
   owner action needed.
3. **Scope of v1 grip types** — confirm Point/Linear/Rotation/Flip + Visibility for the first shipped
   slice (DB-1+DB-2); Polar/XY/Array/Lookup/Alignment/BasePoint follow (DB-3..DB-5).
4. **DXF export of dynamic inserts** — confirm BAKE-to-static with a REGULAR (non-`*`) block name
   (critic Fix 2; a `*`-named block is dropped by `DXFWriter.swift:263`) is the acceptable v1 behavior
   (vs writing nothing dynamic / vs blocking on full AutoCAD encoding).
5. **Stretch member-kind coverage** — confirm v1 stretch is bounded to line/polyline/arc/circle/point
   (whole-entity-move fallback for text/hatch/nested-insert members).
