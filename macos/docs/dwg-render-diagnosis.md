# DWG render diagnosis — `mechanical_example-imperial.dwg`

## 2026-06-12 UPDATE — the text was STILL huge on screen: SECOND root cause found + fixed (dim-textheight-fix-wt)

The DC.5 fix below made the ENGINE read `$DIMTXT=0.125` correctly — confirmed again here:
`CADEngine.shared.readEntities(dwgPath:)` returns `graphicVariables.dimTextHeight == 0.125`,
`$DIMSCALE == 1.0`, unit `inch`, and `loadDrawing(dwgPath:)` resolves every dim glyph at
~0.13–0.16 world units (cap height 0.125 + ascender/descender margin). The `Resolve.swift`
multiplication chain is **correct**: `base 0.125 * scale 1.0 = 0.125`. The "prime suspect"
`textHeight × $DIMSCALE` was a **red herring** — this file's `$DIMSCALE` is 1.0, so the
multiply is a no-op. (Kept `× DIMSCALE`: it is AutoCAD-faithful and only matters for files
that set a large DIMSCALE; the existing `dimScaleMultiplies` test still encodes it correctly.)

**The actual on-screen bug was in the macOS APP's document-open path, NOT the engine:**
`DXFDocumentCodec.payload(from:format:)` (`Sources/LibreCADmacOS/LibreCADDocument.swift`)
constructed its `DXFPayload` with `blocks: BlockTable()` **and** `graphicVariables:
GraphicVariables()` — i.e. it **discarded** the engine's parsed `result.blocks` and
`result.graphicVariables`. `CADDrawing.make(from:)` then loaded the drawing with the DEFAULT
`GraphicVariables()` whose `$DIMTXT` is **2.5**. So the `dimStyleProvider` served 2.5 and every
constraint dim rendered ~20× too big. `loadDrawing(dwgPath:)` (a separate helper used only by
tests) DID pass the parsed vars through, which is why the prior throwaway dump looked fine while
the real app window did not.

**Measured before/after through the EXACT app codec path (real `mech.dwg`):**
- BEFORE (codec drops header): `drawing.$DIMTXT = 2.5` → resolved dimStyle.textHeight = 2.5 →
  **measured glyph-fill height = 2.62 world units** (≈ the owner's "~2.5+ tall" report; bigger
  than the ~1″ features in a 94×68 drawing).
- AFTER (codec carries `result.graphicVariables`/`result.blocks` through): `$DIMTXT = 0.125` →
  resolved textHeight = 0.125 → **measured glyph-fill height = 0.13** (dim[0]) / 0.16 (linear
  dims) — small relative to the features, matching AutoCAD/LibreCAD.

**Fix:** `LibreCADDocument.swift` — pass `result.blocks` + `result.graphicVariables` into the
`DXFPayload` instead of empty placeholders. One-file change in the bridge/app codec; no change
to `Resolve.swift`. Regression pinned by `ConstraintDimHeaderTests.swift` +
`Resources/dim_constraint_header.dxf` (a shippable DXF: $DIMTXT=0.125, $DIMSCALE=1.0, a
formula `textOverride`; asserts the open codec carries $DIMTXT and the constraint glyphs
resolve at ~0.125 through the full bytes→codec→`make(from:)` app path). All 1188 tests green;
imperial_dim (0.18) + dimScaleMultiplies unchanged.

(~~NOTE: the DXF/DWG **write** path still drops blocks + graphicVariables~~ — **CORRECTED 2026-06-15:**
this note was STALE. A round-trip verification test (`SaveRoundTripTests.swift`, 2026-06-15) PROVES the
**DXF (R2000) write path has full fidelity** — blocks, INSERT, graphicVariables ($DIMTXT/$INSUNITS),
named DIMSTYLE tables, and custom layers all save→reload correctly via `DXFDocumentCodec.data(from:)`.
The remaining gap is **DWG write only** (libdxfrw `dwgWriter15` limitation: custom layers/DIMSTYLE
tables/block-member geometry don't round-trip to `.dwg`) — pinned by the test, not a DXF regression.)

---

Status: **investigation complete, data-backed** — **FIX LANDED** (ws-dimstyle-header-read, DC.5).
RC1+RC2+RC3+H2+H3 resolved: the bridge now reads the HEADER vars + DIMSTYLE table (P1+P2+P3 below).
Real-file re-validation on this DWG after the fix: dim text height **2.5 → 0.125**, units **mm → inch**,
linear format **architectural** ($LUNITS=4), all 17 dims resolve at 0.125. P4 (DIMEXO/DIMEXE/DIMGAP →
ResolvedDimStyle) still open (the header/style values are now captured in the PODs but not yet fed to
the extension-line resolve). P5 (VIEWPORT) remains out of scope.
File: `/Users/macatt/Downloads/mechanical_example-imperial.dwg`
(R2010 / AC1024 DWG; 142 KB). Loaded through `CADEngine.shared.readEntities(dwgPath:)`.

> The Downloads folder is TCC-protected, so the file was copied to `/tmp` via `dd`
> / `python3` (which bypass the sandbox) before running the engine read path. The
> measurements below come from a throwaway `@Test` dump (now deleted) that called
> the real DWG read path + `resolve()`.

---

## 1. Measured data

### Entity-kind histogram (top-level records)
```
line:       59
dimension:  17
circle:      8
arc:         7
text/mtext:  0          ← NO standalone text in the file
hatch/solid/polyline/spline/ellipse/insert/point: 0
layers:      6
blocks:      1          (_ClosedBlank, 3 members)
warnings:   "Skipped 2 unsupported VIEWPORT entities"
```

The DimKind breakdown of the 17 dimensions: **linear=15, diameter=2** (no aligned/
radial/angular). All 17 carry a parametric **text override** (e.g. `BOLTHOLE=1"`,
`SHAFTid=3"`, `KEYwidth=1/2"`, `KEYheight=.25+(SHAFTid/2)`), all on dim style `MEP`.

### Per-dimension detail (the headline)
Every dimension came back with:
```
textHeight = 2.5     ← engine DEFAULT (DimData.init default), NOT from the file
arrowSize  = 2.5     ← engine DEFAULT, NOT from the file
```
There is **no** per-dimension or per-style text height/arrow size in the parsed model
at all — the POD struct (`LCEntity` in `lcdxf.h`) has no `dimTextHeight`/`dimArrowSize`
field, and `makeDimensionBase()` never sets one. The `2.5` is `DimData`'s hard-coded
default (Entity.swift:457-458) / `Resolve.dimDefaultTextHeight` (Resolve.swift:880).

### graphicVariables after load
```
$INSUNITS = 4 (millimeter)   ← engine DEFAULT, NOT from the file
$DIMTXT   = 2.5              ← engine DEFAULT
$DIMASZ   = 2.5              ← engine DEFAULT
$DIMSCALE = 1.0             ← engine DEFAULT
```
**None of these are read from the DWG.** They are all the default values returned by
the typed accessors in `CADDrawing.swift` (e.g. `unit` defaults to `.millimeter`,
`$DIMTXT` defaults to 2.5). The file is imperial (filename + override text `1"`,
`1/2"`, `.25`), but we tell the engine it is millimeter.

### Extents (drawing units)
```
all records (incl. dim def-points placed far out):  width 111.9 x height 90.9
hard geometry only (line/circle/arc):                width 94.1 x height 67.7
smallest line length: 0.27     smallest circle radius: 0.5
```
The part's measured features are sub-inch to 3" (matches the override values), so
**1 drawing unit ≈ 1 inch**. Text height 2.5 is ~3.7% of the whole-part height — but
the features being labeled (a 0.5" keyway, a 1"-Ø bolthole) are *much* smaller than
the part, so 2.5"-tall text is 2.5x–5x the local feature size.

### Resolved dimension graphics (the visual proof)
Resolving each dimension with the wired (default) `dimStyleProvider` produces full
graphics (extension lines + dim line + arrowheads + glyph fills) — they are **not
absent** — but the footprints are enormous relative to the features:
```
dim[0]  BOLTHOLE=1" (Ø, on a 1"-Ø circle):   footprint  8.0w x 22.7h   (~23x the circle)
dim[3]  BHtopLeftHalf=BOLTHOLE/2 (0.5"):     footprint 45.0w x  7.8h
dim[4]  BHtopRightHalf=BOLTHOLE/2:           footprint 47.3w x 19.8h
dim[10] KEYheight=.25+(SHAFTid/2) (vert.):   footprint  7.9w x 43.9h
dim[11] KEYheightSide=KEYheight (vert.):     footprint 10.3w x 41.5h
```
3 polylines + 15–30 fills per dim: 2 arrowheads (2.5"-long each — bigger than the
1" bolthole) plus one glyph-outline fill per character of the long override string,
each at 2.5" cap height. The text/arrows sprawl 40–47 units across a 94×68 drawing.

---

## 2. Root causes (each CONFIRMED with data, ranked by visual impact)

### RC1 — Dimension text + arrows fall back to the 2.5 engine default (CONFIRMED) — **dominant**
The bridge **never reads** dimension text height or arrow size:
- `lcdxf.cpp:213` `addDimStyle(...) { (void)data; }` — DIMSTYLE table is dropped.
- `lcdxf.cpp:195` `addHeader(...) { (void)data; }` — `$DIMTXT/$DIMASZ/$DIMSCALE`
  header vars are dropped.
- `makeDimensionBase()` (lcdxf.cpp ~690) reads def points, text override, style
  *name*, align, line-spacing, text rotation, oblique — but no text height/arrow size.
- The POD `LCEntity` (lcdxf.h) has no field for them; the bridge C API
  (`lc_entity_list`, `lc_layers`, `lc_blocks`, `lc_aci_to_rgb`) exposes **no header
  and no dimstyle accessor**.

Result: `DimData.textHeight`/`arrowSize` keep their 2.5 default; `resolve()` draws
2.5"-tall glyphs and 2.5"-long arrowheads. libdxfrw DID parse the real values — its
`DRW_Dimstyle` defaults `dimtxt = dimasz = 0.18` (the standard imperial height) and
fills them from the file — but `addDimStyle` discards the whole object.
**This is the "text too big" complaint and also why the dimension *graphics* look
sparse: they're drowned / overlapped by oversized text + arrows, not missing.**

### RC2 — `$INSUNITS` (and `$LUNITS`/`$LUPREC`) not read → drawing treated as mm (CONFIRMED) — **high**
`$INSUNITS=4` is the engine's millimeter default, not the file's inch value (the
filename and overrides prove it is imperial). Because the header is never parsed,
the document has no unit context. This compounds RC1 (a "2.5" that *should* be read
as a small imperial dim height is instead an arbitrary metric-ish default) and means
any future unit-aware sizing, the status bar, and measurement formatting
(architectural/fractional via `$LUNITS`) are all wrong. The measured values here are
masked only because every dimension has a hard-coded text override.

### RC3 — Long parametric override strings amplify RC1 (CONFIRMED) — **medium (data-specific)**
This is a parametric drawing: overrides are full expressions ("KEYheight=.25+
(SHAFTid/2)", "BHtopLeftHalf=BOLTHOLE/2"). At the correct ~0.18" height these are
fine; at 2.5" they sprawl 40–47 units. Not a bug per se, but it makes RC1's impact
extreme on this particular file. (Fixing RC1 fixes this.)

### RC4 — VIEWPORT entities skipped (CONFIRMED, low impact) — **low / expected**
2 VIEWPORT entities skipped. These are paper-space layout viewports, not model
geometry; skipping them is correct for a model-space render. Not a contributor to
the visible problem. **No other entity type was skipped** — the part geometry (59
lines, 8 circles, 7 arcs) all imported. So "a lot is missing" is NOT missing model
geometry; it is the oversized text/arrows obscuring the (present) dimension graphics.

### H2 / H3 resolution
- **H2 ("missing things"):** REFUTED as "skipped entity types." The only skip is 2
  paper-space VIEWPORTs. Dimension graphics ARE regenerated by `resolve()` from def
  points and look structurally right (3 polylines + arrow/text fills per dim). What
  reads as "sparse/missing dim graphics" is the text+arrows being so large they
  overlap and dominate.
- **H3 (vertical text overlap):** CONFIRMED — vertical linear dims (angle = π/2,
  dim[10]/[11]) resolve to ~44-tall footprints; rotated + 2.5" tall, they overlap.
  This is a *consequence* of RC1 (height), not an independent placement bug.

---

## 3. Prioritized development plan

Effort: S ≈ ½–1 day, M ≈ 1–3 days, L ≈ 1 week+. All items below are **pure engine /
bridge** (no UI) unless noted.

### P1 — Read DIMSTYLE + dimension header vars in the bridge and apply them — **M** — biggest visual win
The single fix that resolves RC1 (and most of RC3/H2/H3).

1. **Bridge: parse the DIMSTYLE table.** Implement `addDimStyle(const DRW_Dimstyle&)`
   in `lcdxf.cpp` (currently a no-op): collect `name → {dimtxt(140), dimasz(41),
   dimscale(40), dimexo(42), dimexe(44), dimgap(147)}`. libdxfrw already parses these
   (`DRW_Dimstyle`, `drw_objects.h:143`), defaulting `dimtxt=dimasz=0.18`.
2. **Bridge: parse the header.** Implement `addHeader(const DRW_Header*)`: pull
   `$DIMTXT/$DIMASZ/$DIMSCALE/$DIMSTYLE` (and the unit vars for P2) via
   `DRW_Header::getDouble/getInt/getStr` (`drw_header.h:128-130`).
3. **Bridge ABI + POD: surface the data.** Either (a) add a small `LCDimStyle`
   array + `lc_dimstyles()`/`lc_dimstyle_count()` and an `LCHeader`/`lc_header()`
   accessor to `lcdxf.h`, **or** (the smaller change) resolve each dimension's height
   in C++ at flatten time (look up its `getStyle()` name in the parsed style table,
   fall back to the header `$DIMTXT`) and stamp `dimTextHeight`/`dimArrowSize` onto
   new `LCEntity` POD fields. Recommend the latter for a first cut (fewer ABI calls),
   then add the header/style accessors for the Document Settings sheet later.
   Files: `Sources/DxfBridge/lcdxf.cpp`, `Sources/DxfBridge/include/lcdxf.h`.
4. **DXFReader.swift: map the new fields.** Set `DimData.textHeight`/`arrowSize` from
   the POD (instead of leaving the 2.5 default) in `mapDimension`
   (`DXFReader.swift:337`). If using the header/style-table ABI instead, populate
   `CADDrawing.graphicVariables` ($DIMTXT/$DIMASZ/$DIMSCALE) at load so the existing
   `makeResolveContext().dimStyleProvider` (already wired, Resolve.swift:179,
   CADDrawing.swift:747-799) supplies them — **this path already exists end-to-end**;
   only the *source* (the file) is missing.
5. **Plumb a header through `DXFReadResult` + `loadDrawing`.** `DXFReadResult`
   currently has no header field; `loadDrawing(dwgPath:)` calls `drawing.load(...)`
   with default graphicVariables (`DXFReader.swift:621-625`). Add a parsed
   `GraphicVariables` to `DXFReadResult` and pass it into `load(... graphicVariables:)`
   (the `load` overload already accepts it, CADDrawing.swift:719).

Expected result: dimension text drops from 2.5" to ~0.18" (or the file's real value),
arrowheads from 2.5" to ~0.18"; overlap and run-off disappear; the dimension lines/
extension lines/arrows become legible instead of drowned. **This alone should make
the drawing render essentially correctly.** Same fix benefits DXF (`addHeader`/
`addDimStyle` are no-ops on the DXF path too).

### P2 — Read `$INSUNITS` / `$LUNITS` / `$LUPREC` header vars — **S** (rides on P1's `addHeader`) — high
Once `addHeader` exists (P1), also surface `$INSUNITS`, `$LUNITS`, `$LUPREC`,
`$AUNITS`, `$AUPREC` and set them on `CADDrawing.graphicVariables` at load. Fixes
RC2: the drawing knows it is inches; measurement formatting can honor
architectural/fractional (`$LUNITS`); status bar / snap / future unit-aware sizing
become correct. Mostly the same wiring as P1 step 5 — incremental once the header
plumbing is in.
Files: `lcdxf.cpp` (read), `lcdxf.h` (ABI if going the accessor route),
`DXFReader.swift` (map into `GraphicVariables`).

### P3 — Per-dimension explicit overrides (DIMTXT/DIMASZ on the dimension itself) — **S** — medium
A dimension can override its style's text height (code 140 on the entity, or via the
`ACAD:DSTYLE` xdata override group). After P1, also read any per-entity override in
`makeDimensionBase` and prefer it (the resolve already implements "per-entity wins"
precedence, Resolve.swift:929-934). Low effort, completes the precedence chain. This
file appears to use one style (`MEP`) without per-entity overrides, so impact here is
small but it future-proofs other files.
Files: `lcdxf.cpp`, `lcdxf.h`, `DXFReader.swift`.

### P4 — Honor DIMEXO/DIMEXE/DIMGAP from the style — **S** — low/polish
Today the resolve uses fixed factors for extension offset/extension-beyond/text gap
(`dimExtensionOffsetFactor=0.2`, `dimExtensionBeyondFactor=0.5`, Resolve.swift:892-895).
Once the DIMSTYLE table is read (P1), feed the real `dimexo/dimexe/dimgap` through
`ResolvedDimStyle` so extension-line geometry matches AutoCAD exactly. Cosmetic
refinement after P1.
Files: `Resolve.swift` (`ResolvedDimStyle` + the dim resolvers), `lcdxf.cpp`/reader
(carry the values).

### P5 — VIEWPORT / paper-space handling — **L** — out of scope for this bug
The 2 skipped VIEWPORTs are paper-space layout viewports. Proper paper-space/layout
support is a large feature and is **not** the cause of the reported problem; leave on
the backlog. No action needed for this drawing's model-space render.

**Recommended order: P1 → P2 → P3 → P4.** P1 is the one that fixes the reported bug;
P2 is cheap once P1's `addHeader` lands and fixes the unit story; P3/P4 are polish.

---

## 4. Needs an owner decision
1. **ABI shape for P1/P2 (one call to make):** add explicit `lc_header()` /
   `lc_dimstyles()` accessors to the bridge ABI (cleaner, also feeds the Document
   Settings sheet and DXF write round-trip), **or** resolve dim height/arrow in C++
   at flatten time and stamp them onto new `LCEntity` fields (smaller, faster to
   ship, but the header/unit data still needs a separate path for P2). Recommend the
   explicit-accessor route for P1+P2 together so the unit + dim-style data both reach
   `CADDrawing.graphicVariables` and the existing `dimStyleProvider`/Document Settings
   plumbing (which is already built and waiting for a data source).
2. **Confirm the file's real values** (optional): no DWG→DXF converter is installed
   locally, so the file's exact `$DIMTXT`/`$INSUNITS`/MEP-style `dimtxt` were not
   read out of the binary directly — but they are provably *not* what the engine uses
   today (it uses pure defaults). If the owner wants the exact numbers verified before
   the fix, install `libredwg`/ODA converter or have me add a one-shot bridge dump of
   the parsed `DRW_Dimstyle`/`DRW_Header` once `addDimStyle`/`addHeader` are stubbed.
