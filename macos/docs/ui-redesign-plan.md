# LibreCAD macOS — UI Redesign Plan: "Seamless & Beautiful"

> One coherent, prioritized, **file-grounded** redesign fusing modern macOS materials/sidebar
> conventions with AutoCAD-idiomatic clarity. Produced by a 11-agent design workflow (5 source
> readers → 4 critique lenses: HIG / CAD / design-tokens / interaction → synthesis → hardening
> audit). **UI-only** — no `EntityKind` switch edits, no `LineInstance` byte-match changes.
>
> **Status:** P0 (color picker) building now in the `ColorSwatch` wave. Waves 1–5 below await owner
> go-ahead on the §5 open questions. _Authored 2026-06-16._
>
> **Audit corrections applied** (resolved decisions flagged inline with ✅): swatch radius = **3**;
> the 2 inspector Form color wells are intentionally **kept** (not shrunk); name-field min-width
> contingency made explicit; Wave 5 toolbar-merge demoted to a **stretch goal** (default = compact
> `barStrip` CurrentPropertiesBar, to honor its "never disappear" invariant); the global-token sweep
> is **folded into each owning wave** (no orphan cross-cutting row); Parts-Library chosen-path
> truncation and Entity/Object vocabulary resolved.

---

## 1. Design direction

Adopt **"Pro-grade macOS"**: the app reads as a first-class Mac document app (system materials,
source-list sidebar, grouped inspector, the standard accent + selection tint, the 8pt rhythm) while
every CAD-specific control speaks AutoCAD's visual grammar (a small color *swatch*, a *dash-pattern*
linetype preview, a *weight-bar* lineweight preview, a status bar with clickable
SNAP/GRID/ORTHO/POLAR/OSNAP toggles, one command line that takes commands *and* coordinates).

The current "dark window chrome behind light floating panels" look is **emergent, not designed** (it
falls out of the dark `CanvasTheme` clear color bleeding behind translucent `.bar` strips while the
sidebar/inspector use default light source-list/grouped-form materials). **Recommendation: keep the
two-tone — but make it intentional.** A dark canvas is correct for CAD (maximizes drawn-line
contrast, matches AutoCAD/BricsCAD muscle memory) and the light source-list/grouped panels are the
native macOS default, so the contrast is *desirable* — we just need to own it by routing every
panel/bar through one token set so the radii, paddings, and selection tints stop drifting. The single
biggest lever is a **design-token file** (`DesignTokens.swift`) all regions reference; without it,
each per-finding fix re-invents its own numbers.

### Design tokens (`Sources/LibreCADmacOS/DesignTokens.swift`, new — `enum DS`)

```swift
import SwiftUI

/// Single source of truth for SwiftUI-chrome metrics. CanvasTheme covers ONLY
/// the Metal canvas; this covers panels/bars/rows. Use these everywhere — no
/// inline radius/padding/width/color literals in views.
enum DS {
    // SPACING — 4pt base. Allowed ONLY {2,4,6,8,12,16,24}. Retire 5,7,9,10,14.
    enum Space { static let xxs:CGFloat=2; static let xs:CGFloat=4; static let sm:CGFloat=6
                 static let md:CGFloat=8; static let lg:CGFloat=12; static let xl:CGFloat=16; static let xxl:CGFloat=24 }
    // CORNER RADIUS — three roles + the swatch exception.
    enum Radius { static let selection:CGFloat=6; static let card:CGFloat=10
                  static let modal:CGFloat=14; static let swatch:CGFloat=3 }   // ✅ swatch = 3 (resolved 3-vs-4)
    // CONTROL SIZE
    enum Size { static let iconButton:CGFloat=22; static let swatch:CGFloat=16; static let rowIcon:CGFloat=20
                static let barDivider:CGFloat=16; static let barPadV:CGFloat=6; static let barPadH:CGFloat=12
                static let listRowMin:CGFloat=22 }
    // FIELD WIDTH — tiers replace the 28..160 grab-bag. `xy` is the documented paired-field exception.
    enum Field { static let xy:CGFloat=56; static let narrow:CGFloat=72; static let std:CGFloat=96; static let wide:CGFloat=130 }
    // TYPE RAMP — semantic roles → system fonts (Dynamic Type preserved).
    enum Font {
        static let panelTitle     = SwiftUI.Font.subheadline.weight(.semibold) // was .headline
        static let rowLabel       = SwiftUI.Font.callout
        static let rowValue       = SwiftUI.Font.callout.monospacedDigit()
        static let secondaryLabel = SwiftUI.Font.caption
        static let hint           = SwiftUI.Font.caption                        // + .foregroundStyle(.tertiary)
        static let barLabel       = SwiftUI.Font.callout.weight(.medium)
    }
    // SEMANTIC COLOR — ONE accent source, ONE selection opacity.
    enum Palette {
        static let accent        = Color.accentColor
        static let selectionFill = Color.accentColor.opacity(0.15)   // ALL selection backgrounds
        static let separator     = Color(nsColor: .separatorColor)
        static let panelBg       = Color(nsColor: .controlBackgroundColor)
        static let onAccent      = Color.white                        // text on a solid-accent fill
    }
}

// Reusable bar primitive (kills the copy-pasted `.background(.bar)+Divider` in 7 places).
extension View {
    func barStrip(dividerEdge: VerticalEdge = .bottom) -> some View {
        self.padding(.horizontal, DS.Size.barPadH).padding(.vertical, DS.Size.barPadV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .overlay(alignment: dividerEdge == .bottom ? .bottom : .top) { Divider() }
    }
}
```

---

## 2. P0 — the color picker (the user's explicit #1 ask) — **building now**

**Problem (confirmed in source).** `ColorPicker("", selection:…, supportsOpacity:false).labelsHidden().frame(width: 28)`
at **LayersSidebar.swift:545-547** renders AppKit's `NSColorWell`, which **enforces its own intrinsic
~44×22pt rounded-pill size and silently ignores `.frame(width:)`**. The stock control cannot be
shrunk; it must be replaced. Same well recurs at **CurrentPropertiesBar.swift:120-122**,
**InspectorEditors.swift:52 / 721**, **AppSettingsView.swift:520**.

**Fix — a reusable `ColorSwatchPicker` (16×16, r3, 0.5pt separator stroke) hosting the system picker
in a `.popover`.** (Code in the worktree; mirrors AutoCAD's Layer-Manager color cell + macOS list
color dots ≈14–16pt.)

✅ **Scope decision (from audit):** apply the swatch at the **two dense sites** — the layer row and
the current-properties bar. **Keep the standard well** at `InspectorEditors.swift:52/721` and
`AppSettingsView.swift:520`: those are full-width **grouped-Form value rows with visible labels**,
exactly where HIG sanctions the full well — a 16pt chip there would look wrong.

✅ **Flash fix (from audit):** drop `@State swatch = .green` (LayersSidebar:496) in favor of a
**computed `Binding<Color>`** off `layer.color` (get/set through the existing color callback), so the
row shows its real color on the first frame and the undo path is unchanged.

⚠️ **Honest caveat (from audit):** a SwiftUI `ColorPicker` inside a `.popover` still spawns the
floating `NSColorPanel` on click (the popover hosts the trigger). That's acceptable and keeps the
native panel + undo path. A fully self-contained popover swatch-grid is more work and out of P0 scope.

**Files:** `Sidebar/ColorSwatchPicker.swift` (new) · `LayersSidebar.swift:545-547` ·
`CurrentPropertiesBar.swift:120-122`. **Effort: M. Risk: Low.**

---

## 3. Region-by-region plan

Severity/effort merged across lenses (HIG `hig-*`, CAD `CAD-*`, tokens `DST-*`, interaction `IDR-*`).
Where lenses conflict, the **Call** column states the decision.

### 3a. Left sidebar

| Problem | Concrete fix (values) | Files | Effort | Risk / Call |
|---|---|---|---|---|
| Oversized color pill | §2 `ColorSwatchPicker`, 16×16, r3, 0.5 stroke | LayersSidebar:545; CurrentPropertiesBar:120 | M | Low |
| Name truncates to "L…"/"0" | CAD column grammar: `[eye][lock]` → **NAME** (`.frame(minWidth:64, alignment:.leading).layoutPriority(1)`) → trailing `[swatch][pen menu]`. ✅ **Required:** demote **printer + construction** toggles into the row `…` context menu — the 220pt-width arithmetic only fits with this demotion (4×22 icons=88 + 16 swatch + 18 menu + spacing ≈ 152 → ~62 for the name). Gated on **Open Q #6**. | LayersSidebar:499-577 | M | Med. Verify the row `onTapGesture` (583) still selects when controls move. |
| Cryptic "/" linetype glyph | Replace `line.diagonal` (line 620) with a **dash-pattern preview** (~20×4pt line at the layer's type); restore `.menuIndicator(.visible)` | LayersSidebar:604-627, PenPickers.swift | M | Low |
| Parts Library truncation + dup Choose-Folder | ✅ When no folder: plain "No folder chosen" (drop `.middle`). When a folder IS chosen: show `url.lastPathComponent`, full path in `.help()` (resolves the dropped CAD-13/IDR-13 vs hig-11 conflict). Helper text `.fixedSize(horizontal:false, vertical:true)`. **Remove the body `Choose Folder…` button** — keep the header `folder.badge.plus`. | PartsLibraryPanel:108-133 | S | Low |
| Cramped rows / tiny targets | `defaultMinListRowHeight` 4 → 22; row `.padding(.vertical,4)`; unify leading glyph to 20 (real block previews may stay 28) | SidebarPanelStack:95, Layers/Blocks/PartsLibrary | S | Low |
| Empty top "tune" band | Remove the dedicated customize row; move panel show/hide into the first panel header's trailing actions or a bottom "Customize…" menu; if kept, distinct glyph (`rectangle.3.group`) | SidebarPanelStack:113-146 | S | Low |
| Heavy header / weak chevron | Title → `DS.Font.panelTitle` (.subheadline.semibold); chevron `.caption2` → `.caption.weight(.semibold)`. ✅ Overrides IDR-19's "keep .headline" | SidebarPanelStack:196-204 | S | Low |
| Three different empty states | One `SidebarEmptyState(icon:title:cta:)`; reuse for Layer States, Blocks, Parts Library | new shared view | M | Low |

### 3b. Top bar (toolbar + properties bar + tool options)

| Problem | Concrete fix | Files | Effort | Risk / Call |
|---|---|---|---|---|
| Three identical "By Layer" dropdowns | Each control self-identifies: **Color**=16pt swatch + mode word; **Linetype**=leading dash preview; **Lineweight**=leading weight-bar preview. Add a `caption` micro-label ("Color"/"Type"/"Width"). Unify widths → 130. Give PenPickers swatch/dash/weight previews in their rows. | CurrentPropertiesBar:52-64,108-126, PenPickers.swift | M | Med. Touches shared PenPickers — coordinate with inspector wave. |
| Hand-rolled active badge / bare dividers / icon collisions | Active-tool highlight via `RoundedRectangle(cornerRadius:6)` fill `selectionFill`(0.25→0.15); toolbar `Divider().frame(height:16)`; distinct group glyphs (Modify `wand.and.rays`); trim `defaultPrimary` so `>>` is rare | ContentView:648-685,743,1229-1290 | M | Med |
| ToolOptionsBar width grab-bag (52..160) | Replace magic widths with `DS.Field.*`; spacing 14→12; leading glyph = active tool's `meta.symbol`; route through `.barStrip()` | ToolOptionsBar.swift | M | Low |

### 3c. Right inspector

| Problem | Concrete fix | Files | Effort | Risk / Call |
|---|---|---|---|---|
| **"Grid spacing" wraps to "Spaci\nng"** (confirmed bug) | `.lineLimit(1).fixedSize(horizontal:true,vertical:false)` on the label; **drop the "Spacing" placeholder**; field 80 → 72. Apply the label-lineLimit fix to **every** `LabeledContent` in the file. | InspectorView.swift:289-295 | S | Low. High-value quick win. |
| Systemic fixed-width fields (70/80/90/120/140) | Route widths through `DS.Field.*` (narrow 72 / std 96 / wide 130; paired x/y → `xy` 56); `.lineLimit(1)` every label; long labels stack above field at narrow width | InspectorEditors:68,274,311,318,387,824-859, InspectorView:392-411 | M | Med. Wide blast radius — keep self-contained. |
| 11 stacked snap toggles clip "Endpoint…Free" | 2-column `LazyVGrid([.flexible(),.flexible()])` of `.checkbox` toggles; pull "Free (no snap)" out as a master "Snap on/off" above the grid | InspectorView:285-300,514-531 | M | Low. Mirrors AutoCAD DSETTINGS ▸ Object Snap. |
| Oversized "No Selection" empty state wastes prime real estate | ✅ **Upgraded (2nd review):** instead of a decorative empty state, show **drawing-level properties** when nothing is selected — Units, Scale, entity count, layer count, drawing extents (read from `CanvasModel.drawing`). Compact `LabeledContent` rows under a "Drawing" header. A tiny `cursorarrow` + one-line hint only if there's no document. | InspectorView:72-79 | S→M | Low |
| Property Painter naming + all-greyed + dup action | ✅ Rename → **"Match Properties"** (AutoCAD MATCHPROP). `Label` icons (Pick Up `eyedropper`, Apply `paintbrush.pointed`, Reset `arrow.uturn.backward`); status "Source: Empty/Loaded"; collapse to one hint line when unavailable; remove the dup "Reset Pen to Layer" | InspectorView:256-278, InspectorEditors:748-750 | M | Low |
| Inconsistent section vocabulary | ✅ Standardize on **"Entity"** app-wide (matches the engine + the existing empty-state copy); "Selection" (summary), "Common" (shared; "(applies to all)" → caption subtitle) | InspectorView/InspectorEditors | S | Low |
| Redundant inner-frame width | Drop `InspectorView:56` self `.frame(minWidth:260…)`; keep only host `.inspectorColumnWidth` (ContentView:312) | InspectorView:56 | S | Low |

### 3d. Bottom chrome

| Problem | Concrete fix | Files | Effort | Risk / Call |
|---|---|---|---|---|
| Redundant tool entry: bottom chips = top toolbar | Re-cast CommandBar as a true command line: empty query shows a prompt hint + optional labeled "Recent", **not** a static mirror of `defaultPrimary`; chips appear only as fuzzy-match results while typing | ToolSuggester.swift:68, CommandBar.swift | M | Med. Toolbar is the sole mouse-tool surface. |
| Two near-identical text inputs (coord + filter) | **Merge into ONE command/coordinate line** (AutoCAD model). ✅ Default if the two focus targets (`commandFieldFocused` vs `commandBarFocused`) collapse cleanly; **else** strongly differentiate (search chrome + `magnifyingglass` vs flat monospaced prompt) — see Open Q #3 | ContentView:879-907, CommandBar.swift | M→L | Med |
| Command-line hint shown twice | Keep syntax hint in the placeholder only; remove the trailing duplicate else-branch (keep it for errors); verb hints (`⏎/⌫/esc`) live in StatusBar only | ContentView:892-917, StatusBar:86 | S | Low |
| Snap/grid/ortho/polar not clickable | Right-aligned toggle cluster: Grid(F7), Snap(F9), Ortho(F8), Polar(F10), OSNAP(F3) — borderless toggles filling `accent` when on; wire existing F-keys | StatusBar.swift, CanvasModel.swift | M | Med. High CAD-muscle value. |
| StatusBar labeling inconsistency | Both readouts carry a leading SF Symbol (zoom → `plus.magnifyingglass`) or neither; `Divider().frame(height:16)` between coord/snap/zoom; numerics `rowValue` | StatusBar:119-128 | S | Low |
| LayoutTabStrip: weak active state, always-on, r5 | Active tab = 2pt accent underline + `.semibold`; pill radius 5→6; fill `selectionFill`; **hide strip until a paper-space layout exists** | ContentView:1974-2012 | S | Low |

### 3e. Global tokens (cross-cutting — built FIRST as Wave 1, then **the radius/tint sweep is folded into each owning wave**, not run as an orphan pass)

| Problem | Fix | Where it lands |
|---|---|---|
| No design-token layer | Create `DesignTokens.swift` + `.barStrip()` | Wave 1 |
| 6 radii / 6 selection-tint variants / 2 accent sources | Collapse to `{6,10,14}` + `selectionFill` + `accent`; replace hardcoded `Color.white` (CommandBar:162) with `onAccent` | ✅ folded: LayersSidebar→Wave 2; ContentView/CommandBar/CommandPalette/BlockVisibilityStatesPanel→Wave 4 |
| Bar padding/spacing drift | Every `.bar` strip via `.barStrip()` (v6/h12); divider heights → 16 | ✅ folded into the wave that owns each bar |

---

## 4. Phased execution (parallel git-worktree waves, disjoint owned files)

Each wave branches off `native-macos` (`git reset --hard native-macos`). Files are **disjoint within a
wave**. `ContentView.swift` is **serialized** (one wave at a time). Build/test as usual (serial).

**Wave 1 — Foundation + the user's #1 ask** _(no ContentView)._
Owns `DesignTokens.swift` (new) + `ColorSwatchPicker.swift` (new). **Done:** `DS` + swatch compile; a
preview/test confirms the 16×16 swatch opens the picker. _(The P0 `ColorSwatch` wave already ships the
swatch component + the two dense wire-ins; Wave 1 generalizes it + adds the token file.)_

**Wave 2 — Sidebar** _(no ContentView; file-disjoint lanes)._
- 2a `LayersSidebar.swift` (swatch generalization, name reorder/min-width, linetype preview, row density, empty state, + its radius/tint token sweep).
- 2b `PartsLibraryPanel.swift` + `BlocksSidebar.swift` (truncation, dup Choose-Folder, shared empty state, icon footprint).
- 2c `SidebarPanelStack.swift` (row height, header typography, customize-band relocation).
`PenPickers.swift` **read-only** here. **Done:** layer name no longer truncates at 220pt; swatches 16pt; serial green; `.app` rebuilt.

**Wave 3 — Inspector + properties bar** _(file-disjoint; shares PenPickers)._
- 3a `InspectorView.swift` + `InspectorEditors.swift` (Grid-spacing wrap, field tokens, snap grid, empty state, Match Properties).
- 3b `CurrentPropertiesBar.swift` + `PenPickers.swift` (3-control disambiguation + previews, `.barStrip()`) + `ToolOptionsBar.swift` (field tokens).
**Done:** "Spaci ng" gone; the three pen controls visually distinct; serial green; `.app` rebuilt.

**Wave 4 — Bottom chrome + status bar** _(serialized on ContentView)._
Owns `ContentView.swift`, `StatusBar.swift`, `CommandBar.swift`, `ToolSuggester.swift`,
`CanvasModel.swift` (snap toggles), `BlockEditBar.swift`, `BlockVisibilityStatesPanel.swift`,
`CommandPalette.swift` (+ their radius/tint/bar-padding token sweep). **Done:** bottom ≤ status + one
command line + conditional tabs; status toggles flip on F-keys; serial green; `.app` rebuilt.

**Wave 5 — Structural consolidation (STRETCH, optional, serialized on ContentView).**
✅ **Default = compact `barStrip()` CurrentPropertiesBar** (honors its "must never disappear"
invariant). **Stretch:** merge CurrentPropertiesBar into the native toolbar — ⚠️ audit-flagged HIGH
risk: SwiftUI `ToolbarItemGroup` hosting 3 Pickers + a swatch reflows into AppKit's `>>` overflow at
default width and could *hide* an always-on control. Only attempt behind the fallback. **Done:** ≤1
always-on top strip; serial green; `.app` rebuilt.

> Waves 1→4 are the seamless-and-beautiful core (tokens + every confirmed bug + the user's explicit
> complaints). Wave 5's toolbar-merge is separable and defaults OFF.

---

## 5. Open questions for the owner

1. **Dark canvas + light panels — keep, or unify?** Plan recommends **keep** (CAD convention; line
   contrast) made intentional via tokens. Alternative: a single flatter material for canvas + panels
   (more "modern Mac", less CAD). Affects `CanvasTheme` vs panel-material work in Wave 4.
2. **Bottom quick-tool chip row — drop the static mirror, or keep as a labeled "Recent/Favorites"?**
   Plan recommends **drop the mirror** (results-only). A Recent strip is fine but needs a label and
   must exclude already-pinned tools.
3. **Merge the coordinate field + command filter into ONE command line?** AutoCAD-canonical, removes a
   band, but unifies two focus targets — confirm the keyboard model can collapse cleanly, else we
   differentiate them visually.
4. **Properties bar: compact second strip (default) vs native-toolbar merge (Wave 5 stretch)?** The
   merge eliminates a strip but risks `>>`-overflow hiding an always-on control.
5. **Toolbar selection: custom tinted active badge vs system `NSToolbar` selected appearance?** System
   is more native/quieter; the custom badge is more legible for an active *drawing tool*.
6. **Layer-row inline flags:** the name-truncation fix **requires** demoting **printer + construction**
   to the row context menu (the 220pt arithmetic depends on it). Confirm those two are rare-enough to
   hide (vs needing them always visible like eye/lock). _This gates the P1 layer-row reorg._
   ✅ **Owner answered (2026-06-16):** keep two-tone (intentional) · drop the bottom chip mirror ·
   demote printer/construction · build Waves 1–4.

---

## 6. Cross-checked follow-ups (2nd independent review, 2026-06-16)

A second design review (AutoCAD/BricsCAD + Sketch/Figma/Linear lens) independently reached the **same
core conclusions** — validating the plan (compact color swatch · disambiguate the "By Layer" dropdowns ·
simplified/name-first layer rows · status-bar Ortho/Polar/OSNAP toggles · drop the redundant bottom tool
pills · stronger type hierarchy + 8pt grid · useful empty states · command autocomplete). Those are all
already P0 or Waves 1–4. Genuinely-NEW items it surfaced, banked here:

- ✅ **[folded into Wave 3]** Inspector "No Selection" → **drawing-level properties** (units, scale,
  entity count, layer count, extents), not a decorative empty state.
- **[P1 follow-up] Toolbar flyouts for tool variants** — Line▸{Ray, XLine}, Circle▸{center-radius,
  2-pt, 3-pt, TTR}, Arc▸{3-pt, start-center-end, …}, Rectangle▸{Rectangle, Polygon}. Click = default,
  hold = flyout. A real feature (many variants already exist as engine tools — this is UI surfacing);
  conserves toolbar width and kills the `>>` overflow.
- **[P1 follow-up] "Match Properties" → toolbar button + shortcuts** (⌘⇧C pick up / ⌘⇧V apply,
  MATCHPROP-style) instead of a permanent inspector section. Wave 3 renames + compacts it; the full
  move-to-command is the follow-up.
- **[P2 follow-up] Snap & Grid → status-bar gear popover.** Once Wave 4's status toggles land, the
  inspector Snap & Grid section is largely redundant; move detailed settings behind a popover, leaving
  quick toggles in the bar.
- **[P2 follow-up] Canvas chrome:** move the "New drawing (mm)" label to the status bar; add a
  layout-tab context menu (Rename / Delete / Duplicate / Page Setup); add a small UCS/axis indicator at
  the origin.
- **[P2 follow-up] Coordinate readout click-to-toggle** absolute / relative / polar.
- **[P3 content] Starter symbol library** — ship ~20–30 bundled DXF symbols (doors/windows/fixtures/
  electrical) so Parts Library isn't empty on first launch + Finder drag-drop into the panel.

**Already covered / in-flight (not re-opened):** crosshair cursor (preference shipped, default
full-window) · command palette (⌘K `CommandPalette.swift`, polished in Wave 4) · dark mode + light-on-
dark canvas (theme system in `AppSettings`) · Ortho/Polar/OSNAP status toggles (Wave 4) · labeled/
disambiguated pen dropdowns (Wave 3) · window-vs-crossing selection + trackpad navigation (engine —
already implemented).
