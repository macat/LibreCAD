# GUI test harness — `LCShot`

`LCShot` is a **headless, device-free, panel-free render-to-PNG tool**. It drives a real
`CanvasModel` from a small JSON action script and renders the resulting drawing's **committed
geometry** to a PNG — using the *same* export path the `RasterExportTests` use
(`ExportSceneBuilder.build` → `DrawingExporter.rasterData` → `CGSceneRenderer`). No Metal, no
window, no `NSApplication`, no save/open panel.

**Why it exists:** so an agent (or the coordinator) can *drive an action sequence, render a PNG, open
it, and visually verify how a feature behaved* — turn-after-turn, unattended, from bash. It is the
autonomous substitute for "launch the app and look," which is not reachable from this environment
(window-server / Screen-Recording TCC are blocked; `screencapture`/`osascript`/`cliclick` all fail
here — see the decision-log).

## Run it

```bash
# Convenience wrapper (builds LCShot once, runs a named scene to a gitignored PNG):
bash macos/scripts/lcshot.sh <sceneName>        # -> macos/build/harness-shots/<sceneName>.png
bash macos/scripts/lcshot.sh --list             # list the bundled scenes
bash macos/scripts/lcshot.sh --demo             # built-in hardcoded single-line proof

# Or directly:
swift run --package-path macos/engine --disable-sandbox LCShot <scene.json> [out.png]
swift run --package-path macos/engine --disable-sandbox LCShot --help
```

Then **open the PNG** (e.g. the `Read` tool renders it visually) and analyze the result. A render is
~0.2–0.4s after the one-time build. Run from the repo root so the in-repo font / `.pat` hatch-pattern
asset dirs resolve (the wrapper `cd`s there for you).

PNGs land in `macos/build/harness-shots/` — a **gitignored** dir (never committed). Scenes, the
wrapper, and the `_Shared*.swift` symlinks **are** committed.

## Scene format

A scene is a JSON object: an optional header + an `actions` array ending in a `render`.

```json
{
  "dpi": 150,                       // optional; default 150
  "background": "#RRGGBB",          // optional; default = CAD canvas dark bg
  "space": "model",                 // optional; pre-selects MODEL space only (see note)
  "actions": [ { "op": "...", ... }, ... ]
}
```

### Action verbs (`op`)

| verb | fields | drives |
|---|---|---|
| `addLine` | `from:[x,y]`, `to:[x,y]` | adds a line directly (setup helper) |
| `addCircle` | `center:[x,y]`, `radius` | adds a circle directly (setup helper) |
| `addLayout` | `name` | creates a paper-space layout |
| `activateTool` | `tool:"<ToolKind raw>"` | `activateTool(...)` |
| `click` | `at:[x,y]` | `handleToolInput(.click)` |
| `value` | `n` | `handleToolInput(.value)` (typed distance/coord) |
| `move` | `at:[x,y]` | `handleToolMove(...)` |
| `commit` / `cancel` / `backspace` | — | `handleToolInput(.commit/.cancel/.backspace)` |
| `select` | `ids:[…]` | `setSelection(...)` (surfaces the Bool) |
| `selectAll` | — | `selectAll()` |
| `constrain` | `kind:"<geometric>"`, `ids:[…]` | `addConstraint(<GeometricConstraintKind>)` — **WARN: + no-op (exit 0) if unsupported/wrong-arity** |
| `dimConstrain` | `kind`, `value` or `expression` | `addConstraint(<DimensionalConstraintKind>, …)` |
| `param` | `name`, `expr` | `setParameterExpression(...)` |
| `cmd` | `text` | `interpretCommandLine(...)` (e.g. `"a=22"`, coordinates) |
| `model` / `layout` / `space` | `name` / `model`\|`paper`+`layout` | `activateModel` / `activateLayout` / `setActiveSpace` |
| `zoomToFit` | — | fit the viewport to content |
| `setOption` | `field`, `value` | set a tool-config field then re-apply: `mirrorKeepOriginal`, `currentHatchPattern`, `hatchPatternScale` |
| `render` | `assert:bool`, `path?` | render the PNG; optional `<name>.assert.json` sidecar (entity/selection counts + bbox) |

Note: `space`/`layout` in the *header* only pre-select MODEL space. To render a **paper** layout,
switch INTO it with the `addLayout` + `layout`/`space` **actions** (which run after the layout
exists).

### Authoring rules that bite

- **Modify tools need a selection first.** `MirrorTool` (and other modify tools) read
  `context.selected` — emit `selectAll`/`select` BEFORE `activateTool mirror` + the axis clicks, or
  every click no-ops. See `mirror.json`.
- **Excluded tools fail loud, never hang.** Any tool that would present a file/open/save panel
  (`image`, `createBlock`, `insert`, `table`) is on an **allow-list deny set** — `activateTool` on
  one exits non-zero (code 3) instead of reaching a modal. Don't add panel-driven tools to the DSL.
- **Constraint no-ops are greppable.** An unsupported geometric constraint (e.g. tangent/collinear)
  or wrong entity arity prints a `WARN:`-prefixed stdout line and keeps exit 0 — `grep WARN:` to
  catch silent no-ops.

## Bundled scenes (`macos/engine/Harness/scripts/`)

`line`, `mirror` (keep-original copy), `hatch` (solid fill), `dimension` (arrows + measurement text),
`perpendicular` (two lines re-solved to 90°), `parameter` (parametric center-distance),
`layout-switch` (model vs paper render distinct content). Copy one as a template for a new scene; the
wrapper accepts a bare name or a full `.json` path, so you can drop an ad-hoc scene anywhere and
point `lcshot.sh` at it.

## Coverage ceiling — read this before concluding "broken"

The PNG shows **committed geometry only, framed fit-to-page**, on the CAD canvas background. It does
**NOT** show — because these are AppKit/SwiftUI layers, not part of the export scene:

- grid, selection highlight, snap marker, in-flight tool **preview**, crosshair, grips/gizmo
- the **constraint glyph** (∥ / ⊥ / H / V badges) and the **live-dimension chip**
- any SwiftUI **chrome**: menus, sheets, sidebar/inspector, layout tabs, Preferences

So a constraint scene proves its effect by the **re-solved geometry** (e.g. two lines now meet at
90°), not by a visible glyph. Don't read the *absence* of an overlay/chrome element as a bug.

It also frames **fit-to-page**, not the live viewport's pan/zoom — it answers "did action X produce
the right geometry," not "what does the live canvas look like mid-gesture."

## Deferred tiers (not built)

- **Real-app `screencapture`** (the only way to verify true chrome + AppKit overlays) — confirmed
  non-autonomous here (TCC / window-server blocked). Would need the user to grant Screen-Recording +
  Accessibility, `brew install cliclick`, a de-risking launch spike, and strict no-modal discipline.
- **Per-view SwiftUI `ImageRenderer` / AppKit-bitmap snapshot** (one chrome View → CGImage, no
  window server, no TCC) — the recommended *next* step if chrome/overlay verification is wanted; it's
  the cheap autonomous middle path between Tier-1 and the real app.

## Architecture notes

- `LCShot` is its own `executableTarget` depending **only on `CADEngine`**; it reaches app-module
  types (`CanvasModel`, the exporter) via committed `_Shared*.swift` **symlinks** (the same zero-drift
  pattern the test target uses) — it never imports the app module, so the `CADEngine ⊥ app` boundary
  holds. `LayoutRenderer` is a local compile-only stub so the modal `DrawingPrinter` stays out.
- `MainActor.assumeIsolated { run() }` lives at `main()` only (the CADBench pattern) — never in an
  `App`/SwiftUI init (that SIGTRAPs at launch).
- Single-process == effectively `--no-parallel`, so the Core Text static-init hang does not apply.
