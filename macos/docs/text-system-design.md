# Text & Typography System Design — LibreCAD Native macOS

**Status:** Design + phased roadmap. Phase 1 is a contract for the next builder.
**Author:** typography/CAD architect pass (2026-06-12).
**North star (user directive):** *"If we want to compete with AutoCAD or other professional tools, we
need a good font story. This should be the goal — lifting LibreCAD to professional level."*

This document specifies a professional text system that targets **AutoCAD-class capability**, is
grounded in **Apple Core Text** (what we get for free), and fits the **frozen architecture** (ADR-001
value-struct entities with computed `resolve()` geometry; ADR-003 f64/f32 floating-origin; ADR-004
two glyph sources behind ONE `FontProvider`). It is consistent with the **ADR-004 REVISION
(2026-06-12)**: native outline fonts are the default; `.lff` strokes are retained; **vector outline
tessellation, NOT an SDF atlas**.

> **Grounding note.** Every type, field, and seam below was verified against the live tree:
> `Entity.swift` (`TextData`, `EntityKind`, `EntityRecord`), `Resolve.swift` (`ResolveContext`,
> `ResolvedGeometry`/`ResolvedPolyline`/`ResolvedFill`, `layoutText`, `textBoundingBox`),
> `Pen.swift` (`ResolvedPen`/`RGBAColor`), `Text/LFFFont.swift` + `LFFParser.swift` +
> `StrokeFontProvider.swift`, `Renderer/RendererGeometry.swift` (`FillTriangulation`,
> `appendFillVertices`) + `LineRenderer.swift` (fills drawn as `.triangle` BEFORE lines),
> `CADDrawing.makeResolveContext` (`fontProvider: CADFonts.provider.makeProvider()`), and the DXF
> seam: upstream `RS_TextData`/`RS_MTextData`/`LC_TextStyle`, libdxfrw `DRW_Text`/`DRW_MText`/
> `DRW_Textstyle`, and our `DxfBridge/lcdxf.h` POD + `DXFReader.mapText`/`DXFWriter` text arm.

---

## 0. Why this matters and what "professional" means here

AutoCAD's text story has four pillars that LibreCAD lacks today (we ship only single-stroke `.lff`):

1. **TrueType/OpenType rendering** — kerning, ligatures, hinting-free crisp outlines, the *actual*
   typeface the user picked, full Unicode + complex scripts.
2. **A STYLE table** — named text styles (font, height, width factor, oblique, big-font) that TEXT/
   MTEXT reference, round-tripped through DXF/DWG.
3. **MTEXT** — rich multi-line paragraphs with per-run font/height/color/bold/italic/underline,
   stacked fractions, wrap width, justification.
4. **Annotative scaling** — text that auto-sizes to the active annotation scale.

The current state: `.text` resolves a single line of `.lff` strokes (`Resolve.layoutText`) honoring
only left/baseline, no width/oblique, no `\n`; `textBoundingBox` is a loose estimate; the DXF writer
emits single-line TEXT only and MTEXT-read-as-`.text` is written back as TEXT (see
`backlog.md` §"DXF writer"). There is no STYLE table and no MTEXT entity.

The win the architecture already hands us: **the renderer draws arbitrary fills with zero changes.**
`LineRenderer` triangulates every `ResolvedFill` via `FillTriangulation` and draws them as `.triangle`
primitives (alpha-blended, under the stroked lines). So **outline glyphs → fills → on screen** needs
no renderer work, no new pipeline, no SDF atlas. This is the lever that makes a pro font story cheap.

---

## 1. Data model (Swift types + fields)

All new types live in `CADEngine` and are `Sendable, Hashable, Codable` value types (ADR-001), so they
snapshot for undo (ADR-002) and serialize for the document store. They mirror the DXF STYLE/TEXT/MTEXT
group codes field-for-field so round-trip is structural, not lossy.

### 1.1 `TextStyle` — the DXF STYLE table entry

Models `DRW_Textstyle` / `LC_TextStyle` / the AutoCAD STYLE table. Round-trippable to DXF group codes
(noted per field). A drawing owns a **`TextStyleTable`** (name → `TextStyle`, like `LayerTable`/
`BlockTable`); TEXT/MTEXT reference a style **by name** (matching how DXF stores group 7 as a name).

```swift
/// The glyph source a style resolves through (ADR-004's "two impls behind ONE FontProvider").
public enum FontSource: Sendable, Hashable, Codable {
    /// Native outline font: a macOS font family resolved via Core Text → glyph paths → fills.
    /// `family` is a PostScript/family name ("Helvetica Neue", "SF Pro Text"). DEFAULT for new text.
    case native(family: String)
    /// LibreCAD stroke font: a `.lff` base name ("standard", "iso"). Retained for DXF fidelity.
    case stroke(lff: String)
    /// AutoCAD compiled shape font (.shx). Phase 3. Read-only; mapped to a fallback until SHX lands.
    case shx(file: String)
}

/// A named text style — the DXF STYLE table entry. One per `TextStyleTable` slot.
/// Field comments give the DXF group code it maps to (DRW_Textstyle / LC_TextStyle).
public struct TextStyle: Sendable, Hashable, Codable, Identifiable {
    public var id: TextStyleID            // stable id in the table (name is the DXF key)
    public var name: String               // STYLE table name, e.g. "Standard" (DXF: the table key)

    /// Where glyphs come from. Encodes BOTH the primary font file (DXF code 3) and source kind.
    /// For DXF round-trip: `.native(family)` ⇒ we store the family in code 3 AND set the
    /// 1071 TTF-family flag; `.stroke(lff)`/`.shx(file)` ⇒ code 3 is the .lff/.shx file name.
    public var primaryFont: FontSource

    /// Optional Asian "big font" companion (DXF code 4). Only meaningful for `.shx` primaries
    /// (SHX + bigfont is the classic CJK pairing). nil for native/lff. Carried for round-trip.
    public var bigFont: String?

    public var fixedTextHeight: Double    // code 40; 0 = "not fixed" (entity supplies height)
    public var widthFactor: Double        // code 41; default 1.0 (horizontal scale of glyphs)
    public var obliqueAngle: Double       // code 50; radians (DXF stores degrees); slant
    public var lastHeight: Double         // code 42; last interactively used height (UI convenience)

    /// Text-generation flags (code 71): backward (X-mirror) / upside-down (Y-mirror).
    public var generation: TextGenerationFlags

    /// TTF family / italic / bold flags (code 1071). For `.native`, bold/italic are ALSO
    /// expressible by choosing a face in `primaryFont.family`; this mirror keeps DXF round-trip.
    public var bold: Bool
    public var italic: Bool

    /// STYLE flags (code 70 on the table entry): e.g. shape-file / vertical. Carried for round-trip.
    public var styleFlags: TextStyleFlags

    public init(/* all fields, with AutoCAD-equivalent defaults: widthFactor 1, oblique 0, ... */)
}

public struct TextGenerationFlags: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int
    public static let backward   = TextGenerationFlags(rawValue: 2) // code 71 bit: mirror X
    public static let upsideDown = TextGenerationFlags(rawValue: 4) // code 71 bit: mirror Y
}
public struct TextStyleFlags: OptionSet, Sendable, Hashable, Codable { public let rawValue: Int /* ... */ }

/// Stable id for a style slot (parallels EntityID / LayerID).
public struct TextStyleID: Hashable, Sendable, Codable { public let rawValue: UInt32 }

/// The document's STYLE table (parallels LayerTable / BlockTable). Always contains "Standard".
public struct TextStyleTable: Sendable, Codable {
    public var styles: [TextStyleID: TextStyle]
    public var byName: [String: TextStyleID]            // case-insensitive lookup like DXF
    public static let standardName = "Standard"
    public func style(named: String) -> TextStyle?      // resolve a code-7 name
    public var standard: TextStyle                       // never nil; created on init
}
```

**Why a name-keyed table, not an inline style on the entity:** DXF/DWG store the style as a *named
reference* (group 7); editing "Standard" must re-flow every TEXT/MTEXT using it (the AutoCAD STYLE
manager semantics). This matches the existing `LayerID`/`Pen.byLayer` resolve-time indirection.

### 1.2 Single-line TEXT — extend `TextData` (it already exists)

`TextData` exists in `Entity.swift` and carries `position, height, rotation, text, styleName, hAlign,
vAlign, letterSpacingFactor`. It is referenced by `EntityKind.text` and read/written by the DXF seam.
**We extend it additively** (no rename, no churn to the exhaustive switches catalogued in
`v3-plan.md`). New fields all default so existing call sites and the DXF reader keep compiling.

Today `TextHAlign` has only `.left/.center/.right` and `TextVAlign` has `.baseline/.bottom/.middle/
.top`. AutoCAD's 15 justification modes are the **product** of those two codes (DXF 72×73) **plus** the
three special H-codes that only apply when V==baseline: **Aligned (3), Middle (4), Fit (5)** — exactly
what `DRW_Text::HAlign` enumerates (`HAligned/HMiddle/HFit`) and what `RS_TextData::HAlign` mirrors
(`HAAligned/HAMiddle/HAFit`). We widen the H enum to the full DXF set and add `secondPoint` (the second
point Aligned/Fit need — `RS_TextData::secondPoint`, DXF group 11):

```swift
public enum TextHAlign: Int, Sendable, Hashable, Codable {
    case left = 0, center = 1, right = 2
    case aligned = 3   // fit between insertion (10) and second point (11); height auto-scales
    case middle = 4    // centered H+V on the midpoint (the "TL…BR" Middle, distinct from center)
    case fit = 5       // fit between two points keeping height, varying width factor
}
// TextVAlign unchanged: baseline=0, bottom=1, middle=2, top=3.

public struct TextData: Sendable, Hashable, Codable {
    public var position: Vector            // insertion point (DXF 10)
    public var secondPoint: Vector?        // DXF 11; required for .aligned / .fit, else nil  [NEW]
    public var height: Double              // cap height (DXF 40)
    public var rotation: Double            // radians (DXF 50 degrees)
    public var text: String
    public var styleName: String?          // STYLE table name (DXF 7); nil ⇒ "Standard"
    public var hAlign: TextHAlign
    public var vAlign: TextVAlign
    public var widthFactor: Double         // DXF 41; per-entity override of style.widthFactor   [NEW]
    public var obliqueAngle: Double        // DXF 51; radians; per-entity slant override          [NEW]
    public var generation: TextGenerationFlags                                                  // [NEW]
    public var letterSpacingFactor: Double // existing
}
```

The 15-mode matrix is realized by `(hAlign, vAlign)` combinations + the three H-only special modes.
The `.aligned/.middle/.fit` modes consult `secondPoint`. **All 15 are honored in Phase 1 layout**
(see §2.4). Per-entity `widthFactor`/`obliqueAngle` override the style's (AutoCAD precedence: entity
group 41/51 over STYLE code 41/50). The `styleName` already exists and already round-trips
(`DXFReader.mapText` reads code 7; `DXFWriter` writes it).

### 1.3 MTEXT — a paragraph/run tree (`MTextData`, new entity kind)

MTEXT is **not** a single string with alignment; it is a tree: paragraphs → runs, each run with its own
font/height/color/decoration, plus stacked fractions. We model it as value types and add **one** new
EntityKind `case mtext(MTextData)` (its own serialized EntityKind step, per `v3-plan.md`'s
EntityKind-isolation rule — it must add an arm to every exhaustive switch).

```swift
/// A contiguous run of text sharing formatting. The atom MTEXT layout shapes.
public struct TextRun: Sendable, Hashable, Codable {
    public var text: String
    /// Per-run overrides; nil ⇒ inherit the paragraph/style value. Maps to MTEXT inline codes:
    public var fontOverride: FontSource?   // \f  (font family / .shx switch)
    public var heightFactor: Double?       // \H  (relative: 1.5x) or absolute height
    public var color: RGBAColor?           // \C / \c  (ACI / true-color)
    public var bold: Bool?                 // \f ... |b1
    public var italic: Bool?               // \f ... |i1
    public var underline: Bool             // \L … \l
    public var overline: Bool              // \O … \o
    public var strikethrough: Bool         // \K … \k  (AutoCAD 2018+)
    public var trackingFactor: Double?     // \T  (char spacing)
    public var obliqueOverride: Double?    // \Q  (per-run slant, radians)
}

/// A stacked fraction / tolerance: \S<upper>^<lower>; \S<num>/<den>; \S<a>#<b>.
public struct StackedRun: Sendable, Hashable, Codable {
    public enum Kind: Sendable, Codable { case fraction, tolerance, diagonal } // / ^ #
    public var upper: String
    public var lower: String
    public var kind: Kind
    public var heightFactor: Double        // stacked text is drawn smaller (AutoCAD ~0.7)
}

/// One inline atom of a paragraph, in logical order. (Bidi reordering happens at layout time.)
public enum MTextInline: Sendable, Hashable, Codable {
    case run(TextRun)
    case stacked(StackedRun)
    case tab            // \t / column tab
    // paragraph break (\P) is the boundary BETWEEN paragraphs, not an inline atom
}

public struct MTextParagraph: Sendable, Hashable, Codable {
    public var inlines: [MTextInline]
    public var alignment: MTextParagraphAlign?   // \pq… per-paragraph justify; nil ⇒ block default
}

public enum MTextAttachment: Int, Sendable, Hashable, Codable {  // DXF group 71 (DRW_MText::Attach)
    case topLeft = 1, topCenter, topRight,
         middleLeft, middleCenter, middleRight,
         bottomLeft, bottomCenter, bottomRight
}
public enum MTextLineSpacingStyle: Int, Sendable, Hashable, Codable { case atLeast = 1, exact = 2 } // 73
public enum MTextParagraphAlign: Sendable, Hashable, Codable { case left, center, right, justified, distributed }

/// `RS_MTextData` equivalent. Tree (paragraphs) + block-level layout. New EntityKind `.mtext`.
public struct MTextData: Sendable, Hashable, Codable {
    public var position: Vector                 // insertion point (DXF 10)
    public var height: Double                   // default cap height (DXF 40); runs scale relative
    public var rectWidth: Double                // wrap reference width (DXF 41); 0 ⇒ no wrap
    public var rotation: Double                 // radians (DXF 50 / X-axis vector 11)
    public var styleName: String?               // STYLE name (DXF 7)
    public var attachment: MTextAttachment      // DXF 71
    public var lineSpacingStyle: MTextLineSpacingStyle  // DXF 73
    public var lineSpacingFactor: Double        // DXF 44
    public var paragraphs: [MTextParagraph]     // the run tree
    /// The raw MTEXT inline-coded string (DXF group 1/3 concatenation), kept verbatim for
    /// LOSSLESS round-trip of codes we don't yet model. `paragraphs` is the parsed view; on write
    /// we re-emit from `paragraphs` when the user edited, else from `rawCode` (faithful passthrough).
    public var rawCode: String?
}
```

**Why a tree + a `rawCode` shadow:** the parsed `paragraphs` tree is what we *layout and edit*; the
verbatim `rawCode` guarantees we never *lose* an MTEXT code we don't model yet (faithful round-trip
even before every code is parsed). This is the same "structural model + lossless shadow" pattern the
DXF write fidelity work uses.

### 1.4 Dimension measurement text reuses `TextStyle` (no second text path)

The in-flight `.dimension` EntityKind (`v3-plan.md` S1) resolves its measurement text **through the
same `FontProvider`** — it does NOT get a private text layout. Concretely, the dimension's
`resolve()` builds a `TextData` (or `MTextData` for multi-line tolerances) from the dim style's text
sub-properties and calls the **same shaping entry point** (§2). The reserved
`ResolveContext` hook `dimStyleProvider` (commented at `Resolve.swift:126`) supplies the dim style's
text height / style name / gap; the resulting `TextData` flows through `FontProvider.shape(...)` like
any other text. This is the ADR-004-revision mandate: *".text AND .dimension measurement text both go
through the same provider abstraction (do not fork a second text path)."*

---

## 2. Glyph + shaping abstraction (ONE protocol, two impls)

ADR-004 mandates **one** `FontProvider`/glyph abstraction in `ResolveContext` with two
implementations. Today `ResolveContext.fontProvider` is a bare closure `((String) -> StrokeFont?)`
wired to `CADFonts.provider`. We **promote it to a protocol** that both the stroke and native impls
satisfy, and the `.text`/`.mtext`/`.dimension` resolve arms call its `shape(...)` method. The closure
shape is kept as a thin compatibility shim during Phase 1 so nothing else breaks.

### 2.1 The protocol

```swift
/// The single glyph/shaping abstraction (ADR-004). Two impls: stroke (.lff/SHX) and native (Core Text).
/// Sendable so it can live in the Sendable ResolveContext. Implementations are immutable + cache
/// internally behind a lock (like StrokeFontProvider today).
public protocol FontProvider: Sendable {
    /// Resolve a TextStyle's font source to a concrete shaper, or nil if unavailable (caller falls
    /// back per the substitution chain, §4.3). `source` carries native-family vs .lff vs .shx.
    func resolveFont(_ source: FontSource) -> ShapedFont?
}

/// A resolved, ready-to-shape font (one family/face at unit em). Immutable + internally cached.
public protocol ShapedFont: Sendable {
    /// Font metrics in em units (scaled by the entity height at layout time). Drives baseline/
    /// ascent/descent placement and tight bounding boxes.
    var metrics: FontMetrics { get }

    /// Shape ONE run of text into positioned glyphs (kerning, ligatures, Unicode, complex/RTL
    /// applied here). `attributes` carries bold/italic/oblique/width-factor/tracking for the run.
    /// Pure: no GPU, fully unit-testable (Core Text shaping runs headless).
    func shape(_ text: String, attributes: RunAttributes) -> [PositionedGlyph]

    /// The drawable geometry of ONE glyph at unit em, in em space, flattened to `tolerance`.
    /// Native ⇒ filled loops (outline). Stroke ⇒ open polylines. Cached by (font, glyphID, tolBucket).
    func glyphGeometry(_ glyph: GlyphID, tolerance: Double) -> GlyphGeometry
}

/// A glyph placed along the baseline by the shaper (em units, pre-scale).
public struct PositionedGlyph: Sendable, Hashable {
    public var glyph: GlyphID
    public var advance: Vector        // pen advance after this glyph (kerned)
    public var offset: Vector         // baseline offset (e.g. for marks / vertical shaping)
}

/// Per-run shaping attributes (assembled from TextStyle + entity/run overrides).
public struct RunAttributes: Sendable, Hashable {
    public var bold: Bool
    public var italic: Bool
    public var obliqueAngle: Double   // radians; applied as a shear AFTER shaping
    public var widthFactor: Double    // horizontal scale; applied AFTER shaping
    public var tracking: Double       // extra advance per glyph (em)
}

/// Glyph drawable geometry at unit em. A glyph is EITHER fills (native outline) OR strokes (.lff/SHX),
/// never both — but the type carries both so the cache + resolve seam is uniform.
public struct GlyphGeometry: Sendable, Hashable {
    public var fills: [[Vector]]      // closed loops (outline contours), em space — native fonts
    public var strokes: [[Vector]]    // open polylines, em space — stroke fonts
    public var isEmpty: Bool { fills.isEmpty && strokes.isEmpty }
}

public struct FontMetrics: Sendable, Hashable {
    public var ascent: Double         // em; cap/ascender top above baseline
    public var descent: Double        // em; below baseline (positive magnitude)
    public var capHeight: Double      // em; DXF `height` maps to this (the scale denominator)
    public var lineGap: Double        // em; inter-line leading
    public var unitsPerEm: Double     // native: CTFont em; stroke: lffCapHeight-based normalization
}

public struct GlyphID: Hashable, Sendable, Codable { public let rawValue: UInt32 }
```

### 2.2 Native (Core Text) implementation — the DEFAULT

`CoreTextFontProvider: FontProvider` / `CoreTextFont: ShapedFont`. Pipeline:

1. **Resolve face:** `CTFontCreateWithName(family, 1.0, nil)` (unit em). bold/italic via
   `CTFontCreateCopyWithSymbolicTraits` (`.boldTrait`/`.italicTrait`). `metrics` from
   `CTFontGetAscent/Descent/CapHeight/Leading` ÷ `CTFontGetUnitsPerEm` normalized to em.
2. **Shape a run:** build a `CFAttributedString` (font + attributes), make a `CTLine`
   (`CTLineCreateWithAttributedString`) — OR a `CTTypesetter` when we wrap. Walk the line's
   `CTRun`s; for each, `CTRunGetGlyphs` + `CTRunGetPositions` + `CTRunGetAdvances` → `PositionedGlyph`s.
   **This is where kerning, ligatures, full Unicode, and complex/RTL shaping come for free** — Core
   Text does it. (For RTL/bidi we let Core Text reorder within the line; `attachment`/justify happen
   after.)
3. **Glyph outline → geometry:** `CTFontCreatePathForGlyph(font, glyph, &transform) -> CGPath`. Flatten
   the path with `CGPathCreateCopyByFlattening` **or** walk it with `CGPathApplyWithBlock`,
   converting `move/line/quad/cubic` to points at a **flattening tolerance derived from
   `tolerance`** (the chord-error budget — same sagitta idea as `Tessellation.segmentCount`, but for
   Béziers: subdivide until the control-point deviation < tol). Quadratics → reuse the existing
   `QuadSpline.point`; cubics → de Casteljau. Output **closed loops** in `GlyphGeometry.fills`
   (outer CCW, holes CW — the `ResolvedFill` loop contract). Counters/holes (the inside of an "O")
   are separate loops; even-odd/nonzero winding is preserved so the triangulator cuts them out.
4. **Em normalization:** glyph paths come back at the CTFont's point size (we pass 1.0). We normalize
   so that **DXF `height` == cap height** maps to a scale of `height / metrics.capHeight` — the same
   contract `Resolve.layoutText` already uses for `.lff` (`lffCapHeight = 9.0`). This keeps native and
   stroke text the same physical cap height for the same DXF `height`.

**No SDF, no atlas, no rasterization.** Outlines are vector → crisp at any zoom, perfect PDF/SVG export
(the export wave's `ResolvedGeometry → CGContext`/SVG path consumes the same fills). This is exactly the
ADR-004-revision rationale.

### 2.3 Stroke (`.lff`, future SHX) implementation

`StrokeFontProvider` already exists and is wired. We make it conform to `FontProvider`:

- `resolveFont(.stroke(lff:))` → loads/caches the `StrokeFont` (existing `font(named:)`).
- `ShapedFont` over a `StrokeFont`: `shape(_:attributes:)` advances per glyph using
  `letterSpacing`/`wordSpacing` (the existing `Resolve.layoutText` logic, lifted into the shaper);
  there is no kerning table in `.lff`, so advance == glyph width + letter spacing.
  `glyphGeometry(_:tolerance:)` returns the glyph's `strokes` (already polylines; bulges expanded at
  parse time by `LFFParser`). `metrics` uses `lffCapHeight = 9.0` as `capHeight`.
- SHX (Phase 3) is a third `FontSource.shx` resolved by the **same** stroke impl once an SHX parser
  lands (§4.2) — SHX shapes are stroke geometry, so they reuse `GlyphGeometry.strokes`.

### 2.4 How a `.text` / `.mtext` / `.dimension` arm resolves (what it emits)

The resolve arm builds `RunAttributes` from `TextStyle` + entity/run overrides, calls
`provider.resolveFont(...)?.shape(...)`, lays glyphs along the baseline (applying justification,
width-factor scale, oblique shear, rotation, then ADR-003 world placement), fetches each glyph's
`GlyphGeometry`, transforms it em→world, and emits:

- **Native glyphs → `ResolvedFill`** (one fill per glyph, loops = contours+holes, color = pen color)
  appended to `ResolvedGeometry.fills`. The renderer triangulates + draws them (verified: `LineRenderer`
  draws `ResolvedFill`s as `.triangle`). AA comes free from the fill pipeline's alpha-blended pass.
- **Stroke glyphs → `ResolvedPolyline`** appended to `ResolvedGeometry.polylines` (unchanged behavior).

**Justification (all 15 modes) is a baseline-placement transform**, identical for both glyph sources:
shape the line, measure its advance width + the font's ascent/descent, then translate so the requested
H×V anchor lands on `position` (`.middle` centers both; `.aligned`/`.fit` use `secondPoint` to set the
run length — `.aligned` scales height to fit, `.fit` varies width factor). This reuses the exact mode
matrix `RS_Text`/`DRW_Text` define, so it round-trips.

### 2.5 Glyph-geometry cache (scale-independent, re-flattened per LOD)

A process-wide cache keyed on **(font identity, glyphID, toleranceBucket)** holding the em-space
`GlyphGeometry`. Outlines are **scale-independent** (unit em), so a glyph is flattened once per LOD
bucket and reused across every instance, size, and zoom — the per-entity `resolve()` only does the
cheap em→world affine. The tolerance bucket mirrors the zoom-bucketed LOD the curve tessellation TODO
already anticipates (`Tessellation.segmentCount` / `rendering-performance.md`): coarse buckets at low
zoom (fewer points), fine at high zoom. The cache lives in the provider (like `StrokeFontProvider`'s
existing font cache, guarded by a lock; `@unchecked Sendable` is already the established pattern).

> Cache invalidation: entries are immutable per key; a new tolerance bucket just adds a key. No
> per-entity geometry is stored on the entity (ADR-001) — only the shared glyph atlas-of-vectors.

---

## 3. Quality / pro features (and how each is delivered)

| Capability | Native (Core Text) | Stroke (.lff/SHX) |
|---|---|---|
| **Kerning** | free via `CTRunGetAdvances`/`CTRunGetPositions` | not in format (letter spacing only) |
| **Ligatures** | free via CTLine shaping | n/a |
| **Unicode / complex scripts / RTL** | free via Core Text + bidi reorder | per-scalar glyph lookup only (existing) |
| **CAD special chars** `%%c`→⌀ `%%d`→° `%%p`→± `%%%`→% `\U+XXXX` | pre-pass expands `%%`/`\U+` to Unicode **before** shaping; ⌀/°/± are real glyphs | same pre-pass; falls back to `.lff` symbol fonts / U+FFFD |
| **MTEXT inline codes** `\f \H \C \S \L \O \Q \T \P \~` | parsed into the run tree (§1.3) and applied as `RunAttributes`/`StackedRun` | same parse; bold/italic ignored (stroke has no faces) |
| **Oblique** (DXF 51 / STYLE 50) | shear transform after shaping | shear transform (matches LibreCAD) |
| **Width factor** (DXF 41) | horizontal scale after shaping | horizontal scale |
| **Metrics / bbox** | exact `FontMetrics` → tight, font-aware `textBoundingBox` (replaces the loose estimate at `Resolve.swift:1010`) | exact from glyph stroke bounds |
| **Anti-aliasing** | free — fills go through the alpha-blended fill pass | strokes use the existing analytic-edge-AA line shader |

**Special-char + inline-code pre-pass** is a shared, pure function (`TextCodec`): `%%c`/`%%d`/`%%p`/
`%%%`/`%%nnn` and `\U+XXXX` → Unicode scalars; MTEXT braces/escapes → the paragraph/run tree. It runs
**once** before shaping, so both glyph sources benefit and the resulting string is plain Unicode that
Core Text shapes correctly.

---

## 4. Interop (faithful vs approximated)

### 4.1 DXF/DWG STYLE round-trip — **faithful**

The seam already exists: `DRW_Textstyle` (codes 3/4/40/41/42/50/71/1071), `LC_TextStyle`, and our
`DxfBridge` POD carry TEXT's 7/40/41/50/51/72/73. The bridge currently passes TEXT through; we add a
**STYLE table** POD pass (read DRW_Textstyle entries → `TextStyle`; write `TextStyle` → DRW_Textstyle).
`TextStyle` maps field-for-field, so STYLE round-trips losslessly. Per-entity `TextData.widthFactor`
(41) and `obliqueAngle` (51) now round-trip too (today the bridge reads them; we stop dropping them).
`.native(family)` writes the family name in code 3 + the 1071 TTF flag — AutoCAD reads that back as a
TrueType style. **Faithful.**

### 4.2 SHX stroke-font reading — **approximated → faithful (Phase 3)**

SHX is AutoCAD's **compiled** shape font (binary). Format assessment:
- Header `AutoCAD-86 shapes 1.0` / `unifont 1.0`; then a shape-definition table: each glyph is a
  byte-coded sequence of pen moves (vectors with a length+direction nibble), arc/octant codes, scale
  push/pop, and subshape calls. Two flavors: **regular SHX** (shape number = char code) and **Unifont
  SHX** (wide chars, used with bigfonts).
- **Effort:** Medium. It's a self-contained byte-stream decoder (a few hundred lines) → the same
  stroke-polyline output the `.lff` path already consumes (`GlyphGeometry.strokes`). No new render
  path. There is mature reference (LibreCAD/other GPL CAD have SHX readers to port; the format is
  documented).
- **Risk:** Medium — bigfont/Unifont subshape recursion and the octant-arc encoding are fiddly; some
  proprietary SHX (encrypted/“secret”) we cannot read.
- **Until it lands:** a style referencing `.shx` resolves through the **substitution chain** (§4.3) to
  the nearest `.lff` or a native fallback — *approximated*, never a crash. Mark in UI as "substituted".

### 4.3 Font substitution / mapping — **approximated (clearly labeled)**

When a referenced font isn't installed (a DWG made on a machine with fonts we lack), AutoCAD uses an
**`.fmp` (font-mapping) chain**. We implement an equivalent fallback resolver inside `FontProvider`:

```
requested font (style code 3)
  → exact match? (CTFontManager has the family / .lff exists / .shx parsable)
  → .fmp-style alias map (bundled defaults: "romans"→"Helvetica", "txt"→"SF Pro Text",
                          "simplex"→"Helvetica", "arial"→"Helvetica Neue", ...) editable by user
  → category fallback (serif→Times, sans→Helvetica, mono→Menlo, symbol→.lff symbol)
  → last resort: the always-present default native family, then .lff "standard"
```

The chain is data-driven (a bundled `font-map.plist` + a user override), so adding mappings needs no
code. **Approximated** by definition — a substituted glyph isn't the original face — but the *layout
metrics* are preserved (we keep the requested height/width factor), so the drawing's geometry stays
close. The style remembers the **original** requested name (round-trips unchanged); substitution is a
*display* concern only.

---

## 5. UI (specify, not build)

Three surfaces, all driven by the model above and the Inspector wiring already planned (`v3-plan.md`
`ws/inspector`):

1. **Font picker with live previews.** A SwiftUI control listing (a) installed native families
   (`CTFontManagerCopyAvailableFontFamilyNames`, each rendered in its own face as the preview) and (b)
   bundled `.lff`/SHX stroke fonts (preview rendered via our own shaper into a tiny `CGContext`). Sets
   `TextStyle.primaryFont` (or a per-run `fontOverride`). Lives in the text tool's options + the
   Inspector's text section.
2. **Text-style manager.** A sheet listing the `TextStyleTable` (New / Rename / Delete / Set Current),
   each row editing a `TextStyle`'s fields (font, fixed height, width factor, oblique, bold/italic,
   backward/upside-down). Editing a style re-flows every entity referencing it (it's a name-keyed
   resolve, so the geometry cache invalidates by style version). This is the AutoCAD STYLE dialog.
3. **Inline MTEXT editing over the Metal canvas.** Per Design Decision **D2** in `v3-plan.md`
   (recommended **A**: a transient AppKit `NSTextView` overlay on the `CADCanvasView`
   `NSViewRepresentable`/flipped `MTKView`). A double-click on an MTEXT (or the text tool) drops an
   `NSTextView` at the entity's screen rect, themed to match (font, size from the world→screen scale),
   giving free IME/cursor/selection/spellcheck. On commit, the editor's attributed string → the
   `paragraphs`/`rawCode` model via the `TextCodec` (NSAttributedString ↔ MTEXT codes). The Inspector
   shows the same MTEXT properties (attachment, wrap width, line spacing) for non-inline edits.

All three bind to `CanvasModel`/the document and emit `ToolEdit.add`/`.replace` (undoable), matching the
existing tool/inspector edit flow.

---

## 6. Phased roadmap

| Phase | Scope | Deliverable | Effort | Risk | Pro capability unlocked |
|---|---|---|---|---|---|
| **1 — Foundation** | `FontProvider`/`ShapedFont` protocol; Core Text outline provider (default); `TextStyle` + `TextStyleTable`; extend `TextData` (15 justification modes, width factor, oblique, secondPoint); single-line shaping; multi-line `\n` layout + alignment; special-char pre-pass; glyph-geometry cache; tight font-aware bbox; `.lff` retained & selectable | The data model **full-scope**; native font is the default for new text; `.text` resolves native fills or `.lff` strokes; all 15 modes honored | **L** | **M** (Core Text path-flatten + cache; bbox change) | Real TrueType typefaces, kerning, ligatures, Unicode, crisp-at-any-zoom, correct justification — the core "good font story" |
| **2 — Rich MTEXT** | `case mtext(MTextData)` (its own EntityKind step); MTEXT inline-code parser → run tree; per-run bold/italic/underline/overline/strike, height/color; stacked fractions; wrap width + line spacing + attachment; **style manager + font-picker UI**; **inline NSTextView editor** | Author + render rich multi-line text; MTEXT round-trips (write real MTEXT, not downgraded TEXT) | **L** | **M** (MTEXT code grammar; NSTextView↔model) | MTEXT parity with AutoCAD for everyday annotation |
| **3 — Interop** | SHX reader (regular + bigfont/Unifont); `.fmp`-style font mapping/substitution chain + UI; DWG STYLE fidelity (the bridge STYLE pass on the DWG path) | Open AutoCAD drawings with SHX/missing fonts and see correct-enough text; SHX styles render natively | **M–L** | **M–H** (SHX bigfont recursion; encrypted SHX unreadable) | Open real-world AutoCAD files without garbled text |
| **4 — Annotative + advanced** | Annotative text scaling (style + per-viewport scale); fields (auto-text: date, filename, computed); columns; background mask/fill | Annotation-scale-aware text; dynamic fields | **M** | **M** | Sheet-set / annotation workflows; the last pro gap |

Sequencing fits `v3-plan.md`: Phase 1 touches `Entity.swift`/`Resolve.swift`/`ResolveContext` and the
font module — it can run as a focused owner; Phase 2's `.mtext` is an EntityKind add (serialize like S1/
S2). Phase 3's SHX/mapping is engine + bridge; DWG STYLE serializes after the DWG-write work.

---

## 7. Scope decisions for the user (either/or + recommendation)

- **T1 — Default native font for new text.** (A) `SF Pro Text` (the macOS system sans — most "native"
  feel) · (B) `Helvetica Neue` (closest to the CAD/ISO look AutoCAD users expect) · (C) keep `.lff`
  "standard" as default, native opt-in.
  **Recommend B (Helvetica Neue) as the default native family**, with `.lff` "standard" one click away.
  It reads as professional CAD lettering, is universally installed, and substitutes cleanly for
  `romans`/`simplex`. (SF Pro is great for UI but looks "app-y" in a drawing.) This honors the ADR-004
  revision: *new text defaults to a clean native font; `.lff` "standard" remains selectable.*

- **T2 — SHX import in the first milestone or deferred?** (A) Phase 1 · (B) Phase 3 (substitute until
  then).
  **Recommend B.** SHX is a self-contained medium effort with no render-path impact, but it is NOT on
  the path to the headline win (nice native fonts). The substitution chain (§4.3) makes SHX-referencing
  drawings *open and read* fine in the meantime. Do it when interop becomes the priority.

- **T3 — How far on rich MTEXT for v1?** (A) Phase 1 ships single-line + `\n` multi-line only; full
  MTEXT (runs/stacked/inline editor) is Phase 2 · (B) push basic per-run bold/italic into Phase 1.
  **Recommend A.** Phase 1's job is the *foundation built full-scope* — the `MTextData` tree types are
  defined now (so Phase 2 layers on without a rewrite) but only single-line/`\n` is *implemented*.
  Stuffing runs + the NSTextView editor into Phase 1 balloons its risk. The model is future-proof
  either way.

- **T4 — Annotative scaling now or later?** (A) Phase 1 reserves the fields · (B) full impl Phase 4.
  **Recommend A then B.** Reserve an `annotative: Bool` + scale hook on `TextStyle`/`TextData` in
  Phase 1's full-scope model (one field, costs nothing), implement the scaling in Phase 4. Don't build
  the viewport-scale machinery before viewports/layouts exist.

- **T5 — `TextData` extend vs new type.** (A) Extend `TextData` additively (new fields default) · (B)
  introduce a fresh `TextData2`.
  **Recommend A.** Additive fields keep the existing `EntityKind.text`, the DXF reader/writer, and the
  resolve/bbox/transform/snapping switches compiling — no EntityKind churn for single-line text. Only
  `.mtext` is a new kind (Phase 2), which *is* an EntityKind step by necessity.

---

## 8. The Phase-1 contract (what the foundation builder implements)

**Designed so Phases 2–4 layer on without rewriting Phase 1.** The builder owns the font module +
the text resolve arm + the `TextData` extension + the STYLE table; it does NOT add a new EntityKind
(single-line text stays `.text`).

### 8.1 Types to add (full-scope, even where features are stubbed)
- `FontSource`, `TextStyle`, `TextStyleID`, `TextStyleTable`, `TextGenerationFlags`, `TextStyleFlags`
  (§1.1) — complete.
- Extend `TextData` with `secondPoint`, `widthFactor`, `obliqueAngle`, `generation` (defaults so the
  DXF reader and all call sites compile); widen `TextHAlign` to `.aligned/.middle/.fit` (§1.2).
- Define `MTextData` + run-tree types (§1.3) **now** (so Phase 2 doesn't re-broadcast a model change),
  but do NOT add `EntityKind.mtext` yet (that's the Phase-2 serialized EntityKind step).
- `FontProvider`, `ShapedFont`, `PositionedGlyph`, `RunAttributes`, `GlyphGeometry`, `FontMetrics`,
  `GlyphID` (§2.1) — complete protocol.

### 8.2 Provider impls
- `CoreTextFontProvider` / `CoreTextFont` (§2.2) — the default. Shaping via `CTLine`/`CTRun`; outlines
  via `CTFontCreatePathForGlyph` → flatten-to-tolerance → closed loops; em normalized to cap height.
- `StrokeFontProvider` conforms to `FontProvider`/`ShapedFont` (§2.3) by lifting the existing
  `Resolve.layoutText` advance logic into the shaper; glyph strokes are its `GlyphGeometry.strokes`.
- The glyph-geometry cache (§2.5), keyed (font, glyphID, toleranceBucket).
- A substitution resolver stub (§4.3): exact match → default native → `.lff` "standard" (the full
  `.fmp` map is Phase 3; the *seam* exists now).

### 8.3 `ResolveContext` change (additive, keeps Sendable)
- Replace the bare `fontProvider: ((String) -> StrokeFont?)?` with `var fontProvider: (any
  FontProvider)?` (and keep a thin closure-compat initializer during the transition so
  `CADDrawing.makeResolveContext` / `CADFonts` keep working). Add `var textStyleProvider: (@Sendable
  (String) -> TextStyle?)?` (resolves a style name → `TextStyle`, defaulting to "Standard"), parallel
  to the reserved `dimStyleProvider` hook.

### 8.4 What `resolve()` emits (the load-bearing contract)
For `case .text(let d)`:
1. Resolve the style: `ctx.textStyleProvider?(d.styleName ?? "Standard") ?? .standard`.
2. Pre-pass the string through `TextCodec` (`%%c/%%d/%%p/%%%`, `\U+XXXX`).
3. Split on `\n` into lines; for each line build `RunAttributes` (style + entity `widthFactor`/
   `obliqueAngle`/`generation`) and call `provider.resolveFont(style.primaryFont)?.shape(line, ...)`.
4. Place glyphs along the baseline; apply the requested **justification (all 15 modes)**, width-factor
   scale, oblique shear, line advance (`metrics` + style/factor), rotation, then ADR-003 world
   placement (em→world affine; offsets are f64, the renderer subtracts `renderOrigin`).
5. Fetch each glyph's `GlyphGeometry` from the cache; transform em→world; emit:
   - native ⇒ append `ResolvedFill(loops:, color: pen.color)` to `ResolvedGeometry.fills`;
   - stroke ⇒ append `ResolvedPolyline(points:, closed:false, pen:)` to `.polylines`.
   No font / no glyph ⇒ substitution chain, else skip the glyph (advance only) — **never crash**
   (preserve the current graceful-empty behavior).
6. `boundingBox()` for `.text` becomes **font-aware and tight**: shape with the default tolerance and
   union the glyph extents (replaces the loose estimate at `Resolve.swift:1010`). Keep a no-font
   fallback to the current metric estimate so the bbox path (which has no provider today) never breaks.

For `case .dimension` (in-flight): the dimension arm builds a `TextData` from its dim style and calls
the **same** shaping entry point — **no second text path** (§1.4). The Phase-1 builder exposes that
entry point (e.g. `TextShaper.resolve(_ d: TextData, style:, pen:, ctx:) -> ResolvedGeometry`) so the
dimension owner consumes it directly.

### 8.5 Renderer / writer impact
- **Renderer:** ZERO changes. `ResolvedFill`s from glyph outlines are already triangulated
  (`FillTriangulation`) and drawn (`LineRenderer`). Holes (counters) rely on the `loops[1...]` hole
  contract — the earcut hole-stitching is the existing `RendererGeometry` backlog item; until it lands,
  glyphs with counters slightly over-fill (the "O" hole fills) but **never crash or misrender shape**.
  *Recommend Phase 1 also lands the earcut hole-bridge* (small, already specced in `FillTriangulation`'s
  TODO) so outline text looks correct — this is the one renderer-adjacent task worth pulling in.
- **DXF writer:** single-line TEXT continues to write as DXF TEXT (existing arm), now also emitting
  width factor (41) / oblique (51) / the full 72/73 codes; STYLE table write is added (the bridge STYLE
  pass). MTEXT write stays downgraded-to-TEXT until Phase 2 (existing behavior, documented in backlog).

### 8.6 Tests (namespaced per the fan-out convention)
`TextStyleTests`, `CoreTextShapingTests` (headless — Core Text shapes without a GPU/window),
`GlyphFlatteningTests` (tolerance → point count monotonic; closed loops; CCW outer/CW holes),
`TextJustificationTests` (all 15 modes anchor correctly), `TextCodecTests` (`%%`/`\U+`/MTEXT codes),
`TextBoundingBoxTests` (tight vs loose). The `.text` resolve arm gets a test asserting native text
emits fills and `.lff` text emits polylines for the same string.

---

## Appendix — key seams referenced (absolute paths)

- Entity/text model: `macos/engine/Sources/CADEngine/Entity.swift` (`TextData`, `EntityKind`,
  `EntityRecord`).
- Resolve seam: `macos/engine/Sources/CADEngine/Resolve.swift` (`ResolveContext.fontProvider` /
  reserved `dimStyleProvider` at ~L126; `layoutText` L710; `textBoundingBox` L1010; `ResolvedGeometry`/
  `ResolvedFill` L24–85).
- Pen/color: `macos/engine/Sources/CADEngine/Pen.swift` (`ResolvedPen`, `RGBAColor`).
- Stroke fonts: `macos/engine/Sources/CADEngine/Text/{LFFFont,LFFParser,StrokeFontProvider}.swift`;
  wiring `macos/engine/Sources/CADEngine/CADDrawing.swift` (`makeResolveContext` L649, `CADFonts` L673).
- Fill render (no changes needed): `macos/engine/Sources/LibreCADmacOS/Renderer/RendererGeometry.swift`
  (`FillTriangulation`, `appendFillVertices`) + `LineRenderer.swift` (fills drawn as `.triangle` L283).
- DXF seam: `macos/engine/Sources/DxfBridge/include/lcdxf.h` (text POD fields),
  `macos/engine/Sources/CADEngine/{DXFReader,DXFWriter}.swift` (text arms);
  upstream `librecad/src/lib/engine/document/{entities/rs_text.h,entities/rs_mtext.h,
  textstyles/lc_textstyle.h}`; libdxfrw `libraries/libdxfrw/src/{drw_entities.h (DRW_Text/DRW_MText),
  drw_objects.h (DRW_Textstyle)}`.
