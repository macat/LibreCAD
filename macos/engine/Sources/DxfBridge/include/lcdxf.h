/******************************************************************************
**  LibreCAD macOS — DXF bridge (C ABI over libdxfrw)                        **
**                                                                           **
**  This file is part of LibreCAD's native macOS port, a derivative work of  **
**  LibreCAD and libdxfrw. Both are licensed GPLv2-or-later; this fork       **
**  inherits that license.                                                   **
**                                                                           **
**  Copyright (C) 2026 LibreCAD macOS contributors.                          **
**                                                                           **
**  This program is free software; you can redistribute it and/or modify     **
**  it under the terms of the GNU General Public License as published by     **
**  the Free Software Foundation; either version 2 of the License, or        **
**  (at your option) any later version.                                      **
******************************************************************************/

#ifndef LCDXF_H
#define LCDXF_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Status codes returned by the bridge. Replaces the previous process-global
 * error-string scheme: every call now returns an explicit, thread-safe status,
 * and outputs are written through out-parameters. Swift maps these to a thrown
 * `CADEngineError`.
 */
typedef enum LCStatus {
    LC_OK = 0,                /**< Success. */
    LC_ERR_INVALID_PATH = 1,  /**< path was null or empty. */
    LC_ERR_READ_FAILED = 2,   /**< libdxfrw could not read the file (bad/missing/corrupt). */
    LC_ERR_WRITE_FAILED = 3   /**< libdxfrw could not write the file (bad path, I/O, or an
                                   exception escaping the export). */
} LCStatus;

/**
 * DXF output version, mirroring the subset of `DRW::Version` the writer accepts.
 * Default is `LC_DXF_R2000` (AutoCAD 2000 / AC1015) — the version LibreCAD's
 * `fileExport` defaults to and the most broadly-compatible modern DXF. An
 * out-of-range value falls back to R2000.
 */
typedef enum LCDxfVersion {
    LC_DXF_R12   = 0,   /**< AC1009 (R11/R12) — ellipses/lwpolylines downgraded by libdxfrw. */
    LC_DXF_R14   = 1,   /**< AC1014. */
    LC_DXF_R2000 = 2,   /**< AC1015 — the default. */
    LC_DXF_R2004 = 3,   /**< AC1018. */
    LC_DXF_R2007 = 4,   /**< AC1021. */
    LC_DXF_R2018 = 5    /**< AC1032. */
} LCDxfVersion;

/* ------------------------------------------------------------------------- *
 *  Flattened entity model
 *
 *  The reader streams a DXF file through libdxfrw's DRW_Interface and flattens
 *  every supported geometric entity into a trivially-copyable POD struct here.
 *  DRW_Header / DRW_Variant / std::shared_ptr graphs NEVER cross to Swift: all
 *  strings are copied into a per-handle pool and referenced by `const char*`
 *  whose lifetime is tied to the LCEntityList that owns them. Variable-length
 *  data (polyline vertices, spline control/knot/weight arrays) live in flat
 *  arrays owned by the handle and are referenced by (pointer + count).
 * ------------------------------------------------------------------------- */

/** Discriminator for `LCEntity::kind`. */
typedef enum LCEntityKind {
    LC_ENT_LINE = 0,
    LC_ENT_POINT = 1,
    LC_ENT_CIRCLE = 2,
    LC_ENT_ARC = 3,
    LC_ENT_ELLIPSE = 4,
    LC_ENT_LWPOLYLINE = 5,
    LC_ENT_POLYLINE = 6,
    LC_ENT_SPLINE = 7,
    /** Single-line / multi-line CAD text (DXF TEXT or MTEXT). The text string is
     *  in `textValue`; insertion point in p1; `height`/`startAngle` (radians) and
     *  `hAlign`/`vAlign` carry the layout. */
    LC_ENT_TEXT = 8,
    /** A filled region (DXF HATCH). Its boundary loops are described by
     *  `loops[loopCount]`, each loop a (offset,count) window into the entity's
     *  flat `vertices` array; `solidFill` flags solid vs. pattern; `textValue`
     *  carries the pattern name. */
    LC_ENT_HATCH = 9,
    /** A filled triangle/quad (DXF SOLID / TRACE). Its 3-4 corners are in the flat
     *  `vertices` array, already un-swapped from DXF's bow-tie 3rd/4th order into
     *  ring order. */
    LC_ENT_SOLID = 10,
    /** Rich multi-line text (DXF MTEXT). The raw inline-coded string is in
     *  `textValue` (kept verbatim for lossless round-trip of the format codes);
     *  insertion point in p1; `height`/`startAngle` (radians); `mtextRectWidth`
     *  (code 41 reference/wrap width), `mtextAttachment` (code 71, 1..9),
     *  `mtextLineSpacingStyle` (code 73) and `mtextLineSpacingFactor` (code 44).
     *  Distinct from LC_ENT_TEXT so the Swift reader maps it to `.mtext`. */
    LC_ENT_MTEXT = 11,
    /** An associative CAD dimension (DXF DIMENSION). The concrete variant is in
     *  `dimType` (an LCDimType); the defining points are in the `dim*` fields
     *  below plus `definitionPoint`/`textMiddle`; the user text override is in
     *  `textValue` (NULL/empty == use the measured value); the style name (code 3)
     *  is in `styleName`. `dimAngle`/`dimOblique` carry the linear angle/oblique
     *  (codes 50/52); `dimAlign` the attachment (code 71); `dimLineStyle`/
     *  `dimLineFactor` the text line spacing (codes 72/41); `dimTextRotation` the
     *  explicit text rotation (code 53). Distinct from LC_ENT_UNSUPPORTED so the
     *  reader maps it to `.dimension`. */
    LC_ENT_DIMENSION = 12,
    /** A block reference (DXF INSERT / MINSERT). The referenced block name is in
     *  `textValue`; the insertion point in p1; per-axis scale in
     *  `insScaleX/Y/Z`; the rotation (radians) in `startAngle`; and the MINSERT
     *  rectangular array in `insRows`/`insCols`/`insRowSpacing`/`insColSpacing`
     *  (default 1×1, zero spacing == a plain single insert). Distinct from
     *  LC_ENT_UNSUPPORTED so the reader maps it to `.insert`. */
    LC_ENT_INSERT = 13,
    /** An INFINITE construction line (DXF XLINE / DRW_Xline). Its base point
     *  (code 10) is in p1; its unit direction (code 11) is in p2 (stored as a
     *  direction vector, NOT a second point). Distinct from LC_ENT_UNSUPPORTED so
     *  the reader maps it to `.xline`. */
    LC_ENT_XLINE = 14,
    /** A RAY — a semi-infinite construction line (DXF RAY / DRW_Ray). Its start
     *  (base) point (code 10) is in p1; its direction (code 11) is in p2. The ray
     *  extends from p1 toward +p2 only. Distinct from LC_ENT_UNSUPPORTED so the
     *  reader maps it to `.ray`. */
    LC_ENT_RAY = 15,
    /** A LEADER — an annotation callout (DXF LEADER / DRW_Leader). Its path
     *  vertices (codes 10/20/30) are in the flat `vertices` array; `leaderHasArrow`
     *  (code 71) flags the arrowhead at the first vertex; `leaderArrowSize` (the
     *  dim style arrow size) is the arrowhead length; `height` carries the text
     *  annotation height (code 40); `styleName` the referenced dim style (code 3).
     *  The leader may carry ZERO vertices (a degenerate callout that round-trips
     *  but draws nothing). The attached annotation entity (DXF hard-ref code 340)
     *  is NOT flattened here — a leader's inline annotation in the engine value
     *  model round-trips via Codable, not DXF. Distinct from LC_ENT_UNSUPPORTED so
     *  the reader maps it to `.leader` (was previously dropped as unsupported). */
    LC_ENT_LEADER = 16,
    /** A raster IMAGE (DXF IMAGE + its IMAGEDEF, DRW_Image + DRW_ImageDef). The
     *  insertion point (lower-left, code 10) is in p1; the per-pixel U vector
     *  (code 11) in p2; the per-pixel V vector (code 12) in `imgVVec*`; the image
     *  pixel size (codes 13/23, and the IMAGEDEF codes 10/20) in `imgSizeU`/
     *  `imgSizeV`; the display params (codes 280/281/282/283) in `imgClip`/
     *  `imgBrightness`/`imgContrast`/`imgFade`; the show-image display flag in
     *  `imgShow`; and the source file PATH (the IMAGEDEF name, code 1) in
     *  `textValue`. The reader links the IMAGE (addImage, code 340 ref) to its
     *  IMAGEDEF (linkImage, code 5 handle) by handle and folds the path + pixel
     *  size in. Distinct from LC_ENT_UNSUPPORTED so the reader maps it to `.image`
     *  (was previously dropped as unsupported). */
    LC_ENT_IMAGE = 17,
    /** An entity libdxfrw delivered but the reader does not flatten
     *  (ordinate-DIMENSION/...). Carries only its `typeName` so Swift
     *  can collect a warning; geometry fields are unset. */
    LC_ENT_UNSUPPORTED = 100
} LCEntityKind;

/** Discriminator for `LCEntity::dimType` (which DRW_Dim* subtype). The values
 *  mirror the DXF type-70 low-nibble codes libdxfrw dispatches on
 *  (processDimension: `dim.type & 0x0F`): linear 0, aligned 1, 2-line angular 2,
 *  diametric 3, radial 4, 3-point angular 5, ordinate 6. ARC-LENGTH has no DXF
 *  DIMENSION subtype in libdxfrw (AutoCAD ARC_DIMENSION is unsupported by
 *  libdxfrw and is not written by upstream LibreCAD either); it is given a
 *  bridge-internal discriminator so the engine value model round-trips, and on
 *  DXF write it is persisted via the 3-point-angular geometry (graceful — its
 *  full fidelity round-trips through the engine's Codable value model). */
typedef enum LCDimType {
    LC_DIM_LINEAR     = 0,  /**< DRW_DimLinear  — def1/def2 (codes 13/14) + dimAngle (50). */
    LC_DIM_ALIGNED    = 1,  /**< DRW_DimAligned — def1/def2 (codes 13/14). */
    LC_DIM_ANGULAR    = 2,  /**< DRW_DimAngular (2-line) — def1/def2/def5 + defPoint + arc (16). */
    LC_DIM_DIAMETRIC  = 3,  /**< DRW_DimDiametric — def5 (code 15) + defPoint (code 10). */
    LC_DIM_RADIAL     = 4,  /**< DRW_DimRadial — defPoint (center, 10) + def5 (radius point, 15). */
    LC_DIM_ANGULAR3P  = 5,  /**< DRW_DimAngular3p — def1 (13), def2 (14), def5 (vertex, 15), defPoint (arc, 10). */
    LC_DIM_ORDINATE   = 6,  /**< DRW_DimOrdinate — defPoint (origin, 10), def1 (feature, 13), def2 (leader end, 14); dimOrdinateX bit selects X- vs Y-datum (type-70 bit 0x40). */
    LC_DIM_ARC_LENGTH = 7   /**< arc-length (no DXF subtype) — center (p1), radius, startAngle/endAngle, dimArc* (def point at the dim-arc radius), dimReversed sweep flag. */
} LCDimType;

/** One flattened polyline vertex: a 2D point plus a DXF bulge. */
typedef struct LCVertex {
    double x;
    double y;
    double bulge;   /**< tan(includedAngle/4) of the following segment; 0 == straight. */
} LCVertex;

/** One flattened hatch boundary loop: a (offset, count) window into the owning
 *  LCEntity's flat `vertices` array. Lets a single hatch carry several loops
 *  (outer boundary + holes) without nested pointers crossing the C boundary. */
typedef struct LCLoop {
    int32_t offset;   /**< index of this loop's first vertex in `vertices`. */
    int32_t count;    /**< number of vertices in this loop. */
} LCLoop;

/**
 * A single flattened entity. Plain-old-data: trivially copyable, no owning
 * pointers except the borrowed `const char*` strings and the borrowed flat
 * arrays, all of which live in the owning LCEntityList. Which fields are
 * meaningful depends on `kind`:
 *
 *  - LINE:        p1, p2
 *  - POINT:       p1
 *  - CIRCLE:      center, radius
 *  - ARC:         center, radius, startAngle, endAngle (radians)
 *  - ELLIPSE:     center, majorEnd (major-axis endpoint RELATIVE to center),
 *                 ratio, startAngle, endAngle (ellipse parameters, radians)
 *  - LWPOLYLINE / POLYLINE: vertices[vertexCount], closed
 *  - SPLINE:      degree, controlPoints (as vertices[].x/.y), knots/weights,
 *                 closed, splineFlags (code 70), fitPoints[fitPointCount] (a
 *                 fit-point/interpolation spline carries its on-curve points)
 *  - TEXT:        p1 (insertion point), height, startAngle (rotation, radians),
 *                 hAlign/vAlign, textValue (string), styleName
 *  - HATCH:       loops[loopCount] (each a window into vertices[]), solidFill,
 *                 textValue (pattern name)
 *  - SOLID:       vertices[vertexCount] (3-4 ring-ordered corners)
 *  - DIMENSION:   dimType, definitionPoint (p1), the dim* defining points,
 *                 dimAngle/dimOblique/dimTextRotation, dimAlign/dimLineStyle/
 *                 dimLineFactor, textValue (text override), styleName (dim style)
 *  - UNSUPPORTED: typeName only
 */
typedef struct LCEntity {
    int32_t kind;          /**< an LCEntityKind value. */

    /* Common attributes (flattened from DRW_Entity). */
    const char *layer;     /**< layer name (never NULL; "0" if absent). */
    const char *lineType;  /**< linetype name (never NULL; "BYLAYER" if absent). */
    int32_t color;         /**< ACI color index, code 62 (0=ByBlock, 256=ByLayer). */
    int32_t color24;       /**< true-color 0x00RRGGBB, code 420, or -1 if unset. */
    int32_t lineWeightMM100;/**< lineweight in mm*100; -1 ByLayer, -2 ByBlock, -3 default. */
    /** Which "space" the entity lives in (paper-space P1): 0 == model space (DXF
     *  code 67 == 0, the default), 1 == paper space (code 67 == 1). The reader
     *  copies DRW_Entity::space (which libdxfrw parses from code 67) here, AND
     *  forces 1 for any entity read inside a `*Paper_Space` block (where AutoCAD
     *  marks the space by the block, not code 67). The Swift reader maps this to
     *  `EntityRecord.space`; the writer sets DRW_Entity::space from it so libdxfrw
     *  emits code 67 for a paper-space entity. */
    int32_t spaceFlag;
    /** The layout (paper sheet) name a paper-space entity belongs to (`spaceFlag
     *  == 1`), borrowing the owning list's string pool — e.g. "Layout1". NULL for
     *  model-space entities (and for paper-space entities not bound to a named
     *  layout). Reconstructed from the `*Paper_Space` block name on read (lossy on
     *  the user-facing tab name — see `LCLayout`). The Swift reader maps this to
     *  `EntityRecord.layoutName`. */
    const char *layoutName;

    /* Geometry (meaning per `kind`). */
    double p1x, p1y, p1z;  /**< line start / point / generic base point. */
    double p2x, p2y, p2z;  /**< line end / ellipse major-axis endpoint (relative). */
    double cx, cy, cz;     /**< center (circle / arc / ellipse). */
    double radius;
    double startAngle;     /**< arc/ellipse start (radians). */
    double endAngle;       /**< arc/ellipse end (radians). */
    double ratio;          /**< ellipse minor/major ratio. */

    int32_t closed;        /**< polyline/spline closed flag (0/1). */
    int32_t degree;        /**< spline degree. */
    /** SPLINE DXF code-70 bit flags (1 closed, 2 periodic, 4 rational, 8 planar,
     *  16 linear). The reader copies the raw flags here so a write round-trips
     *  the closed/periodic/rational state; the writer sets DRW_Spline::flags from
     *  it. 0 == the writer derives a default (planar, +closed/periodic when the
     *  `closed` flag is set). */
    int32_t splineFlags;
    /** SPLINE fit points (DXF codes 11/21), borrowed pointer into the owning
     *  list's vertex pool (bulge unused), or NULL/0 if none. A fit-point spline
     *  (`.splinePoints`) carries its on-curve interpolation points here in
     *  addition to the control points in `vertices`; a pure control-point spline
     *  leaves it empty. */
    const LCVertex *fitPoints;
    int32_t fitPointCount;

    /* Text (TEXT / MTEXT). */
    double height;         /**< text cap height (code 40). */
    int32_t hAlign;        /**< text horizontal align (code 72): 0 left, 1 center, 2 right. */
    int32_t vAlign;        /**< text vertical align (code 73): 0 baseline, 1 bottom, 2 middle, 3 top. */
    int32_t solidFill;     /**< HATCH solid-fill flag (0 pattern, 1 solid). */
    double  hatchScale;    /**< HATCH pattern scale, code 41 (1 == native). */
    double  hatchAngle;    /**< HATCH pattern angle, code 52 (radians). */

    /* MTEXT-only layout (meaningful when kind == LC_ENT_MTEXT). */
    double mtextRectWidth;        /**< MTEXT reference / wrap width (code 41); 0 == no wrap. */
    int32_t mtextAttachment;      /**< MTEXT attachment point (code 71): 1..9 (TL..BR). */
    int32_t mtextLineSpacingStyle;/**< MTEXT line-spacing style (code 73): 1 at-least, 2 exact. */
    double mtextLineSpacingFactor;/**< MTEXT line-spacing factor (code 44); default 1. */

    /* DIMENSION-only fields (meaningful when kind == LC_ENT_DIMENSION).
     * The shared DRW_Dimension data (defPoint code 10, textPoint code 11) reuses
     * the geometry block: definitionPoint -> p1{x,y,z}, textMiddle -> dimText*.
     * Per-variant defining points live in the dedicated dim* coords below; which
     * are meaningful depends on `dimType` (see LCDimType). `textValue` carries the
     * user text override (code 1); `styleName` the dim style (code 3). */
    int32_t dimType;              /**< an LCDimType value (which DRW_Dim* subtype). */
    double dimDef1x, dimDef1y, dimDef1z;   /**< def1 — code 13/23/33 (linear/aligned/angular). */
    double dimDef2x, dimDef2y, dimDef2z;   /**< def2 — code 14/24/34 (linear/aligned/angular). */
    double dimDef5x, dimDef5y, dimDef5z;   /**< circlePoint — code 15/25/35 (radial/diametric/angular). */
    double dimArcx,  dimArcy,  dimArcz;    /**< arcPoint — code 16/26/36 (angular). */
    double dimTextx, dimTexty, dimTextz;   /**< textMiddle — code 11/21/31 (all variants). */
    int32_t dimHasText;           /**< 1 if textMiddle (dimText*) was set, else 0. */
    double dimAngle;              /**< linear angle (code 50, radians). */
    double dimOblique;           /**< linear oblique (code 52, radians). */
    double dimTextRotation;      /**< text rotation (code 53, radians). */
    int32_t dimHasTextRotation;  /**< 1 if dimTextRotation (code 53) was set, else 0. */
    int32_t dimAlign;            /**< attachment point (code 71): 1..9. */
    int32_t dimLineStyle;        /**< text line-spacing style (code 72): 1 at-least, 2 exact. */
    double dimLineFactor;        /**< text line-spacing factor (code 41); default 1. */
    /** Per-entity DIMENSION text-height / arrow-size OVERRIDE, parsed from the
     *  `ACAD:DSTYLE` xdata group (extData: 1070 dim-var code + 1040 value pairs;
     *  text height is var 140, arrow size var 41). `has*` == 0 means "no per-entity
     *  override — inherit the dim style / document default" (resolve precedence:
     *  per-entity wins when set). When 0 the Swift reader leaves DimData.textHeight/
     *  arrowSize at the inherit sentinel so the document `$DIMTXT`/`$DIMASZ` apply. */
    double dimTextHeightOverride;
    int32_t dimHasTextHeightOverride;
    double dimArrowSizeOverride;
    int32_t dimHasArrowSizeOverride;
    /** ORDINATE (dimType == LC_DIM_ORDINATE) X- vs Y-datum: 1 == X-datum (measures
     *  the horizontal distance; DXF type-70 bit 0x40 set), 0 == Y-datum. */
    int32_t dimOrdinateX;
    /** ARC-LENGTH (dimType == LC_DIM_ARC_LENGTH) feature-arc sweep orientation:
     *  1 == clockwise (reversed), 0 == counter-clockwise. The feature arc's
     *  center is p1, its radius is `radius`, its sweep is startAngle→endAngle. */
    int32_t dimReversed;

    /* INSERT-only fields (meaningful when kind == LC_ENT_INSERT). The block name
     * is in `textValue`; the insertion point in p1; the rotation (radians) in
     * `startAngle`. Per-axis scale + the MINSERT rectangular array live here. */
    double insScaleX;            /**< x scale factor (code 41); default 1. */
    double insScaleY;            /**< y scale factor (code 42); default 1. */
    double insScaleZ;            /**< z scale factor (code 43); default 1. */
    int32_t insRows;             /**< MINSERT row count (code 71); default 1. */
    int32_t insCols;             /**< MINSERT column count (code 70); default 1. */
    double insRowSpacing;        /**< MINSERT row spacing (code 45); default 0. */
    double insColSpacing;        /**< MINSERT column spacing (code 44); default 0. */

    /* LEADER-only fields (meaningful when kind == LC_ENT_LEADER). The path
     * vertices live in the flat `vertices` array (bulge unused); the text
     * annotation height is in `height` (code 40); `styleName` the dim style. */
    int32_t leaderHasArrow;      /**< code 71 — 1 if an arrowhead is drawn, else 0. */
    double leaderArrowSize;      /**< arrowhead length (dim style arrow size). */

    /* IMAGE-only fields (meaningful when kind == LC_ENT_IMAGE). The insertion
     * (lower-left, code 10) is in p1; the per-pixel U vector (code 11) in p2; the
     * per-pixel V vector (code 12) here; the pixel size (codes 13/23 + IMAGEDEF
     * 10/20) here; the display params (codes 280–283 + show flag) here; the source
     * file path (IMAGEDEF name, code 1) in `textValue`. */
    double imgVVecX, imgVVecY, imgVVecZ; /**< per-pixel V vector (code 12/22/32). */
    double imgSizeU;             /**< image pixel width  (IMAGEDEF code 10 / IMAGE code 13). */
    double imgSizeV;             /**< image pixel height (IMAGEDEF code 20 / IMAGE code 23). */
    int32_t imgBrightness;       /**< code 281, 0–100; default 50. */
    int32_t imgContrast;         /**< code 282, 0–100; default 50. */
    int32_t imgFade;             /**< code 283, 0–100; default 0. */
    int32_t imgClip;             /**< code 280 clip on/off; default 0. */
    int32_t imgShow;             /**< show-image display flag (code 70 bit 1); default 1. */

    /* Variable-length data — borrowed pointers into the owning list's pools. */
    const LCVertex *vertices;   /**< polyline vertices, spline control points, hatch
                                     boundary vertices, or solid corners (x/y). */
    int32_t vertexCount;
    const double *knots;        /**< spline knot vector (may be NULL/0). */
    int32_t knotCount;
    const double *weights;      /**< spline rational weights (may be NULL/0). */
    int32_t weightCount;
    const LCLoop *loops;        /**< HATCH boundary loops, windows into `vertices` (may be NULL/0). */
    int32_t loopCount;

    const char *textValue;      /**< TEXT/MTEXT string, or HATCH pattern name (may be NULL). */
    const char *styleName;      /**< TEXT/MTEXT style name (code 7), may be NULL. */
    const char *typeName;       /**< DXF type name (e.g. "INSERT"); set for UNSUPPORTED. */
} LCEntity;

/**
 * A flattened layer-table entry (from DRW_Layer). Strings borrow the owning
 * list's pool. `flags` is the DXF code-70 bitfield (1=frozen, 4=locked).
 */
typedef struct LCLayer {
    const char *name;
    const char *lineType;
    int32_t color;          /**< ACI color index (code 62; sign carries the off/frozen bit in DXF, abs() here). */
    int32_t color24;        /**< true-color 0x00RRGGBB or -1. */
    int32_t lineWeightMM100;/**< lineweight in mm*100; -1 ByLayer, -3 default, etc. */
    int32_t flags;          /**< code 70: bit0 frozen, bit2 locked. */
    int32_t plot;           /**< code 290: 1 printable, 0 not. */
} LCLayer;

/**
 * A flattened block DEFINITION (from DRW_Block + its member entities). The member
 * entities live in a SEPARATE flat array on the owning list (`lc_block_entities`);
 * `memberOffset`/`memberCount` window into it. The name + base point come from the
 * BLOCK record; anonymous/layout blocks (`*Model_Space`, `*Paper_Space`, names
 * starting with `*`) are NOT emitted (they are not user-referenceable blocks).
 */
typedef struct LCBlock {
    const char *name;       /**< block name, code 2 (borrows the list's string pool). */
    double bx, by, bz;      /**< block base point, code 10/20/30. */
    int32_t flags;          /**< block type bit flags, code 70. */
    int32_t memberOffset;   /**< index of the first member in `lc_block_entities`. */
    int32_t memberCount;    /**< number of member entities. */
} LCBlock;

/* ------------------------------------------------------------------------- *
 *  Header variables + dimension styles
 *
 *  The reader captures the small set of HEADER variables and the DIMSTYLE table
 *  entries the renderer needs (dimension text height / arrow size / scale and the
 *  drawing-unit / linear-format vars). Both the DXF (`lc_dxf_read`) and DWG
 *  (`lc_dwg_read`) paths populate them via the shared `FlatteningReader`. Each
 *  numeric field carries an explicit `has*` flag (0 == the file did not supply the
 *  var, so Swift should leave the corresponding graphic-variable at its default).
 * ------------------------------------------------------------------------- */

/**
 * The captured drawing HEADER variables (a flat POD copy of the subset of
 * `DRW_Header.vars` the renderer needs). DXF stores these keys `$`-prefixed
 * ($INSUNITS); the DWG path stores them un-prefixed (INSUNITS) — the reader looks
 * up both. A `has*` flag of 0 means the var was absent (leave the Swift default).
 */
typedef struct LCHeader {
    int32_t insUnits;       /**< $INSUNITS — drawing unit code (DrawingUnit). */
    int32_t hasInsUnits;
    int32_t luUnits;        /**< $LUNITS — linear display format (1..5). */
    int32_t hasLuUnits;
    int32_t luPrec;         /**< $LUPREC — linear precision (decimal places). */
    int32_t hasLuPrec;
    int32_t auUnits;        /**< $AUNITS — angle display format (0..4). */
    int32_t hasAuUnits;
    int32_t auPrec;         /**< $AUPREC — angle precision. */
    int32_t hasAuPrec;
    double dimTxt;          /**< $DIMTXT — dimension text height (world units). */
    int32_t hasDimTxt;
    double dimAsz;          /**< $DIMASZ — dimension arrowhead size (world units). */
    int32_t hasDimAsz;
    double dimScale;        /**< $DIMSCALE — overall dimension scale factor. */
    int32_t hasDimScale;
    int32_t dimLUnit;       /**< $DIMLUNIT — dimension linear format (1..5). */
    int32_t hasDimLUnit;
    int32_t dimDec;         /**< $DIMDEC — dimension linear precision. */
    int32_t hasDimDec;
    double dimExo;          /**< $DIMEXO — extension-line offset (world units). */
    int32_t hasDimExo;
    double dimExe;          /**< $DIMEXE — extension-line extend-beyond (world units). */
    int32_t hasDimExe;
    double dimGap;          /**< $DIMGAP — text gap (world units). */
    int32_t hasDimGap;
    /** The active dimension style name ($DIMSTYLE, code 2). NULL/empty if absent. */
    const char *dimStyle;
} LCHeader;

/**
 * One captured DIMSTYLE table entry (a flat POD copy of the subset of
 * `DRW_Dimstyle` the renderer needs). libdxfrw defaults the imperial standard
 * (`dimtxt = dimasz = 0.18`) and fills these from the file. `name` borrows the
 * owning list's string pool. Populated by both the DXF and DWG read paths.
 */
typedef struct LCDimStyle {
    const char *name;       /**< style name, code 2 (borrows the list's string pool). */
    double dimTxt;          /**< code 140 — text height (world units). */
    double dimAsz;          /**< code 41 — arrowhead size (world units). */
    double dimScale;        /**< code 40 — overall scale factor. */
    int32_t dimDec;         /**< code 271 — linear precision (decimal places). */
    int32_t dimLUnit;       /**< code 277 — linear format (1..5). */
    double dimExo;          /**< code 42 — extension-line offset (world units). */
    double dimExe;          /**< code 44 — extension-line extend-beyond (world units). */
    double dimGap;          /**< code 147 — text gap (world units). */
} LCDimStyle;

/* ------------------------------------------------------------------------- *
 *  Reconstructed paper-space LAYOUT (paper-space P1)
 *
 *  libdxfrw's DXF reader does NOT parse the ACAD_LAYOUT dictionary (its
 *  processObjects handles only IMAGEDEF + PLOTSETTINGS), so the named LAYOUT
 *  table — tab name, tab order, the paper-size selection — is not available.
 *  We therefore RECONSTRUCT a SINGLE layout when a drawing has paper-space
 *  content: the reader emits one LCLayout whenever it sees either a non-empty
 *  `*Paper_Space` block OR a PLOTSETTINGS object. Its page geometry comes from
 *  PLOTSETTINGS where present (margins; codes 40–43), defaulting otherwise.
 *
 *  KNOWN LOSS (single-layout, stock libdxfrw): the user-facing tab name + order
 *  are NOT recoverable, so the reconstructed layout is always named "Layout1".
 *  Stock libdxfrw's DRW_PlotSettings parses ONLY the margins + plot-view name —
 *  NOT the paper width/height — so `widthMM`/`heightMM` are 0 (== "use the
 *  engine default sheet size") unless a future libdxfrw patch supplies them.
 *  Multi-layout read + true tab names require the libdxfrw LAYOUT-dict patch
 *  (the documented follow-up).
 * ------------------------------------------------------------------------- */

/**
 * One reconstructed paper-space layout (see the section comment above). Strings
 * borrow the owning list's pool; lifetime is tied to the LCEntityList.
 */
typedef struct LCLayout {
    const char *name;       /**< layout / tab name. Always "Layout1" on stock
                                 libdxfrw (the LAYOUT dict is not parsed). */
    double widthMM;         /**< paper width  (mm); 0 == use the engine default. */
    double heightMM;        /**< paper height (mm); 0 == use the engine default. */
    double marginMM;        /**< uniform page margin (mm) — the max of the
                                 PLOTSETTINGS margins (codes 40–43); 0 if none. */
    int32_t tabOrder;       /**< left-to-right tab position (0-based); always 0. */
} LCLayout;

/** Opaque owned result handle. Free with `lc_entity_list_free`. */
typedef struct LCEntityList LCEntityList;

/**
 * Read a DXF file and flatten every supported geometric entity, the layer
 * table, and the warning list into an owned handle.
 *
 * Pure C ABI: the whole libdxfrw graph is flattened in-callback into POD copies,
 * so Swift never touches a C++ type. The body is wrapped in try/catch — no
 * exception ever crosses this boundary.
 *
 * libdxfrw is non-reentrant; callers MUST serialize through the single shared
 * engine actor (see CADEngine).
 *
 * @param path  UTF-8 filesystem path to a DXF file.
 * @param out   On LC_OK, receives a newly-allocated handle the caller owns and
 *              must free with `lc_entity_list_free`. Untouched on error.
 * @return LC_OK on success; LC_ERR_INVALID_PATH for a null/empty path or null
 *         out; LC_ERR_READ_FAILED if libdxfrw fails to read (also covers any
 *         exception escaping the parse).
 */
LCStatus lc_dxf_read(const char *path, LCEntityList **out);

/**
 * Read a DWG file (AutoCAD binary drawing) and flatten it into the SAME owned
 * `LCEntityList` handle the DXF reader produces — every supported entity kind,
 * the layer table, and the block definitions flow through the identical
 * `FlatteningReader` (a `DRW_Interface` subclass), so Swift consumes one model
 * regardless of source format. DWG is binary (not text), so it gets its own
 * entry point rather than auto-detection inside `lc_dxf_read`; libdxfrw routes
 * DXF through `dxfRW` and DWG through `dwgRW`, two different parsers.
 *
 * libdxfrw supports reading DWG versions R2000 (AC1015) and newer; an older or
 * corrupt file fails the read (LC_ERR_READ_FAILED). The result handle is freed
 * with `lc_entity_list_free`, exactly like the DXF reader's.
 *
 * libdxfrw is non-reentrant; callers MUST serialize through the single shared
 * engine actor (see CADEngine), exactly as for `lc_dxf_read`.
 *
 * @param path  UTF-8 filesystem path to a DWG file.
 * @param out   On LC_OK, receives a newly-allocated handle the caller owns and
 *              must free with `lc_entity_list_free`. Untouched on error.
 * @return LC_OK on success; LC_ERR_INVALID_PATH for a null/empty path or null
 *         out; LC_ERR_READ_FAILED if libdxfrw fails to read (also covers any
 *         exception escaping the parse, and unsupported/old DWG versions).
 */
LCStatus lc_dwg_read(const char *path, LCEntityList **out);

/** Number of flattened entities in the list (>= 0). NULL-safe (returns 0). */
int lc_entity_list_count(const LCEntityList *list);

/**
 * Pointer to the contiguous flat array of `lc_entity_list_count` entities, or
 * NULL if empty. The pointer (and every string / vertex / array it references)
 * stays valid until `lc_entity_list_free`.
 */
const LCEntity *lc_entity_list_entities(const LCEntityList *list);

/** Number of geometric entities libdxfrw delivered (supported + unsupported).
 *  This matches the old `lc_dxf_count_entities` semantics. NULL-safe. */
int lc_entity_list_geometry_count(const LCEntityList *list);

/** Number of layers in the flattened layer table (>= 0). NULL-safe. */
int lc_layer_count(const LCEntityList *list);

/** Pointer to the contiguous flat array of `lc_layer_count` layers, or NULL. */
const LCLayer *lc_layers(const LCEntityList *list);

/** Number of block DEFINITIONS the reader collected (>= 0). NULL-safe. Anonymous
 *  / layout blocks (`*`-prefixed names) are excluded. */
int lc_block_count(const LCEntityList *list);

/** Pointer to the contiguous flat array of `lc_block_count` blocks, or NULL. The
 *  pointer (and the member window each block references) stays valid until
 *  `lc_entity_list_free`. */
const LCBlock *lc_blocks(const LCEntityList *list);

/** Number of block-MEMBER entities across all blocks (>= 0). NULL-safe. Each
 *  block's members are the window `[memberOffset, memberOffset+memberCount)` into
 *  this array. */
int lc_block_entity_count(const LCEntityList *list);

/** Pointer to the contiguous flat array of `lc_block_entity_count` block-member
 *  entities, or NULL. Same lifetime as the top-level entity array. */
const LCEntity *lc_block_entities(const LCEntityList *list);

/** Pointer to the captured drawing HEADER variables, or NULL if the list is NULL.
 *  Always non-NULL for a successfully-read file (the struct's `has*` flags say which
 *  vars the file actually supplied). The pointer (and `dimStyle`) stays valid until
 *  `lc_entity_list_free`. NULL-safe. */
const LCHeader *lc_header(const LCEntityList *list);

/** Number of captured DIMSTYLE table entries (>= 0). NULL-safe. */
int lc_dimstyle_count(const LCEntityList *list);

/** Pointer to the contiguous flat array of `lc_dimstyle_count` dimension styles,
 *  or NULL. The pointer (and each style's `name`) stays valid until
 *  `lc_entity_list_free`. NULL-safe. */
const LCDimStyle *lc_dimstyles(const LCEntityList *list);

/** Number of RECONSTRUCTED paper-space layouts (paper-space P1). 0 for a model-
 *  space-only drawing; 1 when the file carries paper-space content (a non-empty
 *  `*Paper_Space` block or a PLOTSETTINGS object). Never > 1 on stock libdxfrw
 *  (the LAYOUT dictionary is not parsed — see `LCLayout`). NULL-safe. */
int lc_layout_count(const LCEntityList *list);

/** Pointer to the contiguous flat array of `lc_layout_count` layouts, or NULL.
 *  The pointer (and each layout's `name`) stays valid until
 *  `lc_entity_list_free`. NULL-safe. */
const LCLayout *lc_layouts(const LCEntityList *list);

/** Frees a handle returned by `lc_dxf_read`. NULL-safe. */
void lc_entity_list_free(LCEntityList *list);

/**
 * Map an AutoCAD Color Index (1..255) to a packed 0x00RRGGBB true color using
 * libdxfrw's standard ACI palette (`DRW::dxfColors`). Returns -1 for the
 * sentinels (0 == ByBlock, 256 == ByLayer) and for any out-of-range index, so
 * callers treat those as "inherit". ACI 7 maps to black in the palette.
 */
int32_t lc_aci_to_rgb(int32_t aci);

/**
 * Count the geometric entities in a DXF file. Reimplemented atop the reader:
 * counts every entity libdxfrw delivers (supported + unsupported), matching the
 * historical counting-reader semantics. Kept for the existing count tests.
 *
 * @param path       UTF-8 filesystem path to a DXF file.
 * @param out_count  On LC_OK, receives the entity count (>= 0). May be NULL.
 * @return LC_OK / LC_ERR_INVALID_PATH / LC_ERR_READ_FAILED.
 */
LCStatus lc_dxf_count_entities(const char *path, int *out_count);

/* ------------------------------------------------------------------------- *
 *  Writer (CADDrawing -> .dxf)
 *
 *  The inverse of the reader: Swift builds flat POD arrays (the same LCEntity /
 *  LCVertex / LCLayer structs the reader hands back) and this writes them to a
 *  DXF file via libdxfrw's write path. A DRW_Interface subclass emits the PODs
 *  through libdxfrw's write* callbacks (writeLine/writeCircle/...). The whole
 *  body is wrapped in try/catch — no exception crosses the C boundary.
 *
 *  libdxfrw is non-reentrant; callers MUST serialize through the single shared
 *  engine actor (see CADEngine), exactly as for the reader.
 * ------------------------------------------------------------------------- */

/**
 * Write a DXF file from flat POD entity + layer arrays.
 *
 * Supported `LCEntity::kind` values are emitted: LINE, POINT, CIRCLE, ARC,
 * ELLIPSE, LWPOLYLINE, POLYLINE, SPLINE, TEXT, MTEXT, SOLID, HATCH, DIMENSION.
 * Any other kind (UNSUPPORTED, ...) is silently skipped and counted in
 * `*out_skipped`. (MTEXT, DIMENSION and SPLINE only exist for R2000+; at R12
 * they are dropped and counted as skipped.)
 * Common attributes
 * (layer/linetype/color/color24/lineweight) map onto the DRW_* fields, mirroring
 * the reader's POD mapping in reverse.
 *
 * @param path          UTF-8 filesystem path to write. Overwritten if it exists.
 * @param entities      Pointer to `entityCount` LCEntity PODs (may be NULL iff
 *                      entityCount == 0).
 * @param entityCount   Number of entities (>= 0).
 * @param layers        Pointer to `layerCount` LCLayer PODs (may be NULL iff
 *                      layerCount == 0). Layer "0" is always emitted; if it is
 *                      absent from this array a default one is synthesized.
 * @param layerCount    Number of layers (>= 0).
 * @param version       An LCDxfVersion. Out-of-range falls back to R2000.
 * @param blocks        Pointer to `blockCount` LCBlock block definitions, each
 *                      windowing into `blockEntities` (may be NULL iff
 *                      blockCount == 0). Emitted in the BLOCKS section so an
 *                      INSERT entity resolves to real geometry on re-read.
 * @param blockCount    Number of block definitions (>= 0).
 * @param blockEntities Pointer to `blockEntityCount` LCEntity block-member PODs
 *                      (may be NULL iff blockEntityCount == 0).
 * @param blockEntityCount Number of block-member entities (>= 0).
 * @param out_skipped   If non-NULL, receives the count of entities whose kind is
 *                      not yet supported by the writer (skipped). 0 on error.
 * @param header        Optional pointer to the drawing HEADER variables to emit
 *                      ($INSUNITS/$LUNITS/... + the $DIM* dimension defaults incl.
 *                      $DIMEXO/$DIMEXE/$DIMGAP). Only fields whose `has*` flag is
 *                      set are written; NULL ⇒ libdxfrw's default header is kept.
 * @param dimStyles     Optional pointer to `dimStyleCount` LCDimStyle PODs to emit
 *                      as the DIMSTYLE table (so named styles + their ext-line
 *                      offsets round-trip). NULL / 0 ⇒ only the default "Standard"
 *                      style libdxfrw always writes.
 * @param dimStyleCount Number of dimension styles (>= 0).
 * @return LC_OK on success; LC_ERR_INVALID_PATH for a null/empty path or a
 *         negative count with a NULL array; LC_ERR_WRITE_FAILED if libdxfrw
 *         fails to write (also covers any exception escaping the export).
 */
LCStatus lc_dxf_write(const char *path,
                      const LCEntity *entities, int entityCount,
                      const LCLayer *layers, int layerCount,
                      const LCBlock *blocks, int blockCount,
                      const LCEntity *blockEntities, int blockEntityCount,
                      int version,
                      int *out_skipped,
                      const LCHeader *header,
                      const LCDimStyle *dimStyles, int dimStyleCount);

/**
 * Write a DWG file from flat POD entity + layer arrays. The DWG counterpart of
 * `lc_dxf_write`, with the SAME POD inputs so the Swift writer reuses its entire
 * POD-build path. Internally drives libdxfrw's `dwgRW` (its `dwgWriter15`)
 * through the same `WritingInterface` (a `DRW_Interface` subclass); each
 * supported entity is encoded into the DWG object stream.
 *
 * Format scope (the honest state of libdxfrw's DWG writer in THIS repo):
 *  - DWG WRITE supports ONLY version R2000 (AC1015). The `version` argument is
 *    ACCEPTED for ABI symmetry with `lc_dxf_write` but is forced to R2000 (any
 *    other value is overridden); libdxfrw's `dwgRW::write` rejects non-AC1015.
 *  - Top-level entities of every kind `lc_dxf_write` supports are emitted
 *    (LINE/POINT/CIRCLE/ARC/ELLIPSE/LWPOLYLINE/POLYLINE/SPLINE/TEXT/MTEXT/
 *    SOLID/HATCH/DIMENSION/INSERT). Unsupported kinds are skipped + counted in
 *    `*out_skipped`, exactly as for DXF.
 *  - BLOCK definitions are emitted as EMPTY user blocks (libdxfrw's
 *    `dwgWriter15::defineBlock` allocates an empty block_record — it has no path
 *    to write a user block's MEMBER geometry yet). An INSERT that references a
 *    block by name therefore resolves to an empty block on re-read. The block
 *    MEMBER entities passed in `blockEntities` are NOT written to DWG (they ARE
 *    written for DXF). This is the one round-trip gap vs DXF; surface it.
 *
 * The whole body is wrapped in try/catch — no exception crosses the C boundary.
 * libdxfrw is non-reentrant; callers MUST serialize through the single shared
 * engine actor (see CADEngine), exactly as for `lc_dxf_write`.
 *
 * @param path          UTF-8 filesystem path to write. Overwritten if it exists.
 * @param entities      Pointer to `entityCount` LCEntity PODs (may be NULL iff 0).
 * @param entityCount   Number of entities (>= 0).
 * @param layers        Pointer to `layerCount` LCLayer PODs (may be NULL iff 0).
 * @param layerCount    Number of layers (>= 0).
 * @param blocks        Pointer to `blockCount` LCBlock definitions (may be NULL
 *                      iff 0). Emitted as empty user blocks (see above) so an
 *                      INSERT's block name resolves on re-read.
 * @param blockCount    Number of block definitions (>= 0).
 * @param blockEntities Pointer to `blockEntityCount` LCEntity block-member PODs
 *                      (may be NULL iff 0). Accepted for ABI symmetry but NOT
 *                      written for DWG (the writer makes empty blocks).
 * @param blockEntityCount Number of block-member entities (>= 0).
 * @param version       An LCDxfVersion. IGNORED — DWG write is R2000-only.
 * @param out_skipped   If non-NULL, receives the count of entities whose kind is
 *                      not supported by the writer (skipped). 0 on error.
 * @param header        Optional pointer to the drawing HEADER variables to emit
 *                      (see `lc_dxf_write`). NULL ⇒ libdxfrw's default header.
 * @param dimStyles     Optional pointer to `dimStyleCount` LCDimStyle PODs. NOTE:
 *                      libdxfrw's DWG writer (dwgWriter15) emits the standard
 *                      DIMSTYLE table internally and exposes no per-style write
 *                      path, so these are accepted for ABI symmetry but NOT
 *                      written to DWG (the documented DWG table gap, like layers).
 *                      The header `$DIM*` vars ARE applied where the DWG writer
 *                      honors them.
 * @param dimStyleCount Number of dimension styles (>= 0).
 * @return LC_OK on success; LC_ERR_INVALID_PATH for a null/empty path or a
 *         negative count with a NULL array; LC_ERR_WRITE_FAILED if libdxfrw
 *         fails to write (also covers any exception escaping the export).
 */
LCStatus lc_dwg_write(const char *path,
                      const LCEntity *entities, int entityCount,
                      const LCLayer *layers, int layerCount,
                      const LCBlock *blocks, int blockCount,
                      const LCEntity *blockEntities, int blockEntityCount,
                      int version,
                      int *out_skipped,
                      const LCHeader *header,
                      const LCDimStyle *dimStyles, int dimStyleCount);

#ifdef __cplusplus
}
#endif

#endif /* LCDXF_H */
