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
    /** An entity libdxfrw delivered but the reader does not flatten
     *  (INSERT/IMAGE/ordinate-DIMENSION/...). Carries only its `typeName` so Swift
     *  can collect a warning; geometry fields are unset. */
    LC_ENT_UNSUPPORTED = 100
} LCEntityKind;

/** Discriminator for `LCEntity::dimType` (which DRW_Dim* subtype). The values
 *  mirror the DXF type-70 low-nibble codes libdxfrw dispatches on
 *  (processDimension: `dim.type & 0x0F`). ORDINATE is not in the frozen DimKind
 *  model, so the reader maps it to LC_ENT_UNSUPPORTED rather than this enum. */
typedef enum LCDimType {
    LC_DIM_LINEAR    = 0,   /**< DRW_DimLinear  — def1/def2 (codes 13/14) + dimAngle (50). */
    LC_DIM_ALIGNED   = 1,   /**< DRW_DimAligned — def1/def2 (codes 13/14). */
    LC_DIM_ANGULAR   = 2,   /**< DRW_DimAngular (2-line) — def1/def2/def5 + defPoint + arc (16). */
    LC_DIM_DIAMETRIC = 3,   /**< DRW_DimDiametric — def5 (code 15) + defPoint (code 10). */
    LC_DIM_RADIAL    = 4     /**< DRW_DimRadial — defPoint (center, 10) + def5 (radius point, 15). */
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
 *                 closed
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

    /* Text (TEXT / MTEXT). */
    double height;         /**< text cap height (code 40). */
    int32_t hAlign;        /**< text horizontal align (code 72): 0 left, 1 center, 2 right. */
    int32_t vAlign;        /**< text vertical align (code 73): 0 baseline, 1 bottom, 2 middle, 3 top. */
    int32_t solidFill;     /**< HATCH solid-fill flag (0 pattern, 1 solid). */

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
 * ELLIPSE, LWPOLYLINE, POLYLINE, TEXT, MTEXT, SOLID, HATCH, DIMENSION. Any other
 * kind (SPLINE, UNSUPPORTED, ...) is silently skipped and counted in
 * `*out_skipped`. (MTEXT and DIMENSION only exist for R2000+; at R12 they are
 * dropped and counted as skipped.)
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
 * @param out_skipped   If non-NULL, receives the count of entities whose kind is
 *                      not yet supported by the writer (skipped). 0 on error.
 * @return LC_OK on success; LC_ERR_INVALID_PATH for a null/empty path or a
 *         negative count with a NULL array; LC_ERR_WRITE_FAILED if libdxfrw
 *         fails to write (also covers any exception escaping the export).
 */
LCStatus lc_dxf_write(const char *path,
                      const LCEntity *entities, int entityCount,
                      const LCLayer *layers, int layerCount,
                      int version,
                      int *out_skipped);

#ifdef __cplusplus
}
#endif

#endif /* LCDXF_H */
