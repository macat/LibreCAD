/******************************************************************************
**  LibreCAD macOS — DXF bridge implementation (C ABI over libdxfrw)         **
**                                                                           **
**  Derivative work of LibreCAD and libdxfrw, both GPLv2-or-later. The       **
**  DRW_Interface override list mirrors libdxfrw's drw_interface.h and       **
**  LibreCAD's rs_filterdxfrw.h (Qt/RS_* bodies stripped); the callback ->   **
**  data mapping (arc/ellipse/polyline/spline fields, layer flags, ACI       **
**  colors) is ported from rs_filterdxfrw.cpp.                               **
**                                                                           **
**  Copyright (C) 2026 LibreCAD macOS contributors.                          **
**  Copyright (C) 2001-2003 RibbonSoft; (C) 2011-2015 José F. Soriano.       **
**                                                                           **
**  This program is free software; you can redistribute it and/or modify     **
**  it under the terms of the GNU General Public License as published by     **
**  the Free Software Foundation; either version 2 of the License, or        **
**  (at your option) any later version.                                      **
******************************************************************************/

#include "lcdxf.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <exception>
#include <string>
#include <vector>

#include "libdxfrw.h"
#include "libdwgr.h"       // dwgRW: the DWG (binary AutoCAD) read/write path
#include "drw_interface.h"
#include "drw_objects.h"   // DRW::dxfColors[][3]

#include <map>             // DWG block name -> block_record handle (INSERT resolve)

/**
 * The owned result handle. Holds the flat POD arrays handed to Swift plus the
 * backing pools that keep their borrowed pointers alive:
 *
 *  - `strings`: a std::deque<std::string> (NOT a vector) so element addresses
 *    are stable across growth — every `const char*` in `entities`/`layers`
 *    points into one of these.
 *  - `vertexPool` / `doublePool`: std::deque of vectors, same stability
 *    rationale, so each entity's `vertices`/`knots`/`weights` pointer stays
 *    valid for the handle's whole lifetime.
 *
 * Everything is freed together by `lc_entity_list_free`.
 */
struct LCEntityList {
    std::vector<LCEntity> entities;
    std::vector<LCLayer>  layers;
    int geometryCount = 0;   // every add* entity libdxfrw delivered

    // Block DEFINITIONS + the flat array of their member entities. A block's
    // members are the window [memberOffset, memberOffset+memberCount) into
    // `blockEntities`. Built incrementally during read (members collected per
    // block) and flattened contiguous in `finalizeBlocks()` before Swift sees them.
    std::vector<LCBlock>  blocks;
    std::vector<LCEntity> blockEntities;

    // Captured HEADER variables (zero-initialized: every `has*` flag starts 0, so
    // an unread file leaves Swift's graphic-variable defaults untouched) + the
    // captured DIMSTYLE table. Both are filled by the FlatteningReader's
    // addHeader / addDimStyle hooks; both DXF and DWG drive those hooks.
    LCHeader header{};
    std::vector<LCDimStyle> dimStyles;

    // R4b: generic extra HEADER vars (the document-settings vars NOT mapped into the
    // fixed `LCHeader` POD — $GRIDUNIT/$PDMODE/$PDSIZE/$ANGBASE/$ANGDIR/$PINSBASE,
    // etc.). Filled by the FlatteningReader's addHeader hook from DRW_Header.vars;
    // each record's `name` borrows the `strings` pool (stable for the handle's life).
    std::vector<LCHeaderVar> headerVars;

    // RECONSTRUCTED paper-space layouts (paper-space P1). Built by the reader's
    // `finalizeLayouts()` from observed paper-space content (`*Paper_Space` block
    // members and/or a PLOTSETTINGS object). At most one entry on stock libdxfrw
    // (the LAYOUT dictionary is not parsed — see LCLayout).
    std::vector<LCLayout> layouts;

    // Paper-space VIEWPORT entities (paper-space P3). Collected by the reader's
    // addViewport hook for REAL viewports (vpID>1) only — the AutoCAD overview
    // viewport (vpID<=1) is skipped as UNSUPPORTED. Kept in a SEPARATE list (not
    // `entities`) so the Swift reader's per-entity EntityKind mapping is untouched.
    std::vector<LCViewport> viewports;

    // Stable-address backing pools (deque: pointers survive growth).
    std::deque<std::string>          strings;
    std::deque<std::vector<LCVertex>> vertexPool;
    std::deque<std::vector<double>>  doublePool;
    std::deque<std::vector<LCLoop>>  loopPool;
    // Block ATTRIB / ATTDEF flat arrays (one vector per owning INSERT / block).
    // Each LCEntity.attribs / LCBlock.attribDefs borrows a pointer into one of
    // these; the deque keeps those pointers stable for the handle's lifetime.
    std::deque<std::vector<LCAttrib>> attribPool;
};

namespace {

/**
 * FlatteningReader implements every DRW_Interface pure-virtual. The geometric
 * add* callbacks flatten their payload into POD copies on `out`; tables collect
 * the layer list; header/blocks/comments and every write* hook (never called on
 * read) are no-ops. The DRW_Interface override list is the checklist
 * (drw_interface.h + rs_filterdxfrw.h).
 */
class FlatteningReader final : public DRW_Interface {
public:
    explicit FlatteningReader(LCEntityList *out) : m_out(out) {}

    // One collected block definition (name/base/flags + its member PODs). Members
    // are gathered here while inside the block; `finalizeBlocks()` flattens every
    // block's members into the list's contiguous `blockEntities` array afterward.
    struct PendingBlock {
        std::string name;
        double bx = 0, by = 0, bz = 0;
        int flags = 0;
        std::vector<LCEntity> members;
        bool anonymous = false;   // *-prefixed (model/paper space, *U…) — not emitted
        // Paper-space P1: a `*Paper_Space`/`*Paper_Space<n>` layout block. Its
        // members are paper-space entities for the reconstructed layout (NOT the
        // auto-generated graphic of a dimension/hatch, which live in `*D…`/`*U…`
        // blocks). Members are routed to the TOP-LEVEL entity list (like model
        // space) but tagged spaceFlag = 1 + layoutName, so they become paper-space
        // EntityRecords. `paperLayoutName` is the reconstructed layout name.
        bool paperSpace = false;
        std::string paperLayoutName;
        // Block ATTDEF templates (delivered via addAttdef while this block is open).
        // Flattened into the block's `attribDefs` window at finalizeBlocks().
        std::vector<LCAttrib> attdefs;
    };

    // A captured IMAGE entity awaiting its IMAGEDEF link (the entity arrives in the
    // ENTITIES section; the IMAGEDEF — with the path + pixel size — arrives later in
    // OBJECTS). `defHandle` is the IMAGE's code-340 hard reference; the geometry +
    // display fields are captured verbatim. `target` records whether the IMAGE was
    // read inside a block (so finalize routes it to the same target pushEntity would).
    struct PendingImage {
        LCEntity e;
        duint32 defHandle = 0;
        PendingBlock *block = nullptr;   // the block being read, or nullptr (top level)
    };
    // One captured IMAGEDEF (file path + pixel size) keyed by its code-5 handle.
    struct ImageDefRecord {
        std::string path;
        double u = 0;
        double v = 0;
    };

    // After the whole read, link each captured IMAGE to its IMAGEDEF (path + pixel
    // size) by the code-340 handle, then push the finished POD into its target (the
    // block it was read in, or the top-level entity list). A missing/unknown
    // IMAGEDEF still yields a valid `.image` (empty path → placeholder on render),
    // so an IMAGE never silently vanishes. Call BEFORE finalizeBlocks so any
    // block-embedded IMAGE is linked and pushed into its block's members here,
    // before finalizeBlocks() flattens those members.
    void finalizeImages() {
        for (auto &pi : m_pendingImages) {
            LCEntity e = pi.e;
            auto it = m_imageDefs.find(pi.defHandle);
            if (it != m_imageDefs.end()) {
                e.textValue = intern(it->second.path);
                e.imgSizeU = it->second.u;
                e.imgSizeV = it->second.v;
            }
            // A robust fallback: if the IMAGEDEF gave no pixel size, fall back to the
            // IMAGE entity's own sizeu/sizev (DXF codes 13/23), which carry the pixel
            // dimensions on the entity too.
            if (e.imgSizeU <= 0 && pi.e.imgSizeU > 0) e.imgSizeU = pi.e.imgSizeU;
            if (e.imgSizeV <= 0 && pi.e.imgSizeV > 0) e.imgSizeV = pi.e.imgSizeV;
            if (e.textValue == nullptr) e.textValue = intern("");
            if (pi.block != nullptr) pi.block->members.push_back(e);
            else m_out->entities.push_back(e);
        }
    }

    // After the whole read, RECONSTRUCT a single paper-space layout when the file
    // carried any paper-space content (a non-empty `*Paper_Space` block, a top-level
    // entity with code 67 == 1, or a PLOTSETTINGS object). Stock libdxfrw does not
    // parse the LAYOUT dictionary, so we cannot recover the real tab name/order/paper
    // size — we emit ONE layout named "Layout1" with the PLOTSETTINGS margin (paper
    // size left 0 == engine default). Call AFTER finalizeImages (so block-embedded
    // paper images are counted) — the read entry points order it so. Multi-layout +
    // true names are the documented libdxfrw-patch follow-up.
    void finalizeLayouts() {
        if (!m_sawPaperContent && !m_sawPlotSettings) return;   // model-space-only: no layout
        LCLayout l{};
        l.name = intern(std::string(kReconstructedLayoutName));
        l.widthMM = 0.0;        // 0 == use the engine default sheet size (stock
        l.heightMM = 0.0;       //      libdxfrw does not parse plot paper size)
        l.marginMM = (m_plotMarginMM > 0.0) ? m_plotMarginMM : 0.0;
        l.tabOrder = 0;
        m_out->layouts.push_back(l);
    }

    // After the whole read, flatten the (non-anonymous, non-empty) pending blocks
    // into `m_out->blocks` + `m_out->blockEntities` with correct member windows.
    void finalizeBlocks() {
        for (auto &pb : m_pendingBlocks) {
            if (pb.anonymous) continue;
            LCBlock b{};
            b.name = intern(pb.name);
            b.bx = pb.bx; b.by = pb.by; b.bz = pb.bz;
            b.flags = pb.flags;
            b.memberOffset = static_cast<int32_t>(m_out->blockEntities.size());
            b.memberCount = static_cast<int32_t>(pb.members.size());
            for (auto &m : pb.members) m_out->blockEntities.push_back(m);
            // Flatten the block's ATTDEF templates into the stable attribute pool.
            b.attribDefs = nullptr;
            b.attribDefCount = 0;
            if (!pb.attdefs.empty()) {
                m_out->attribPool.push_back(pb.attdefs);
                b.attribDefs = m_out->attribPool.back().data();
                b.attribDefCount = static_cast<int32_t>(m_out->attribPool.back().size());
            }
            m_out->blocks.push_back(b);
        }
    }

    // ----- string / array pooling ----------------------------------------
    const char *intern(const std::string &s) {
        m_out->strings.push_back(s);
        return m_out->strings.back().c_str();
    }
    const char *intern(const char *s) {
        return intern(std::string(s ? s : ""));
    }

    // Paper-space P1: the single reconstructed layout's name (the LAYOUT dictionary
    // is not parsed by stock libdxfrw, so the real tab name is unknown — see
    // LCLayout). Matches the engine's `Layout(name: "Layout1")` default.
    static constexpr const char *kReconstructedLayoutName = "Layout1";

    // Whether a block name denotes a paper-space LAYOUT block: `*Paper_Space`,
    // `*Paper_Space0`, `*Paper_Space<n>` (case-insensitive prefix). NOT a model-
    // space block and NOT a `*D…`/`*U…` dimension/hatch graphic block.
    static bool isPaperSpaceBlock(const std::string &name) {
        const std::string prefix = "*PAPER_SPACE";
        if (name.size() < prefix.size()) return false;
        for (std::size_t i = 0; i < prefix.size(); ++i) {
            if (std::toupper(static_cast<unsigned char>(name[i])) != prefix[i]) return false;
        }
        return true;
    }

    // Push a flattened entity into the CURRENT target (paper-space P1):
    //  - inside a `*Paper_Space` LAYOUT block: route the member to the TOP-LEVEL
    //    entity list (like model space) but tag it as paper space + stamp the
    //    reconstructed layout name, so it becomes a paper-space EntityRecord. Note
    //    we observed paper content, so a layout will be reconstructed at finalize.
    //  - inside any other (named user) block: collect into that block's members.
    //  - at the top level: push to the top-level entity list.
    // The pooled pointers an entity borrows (vertices/strings) live on `m_out`
    // regardless of which vector holds the POD, so this is a plain copy either way.
    void pushEntity(const LCEntity &e) {
        if (m_currentBlock != nullptr && m_currentBlock->paperSpace) {
            LCEntity paper = e;
            paper.spaceFlag = 1;
            paper.layoutName = intern(m_currentBlock->paperLayoutName);
            m_sawPaperContent = true;
            m_out->entities.push_back(paper);
        } else if (m_currentBlock != nullptr) {
            m_currentBlock->members.push_back(e);
        } else {
            // A top-level ENTITIES-section entity carrying code 67 == 1 is paper
            // space too (the form libdxfrw's own writer emits); note it so a layout
            // is reconstructed. fillCommon already set spaceFlag from code 67.
            if (e.spaceFlag == 1) m_sawPaperContent = true;
            m_out->entities.push_back(e);
        }
    }

    // Fill the common (layer/linetype/color/lineweight/space) attributes from any
    // DRW_Entity. Ported from rs_filterdxfrw.cpp setEntityAttributes.
    //
    // Paper-space P1: copy DRW_Entity::space (libdxfrw parses it from DXF code 67)
    // into spaceFlag (0 model / 1 paper). This handles entities in the ENTITIES
    // section that carry code 67 == 1 (the form libdxfrw's OWN writer emits). An
    // entity read INSIDE a `*Paper_Space` block — where AutoCAD marks the space by
    // the block, not code 67 — is tagged paper by pushEntity (block context wins),
    // which also stamps the layout name.
    void fillCommon(LCEntity &e, const DRW_Entity &src) {
        e.layer = intern(src.layer);
        e.lineType = intern(src.lineType);
        e.color = src.color;
        e.color24 = src.color24;
        e.lineWeightMM100 = DRW_LW_Conv::lineWidth2dxfInt(src.lWeight);
        e.spaceFlag = (src.space == DRW::PaperSpace) ? 1 : 0;
        e.layoutName = nullptr;
    }

    // Allocate a fresh entity slot with defaulted geometry fields.
    LCEntity makeEntity(int kind) {
        LCEntity e{};
        e.kind = kind;
        e.layer = nullptr;
        e.lineType = nullptr;
        e.color = DRW::ColorByLayer;
        e.color24 = -1;
        e.lineWeightMM100 = -1;
        e.spaceFlag = 0;          // model space by default (DXF code 67 == 0)
        e.layoutName = nullptr;   // bound only for paper-space block members
        e.ratio = 1.0;
        e.degree = 0;
        e.closed = 0;
        e.splineFlags = 0;
        e.fitPoints = nullptr;
        e.fitPointCount = 0;
        e.height = 0.0;
        e.hAlign = 0;
        e.vAlign = 0;
        e.solidFill = 0;
        e.hatchScale = 1.0;
        e.hatchAngle = 0.0;
        e.mtextRectWidth = 0.0;
        e.mtextAttachment = 1;            // TopLeft default
        e.mtextLineSpacingStyle = 1;      // at-least
        e.mtextLineSpacingFactor = 1.0;
        e.dimType = LC_DIM_LINEAR;
        e.dimDef1x = e.dimDef1y = e.dimDef1z = 0.0;
        e.dimDef2x = e.dimDef2y = e.dimDef2z = 0.0;
        e.dimDef5x = e.dimDef5y = e.dimDef5z = 0.0;
        e.dimArcx  = e.dimArcy  = e.dimArcz  = 0.0;
        e.dimTextx = e.dimTexty = e.dimTextz = 0.0;
        e.dimHasText = 0;
        e.dimAngle = 0.0;
        e.dimOblique = 0.0;
        e.dimTextRotation = 0.0;
        e.dimHasTextRotation = 0;
        e.dimAlign = 5;                   // middle-center default (DRW_Dimension)
        e.dimLineStyle = 1;              // at-least
        e.dimLineFactor = 1.0;
        e.dimTextHeightOverride = 0.0;
        e.dimHasTextHeightOverride = 0;
        e.dimArrowSizeOverride = 0.0;
        e.dimHasArrowSizeOverride = 0;
        e.insScaleX = 1.0;
        e.insScaleY = 1.0;
        e.insScaleZ = 1.0;
        e.insRows = 1;
        e.insCols = 1;
        e.insRowSpacing = 0.0;
        e.insColSpacing = 0.0;
        e.attribs = nullptr;
        e.attribCount = 0;
        e.vertices = nullptr;
        e.vertexCount = 0;
        e.knots = nullptr;
        e.knotCount = 0;
        e.weights = nullptr;
        e.weightCount = 0;
        e.loops = nullptr;
        e.loopCount = 0;
        e.textValue = nullptr;
        e.styleName = nullptr;
        e.typeName = nullptr;
        return e;
    }

    // ----- header / tables -----------------------------------------------
    // Capture the small set of HEADER variables the renderer needs (dimension
    // text/arrow/scale + the unit/linear-format vars). The DXF reader keys
    // DRW_Header.vars with the `$`-prefixed name ($DIMTXT); the DWG reader keys
    // them un-prefixed (DIMTXT) — so every lookup tries both spellings. A missing
    // key leaves the matching `has*` flag at 0 (POD is zero-initialized), and Swift
    // keeps its built-in default for that graphic variable.
    void addHeader(const DRW_Header *data) override {
        if (data == nullptr) return;
        LCHeader &h = m_out->header;
        getHdrInt(*data, "INSUNITS", h.insUnits, h.hasInsUnits);
        getHdrInt(*data, "LUNITS",   h.luUnits,  h.hasLuUnits);
        getHdrInt(*data, "LUPREC",   h.luPrec,   h.hasLuPrec);
        getHdrInt(*data, "AUNITS",   h.auUnits,  h.hasAuUnits);
        getHdrInt(*data, "AUPREC",   h.auPrec,   h.hasAuPrec);
        getHdrDouble(*data, "DIMTXT",   h.dimTxt,   h.hasDimTxt);
        getHdrDouble(*data, "DIMASZ",   h.dimAsz,   h.hasDimAsz);
        getHdrDouble(*data, "DIMSCALE", h.dimScale, h.hasDimScale);
        getHdrInt(*data, "DIMLUNIT", h.dimLUnit, h.hasDimLUnit);
        getHdrInt(*data, "DIMDEC",   h.dimDec,   h.hasDimDec);
        getHdrDouble(*data, "DIMEXO", h.dimExo, h.hasDimExo);
        getHdrDouble(*data, "DIMEXE", h.dimExe, h.hasDimExe);
        getHdrDouble(*data, "DIMGAP", h.dimGap, h.hasDimGap);
        std::string styleName;
        if (getHdrStr(*data, "DIMSTYLE", styleName)) {
            h.dimStyle = intern(styleName);
        }
        // R4b: capture the GENERIC document-settings header vars (the ones NOT in the
        // fixed POD above) into the extra-var bag so they round-trip verbatim. We key
        // off a fixed whitelist of doc-settings vars: $GRIDMODE/$GRIDUNIT (grid),
        // $PDMODE/$PDSIZE (points), $ANGBASE/$ANGDIR (angles), $PINSBASE (paper base).
        // Coord-typed vars ($GRIDUNIT/$PINSBASE — codes 10/20/30) preserve all three
        // components. The DXF reader keys $-prefixed, the DWG reader un-prefixed; both
        // spellings are tried (findHdrVar). A missing var simply yields no record.
        static const char *kExtraInt[]    = { "GRIDMODE", "PDMODE", "ANGDIR" };
        static const char *kExtraDouble[] = { "PDSIZE", "ANGBASE" };
        static const char *kExtraCoord[]  = { "GRIDUNIT", "PINSBASE" };
        for (const char *key : kExtraInt) {
            const DRW_Variant *v = findHdrVar(*data, key);
            if (v == nullptr) continue;
            if (v->type() != DRW_Variant::INTEGER &&
                v->type() != DRW_Variant::DOUBLE) continue;
            LCHeaderVar hv{};
            hv.name = intern(std::string("$") + key);
            hv.type = LC_HVAR_INT;
            hv.i = (v->type() == DRW_Variant::INTEGER)
                       ? static_cast<long>(v->i_val())
                       : static_cast<long>(v->d_val());
            m_out->headerVars.push_back(hv);
        }
        for (const char *key : kExtraDouble) {
            const DRW_Variant *v = findHdrVar(*data, key);
            if (v == nullptr) continue;
            if (v->type() != DRW_Variant::DOUBLE &&
                v->type() != DRW_Variant::INTEGER) continue;
            LCHeaderVar hv{};
            hv.name = intern(std::string("$") + key);
            hv.type = LC_HVAR_DOUBLE;
            hv.d = (v->type() == DRW_Variant::DOUBLE)
                       ? v->d_val()
                       : static_cast<double>(v->i_val());
            m_out->headerVars.push_back(hv);
        }
        for (const char *key : kExtraCoord) {
            const DRW_Variant *v = findHdrVar(*data, key);
            if (v == nullptr || v->type() != DRW_Variant::COORD) continue;
            const DRW_Coord *c = v->coord();
            if (c == nullptr) continue;
            LCHeaderVar hv{};
            hv.name = intern(std::string("$") + key);
            hv.type = LC_HVAR_COORD;
            hv.coord[0] = c->x;
            hv.coord[1] = c->y;
            hv.coord[2] = c->z;
            m_out->headerVars.push_back(hv);
        }
    }
    void addLType(const DRW_LType &data) override { (void)data; }

    void addLayer(const DRW_Layer &data) override {
        LCLayer l{};
        l.name = intern(data.name);
        l.lineType = intern(data.lineType);
        // DXF stores a frozen/off layer with a negative color number; the flags
        // (code 70) carry the authoritative frozen/locked bits, so normalize the
        // color to its magnitude here.
        l.color = std::abs(data.color);
        l.color24 = data.color24;
        l.lineWeightMM100 = DRW_LW_Conv::lineWidth2dxfInt(data.lWeight);
        l.flags = data.flags;          // bit0 frozen, bit2 locked
        l.plot = data.plotF ? 1 : 0;
        m_out->layers.push_back(l);
    }

    // Capture one DIMSTYLE table entry. DRW_Dimstyle exposes the values as typed
    // members (libdxfrw defaults the imperial standard dimtxt=dimasz=0.18 and fills
    // them from the file); we flatten the subset the renderer needs into an
    // LCDimStyle POD. Driven by both the DXF and DWG read paths.
    void addDimStyle(const DRW_Dimstyle &data) override {
        LCDimStyle s{};
        s.name = intern(data.name);
        s.dimTxt = data.dimtxt;
        s.dimAsz = data.dimasz;
        s.dimScale = data.dimscale;
        s.dimDec = data.dimdec;
        s.dimLUnit = data.dimlunit;
        s.dimExo = data.dimexo;
        s.dimExe = data.dimexe;
        s.dimGap = data.dimgap;
        m_out->dimStyles.push_back(s);
    }
    void addVport(const DRW_Vport &data) override { (void)data; }
    void addTextStyle(const DRW_Textstyle &data) override { (void)data; }
    void addAppId(const DRW_AppId &data) override { (void)data; }

    // ----- block structure ------------------------------------------------
    // libdxfrw drives a block as: addBlock(record) → the member add* callbacks →
    // endBlock(). We open a PendingBlock on addBlock and route the member entities
    // into it (via pushEntity) until endBlock. Anonymous / layout blocks
    // (`*Model_Space`, `*Paper_Space`, `*U…` dimension/hatch blocks — names starting
    // with `*`) are flagged so they are NOT emitted as user-referenceable blocks,
    // but their member entities are still collected and simply dropped at finalize
    // (they are regenerated by resolve()).
    void addBlock(const DRW_Block &data) override {
        const bool anonymous = (!data.name.empty() && data.name[0] == '*');
        // Paper-space P1: a `*Paper_Space` / `*Paper_Space0` / `*Paper_Space<n>`
        // block holds the entities painted on a LAYOUT sheet. Stock libdxfrw does
        // NOT parse the LAYOUT dictionary, so the user-facing tab name is unknown —
        // we route these members to PAPER space (top-level list, tagged paper) under
        // a single reconstructed layout named "Layout1" (the documented single-
        // layout limitation). `*Model_Space` keeps flowing to model space.
        if (isPaperSpaceBlock(data.name)) {
            m_pendingBlocks.emplace_back();
            PendingBlock &pb = m_pendingBlocks.back();
            pb.name = data.name;
            pb.bx = data.basePoint.x; pb.by = data.basePoint.y; pb.bz = data.basePoint.z;
            pb.flags = data.flags;
            pb.anonymous = true;           // not a user-referenceable block (not emitted)
            pb.paperSpace = true;
            pb.paperLayoutName = kReconstructedLayoutName;
            m_currentBlock = &pb;
            return;
        }
        // Other anonymous / layout blocks (`*Model_Space`, the `*D…`/`*U…` dimension
        // & hatch graphic blocks) are NOT user-referenceable blocks: their member
        // entities are the auto-generated graphic for a DIMENSION/etc, which
        // LibreCAD's own filter expands inline. We therefore leave `m_currentBlock`
        // nullptr for them so their members flow to the TOP-LEVEL entity list (model
        // space) exactly as before (the DIMENSION entity itself is imported +
        // resolved separately). Only NAMED user blocks collect their members into
        // the block table.
        if (anonymous) {
            m_currentBlock = nullptr;
            return;
        }
        m_pendingBlocks.emplace_back();
        PendingBlock &pb = m_pendingBlocks.back();
        pb.name = data.name;
        pb.bx = data.basePoint.x; pb.by = data.basePoint.y; pb.bz = data.basePoint.z;
        pb.flags = data.flags;
        pb.anonymous = false;
        m_currentBlock = &pb;
    }
    void setBlock(const int handle) override { (void)handle; }
    void endBlock() override { m_currentBlock = nullptr; }

    // ----- geometric entities --------------------------------------------
    void addPoint(const DRW_Point &data) override {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_POINT);
        fillCommon(e, data);
        e.p1x = data.basePoint.x; e.p1y = data.basePoint.y; e.p1z = data.basePoint.z;
        pushEntity(e);
    }

    void addLine(const DRW_Line &data) override {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_LINE);
        fillCommon(e, data);
        e.p1x = data.basePoint.x; e.p1y = data.basePoint.y; e.p1z = data.basePoint.z;
        e.p2x = data.secPoint.x;  e.p2y = data.secPoint.y;  e.p2z = data.secPoint.z;
        pushEntity(e);
    }

    // RAY / XLINE: semi-infinite / infinite construction lines (DRW_Ray /
    // DRW_Xline, both DRW_Line subclasses). basePoint (code 10) -> p1; secPoint
    // (code 11) is the DIRECTION vector -> p2. Flattened to real PODs so the Swift
    // reader maps them to `.ray` / `.xline` (was previously dropped as unsupported).
    void addRay(const DRW_Ray &data) override {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_RAY);
        fillCommon(e, data);
        e.p1x = data.basePoint.x; e.p1y = data.basePoint.y; e.p1z = data.basePoint.z;
        e.p2x = data.secPoint.x;  e.p2y = data.secPoint.y;  e.p2z = data.secPoint.z;
        pushEntity(e);
    }
    void addXline(const DRW_Xline &data) override {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_XLINE);
        fillCommon(e, data);
        e.p1x = data.basePoint.x; e.p1y = data.basePoint.y; e.p1z = data.basePoint.z;
        e.p2x = data.secPoint.x;  e.p2y = data.secPoint.y;  e.p2z = data.secPoint.z;
        pushEntity(e);
    }

    void addArc(const DRW_Arc &data) override {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_ARC);
        fillCommon(e, data);
        e.cx = data.basePoint.x; e.cy = data.basePoint.y; e.cz = data.basePoint.z;
        e.radius = data.radious;
        e.startAngle = data.staangle;
        e.endAngle = data.endangle;
        pushEntity(e);
    }

    void addCircle(const DRW_Circle &data) override {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_CIRCLE);
        fillCommon(e, data);
        e.cx = data.basePoint.x; e.cy = data.basePoint.y; e.cz = data.basePoint.z;
        e.radius = data.radious;
        pushEntity(e);
    }

    void addEllipse(const DRW_Ellipse &data) override {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_ELLIPSE);
        fillCommon(e, data);
        // center=basePoint, major-axis endpoint (relative)=secPoint,
        // ratio, start/end ellipse parameters. Mirrors addEllipse in
        // rs_filterdxfrw.cpp, including the full-ellipse end==0 normalization.
        e.cx = data.basePoint.x; e.cy = data.basePoint.y; e.cz = data.basePoint.z;
        e.p2x = data.secPoint.x; e.p2y = data.secPoint.y; e.p2z = data.secPoint.z;
        e.ratio = data.ratio;
        e.startAngle = data.staparam;
        double ang2 = data.endparam;
        if (std::fabs(ang2 - 2.0 * M_PI) < 1e-10 && std::fabs(data.staparam) < 1e-10) {
            ang2 = 0.0;
        }
        e.endAngle = ang2;
        pushEntity(e);
    }

    void addLWPolyline(const DRW_LWPolyline &data) override {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_LWPOLYLINE);
        fillCommon(e, data);
        e.closed = (data.flags & 0x1) ? 1 : 0;
        m_out->vertexPool.emplace_back();
        std::vector<LCVertex> &verts = m_out->vertexPool.back();
        verts.reserve(data.vertlist.size());
        for (const auto &v : data.vertlist) {
            if (v) verts.push_back(LCVertex{v->x, v->y, v->bulge});
        }
        e.vertices = verts.empty() ? nullptr : verts.data();
        e.vertexCount = static_cast<int32_t>(verts.size());
        pushEntity(e);
    }

    void addPolyline(const DRW_Polyline &data) override {
        ++m_out->geometryCount;
        // Only the simple 2D polyline is flattened; 3D meshes / polyface meshes
        // (flags 0x10 / 0x40) are not in the frozen model -> unsupported warning.
        if ((data.flags & 0x10) || (data.flags & 0x40)) {
            LCEntity e = makeEntity(LC_ENT_UNSUPPORTED);
            fillCommon(e, data);
            e.typeName = intern("POLYLINE_MESH");
            pushEntity(e);
            return;
        }
        LCEntity e = makeEntity(LC_ENT_POLYLINE);
        fillCommon(e, data);
        e.closed = (data.flags & 0x1) ? 1 : 0;
        m_out->vertexPool.emplace_back();
        std::vector<LCVertex> &verts = m_out->vertexPool.back();
        verts.reserve(data.vertlist.size());
        for (const auto &v : data.vertlist) {
            if (v) verts.push_back(LCVertex{v->basePoint.x, v->basePoint.y, v->bulge});
        }
        e.vertices = verts.empty() ? nullptr : verts.data();
        e.vertexCount = static_cast<int32_t>(verts.size());
        pushEntity(e);
    }

    void addSpline(const DRW_Spline *data) override {
        ++m_out->geometryCount;
        if (data == nullptr) return;
        LCEntity e = makeEntity(LC_ENT_SPLINE);
        fillCommon(e, *data);
        e.degree = data->degree;
        e.closed = (data->flags & 0x1) ? 1 : 0;
        e.splineFlags = data->flags;   // raw code-70 flags, for a faithful re-write

        // Control points -> vertices (bulge unused). Mirrors addSpline's
        // controllist walk in rs_filterdxfrw.cpp.
        m_out->vertexPool.emplace_back();
        std::vector<LCVertex> &cps = m_out->vertexPool.back();
        cps.reserve(data->controllist.size());
        for (const auto &c : data->controllist) {
            if (c) cps.push_back(LCVertex{c->x, c->y, 0.0});
        }
        e.vertices = cps.empty() ? nullptr : cps.data();
        e.vertexCount = static_cast<int32_t>(cps.size());

        // Knots.
        m_out->doublePool.emplace_back(data->knotslist.begin(), data->knotslist.end());
        std::vector<double> &knots = m_out->doublePool.back();
        e.knots = knots.empty() ? nullptr : knots.data();
        e.knotCount = static_cast<int32_t>(knots.size());

        // Weights.
        m_out->doublePool.emplace_back(data->weightlist.begin(), data->weightlist.end());
        std::vector<double> &weights = m_out->doublePool.back();
        e.weights = weights.empty() ? nullptr : weights.data();
        e.weightCount = static_cast<int32_t>(weights.size());

        pushEntity(e);
    }

    void addKnot(const DRW_Entity &data) override { (void)data; } // sub-record

    // ----- TEXT / MTEXT --------------------------------------------------
    // Single-line TEXT. Insertion point, height, rotation (DXF stores degrees;
    // converted to radians here to match the POD/Swift contract), and the
    // horizontal/vertical alignment codes (72/73). Mirrors addText in
    // rs_filterdxfrw.cpp; the alignment-driven base/sec-point swap is irrelevant
    // here because the POD carries a single insertion point.
    void addText(const DRW_Text &data) override {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_TEXT);
        fillCommon(e, data);
        // For an aligned/fit/middle text DXF stores the insertion in secPoint;
        // otherwise basePoint. Pick the meaningful one (rs_filterdxfrw.cpp logic).
        bool useSec = (data.alignV != 0 || data.alignH != 0)
                   && data.alignH != DRW_Text::HAligned
                   && data.alignH != DRW_Text::HFit;
        if (useSec) {
            e.p1x = data.secPoint.x; e.p1y = data.secPoint.y; e.p1z = data.secPoint.z;
        } else {
            e.p1x = data.basePoint.x; e.p1y = data.basePoint.y; e.p1z = data.basePoint.z;
        }
        e.height = data.height;
        e.startAngle = data.angle * M_PI / 180.0;  // DXF degrees -> radians
        e.hAlign = static_cast<int32_t>(data.alignH);
        e.vAlign = static_cast<int32_t>(data.alignV);
        e.textValue = intern(data.text);
        e.styleName = intern(data.style);
        pushEntity(e);
    }

    // Multi-line MTEXT. DRW_MText derives from DRW_Text, so it inherits height
    // (40), angle (50), widthscale (41 = reference/wrap width), style (7), and the
    // attachment point (71 -> textgen). DRW_MText adds interlin (44 = line-spacing
    // factor); the line-spacing style (73) is parsed into alignV. We emit the RAW
    // inline-coded string (data.text, the concatenation of group 1/3) verbatim so
    // the Swift side can both PARSE it into the run tree AND keep it for lossless
    // round-trip. Mapped to LC_ENT_MTEXT so the reader builds `.mtext`, not `.text`.
    void addMText(const DRW_MText &data) override {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_MTEXT);
        fillCommon(e, data);
        e.p1x = data.basePoint.x; e.p1y = data.basePoint.y; e.p1z = data.basePoint.z;
        e.height = data.height;
        e.startAngle = data.angle * M_PI / 180.0;  // DXF degrees -> radians
        e.mtextRectWidth = data.widthscale;        // code 41: reference/wrap width
        // Attachment point (code 71) is parsed into textgen by DRW_Text::parseCode.
        e.mtextAttachment = data.textgen >= 1 && data.textgen <= 9 ? data.textgen : 1;
        e.mtextLineSpacingFactor = data.interlin;  // code 44
        // Line-spacing style (code 73) lands in alignV for MTEXT (1 at-least, 2 exact).
        e.mtextLineSpacingStyle = (data.alignV == 2) ? 2 : 1;
        e.textValue = intern(data.text);
        e.styleName = intern(data.style);
        pushEntity(e);
    }

    // ----- INSERT (block reference) --------------------------------------
    // Flatten a DXF INSERT/MINSERT into LC_ENT_INSERT: block name (code 2),
    // insertion point (p1), per-axis scale (41/42/43), rotation in radians (50 →
    // startAngle), and the MINSERT rectangular array (70/71 counts, 44/45 spacing).
    // DRW_Insert::angle is already radians (libdxfrw parses code 50 degrees → rad).
    void addInsert(const DRW_Insert &data) override {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_INSERT);
        fillCommon(e, data);
        e.p1x = data.basePoint.x; e.p1y = data.basePoint.y; e.p1z = data.basePoint.z;
        e.insScaleX = data.xscale;
        e.insScaleY = data.yscale;
        e.insScaleZ = data.zscale;
        e.startAngle = data.angle;            // radians
        e.insCols = data.colcount > 0 ? data.colcount : 1;
        e.insRows = data.rowcount > 0 ? data.rowcount : 1;
        e.insColSpacing = data.colspace;
        e.insRowSpacing = data.rowspace;
        e.textValue = intern(data.name);      // referenced block name
        // Block ATTRIB values (code 66 → ATTRIB sub-entities, populated by
        // dxfRW::processInsert into data.attlist). Flatten into the stable attribute
        // pool; DRW_Attrib derives DRW_Text, so angle is in DEGREES → radians here.
        if (!data.attlist.empty()) {
            std::vector<LCAttrib> attrs;
            attrs.reserve(data.attlist.size());
            for (const auto &att : data.attlist) {
                if (!att) continue;
                LCAttrib a{};
                a.tag = intern(att->tag);
                a.text = intern(att->text);
                a.prompt = intern("");
                a.x = att->basePoint.x;
                a.y = att->basePoint.y;
                a.height = att->height;
                a.rotation = att->angle * M_PI / 180.0;
                a.flags = static_cast<int32_t>(att->attribFlags);
                attrs.push_back(a);
            }
            if (!attrs.empty()) {
                m_out->attribPool.push_back(std::move(attrs));
                e.attribs = m_out->attribPool.back().data();
                e.attribCount = static_cast<int32_t>(m_out->attribPool.back().size());
            }
        }
        pushEntity(e);
    }

    // ATTDEF (block attribute-definition template). Delivered while a block is open
    // (between addBlock and endBlock); collected onto the current block's `attdefs`
    // so finalizeBlocks flattens them into `LCBlock.attribDefs`. An ATTDEF read
    // OUTSIDE a block (malformed input) is ignored gracefully. DRW_Attdef derives
    // DRW_Text, so angle is in DEGREES → radians here.
    void addAttdef(const DRW_Attdef &data) override {
        if (m_currentBlock == nullptr) return;   // ATTDEF only meaningful in a block
        LCAttrib a{};
        a.tag = intern(data.tag);
        a.text = intern(data.text);              // default value (code 1)
        a.prompt = intern(data.prompt);          // prompt (code 3)
        a.x = data.basePoint.x;
        a.y = data.basePoint.y;
        a.height = data.height;
        a.rotation = data.angle * M_PI / 180.0;
        a.flags = static_cast<int32_t>(data.attribFlags);
        m_currentBlock->attdefs.push_back(a);
    }
    void addTrace(const DRW_Trace &data) override { emitSolid(data); }
    void add3dFace(const DRW_3Dface &data) override { addUnsupportedEntity(data, "3DFACE"); }
    void addSolid(const DRW_Solid &data) override { emitSolid(data); }
    void addDimAlign(const DRW_DimAligned *data) override { emitDimAligned(data); }
    void addDimLinear(const DRW_DimLinear *data) override { emitDimLinear(data); }
    void addDimRadial(const DRW_DimRadial *data) override { emitDimRadial(data); }
    void addDimDiametric(const DRW_DimDiametric *data) override { emitDimDiametric(data); }
    void addDimAngular(const DRW_DimAngular *data) override { emitDimAngular(data); }
    void addDimAngular3P(const DRW_DimAngular3p *data) override { emitDimAngular3P(data); }
    void addDimOrdinate(const DRW_DimOrdinate *data) override { emitDimOrdinate(data); }
    void addLeader(const DRW_Leader *data) override { emitLeader(data); }
    void addHatch(const DRW_Hatch *data) override { emitHatch(data); }
    // VIEWPORT entity (DRW_Viewport, paper-space P3): a window on a layout sheet.
    // The DXF ENTITIES section always carries an AutoCAD "overview" viewport
    // (vpID == 1 / vpstatus <= 1) that represents the whole paper space, NOT a real
    // user viewport — we SKIP it (keep the historical UNSUPPORTED skip behavior) so
    // it does not appear as a stray viewport. Only a REAL viewport (vpID > 1)
    // becomes an LCViewport in the separate `lc_viewports` list. The model-view
    // center/height (codes 12/22/45) describe what model space the window shows; the
    // paper frame center/size (codes 10/20/40/41) describe the window on the sheet.
    void addViewport(const DRW_Viewport &data) override {
        // The AutoCAD overview viewport (id 1) is bookkeeping, not a user viewport.
        if (data.vpID <= 1) { addUnsupportedEntity(data, "VIEWPORT"); return; }
        ++m_out->geometryCount;
        m_sawPaperContent = true;   // a viewport implies a paper-space layout
        LCViewport v{};
        v.centerX = data.basePoint.x;
        v.centerY = data.basePoint.y;
        v.width = data.pswidth;
        v.height = data.psheight;
        v.viewCenterX = data.centerPX;
        v.viewCenterY = data.centerPY;
        v.viewHeight = data.viewHeight;
        v.vpID = data.vpID;
        v.vpStatus = data.vpstatus;
        // The layout the viewport belongs to: the `*Paper_Space` block being read,
        // else the single reconstructed layout name (matching how paper-space
        // entities are stamped). Borrows the list's string pool.
        if (m_currentBlock != nullptr && m_currentBlock->paperSpace
            && !m_currentBlock->paperLayoutName.empty()) {
            v.layoutName = intern(m_currentBlock->paperLayoutName);
        } else {
            v.layoutName = intern(std::string(kReconstructedLayoutName));
        }
        m_out->viewports.push_back(v);
    }
    // IMAGE entity (DRW_Image): captured into a PENDING image (POD + its IMAGEDEF
    // hard-ref handle, code 340) here; finalizeImages() links it to its IMAGEDEF
    // (linkImage, by code-5 handle) afterward and pushes the finished POD into the
    // right target. We can't push immediately because the IMAGEDEF (with the file
    // path + pixel size) arrives LATER in the OBJECTS section.
    void addImage(const DRW_Image *data) override { capturePendingImage(data); }
    // IMAGEDEF object (DRW_ImageDef): recorded in the handle→def map so a pending
    // IMAGE can resolve its path + pixel size by its code-340 reference.
    void linkImage(const DRW_ImageDef *data) override {
        if (data == nullptr) return;
        ImageDefRecord rec;
        rec.path = data->name;
        rec.u = data->u;
        rec.v = data->v;
        m_imageDefs[data->handle] = rec;
    }

    // ----- misc read hooks (not collected) -------------------------------
    void addComment(const char *comment) override { (void)comment; }
    // PLOTSETTINGS (paper-space P1): captured to drive the reconstructed layout's
    // page geometry. Stock libdxfrw's DRW_PlotSettings parses ONLY the margins
    // (codes 40–43) and the plot-view name — NOT the paper width/height — so we
    // capture the margins (the uniform page margin is their max) and note that
    // PLOTSETTINGS was seen (which alone reconstructs a Layout1 even for a drawing
    // whose paper space holds no entities yet). Paper size stays at the engine
    // default until a libdxfrw patch exposes the plot-paper-size codes (44/45).
    void addPlotSettings(const DRW_PlotSettings *data) override {
        m_sawPlotSettings = true;
        if (data == nullptr) return;
        const double maxMargin = std::max(
            std::max(data->marginLeft, data->marginRight),
            std::max(data->marginTop, data->marginBottom));
        if (maxMargin > m_plotMarginMM) m_plotMarginMM = maxMargin;
    }

    // ----- write hooks: never called during read; required to be defined --
    void writeHeader(DRW_Header &data) override { (void)data; }
    void writeBlocks() override {}
    void writeBlockRecords() override {}
    void writeEntities() override {}
    void writeLTypes() override {}
    void writeLayers() override {}
    void writeTextstyles() override {}
    void writeVports() override {}
    void writeDimstyles() override {}
    void writeObjects() override {}
    void writeAppId() override {}

private:
    LCEntityList *m_out;

    // Block-read state: the collected block definitions and the one currently being
    // read (nullptr at top level). `pushEntity` routes member entities into
    // `m_currentBlock` between addBlock and endBlock; `finalizeBlocks` flattens them.
    std::deque<PendingBlock> m_pendingBlocks;   // deque: addresses stable for m_currentBlock
    PendingBlock *m_currentBlock = nullptr;

    // IMAGE/IMAGEDEF link state: pending IMAGE entities (awaiting their IMAGEDEF)
    // and the IMAGEDEF records keyed by code-5 handle. finalizeImages() joins them.
    std::vector<PendingImage> m_pendingImages;
    std::map<duint32, ImageDefRecord> m_imageDefs;

    // Paper-space P1: layout-reconstruction state. `m_sawPaperContent` is set when
    // any paper-space entity is seen (a `*Paper_Space` block member or a top-level
    // entity with code 67 == 1); `m_sawPlotSettings` when a PLOTSETTINGS object is
    // read; `m_plotMarginMM` is the largest PLOTSETTINGS margin captured (the
    // reconstructed layout's uniform page margin). finalizeLayouts() emits ONE
    // Layout1 when either flag is set (see finalizeLayouts).
    bool m_sawPaperContent = false;
    bool m_sawPlotSettings = false;
    double m_plotMarginMM = 0.0;

    // ----- SOLID / TRACE -------------------------------------------------
    // A filled triangle or quadrilateral. DXF orders the 4 corners as
    // basePoint(10), secPoint(11), thirdPoint(12), fourPoint(13) where the 3rd
    // and 4th are "bow-tie" swapped relative to a non-self-intersecting ring; we
    // un-swap them to [c0, c1, c3, c2] so SolidData.corners is already a ring
    // (matches RS_Painter::drawSolidWCS's std::swap of corner[2]/corner[3]). A
    // degenerate solid (fourPoint == thirdPoint) is a triangle -> 3 corners.
    void emitSolid(const DRW_Trace &data) {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_SOLID);
        fillCommon(e, data);
        const LCVertex c0{data.basePoint.x,  data.basePoint.y,  0.0};
        const LCVertex c1{data.secPoint.x,   data.secPoint.y,   0.0};
        const LCVertex c2{data.thirdPoint.x, data.thirdPoint.y, 0.0};
        const LCVertex c3{data.fourPoint.x,  data.fourPoint.y,  0.0};
        m_out->vertexPool.emplace_back();
        std::vector<LCVertex> &verts = m_out->vertexPool.back();
        const bool triangle = (c2.x == c3.x && c2.y == c3.y);
        if (triangle) {
            verts = {c0, c1, c2};
        } else {
            verts = {c0, c1, c3, c2};   // un-swap bow-tie 3rd/4th into ring order
        }
        e.vertices = verts.data();
        e.vertexCount = static_cast<int32_t>(verts.size());
        pushEntity(e);
    }

    // ----- HATCH ---------------------------------------------------------
    // A filled region described by one or more boundary loops. Each loop is read
    // into a contiguous window of this entity's flat vertex array; the per-loop
    // (offset,count) windows are stored in `loops`. Ported from addHatch in
    // rs_filterdxfrw.cpp: a polyline boundary (type & 2) walks its vertlist with
    // bulges; otherwise each edge entity (LINE/ARC/ELLIPSE/SPLINE) contributes
    // its vertices. A LINE edge becomes a single straight vertex; an ARC edge is
    // recovered EXACTLY as a single bulged vertex (the inverse of the writer's
    // WritingInterface::appendBulgeArcEdge, see appendBulgeArcVertex), so a curved
    // boundary round-trips as one bulged PolylineVertex rather than a sampled chord
    // run — preserving both the arc geometry and the DXF bulge encoding. Ellipse
    // and spline edges are still tessellated into straight segments (no bulge for
    // those primitives). Bulges on polyline-boundary edges are carried through.
    // solidFill and the pattern name round-trip.
    void emitHatch(const DRW_Hatch *data) {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_HATCH);
        if (data) {
            fillCommon(e, *data);
        } else {
            e.layer = intern("0"); e.lineType = intern("BYLAYER");
            pushEntity(e);
            return;
        }
        e.solidFill = data->solid ? 1 : 0;
        // Pattern scale (code 41) + angle (code 52, DXF degrees -> radians). Only a
        // PATTERN hatch carries them; a solid hatch leaves the defaults (1 / 0).
        e.hatchScale = (data->scale != 0.0) ? data->scale : 1.0;
        e.hatchAngle = data->angle * M_PI / 180.0;
        e.textValue = intern(data->name);   // pattern name (e.g. "SOLID", "ANSI31")

        // One flat vertex array for ALL loops; loops index into it via windows.
        m_out->vertexPool.emplace_back();
        std::vector<LCVertex> &verts = m_out->vertexPool.back();
        m_out->loopPool.emplace_back();
        std::vector<LCLoop> &loops = m_out->loopPool.back();

        for (const auto &loop : data->looplist) {
            if (!loop) continue;
            // type bit 32 == an outermost/derived loop libdxfrw flags as skip
            // (mirrors rs_filterdxfrw.cpp's `(loop->type & 32) == 32` continue).
            if ((loop->type & 32) == 32) continue;
            const int32_t start = static_cast<int32_t>(verts.size());
            readHatchLoop(*loop, verts);
            const int32_t count = static_cast<int32_t>(verts.size()) - start;
            if (count > 0) loops.push_back(LCLoop{start, count});
        }

        e.vertices = verts.empty() ? nullptr : verts.data();
        e.vertexCount = static_cast<int32_t>(verts.size());
        e.loops = loops.empty() ? nullptr : loops.data();
        e.loopCount = static_cast<int32_t>(loops.size());
        pushEntity(e);
    }

    // ----- LEADER (annotation callout) -----------------------------------
    // Flatten a DRW_Leader into LC_ENT_LEADER: the path vertices (codes 10/20/30,
    // bulge unused) into the flat vertex pool; the arrow flag (code 71), the text
    // annotation height (code 40) and the referenced dim-style name (code 3) into
    // the dedicated fields. A zero-vertex leader (as in dim_sample.dxf) flattens to
    // a real LC_ENT_LEADER with an empty vertex array — so it imports (no warning)
    // and round-trips, even though it draws nothing. The attached annotation entity
    // (hard-ref code 340) is NOT collected — the engine's inline annotation
    // round-trips via Codable, not DXF (mirrors libdxfrw's own writeLeader, which
    // emits only the path + arrow + text height).
    void emitLeader(const DRW_Leader *data) {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_LEADER);
        if (data) {
            fillCommon(e, *data);
        } else {
            e.layer = intern("0"); e.lineType = intern("BYLAYER");
            pushEntity(e);
            return;
        }
        e.leaderHasArrow = (data->arrow != 0) ? 1 : 0;
        e.height = data->textheight;            // code 40 — annotation height
        e.leaderArrowSize = data->textheight;   // default arrow size to the text height
        if (!data->style.empty()) e.styleName = intern(data->style);

        m_out->vertexPool.emplace_back();
        std::vector<LCVertex> &verts = m_out->vertexPool.back();
        verts.reserve(data->vertexlist.size());
        for (const auto &v : data->vertexlist) {
            if (v) verts.push_back(LCVertex{v->x, v->y, 0.0});
        }
        e.vertices = verts.empty() ? nullptr : verts.data();
        e.vertexCount = static_cast<int32_t>(verts.size());
        pushEntity(e);
    }

    // ----- IMAGE (raster image entity) -----------------------------------
    // Capture a DRW_Image into a PendingImage. DRW_Image derives from DRW_Line, so
    // it inherits basePoint (code 10, the lower-left insertion) and secPoint (code
    // 11, the per-pixel U vector); DRW_Image adds vVector (code 12, the per-pixel V
    // vector), sizeu/sizev (codes 13/23, the pixel size), the code-340 IMAGEDEF
    // hard reference (`ref`), and the display ints (clip/brightness/contrast/fade,
    // codes 280–283). The path + (authoritative) pixel size come from the linked
    // IMAGEDEF, joined later in finalizeImages() by the `ref` handle; the entity's
    // own sizeu/sizev are kept as a fallback. The display "show image" flag is DXF
    // code-70 bit 1 — libdxfrw stores DRW_Image's code-70 as the generic entity
    // `space`/visibility, so we default show=1 (the common case) and let the engine
    // toggle it via the inspector; clipping is carried for round-trip.
    void capturePendingImage(const DRW_Image *data) {
        ++m_out->geometryCount;
        PendingImage pi;
        pi.e = makeEntity(LC_ENT_IMAGE);
        if (data) {
            fillCommon(pi.e, *data);
            pi.e.p1x = data->basePoint.x; pi.e.p1y = data->basePoint.y; pi.e.p1z = data->basePoint.z;
            pi.e.p2x = data->secPoint.x;  pi.e.p2y = data->secPoint.y;  pi.e.p2z = data->secPoint.z;
            pi.e.imgVVecX = data->vVector.x; pi.e.imgVVecY = data->vVector.y; pi.e.imgVVecZ = data->vVector.z;
            pi.e.imgSizeU = data->sizeu;
            pi.e.imgSizeV = data->sizev;
            pi.e.imgBrightness = data->brightness;
            pi.e.imgContrast = data->contrast;
            pi.e.imgFade = data->fade;
            pi.e.imgClip = data->clip;
            pi.e.imgShow = 1;             // DXF show-image flag; default visible.
            pi.defHandle = data->ref;     // code 340 → IMAGEDEF handle (code 5).
        } else {
            pi.e.layer = intern("0"); pi.e.lineType = intern("BYLAYER");
        }
        pi.block = m_currentBlock;
        m_pendingImages.push_back(pi);
    }

    // Append one hatch boundary loop's vertices to `verts`.
    void readHatchLoop(const DRW_HatchLoop &loop, std::vector<LCVertex> &verts) {
        if ((loop.type & 2) == 2) {
            // Polyline boundary: a single DRW_LWPolyline holds all vertices+bulges.
            if (loop.objlist.empty()) return;
            const DRW_LWPolyline *pline =
                dynamic_cast<DRW_LWPolyline *>(loop.objlist.front().get());
            if (!pline) return;
            for (const auto &v : pline->vertlist) {
                if (v) verts.push_back(LCVertex{v->x, v->y, v->bulge});
            }
            return;
        }
        // Edge boundary: walk each edge entity, appending its start point so the
        // chained edges form one ring. A LINE contributes a plain (zero-bulge)
        // start vertex; an ARC contributes a single bulged start vertex (its arc
        // geometry recovered exactly, see appendBulgeArcVertex); ellipse/spline
        // edges still tessellate into intermediate points.
        for (const auto &ent : loop.objlist) {
            if (!ent) continue;
            switch (ent->eType) {
            case DRW::LINE: {
                const auto *l = dynamic_cast<DRW_Line *>(ent.get());
                if (l) verts.push_back(LCVertex{l->basePoint.x, l->basePoint.y, 0.0});
                break;
            }
            case DRW::ARC: {
                // A curved boundary edge round-trips as a SINGLE bulged vertex
                // (the exact inverse of WritingInterface::appendBulgeArcEdge),
                // not a tessellated chord run: emit the edge's START point
                // carrying the recovered DXF bulge. The next edge contributes the
                // end point, so the chained ring is preserved with the minimal
                // vertex count and the arc geometry survives losslessly.
                const auto *a = dynamic_cast<DRW_Arc *>(ent.get());
                if (a) appendBulgeArcVertex(a->basePoint.x, a->basePoint.y, a->radious,
                                            a->staangle, a->endangle, a->isccw != 0, verts);
                break;
            }
            case DRW::CIRCLE: {
                const auto *c = dynamic_cast<DRW_Circle *>(ent.get());
                if (c) tessellateArc(c->basePoint.x, c->basePoint.y, c->radious,
                                     0.0, 2.0 * M_PI, true, verts);
                break;
            }
            case DRW::ELLIPSE: {
                // Tessellate via the ellipse parametric form. staparam/endparam
                // are ellipse parameters (radians); ratio scales the minor axis.
                const auto *el = dynamic_cast<DRW_Ellipse *>(ent.get());
                if (el) tessellateEllipse(*el, verts);
                break;
            }
            case DRW::SPLINE: {
                // Approximate a spline boundary edge by its control polygon.
                // (Proper NURBS boundary tessellation is backlog.)
                const auto *s = dynamic_cast<DRW_Spline *>(ent.get());
                if (s) for (const auto &cp : s->controllist) {
                    if (cp) verts.push_back(LCVertex{cp->x, cp->y, 0.0});
                }
                break;
            }
            default:
                break;
            }
        }
    }

    // Recover a hatch boundary ARC edge as ONE bulged boundary vertex — the exact
    // inverse of WritingInterface::appendBulgeArcEdge. The writer encoded a bulged
    // segment a->b as a DRW_Arc with staangle at a, endangle at b, and
    // isccw = (bulge <= 0); the traversal a->b therefore sweeps -included radians
    // around the center (see Resolve.expandPolyline / appendBulgeArcEdge). We
    // recover the arc START point a (at staangle), measure the SIGNED a->b angular
    // sweep around the center (CCW positive), and invert:
    //   included = -sweep,  bulge = tan(included / 4).
    // The sign falls out naturally: a left-bowing (CCW-bowing) apex gives a
    // positive bulge and isccw == 0, matching the writer and Resolve. We push only
    // the START vertex (carrying the bulge); the next edge in the loop supplies
    // the end point, so the ring is preserved with the minimal vertex count.
    static void appendBulgeArcVertex(double cx, double cy, double r,
                                     double staang, double endang, bool ccw,
                                     std::vector<LCVertex> &verts) {
        const double ax = cx + r * std::cos(staang);
        const double ay = cy + r * std::sin(staang);
        // Signed a->b angular sweep around the center (CCW positive). The
        // magnitude is the traversal sweep in the isccw direction, normalized to
        // (0, 2π]; CW traversals carry a negative sign.
        double mag;
        if (ccw) {
            mag = endang - staang;
            while (mag <= 0.0) mag += 2.0 * M_PI;
        } else {
            mag = staang - endang;
            while (mag <= 0.0) mag += 2.0 * M_PI;
        }
        const double signedSweep = ccw ? mag : -mag;
        const double included = -signedSweep;       // inverse of expandPolyline's -included
        const double bulge = std::tan(included / 4.0);
        verts.push_back(LCVertex{ax, ay, bulge});
    }

    // Tessellate an arc (center cx,cy; radius r; staang..endang radians) into
    // straight segments, appending each sample point. `ccw` is the sweep
    // direction. ~16 segments per full turn keeps boundary fills smooth without
    // exploding the vertex count.
    static void tessellateArc(double cx, double cy, double r,
                              double staang, double endang, bool ccw,
                              std::vector<LCVertex> &verts) {
        double sweep;
        if (ccw) {
            sweep = endang - staang;
            while (sweep <= 0.0) sweep += 2.0 * M_PI;
        } else {
            sweep = staang - endang;
            while (sweep <= 0.0) sweep += 2.0 * M_PI;
            sweep = -sweep;   // negative for CW
        }
        const int segs = std::max(2, static_cast<int>(std::ceil(std::fabs(sweep) / (M_PI / 8.0))));
        for (int i = 0; i <= segs; ++i) {
            const double t = staang + sweep * (static_cast<double>(i) / segs);
            verts.push_back(LCVertex{cx + r * std::cos(t), cy + r * std::sin(t), 0.0});
        }
    }

    // Tessellate an ellipse / elliptic-arc boundary edge.
    static void tessellateEllipse(const DRW_Ellipse &el, std::vector<LCVertex> &verts) {
        const double cx = el.basePoint.x, cy = el.basePoint.y;
        const double mx = el.secPoint.x,  my = el.secPoint.y;   // major-axis endpoint (relative)
        const double rot = std::atan2(my, mx);
        const double majR = std::sqrt(mx * mx + my * my);
        const double minR = majR * el.ratio;
        double a1 = el.staparam;
        double a2 = el.endparam;
        if (std::fabs(a2 - 2.0 * M_PI) < 1e-10 && std::fabs(a1) < 1e-10) {
            a2 = 2.0 * M_PI;   // full ellipse
        }
        double sweep = a2 - a1;
        while (sweep < 0.0) sweep += 2.0 * M_PI;
        const int segs = std::max(2, static_cast<int>(std::ceil(sweep / (M_PI / 8.0))));
        const double cosR = std::cos(rot), sinR = std::sin(rot);
        for (int i = 0; i <= segs; ++i) {
            const double t = a1 + sweep * (static_cast<double>(i) / segs);
            const double ex = majR * std::cos(t);
            const double ey = minR * std::sin(t);
            verts.push_back(LCVertex{cx + ex * cosR - ey * sinR,
                                     cy + ex * sinR + ey * cosR, 0.0});
        }
    }

    // ----- DIMENSION -----------------------------------------------------
    // Flatten the shared DRW_Dimension data (def point, text point, text
    // override, style, attachment, line-spacing, text rotation). Mirrors the
    // RS_Dimension common-field mapping in rs_filterdxfrw.cpp; per-variant points
    // are filled by the emitDim* callers. `text` is the user text override (code
    // 1): empty == use the measured value. `rot` (code 53) is the explicit text
    // rotation; libdxfrw defaults it to 0, so we mark it "set" only when nonzero.
    LCEntity makeDimensionBase(const DRW_Dimension &d, int dimType) {
        LCEntity e = makeEntity(LC_ENT_DIMENSION);
        fillCommon(e, d);
        e.dimType = dimType;
        const DRW_Coord def = d.getDefPoint();
        e.p1x = def.x; e.p1y = def.y; e.p1z = def.z;
        const DRW_Coord tp = d.getTextPoint();
        e.dimTextx = tp.x; e.dimTexty = tp.y; e.dimTextz = tp.z;
        // A zeroed text point means "no override" (resolve centers the label).
        e.dimHasText = (tp.x != 0.0 || tp.y != 0.0 || tp.z != 0.0) ? 1 : 0;
        const std::string text = d.getText();
        if (!text.empty()) e.textValue = intern(text);
        e.styleName = intern(d.getStyle());
        e.dimAlign = d.getAlign();
        e.dimLineStyle = d.getTextLineStyle();
        e.dimLineFactor = d.getTextLineFactor();
        e.dimTextRotation = d.getDir();
        e.dimHasTextRotation = (d.getDir() != 0.0) ? 1 : 0;
        // Per-entity text-height / arrow-size override from the ACAD:DSTYLE xdata,
        // if present (else the has* flags stay 0 == inherit the style/doc default).
        applyDimOverrides(e, d);
        return e;
    }

    void emitDimLinear(const DRW_DimLinear *data) {
        ++m_out->geometryCount;
        if (!data) { addUnsupportedDim(data, "DIMENSION"); return; }
        LCEntity e = makeDimensionBase(*data, LC_DIM_LINEAR);
        const DRW_Coord d1 = data->getDef1Point();
        const DRW_Coord d2 = data->getDef2Point();
        e.dimDef1x = d1.x; e.dimDef1y = d1.y; e.dimDef1z = d1.z;
        e.dimDef2x = d2.x; e.dimDef2y = d2.y; e.dimDef2z = d2.z;
        e.dimAngle = data->getAngle() * M_PI / 180.0;     // DXF degrees -> radians
        e.dimOblique = data->getOblique() * M_PI / 180.0;
        pushEntity(e);
    }

    void emitDimAligned(const DRW_DimAligned *data) {
        ++m_out->geometryCount;
        if (!data) { addUnsupportedDim(data, "DIMENSION"); return; }
        LCEntity e = makeDimensionBase(*data, LC_DIM_ALIGNED);
        const DRW_Coord d1 = data->getDef1Point();
        const DRW_Coord d2 = data->getDef2Point();
        e.dimDef1x = d1.x; e.dimDef1y = d1.y; e.dimDef1z = d1.z;
        e.dimDef2x = d2.x; e.dimDef2y = d2.y; e.dimDef2z = d2.z;
        pushEntity(e);
    }

    void emitDimRadial(const DRW_DimRadial *data) {
        ++m_out->geometryCount;
        if (!data) { addUnsupportedDim(data, "DIMENSION"); return; }
        // center == defPoint (code 10), already in p1; radius point == code 15.
        LCEntity e = makeDimensionBase(*data, LC_DIM_RADIAL);
        const DRW_Coord rp = data->getDiameterPoint();
        e.dimDef5x = rp.x; e.dimDef5y = rp.y; e.dimDef5z = rp.z;
        pushEntity(e);
    }

    void emitDimDiametric(const DRW_DimDiametric *data) {
        ++m_out->geometryCount;
        if (!data) { addUnsupportedDim(data, "DIMENSION"); return; }
        // p2 == code 10 (getDiameter2Point, already in p1 as defPoint);
        // p1 == code 15 (getDiameter1Point).
        LCEntity e = makeDimensionBase(*data, LC_DIM_DIAMETRIC);
        const DRW_Coord p1 = data->getDiameter1Point();
        e.dimDef5x = p1.x; e.dimDef5y = p1.y; e.dimDef5z = p1.z;
        pushEntity(e);
    }

    void emitDimAngular(const DRW_DimAngular *data) {
        ++m_out->geometryCount;
        if (!data) { addUnsupportedDim(data, "DIMENSION"); return; }
        // 2-line angular: line1 = (firstLine1 code13, firstLine2 code14),
        // line2 = (secondLine1 code15, secondLine2 code10 == defPoint == p1);
        // the dimension arc passes through dimPoint (code 16).
        LCEntity e = makeDimensionBase(*data, LC_DIM_ANGULAR);
        const DRW_Coord l1a = data->getFirstLine1();
        const DRW_Coord l1b = data->getFirstLine2();
        const DRW_Coord l2a = data->getSecondLine1();
        const DRW_Coord arc = data->getDimPoint();   // code 16: arc-through point
        e.dimDef1x = l1a.x; e.dimDef1y = l1a.y; e.dimDef1z = l1a.z;
        e.dimDef2x = l1b.x; e.dimDef2y = l1b.y; e.dimDef2z = l1b.z;
        e.dimDef5x = l2a.x; e.dimDef5y = l2a.y; e.dimDef5z = l2a.z;
        e.dimArcx  = arc.x; e.dimArcy  = arc.y; e.dimArcz  = arc.z;
        pushEntity(e);
    }

    void emitDimAngular3P(const DRW_DimAngular3p *data) {
        ++m_out->geometryCount;
        if (!data) { addUnsupportedDim(data, "DIMENSION"); return; }
        // 3-point angular: firstLine = point1 (code13), secondLine = point2
        // (code14), vertex (code15); the dimension arc passes through the def point
        // (code10, the dim point), already in p1 via makeDimensionBase.
        LCEntity e = makeDimensionBase(*data, LC_DIM_ANGULAR3P);
        const DRW_Coord p1 = data->getFirstLine();
        const DRW_Coord p2 = data->getSecondLine();
        const DRW_Coord vx = data->getVertexPoint();
        e.dimDef1x = p1.x; e.dimDef1y = p1.y; e.dimDef1z = p1.z;
        e.dimDef2x = p2.x; e.dimDef2y = p2.y; e.dimDef2z = p2.z;
        e.dimDef5x = vx.x; e.dimDef5y = vx.y; e.dimDef5z = vx.z;
        pushEntity(e);
    }

    void emitDimOrdinate(const DRW_DimOrdinate *data) {
        ++m_out->geometryCount;
        if (!data) { addUnsupportedDim(data, "DIMENSION"); return; }
        // Ordinate: origin == def point (code 10, already in p1); feature ==
        // firstLine (code 13); leader end == secondLine (code 14). The X- vs
        // Y-datum is carried in type-70 bit 0x40 (set == X-datum).
        LCEntity e = makeDimensionBase(*data, LC_DIM_ORDINATE);
        const DRW_Coord feat = data->getFirstLine();
        const DRW_Coord lead = data->getSecondLine();
        e.dimDef1x = feat.x; e.dimDef1y = feat.y; e.dimDef1z = feat.z;
        e.dimDef2x = lead.x; e.dimDef2y = lead.y; e.dimDef2z = lead.z;
        e.dimOrdinateX = (data->type & 0x40) ? 1 : 0;
        pushEntity(e);
    }

    // ----- HEADER-var lookup helpers -------------------------------------
    // DRW_Header.vars is keyed `$`-prefixed by the DXF reader ($DIMTXT) and
    // un-prefixed by the DWG reader (DIMTXT); look up both spellings. The variant
    // stores its type tag, so accept INTEGER or DOUBLE interchangeably for a
    // numeric var (a header var occasionally arrives as the "wrong" numeric type).
    static const DRW_Variant *findHdrVar(const DRW_Header &h, const char *key) {
        auto it = h.vars.find(std::string("$") + key);
        if (it != h.vars.end()) return it->second;
        it = h.vars.find(std::string(key));
        if (it != h.vars.end()) return it->second;
        return nullptr;
    }
    static void getHdrInt(const DRW_Header &h, const char *key,
                          int32_t &out, int32_t &has) {
        const DRW_Variant *v = findHdrVar(h, key);
        if (v == nullptr) return;
        if (v->type() == DRW_Variant::INTEGER) {
            out = static_cast<int32_t>(v->i_val()); has = 1;
        } else if (v->type() == DRW_Variant::DOUBLE) {
            out = static_cast<int32_t>(v->d_val()); has = 1;
        }
    }
    static void getHdrDouble(const DRW_Header &h, const char *key,
                             double &out, int32_t &has) {
        const DRW_Variant *v = findHdrVar(h, key);
        if (v == nullptr) return;
        if (v->type() == DRW_Variant::DOUBLE) {
            out = v->d_val(); has = 1;
        } else if (v->type() == DRW_Variant::INTEGER) {
            out = static_cast<double>(v->i_val()); has = 1;
        }
    }
    static bool getHdrStr(const DRW_Header &h, const char *key, std::string &out) {
        const DRW_Variant *v = findHdrVar(h, key);
        if (v == nullptr || v->type() != DRW_Variant::STRING) return false;
        out = v->c_str();
        return !out.empty();
    }

    // ----- per-dimension DSTYLE override (xdata) -------------------------
    // A DIMENSION can override its style's text height / arrow size inline via the
    // `ACAD:DSTYLE` xdata group. In extData it appears as: 1001 "ACAD" (appid),
    // 1000 "DSTYLE", then a brace-delimited list of (1070 dim-var-code, value)
    // pairs — text height is dim-var 140, arrow size dim-var 41; the value follows
    // as a 1040 double. We scan the FIFO extData for this pattern and stamp any
    // found override (with its `has*` flag) onto the entity; resolve precedence
    // makes a per-entity override win over the document/style default. Absent =>
    // flags stay 0 (inherit). Mirrors how AutoCAD/LibreCAD store dim overrides.
    static void applyDimOverrides(LCEntity &e, const DRW_Entity &d) {
        bool inDStyle = false;
        int pendingVar = 0;          // the dim-var code from the last 1070
        bool havePendingVar = false;
        for (const auto &vp : d.extData) {
            if (!vp) continue;
            const DRW_Variant &v = *vp;
            switch (v.code()) {
            case 1001:               // appid: a new xdata group begins
                inDStyle = false;
                havePendingVar = false;
                break;
            case 1000:               // string control: "DSTYLE" opens the override list
                if (v.type() == DRW_Variant::STRING && v.c_str() != nullptr) {
                    inDStyle = (std::string(v.c_str()) == "DSTYLE");
                }
                havePendingVar = false;
                break;
            case 1070:               // the dim-variable code this override targets
                if (inDStyle && v.type() == DRW_Variant::INTEGER) {
                    pendingVar = static_cast<int>(v.i_val());
                    havePendingVar = true;
                }
                break;
            case 1040:               // the override value for the pending dim-var
                if (inDStyle && havePendingVar && v.type() == DRW_Variant::DOUBLE) {
                    if (pendingVar == 140) {       // DIMTXT — text height
                        e.dimTextHeightOverride = v.d_val();
                        e.dimHasTextHeightOverride = 1;
                    } else if (pendingVar == 41) { // DIMASZ — arrow size
                        e.dimArrowSizeOverride = v.d_val();
                        e.dimHasArrowSizeOverride = 1;
                    }
                    havePendingVar = false;
                }
                break;
            default:
                break;
            }
        }
    }

    // Common path for an entity passed by const-ref that we don't flatten.
    template <typename T>
    void addUnsupportedEntity(const T &data, const char *name) {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_UNSUPPORTED);
        fillCommon(e, data);
        e.typeName = intern(name);
        pushEntity(e);
    }

    // Common path for an entity passed by const-pointer (dimensions, hatch,
    // leader, image) that we don't flatten.
    template <typename T>
    void addUnsupportedDim(const T *data, const char *name) {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_UNSUPPORTED);
        if (data) fillCommon(e, *data);
        else { e.layer = intern("0"); e.lineType = intern("BYLAYER"); }
        e.typeName = intern(name);
        pushEntity(e);
    }
};

// ===========================================================================
//  Writer: flat POD arrays -> DXF, via libdxfrw's write path.
// ===========================================================================

/**
 * Mirror of the reader, in reverse: a DRW_Interface whose write* callbacks emit
 * the caller-supplied LCEntity / LCLayer PODs through dxfRW's write API. The
 * `writeEntities()` / `writeLayers()` / `writeLTypes()` callbacks are the ones
 * libdxfrw drives during a `write()`; the rest are required no-ops (some emit a
 * minimal standard table so the file is well-formed).
 *
 * The per-entity attribute and per-kind geometry mapping is the inverse of
 * FlatteningReader above and of rs_filterdxfrw.cpp's write* callbacks.
 */
class WritingInterface final : public DRW_Interface {
public:
    // DXF mode: drive the DXF writer (`dxfRW`). `m_dwg` stays null, so every
    // per-entity emit and the table callbacks route to `m_dxf`.
    WritingInterface(dxfRW *dxf,
                     const LCEntity *entities, int entityCount,
                     const LCLayer *layers, int layerCount,
                     const LCBlock *blocks, int blockCount,
                     const LCEntity *blockEntities, int blockEntityCount,
                     const LCHeader *header,
                     const LCDimStyle *dimStyles, int dimStyleCount,
                     const LCViewport *viewports, int viewportCount,
                     const LCHeaderVar *headerVars, int headerVarCount)
        : m_dxf(dxf),
          m_entities(entities), m_entityCount(entityCount < 0 ? 0 : entityCount),
          m_layers(layers), m_layerCount(layerCount < 0 ? 0 : layerCount),
          m_blocks(blocks), m_blockCount(blockCount < 0 ? 0 : blockCount),
          m_blockEntities(blockEntities),
          m_blockEntityCount(blockEntityCount < 0 ? 0 : blockEntityCount),
          m_header(header),
          m_dimStyles(dimStyles),
          m_dimStyleCount(dimStyleCount < 0 ? 0 : dimStyleCount),
          m_viewports(viewports),
          m_viewportCount(viewportCount < 0 ? 0 : viewportCount),
          m_headerVars(headerVars),
          m_headerVarCount(headerVarCount < 0 ? 0 : headerVarCount) {}

    // DWG mode: drive the DWG writer (`dwgRW`). The SAME per-kind geometry
    // mapping runs; the only differences are routed through the `emit*` helpers
    // and the table/block callbacks below: dwgWriter15 emits the standard
    // R2000 tables internally (so writeLayers/LTypes/Textstyles are no-ops),
    // and user blocks are declared via `defineBlock` (empty, no member geometry).
    WritingInterface(dwgRW *dwg,
                     const LCEntity *entities, int entityCount,
                     const LCLayer *layers, int layerCount,
                     const LCBlock *blocks, int blockCount,
                     const LCEntity *blockEntities, int blockEntityCount,
                     const LCHeader *header,
                     const LCDimStyle *dimStyles, int dimStyleCount,
                     const LCViewport *viewports, int viewportCount,
                     const LCHeaderVar *headerVars, int headerVarCount)
        : m_dwg(dwg),
          m_entities(entities), m_entityCount(entityCount < 0 ? 0 : entityCount),
          m_layers(layers), m_layerCount(layerCount < 0 ? 0 : layerCount),
          m_blocks(blocks), m_blockCount(blockCount < 0 ? 0 : blockCount),
          m_blockEntities(blockEntities),
          m_blockEntityCount(blockEntityCount < 0 ? 0 : blockEntityCount),
          m_header(header),
          m_dimStyles(dimStyles),
          m_dimStyleCount(dimStyleCount < 0 ? 0 : dimStyleCount),
          m_viewports(viewports),
          m_viewportCount(viewportCount < 0 ? 0 : viewportCount),
          m_headerVars(headerVars),
          m_headerVarCount(headerVarCount < 0 ? 0 : headerVarCount) {}

    int skipped() const { return m_skipped; }

    // ----- per-entity emit dispatch (DXF vs DWG) ---------------------------
    // dxfRW and dwgRW expose identical per-entity write signatures but share no
    // base class, so route through these thin helpers: drive whichever writer is
    // set. Exactly one of m_dxf / m_dwg is non-null (set by the ctor used).
    DRW::Version writerVersion() const {
        // DWG write is always R2000 (AC1015); the DXF writer carries its own.
        return m_dwg ? DRW::AC1015 : m_dxf->getVersion();
    }
    void emitPoint(DRW_Point *e)        { if (m_dwg) m_dwg->writePoint(e);     else m_dxf->writePoint(e); }
    void emitLine(DRW_Line *e)          { if (m_dwg) m_dwg->writeLine(e);      else m_dxf->writeLine(e); }
    void emitCircle(DRW_Circle *e)      { if (m_dwg) m_dwg->writeCircle(e);    else m_dxf->writeCircle(e); }
    void emitArc(DRW_Arc *e)            { if (m_dwg) m_dwg->writeArc(e);       else m_dxf->writeArc(e); }
    void emitEllipse(DRW_Ellipse *e)    { if (m_dwg) m_dwg->writeEllipse(e);   else m_dxf->writeEllipse(e); }
    void emitLWPolyline(DRW_LWPolyline *e) { if (m_dwg) m_dwg->writeLWPolyline(e); else m_dxf->writeLWPolyline(e); }
    void emitSpline(DRW_Spline *e)      { if (m_dwg) m_dwg->writeSpline(e);    else m_dxf->writeSpline(e); }
    void emitText(DRW_Text *e)          { if (m_dwg) m_dwg->writeText(e);      else m_dxf->writeText(e); }
    void emitMText(DRW_MText *e)        { if (m_dwg) m_dwg->writeMText(e);     else m_dxf->writeMText(e); }
    void emitSolid(DRW_Solid *e)        { if (m_dwg) m_dwg->writeSolid(e);     else m_dxf->writeSolid(e); }
    void emitHatch(DRW_Hatch *e)        { if (m_dwg) m_dwg->writeHatch(e);     else m_dxf->writeHatch(e); }
    void emitDimension(DRW_Dimension *e){ if (m_dwg) m_dwg->writeDimension(e); else m_dxf->writeDimension(e); }
    void emitInsert(DRW_Insert *e)      { if (m_dwg) m_dwg->writeInsert(e);    else m_dxf->writeInsert(e); }
    void emitRay(DRW_Ray *e)            { if (m_dwg) m_dwg->writeRay(e);       else m_dxf->writeRay(e); }
    void emitXline(DRW_Xline *e)        { if (m_dwg) m_dwg->writeXline(e);     else m_dxf->writeXline(e); }
    // libdxfrw's DWG writer (dwgWriter15) has no writeLeader path; DWG leaders are
    // skipped (returns false here so the caller counts the skip), DXF emits them.
    bool emitLeader(DRW_Leader *e)      { if (m_dwg) return false; m_dxf->writeLeader(e); return true; }

    // ----- attribute mapping (inverse of FlatteningReader::fillCommon) -----
    void fillCommon(DRW_Entity &ent, const LCEntity &src) {
        ent.layer    = (src.layer    && src.layer[0])    ? std::string(src.layer)    : std::string("0");
        ent.lineType = (src.lineType && src.lineType[0]) ? std::string(src.lineType) : std::string("BYLAYER");
        ent.color    = src.color;
        ent.color24  = src.color24;
        // src.lineWeightMM100 holds the DXF lineweight integer (mm*100 / sentinel
        // -1/-2/-3), exactly what dxfInt2lineWidth expects.
        ent.lWeight  = DRW_LW_Conv::dxfInt2lineWidth(src.lineWeightMM100);
        // Paper-space P1: a paper-space entity (spaceFlag == 1) gets DRW::PaperSpace,
        // which libdxfrw emits as DXF code 67 == 1 in the ENTITIES section
        // (libdxfrw.cpp:197). libdxfrw also writes a single built-in `*Paper_Space`
        // block, so a single layout's paper-space entities round-trip on stock lib.
        // Multi-layout write (one block per layout) needs a libdxfrw patch — the
        // documented follow-up. Model entities (spaceFlag == 0) are unaffected.
        ent.space = (src.spaceFlag == 1) ? DRW::PaperSpace : DRW::ModelSpace;
    }

    // ----- the table/entity callbacks libdxfrw drives during write() -------
    void writeLayers() override {
        // DWG: dwgWriter15 emits the standard R2000 LAYER table internally (the
        // fixed-handle layer "0"); it has no public per-layer write path, so the
        // caller's layer table is not authored beyond "0". No-op in DWG mode.
        if (m_dwg) return;
        bool wroteLayer0 = false;
        for (int i = 0; i < m_layerCount; ++i) {
            const LCLayer &l = m_layers[i];
            const std::string name = (l.name && l.name[0]) ? std::string(l.name) : std::string("0");
            if (name == "0") wroteLayer0 = true;
            DRW_Layer lay;          // ctor sets sane defaults
            lay.name     = name;
            lay.lineType = (l.lineType && l.lineType[0]) ? std::string(l.lineType) : std::string("CONTINUOUS");
            lay.color    = l.color;
            lay.color24  = l.color24;
            lay.lWeight  = DRW_LW_Conv::dxfInt2lineWidth(l.lineWeightMM100);
            lay.flags    = l.flags;     // bit0 frozen, bit2 locked
            lay.plotF    = (l.plot != 0);
            m_dxf->writeLayer(&lay);
        }
        // DXF requires layer "0"; synthesize it if the caller didn't supply one.
        if (!wroteLayer0) {
            DRW_Layer lay;
            lay.name = "0";
            m_dxf->writeLayer(&lay);
        }
    }

    void writeEntities() override {
        for (int i = 0; i < m_entityCount; ++i) {
            writeEntity(m_entities[i]);
        }
        // Paper-space P3: emit any VIEWPORT entities at the end of the ENTITIES
        // section (they are paper-space entities). DXF only — the DWG writer has no
        // writeViewport path, so on DWG each is skipped + counted (like leaders).
        for (int i = 0; i < m_viewportCount; ++i) {
            writeViewport(m_viewports[i]);
        }
    }

    // libdxfrw drives this once; emit the minimal standard linetypes LibreCAD
    // also writes so referencing CONTINUOUS/BYLAYER/BYBLOCK names resolve.
    // DWG: dwgWriter15 emits the standard LTYPE table (BYBLOCK/BYLAYER/
    // CONTINUOUS) internally — no-op here.
    void writeLTypes() override {
        if (m_dwg) return;
        writeStdLType("CONTINUOUS", "Solid line");
        writeStdLType("ByLayer", "");
        writeStdLType("ByBlock", "");
    }

    void writeTextstyles() override {
        // A single "Standard" text style keeps R2000 readers happy even though
        // we emit no TEXT entities yet. DWG: dwgWriter15 emits the standard
        // STANDARD text style internally — no-op here.
        if (m_dwg) return;
        DRW_Textstyle ts;
        ts.name = "Standard";
        m_dxf->writeTextstyle(&ts);
    }

    // ----- header: emit the captured drawing vars on top of libdxfrw's --------
    // libdxfrw constructs a default DRW_Header and hands it here before writing the
    // HEADER section ($ACADVER etc. are filled by DRW_Header::write itself). We add
    // the drawing's unit / linear-format / dimension vars (incl. the ext-line
    // offsets $DIMEXO/$DIMEXE/$DIMGAP) so a Save preserves them. Only fields whose
    // `has*` flag is set are written; an absent field leaves libdxfrw's default.
    // Codes: doubles=40, ints=70, strings=2 (the value is what DRW_Header::write
    // reads — the per-key DXF group code is hardcoded there, so the code arg here
    // only tags the variant's type).
    void writeHeader(DRW_Header &data) override {
        if (m_header == nullptr) return;
        const LCHeader &h = *m_header;
        if (h.hasInsUnits)  data.addInt("$INSUNITS", h.insUnits, 70);
        if (h.hasLuUnits)   data.addInt("$LUNITS",   h.luUnits,  70);
        if (h.hasLuPrec)    data.addInt("$LUPREC",   h.luPrec,   70);
        if (h.hasAuUnits)   data.addInt("$AUNITS",   h.auUnits,  70);
        if (h.hasAuPrec)    data.addInt("$AUPREC",   h.auPrec,   70);
        if (h.hasDimTxt)    data.addDouble("$DIMTXT",   h.dimTxt,   40);
        if (h.hasDimAsz)    data.addDouble("$DIMASZ",   h.dimAsz,   40);
        if (h.hasDimScale)  data.addDouble("$DIMSCALE", h.dimScale, 40);
        if (h.hasDimLUnit)  data.addInt("$DIMLUNIT", h.dimLUnit, 70);
        if (h.hasDimDec)    data.addInt("$DIMDEC",   h.dimDec,   70);
        if (h.hasDimExo)    data.addDouble("$DIMEXO", h.dimExo, 40);
        if (h.hasDimExe)    data.addDouble("$DIMEXE", h.dimExe, 40);
        if (h.hasDimGap)    data.addDouble("$DIMGAP", h.dimGap, 40);
        if (h.dimStyle != nullptr && h.dimStyle[0] != '\0')
            data.addStr("$DIMSTYLE", std::string(h.dimStyle), 2);
        // R4b: emit the GENERIC extra HEADER vars (the document-settings vars the
        // fixed POD above does not carry). Each rides into DRW_Header.vars; the 7
        // standard targets ($GRIDMODE/$GRIDUNIT/$PDMODE/$PDSIZE/$ANGBASE/$ANGDIR/
        // $PINSBASE) are in libdxfrw's curated emit list, so they write for free.
        // Coord vars ($GRIDUNIT/$PINSBASE) preserve all three components. The `code`
        // arg only tags the variant TYPE (DRW_Header::write hardcodes the per-key DXF
        // group code), so 70=int, 40=double, 10=coord are conventional placeholders.
        for (int i = 0; i < m_headerVarCount; ++i) {
            const LCHeaderVar &hv = m_headerVars[i];
            if (hv.name == nullptr || hv.name[0] == '\0') continue;
            const std::string key(hv.name);
            switch (hv.type) {
            case LC_HVAR_INT:
                data.addInt(key, static_cast<int>(hv.i), 70);
                break;
            case LC_HVAR_DOUBLE:
                data.addDouble(key, hv.d, 40);
                break;
            case LC_HVAR_COORD:
                data.addCoord(key, DRW_Coord{hv.coord[0], hv.coord[1], hv.coord[2]}, 10);
                break;
            default:
                break;
            }
        }
    }

    // ----- block records + block definitions --------------------------------
    // libdxfrw drives writeBlockRecords() during the TABLES section (it populates
    // the block-name → handle map writeBlock() needs) and writeBlocks() during the
    // BLOCKS section. We emit one BLOCK_RECORD + one BLOCK definition per caller
    // block, with the block's member entities between BLOCK and the auto-emitted
    // ENDBLK (dxfRW closes the previous block on the next writeBlock / at the end).
    void writeBlockRecords() override {
        // DWG: there is no separate block-record write step — `defineBlock`
        // (called from writeBlocks) allocates the block_record itself. No-op.
        if (m_dwg) return;
        for (int i = 0; i < m_blockCount; ++i) {
            const std::string name = blockName(m_blocks[i]);
            if (name.empty()) continue;
            m_dxf->writeBlockRecord(name);
        }
    }

    void writeBlocks() override {
        // DWG: declare each user block via `defineBlock`, capturing the returned
        // block_record handle so a later INSERT can set `blockRecH.ref` to resolve
        // the block name on re-read. dwgWriter15's defineBlock makes an EMPTY
        // block (no member-geometry path yet), so the block's member entities are
        // NOT written for DWG — the INSERT references an empty block. (DXF writes
        // the members; this is the documented DWG round-trip gap.)
        if (m_dwg) {
            for (int i = 0; i < m_blockCount; ++i) {
                const LCBlock &blk = m_blocks[i];
                const std::string name = blockName(blk);
                if (name.empty()) continue;
                const duint32 h = m_dwg->defineBlock(name, DRW_Coord{blk.bx, blk.by, blk.bz});
                if (h != 0) m_dwgBlockHandles[name] = h;
            }
            return;
        }
        for (int i = 0; i < m_blockCount; ++i) {
            const LCBlock &blk = m_blocks[i];
            const std::string name = blockName(blk);
            if (name.empty()) continue;
            DRW_Block b;
            b.name = name;
            b.basePoint.x = blk.bx; b.basePoint.y = blk.by; b.basePoint.z = blk.bz;
            b.flags = blk.flags;
            // Block ATTDEF templates → emitted inside the block by dxfRW::writeBlock.
            // DRW_Attdef derives DRW_Text whose angle is in DEGREES (radians → here).
            if (blk.attribDefs != nullptr && blk.attribDefCount > 0) {
                for (int j = 0; j < blk.attribDefCount; ++j) {
                    const LCAttrib &a = blk.attribDefs[j];
                    auto def = std::make_shared<DRW_Attdef>();
                    def->layer = std::string("0");
                    def->tag = (a.tag != nullptr) ? std::string(a.tag) : std::string();
                    def->text = (a.text != nullptr) ? std::string(a.text) : std::string();
                    def->prompt = (a.prompt != nullptr) ? std::string(a.prompt) : std::string();
                    def->basePoint.x = a.x;
                    def->basePoint.y = a.y;
                    def->basePoint.z = 0.0;
                    def->height = a.height;
                    def->angle = a.rotation * 180.0 / M_PI;   // radians → degrees
                    def->attribFlags = static_cast<duint8>(a.flags);
                    b.attdefs.push_back(def);
                }
            }
            m_dxf->writeBlock(&b);
            // Member entities (the block's geometry), windowed into blockEntities.
            const int start = blk.memberOffset;
            const int count = blk.memberCount;
            if (m_blockEntities != nullptr && start >= 0 && count > 0 &&
                start + count <= m_blockEntityCount) {
                for (int j = 0; j < count; ++j) {
                    writeEntity(m_blockEntities[start + j]);
                }
            }
        }
    }

    // ----- DIMSTYLE table ---------------------------------------------------
    // libdxfrw drives writeDimstyles() inside the TABLES section; we emit one
    // DRW_Dimstyle per caller style (mapping the renderer subset back onto the
    // DRW_Dimstyle fields — the inverse of FlatteningReader::addDimStyle). If a
    // "Standard" entry is among them, libdxfrw sees `dimstyleStd` set and does not
    // append its own default; otherwise it adds a Standard for us. DWG: dwgWriter15
    // emits the standard DIMSTYLE table internally and has no per-style write path,
    // so this is a no-op for DWG (the documented DWG table gap, like writeLayers).
    void writeDimstyles() override {
        if (m_dwg) return;
        if (m_dimStyles == nullptr) return;
        for (int i = 0; i < m_dimStyleCount; ++i) {
            const LCDimStyle &s = m_dimStyles[i];
            DRW_Dimstyle dsty;          // ctor seeds the imperial-standard defaults
            dsty.name    = (s.name && s.name[0]) ? std::string(s.name) : std::string("Standard");
            if (s.dimTxt   > 0) dsty.dimtxt   = s.dimTxt;
            if (s.dimAsz   > 0) dsty.dimasz   = s.dimAsz;
            if (s.dimScale > 0) dsty.dimscale = s.dimScale;
            dsty.dimdec   = s.dimDec;
            if (s.dimLUnit > 0) dsty.dimlunit = s.dimLUnit;
            // Ext-line offsets: write whatever the style carries (0 is a legal
            // "snug" value, so do not gate these on > 0).
            dsty.dimexo = s.dimExo;
            dsty.dimexe = s.dimExe;
            dsty.dimgap = s.dimGap;
            m_dxf->writeDimstyle(&dsty);
        }
    }

    // ----- required no-ops --------------------------------------------------
    void writeVports() override {}
    void writeObjects() override {}
    void writeAppId() override {}

    // ----- read callbacks: never called during write; required to be defined -
    void addHeader(const DRW_Header *data) override { (void)data; }
    void addLType(const DRW_LType &data) override { (void)data; }
    void addLayer(const DRW_Layer &data) override { (void)data; }
    void addDimStyle(const DRW_Dimstyle &data) override { (void)data; }
    void addVport(const DRW_Vport &data) override { (void)data; }
    void addTextStyle(const DRW_Textstyle &data) override { (void)data; }
    void addAppId(const DRW_AppId &data) override { (void)data; }
    void addBlock(const DRW_Block &data) override { (void)data; }
    void setBlock(const int handle) override { (void)handle; }
    void endBlock() override {}
    void addPoint(const DRW_Point &data) override { (void)data; }
    void addLine(const DRW_Line &data) override { (void)data; }
    void addRay(const DRW_Ray &data) override { (void)data; }
    void addXline(const DRW_Xline &data) override { (void)data; }
    void addArc(const DRW_Arc &data) override { (void)data; }
    void addCircle(const DRW_Circle &data) override { (void)data; }
    void addEllipse(const DRW_Ellipse &data) override { (void)data; }
    void addLWPolyline(const DRW_LWPolyline &data) override { (void)data; }
    void addPolyline(const DRW_Polyline &data) override { (void)data; }
    void addSpline(const DRW_Spline *data) override { (void)data; }
    void addKnot(const DRW_Entity &data) override { (void)data; }
    void addInsert(const DRW_Insert &data) override { (void)data; }
    void addTrace(const DRW_Trace &data) override { (void)data; }
    void add3dFace(const DRW_3Dface &data) override { (void)data; }
    void addSolid(const DRW_Solid &data) override { (void)data; }
    void addMText(const DRW_MText &data) override { (void)data; }
    void addText(const DRW_Text &data) override { (void)data; }
    void addDimAlign(const DRW_DimAligned *data) override { (void)data; }
    void addDimLinear(const DRW_DimLinear *data) override { (void)data; }
    void addDimRadial(const DRW_DimRadial *data) override { (void)data; }
    void addDimDiametric(const DRW_DimDiametric *data) override { (void)data; }
    void addDimAngular(const DRW_DimAngular *data) override { (void)data; }
    void addDimAngular3P(const DRW_DimAngular3p *data) override { (void)data; }
    void addDimOrdinate(const DRW_DimOrdinate *data) override { (void)data; }
    void addLeader(const DRW_Leader *data) override { (void)data; }
    void addHatch(const DRW_Hatch *data) override { (void)data; }
    void addViewport(const DRW_Viewport &data) override { (void)data; }
    void addImage(const DRW_Image *data) override { (void)data; }
    void linkImage(const DRW_ImageDef *data) override { (void)data; }
    void addComment(const char *comment) override { (void)comment; }
    void addPlotSettings(const DRW_PlotSettings *data) override { (void)data; }

private:
    // Exactly one of these is set (by the matching ctor): DXF -> m_dxf, DWG ->
    // m_dwg. The emit*/table callbacks branch on whether m_dwg is non-null.
    dxfRW *m_dxf = nullptr;
    dwgRW *m_dwg = nullptr;
    const LCEntity *m_entities;
    int m_entityCount;
    const LCLayer *m_layers;
    int m_layerCount;
    const LCBlock *m_blocks;
    int m_blockCount;
    const LCEntity *m_blockEntities;
    int m_blockEntityCount;
    // The drawing HEADER vars + DIMSTYLE table to emit (both optional / NULL).
    const LCHeader *m_header = nullptr;
    const LCDimStyle *m_dimStyles = nullptr;
    int m_dimStyleCount = 0;
    // R4b: generic extra HEADER vars to emit verbatim (optional / NULL).
    const LCHeaderVar *m_headerVars = nullptr;
    int m_headerVarCount = 0;
    // Paper-space VIEWPORT entities to emit (paper-space P3; optional / NULL).
    const LCViewport *m_viewports = nullptr;
    int m_viewportCount = 0;
    int m_skipped = 0;

    // DWG-only: block name -> block_record handle from `dwgRW::defineBlock`, so a
    // later INSERT sets `blockRecH.ref` to resolve the block name on re-read.
    std::map<std::string, duint32> m_dwgBlockHandles;

    // The block's name, or "" if unnamed/null (such a block is skipped).
    static std::string blockName(const LCBlock &b) {
        return (b.name && b.name[0]) ? std::string(b.name) : std::string();
    }

    void writeStdLType(const char *name, const char *desc) {
        DRW_LType lt;
        lt.name = name;
        lt.desc = desc;
        lt.size = 0;
        lt.length = 0.0;
        m_dxf->writeLineType(&lt);
    }

    // Dispatch one POD entity to the matching writer. Unsupported kinds are
    // counted and skipped (mirrors the reader's unsupported-warning path).
    void writeEntity(const LCEntity &e) {
        switch (e.kind) {
        case LC_ENT_LINE:       writeLine(e);       break;
        case LC_ENT_POINT:      writePoint(e);      break;
        case LC_ENT_CIRCLE:     writeCircle(e);     break;
        case LC_ENT_ARC:        writeArc(e);        break;
        case LC_ENT_ELLIPSE:    writeEllipse(e);    break;
        case LC_ENT_LWPOLYLINE: writeLWPolyline(e); break;
        case LC_ENT_POLYLINE:   writeLWPolyline(e); break; // emit as LWPOLYLINE
        case LC_ENT_SPLINE:     writeSpline(e);     break;
        case LC_ENT_TEXT:       writeText(e);       break;
        case LC_ENT_MTEXT:      writeMText(e);      break;
        case LC_ENT_SOLID:      writeSolid(e);      break;
        case LC_ENT_HATCH:      writeHatch(e);      break;
        case LC_ENT_DIMENSION:  writeDimension(e);  break;
        case LC_ENT_INSERT:     writeInsert(e);     break;
        case LC_ENT_XLINE:      writeXline(e);      break;
        case LC_ENT_RAY:        writeRay(e);        break;
        case LC_ENT_LEADER:     writeLeader(e);     break;
        case LC_ENT_IMAGE:      writeImage(e);      break;
        default:                ++m_skipped;        break; // UNSUPPORTED / ...
        }
    }

    // ----- XLINE / RAY (construction lines) ------------------------------
    // Emit a DXF XLINE / RAY (the inverse of FlatteningReader::addXline/addRay).
    // p1 -> basePoint (code 10); p2 -> secPoint (code 11), the direction. libdxfrw
    // unitizes the direction on write, so a re-read yields a unit direction (the
    // engine's resolve normalizes regardless).
    void writeXline(const LCEntity &e) {
        DRW_Xline x;
        fillCommon(x, e);
        x.basePoint.x = e.p1x; x.basePoint.y = e.p1y; x.basePoint.z = e.p1z;
        x.secPoint.x  = e.p2x; x.secPoint.y  = e.p2y; x.secPoint.z  = e.p2z;
        emitXline(&x);
    }

    void writeRay(const LCEntity &e) {
        DRW_Ray r;
        fillCommon(r, e);
        r.basePoint.x = e.p1x; r.basePoint.y = e.p1y; r.basePoint.z = e.p1z;
        r.secPoint.x  = e.p2x; r.secPoint.y  = e.p2y; r.secPoint.z  = e.p2z;
        emitRay(&r);
    }

    // ----- LEADER (annotation callout) -----------------------------------
    // Emit a DXF LEADER (the inverse of FlatteningReader::emitLeader). The path
    // vertices, the arrow flag (code 71), and the annotation text height (code 40)
    // map onto DRW_Leader; the dim-style name (code 3) round-trips. The engine's
    // inline annotation entity is NOT emitted here (it round-trips via Codable, and
    // libdxfrw's writeLeader itself writes only path+arrow+height). DXF LEADER needs
    // R2000+; the DWG writer has no leader path, so on DWG it is skipped + counted
    // (emitLeader returns false). The path's vertices come from the flat array.
    void writeLeader(const LCEntity &e) {
        DRW_Leader ld;
        fillCommon(ld, e);
        ld.arrow = e.leaderHasArrow ? 1 : 0;
        ld.textheight = e.height;
        if (e.styleName && e.styleName[0]) ld.style = std::string(e.styleName);
        else ld.style = std::string("Standard");
        for (int i = 0; i < e.vertexCount; ++i) {
            ld.vertexlist.push_back(
                std::make_shared<DRW_Coord>(e.vertices[i].x, e.vertices[i].y, 0.0));
        }
        ld.vertnum = static_cast<int>(ld.vertexlist.size());
        if (!emitLeader(&ld)) ++m_skipped;   // DWG has no leader writer
    }

    // ----- IMAGE (raster image) ------------------------------------------
    // Emit a DXF IMAGE + its IMAGEDEF via dxfRW::writeImage(ent, name). That helper
    // creates (or reuses) the IMAGEDEF object, wires the IMAGEDEF_REACTOR, and emits
    // the IMAGE entity + group 340 hard reference for us; we set the DRW_Image's
    // insertion (basePoint, code 10), per-pixel U vector (secPoint, code 11), V
    // vector (code 12), pixel size (sizeu/sizev, codes 13/23), and display ints
    // (clip/brightness/contrast/fade, codes 280–283). The IMAGEDEF's pixel size
    // (codes 10/20) is set on the returned DRW_ImageDef* AFTER the call (writeImage
    // leaves it at 0; the IMAGEDEF is written later in writeObjects, so the values
    // persist). The bitmap is NEVER embedded — only the file PATH is linked, exactly
    // as AutoCAD/LibreCAD store a raster image.
    //
    // Scope: IMAGE needs R2000+ (dxfRW::writeImage returns NULL at AC1009) and the
    // DWG writer (dwgRW) has NO writeImage path — both cases are skipped + counted,
    // matching the MTEXT/DIMENSION/LEADER R12/DWG gaps. The polygon clip boundary
    // (clipPath) is NOT emitted (the engine does not yet model clipping).
    void writeImage(const LCEntity &e) {
        // No DXF writer (DWG mode) or pre-R2000 → IMAGE is unsupported here. Count it.
        if (m_dwg != nullptr || writerVersion() <= DRW::AC1009) { ++m_skipped; return; }
        const std::string name = (e.textValue && e.textValue[0]) ? std::string(e.textValue)
                                                                 : std::string();
        DRW_Image img;
        fillCommon(img, e);
        img.basePoint.x = e.p1x; img.basePoint.y = e.p1y; img.basePoint.z = e.p1z;
        img.secPoint.x  = e.p2x; img.secPoint.y  = e.p2y; img.secPoint.z  = e.p2z;
        img.vVector.x = e.imgVVecX; img.vVector.y = e.imgVVecY; img.vVector.z = e.imgVVecZ;
        img.sizeu = e.imgSizeU;
        img.sizev = e.imgSizeV;
        img.clip = e.imgClip;
        img.brightness = e.imgBrightness;
        img.contrast = e.imgContrast;
        img.fade = e.imgFade;
        DRW_ImageDef *def = m_dxf->writeImage(&img, name);
        if (def == nullptr) { ++m_skipped; return; }   // NULL only at <R2000 (guarded above)
        // Carry the pixel size into the IMAGEDEF (written in writeObjects).
        if (e.imgSizeU > 0) def->u = e.imgSizeU;
        if (e.imgSizeV > 0) def->v = e.imgSizeV;
    }

    // ----- VIEWPORT (paper-space window) ---------------------------------
    // Emit a DXF VIEWPORT (DRW_Viewport) via dxfRW::writeViewport. The paper frame
    // center -> basePoint (codes 10/20); the frame size -> pswidth/psheight (40/41);
    // the model view center -> centerPX/PY (12/22); the model view height -> code 45.
    // vpID/vpStatus are forced > 1 so a re-read treats it as a REAL viewport (the
    // reader skips the overview viewport vpID<=1). The viewport is marked paper-space
    // (DXF code 67 == 1) so it lands in paper space. DXF only — dwgWriter15 has no
    // writeViewport path, so on DWG it is skipped + counted (like a leader/image).
    void writeViewport(const LCViewport &v) {
        if (m_dwg != nullptr) { ++m_skipped; return; }   // DWG: no viewport writer.
        DRW_Viewport vp;
        // Mark the entity paper-space (code 67 == 1) + layer "0" by default.
        vp.space = DRW::PaperSpace;
        vp.layer = std::string("0");
        vp.lineType = std::string("BYLAYER");
        vp.basePoint.x = v.centerX;
        vp.basePoint.y = v.centerY;
        vp.basePoint.z = 0.0;
        vp.pswidth = v.width;
        vp.psheight = v.height;
        vp.centerPX = v.viewCenterX;
        vp.centerPY = v.viewCenterY;
        vp.viewHeight = v.viewHeight;
        // Force real-viewport id/status so the round-trip read keeps it (the reader
        // skips vpID <= 1 as the AutoCAD overview viewport).
        vp.vpID = (v.vpID > 1) ? v.vpID : 2;
        vp.vpstatus = (v.vpStatus > 1) ? v.vpStatus : 2;
        m_dxf->writeViewport(&vp);
    }

    // ----- INSERT (block reference) --------------------------------------
    // Emit a DXF INSERT/MINSERT (the inverse of FlatteningReader::addInsert). The
    // POD carries the block name (textValue), insertion point (p1), per-axis scale,
    // rotation (radians; DRW_Insert::angle is radians, libdxfrw converts to degrees
    // on write), and the MINSERT array (counts + spacing). A missing block name is
    // skipped (an INSERT with no block is meaningless).
    void writeInsert(const LCEntity &e) {
        if (!(e.textValue && e.textValue[0])) { ++m_skipped; return; }
        DRW_Insert ins;
        fillCommon(ins, e);
        ins.name = std::string(e.textValue);
        ins.basePoint.x = e.p1x; ins.basePoint.y = e.p1y; ins.basePoint.z = e.p1z;
        ins.xscale = e.insScaleX;
        ins.yscale = e.insScaleY;
        ins.zscale = e.insScaleZ;
        ins.angle = e.startAngle;   // radians; libdxfrw scales to degrees on write
        ins.colcount = e.insCols > 0 ? e.insCols : 1;
        ins.rowcount = e.insRows > 0 ? e.insRows : 1;
        ins.colspace = e.insColSpacing;
        ins.rowspace = e.insRowSpacing;
        // Block ATTRIB values → DRW_Insert::attlist (code 66 + ATTRIB sub-entities +
        // SEQEND emitted by dxfRW::writeInsert). DRW_Attrib derives DRW_Text whose
        // angle is in DEGREES, so convert from the engine's radians here. DXF only:
        // the DWG writer makes empty blocks and does not emit attributes (documented
        // gap). Each ATTRIB inherits the INSERT's layer so the record is well-formed.
        if (!m_dwg && e.attribs != nullptr && e.attribCount > 0) {
            for (int i = 0; i < e.attribCount; ++i) {
                const LCAttrib &a = e.attribs[i];
                auto att = std::make_shared<DRW_Attrib>();
                att->layer = ins.layer;
                att->tag = (a.tag != nullptr) ? std::string(a.tag) : std::string();
                att->text = (a.text != nullptr) ? std::string(a.text) : std::string();
                att->basePoint.x = a.x;
                att->basePoint.y = a.y;
                att->basePoint.z = 0.0;
                att->height = a.height;
                att->angle = a.rotation * 180.0 / M_PI;   // radians → degrees
                att->attribFlags = static_cast<duint8>(a.flags);
                ins.attlist.push_back(att);
            }
        }
        // DWG: resolve the block name to the block_record handle captured in
        // writeBlocks (defineBlock). dwgWriter15 encodes INSERT by `blockRecH.ref`,
        // not by name; without this the INSERT can't reference its block on re-read.
        if (m_dwg) {
            auto it = m_dwgBlockHandles.find(ins.name);
            if (it == m_dwgBlockHandles.end()) { ++m_skipped; return; }
            ins.blockRecH.ref = it->second;
        }
        emitInsert(&ins);
    }

    void writePoint(const LCEntity &e) {
        DRW_Point p;
        fillCommon(p, e);
        p.basePoint.x = e.p1x; p.basePoint.y = e.p1y; p.basePoint.z = e.p1z;
        emitPoint(&p);
    }

    void writeLine(const LCEntity &e) {
        DRW_Line l;
        fillCommon(l, e);
        l.basePoint.x = e.p1x; l.basePoint.y = e.p1y; l.basePoint.z = e.p1z;
        l.secPoint.x  = e.p2x; l.secPoint.y  = e.p2y; l.secPoint.z  = e.p2z;
        emitLine(&l);
    }

    void writeCircle(const LCEntity &e) {
        DRW_Circle c;
        fillCommon(c, e);
        c.basePoint.x = e.cx; c.basePoint.y = e.cy; c.basePoint.z = e.cz;
        c.radious = e.radius;
        emitCircle(&c);
    }

    void writeArc(const LCEntity &e) {
        DRW_Arc a;
        fillCommon(a, e);
        a.basePoint.x = e.cx; a.basePoint.y = e.cy; a.basePoint.z = e.cz;
        a.radious  = e.radius;
        a.staangle = e.startAngle;   // POD already carries CCW start/end
        a.endangle = e.endAngle;
        emitArc(&a);
    }

    void writeEllipse(const LCEntity &e) {
        DRW_Ellipse el;
        fillCommon(el, e);
        el.basePoint.x = e.cx;  el.basePoint.y = e.cy;  el.basePoint.z = e.cz;
        el.secPoint.x  = e.p2x; el.secPoint.y  = e.p2y; el.secPoint.z  = e.p2z;
        el.ratio    = e.ratio;
        el.staparam = e.startAngle;
        el.endparam = e.endAngle;
        emitEllipse(&el);
    }

    void writeLWPolyline(const LCEntity &e) {
        DRW_LWPolyline pol;
        fillCommon(pol, e);
        pol.flags = (e.closed != 0) ? 1 : 0;
        if (e.vertexCount > 0 && e.vertices != nullptr) {
            for (int i = 0; i < e.vertexCount; ++i) {
                const LCVertex &v = e.vertices[i];
                pol.addVertex(DRW_Vertex2D(v.x, v.y, v.bulge));
            }
        }
        pol.vertexnum = static_cast<int>(pol.vertlist.size());
        emitLWPolyline(&pol);
    }

    // ----- SPLINE --------------------------------------------------------
    // Emit a DXF SPLINE (the inverse of FlatteningReader::addSpline). The POD
    // carries the degree, the control polygon in `vertices`, the (optional) knot
    // and rational-weight vectors, the raw code-70 flags in `splineFlags`, and —
    // for a fit-point/interpolation spline (`.splinePoints`) — its on-curve
    // interpolation points in `fitPoints`. We set DRW_Spline's nknots/ncontrol/
    // nfit counts ourselves because libdxfrw's writeSpline loops on those (not on
    // the list sizes). Mirrors rs_filterdxfrw.cpp::writeSpline /
    // writeSplinePoints. SPLINE only exists for R2000+; at R12 libdxfrw's
    // writeSpline is a no-op, so the entity is dropped — count it as skipped so
    // the written/skipped tally stays honest (matches MTEXT/HATCH/DIMENSION).
    void writeSpline(const LCEntity &e) {
        if (writerVersion() <= DRW::AC1009) {
            ++m_skipped;
            return;
        }
        const int ncontrol = (e.vertices != nullptr && e.vertexCount > 0) ? e.vertexCount : 0;
        // A spline needs at least degree+1 control points to be valid; drop a
        // degenerate one (matches the reader rejecting it on read).
        if (e.degree < 1 || ncontrol < e.degree + 1) {
            ++m_skipped;
            return;
        }
        DRW_Spline sp{};
        fillCommon(sp, e);
        sp.degree = e.degree;

        // code-70 bit flags: 1 closed, 2 periodic, 4 rational, 8 planar, 16 linear.
        // Prefer the preserved raw flags (a faithful re-write of a read spline);
        // otherwise derive a sane default — planar, plus closed+periodic when the
        // `closed` flag is set (mirrors rs_filterdxfrw.cpp::writeSpline's
        // 0b1011 / 0b1000).
        sp.flags = (e.splineFlags != 0) ? e.splineFlags
                                        : ((e.closed != 0) ? 0b1011 : 0b1000);

        // Control points (code 10/20/30).
        for (int i = 0; i < ncontrol; ++i) {
            const LCVertex &v = e.vertices[i];
            sp.controllist.push_back(std::make_shared<DRW_Coord>(v.x, v.y, 0.0));
        }
        sp.ncontrol = ncontrol;

        // Rational weights (code 41), only when they cover every control point.
        if (e.weights != nullptr && e.weightCount == ncontrol) {
            sp.weightlist.assign(e.weights, e.weights + e.weightCount);
        }

        // Knot vector (code 40). Use the supplied one if present; otherwise leave
        // it empty (a downstream reader / our NURBS evaluator generates a clamped
        // uniform vector from degree + control-point count).
        if (e.knots != nullptr && e.knotCount > 0) {
            sp.knotslist.assign(e.knots, e.knots + e.knotCount);
        }
        sp.nknots = static_cast<dint32>(sp.knotslist.size());

        // Fit points (code 11/21) for an interpolation spline (`.splinePoints`).
        if (e.fitPoints != nullptr && e.fitPointCount > 0) {
            for (int i = 0; i < e.fitPointCount; ++i) {
                const LCVertex &v = e.fitPoints[i];
                sp.fitlist.push_back(std::make_shared<DRW_Coord>(v.x, v.y, 0.0));
            }
        }
        sp.nfit = static_cast<dint32>(sp.fitlist.size());

        emitSpline(&sp);
    }

    // ----- TEXT ----------------------------------------------------------
    // Emit a single-line DXF TEXT (the inverse of FlatteningReader::addText).
    // The POD carries a single insertion point plus the 72/73 alignment codes,
    // which DRW_Text round-trips exactly; MTEXT (which uses attachment codes
    // rather than 72/73) would lose that alignment, so a POD TEXT — whether it
    // came from a DXF TEXT or MTEXT on read — is written back as TEXT. We mirror
    // the insertion point into BOTH basePoint and secPoint: libdxfrw's writeText
    // only emits group 11/21 (which the reader prefers for aligned text) when the
    // alignment is non-default, so writing both keeps the insertion correct for
    // every alignment without branching here.
    void writeText(const LCEntity &e) {
        DRW_Text t;
        fillCommon(t, e);
        t.basePoint.x = e.p1x; t.basePoint.y = e.p1y; t.basePoint.z = e.p1z;
        t.secPoint.x  = e.p1x; t.secPoint.y  = e.p1y; t.secPoint.z  = e.p1z;
        t.height = e.height;
        t.text   = (e.textValue && e.textValue[0]) ? std::string(e.textValue) : std::string();
        t.angle  = e.startAngle * 180.0 / M_PI;   // radians -> DXF degrees
        t.style  = (e.styleName && e.styleName[0]) ? std::string(e.styleName) : std::string("STANDARD");
        t.alignH = static_cast<DRW_Text::HAlign>(e.hAlign);
        t.alignV = static_cast<DRW_Text::VAlign>(e.vAlign);
        emitText(&t);
    }

    // ----- MTEXT ---------------------------------------------------------
    // Emit a DXF MTEXT (the inverse of FlatteningReader::addMText). DRW_MText
    // derives from DRW_Text and adds `interlin` (code 44). The POD carries the
    // RAW inline-coded string in `textValue` (group 1/3 — Swift re-emits either
    // the preserved raw code or a reconstruction of the run tree, so this side
    // stays format-agnostic), the insertion point (10/20/30), height (40),
    // reference/wrap width (41 -> widthscale), attachment point (71 -> textgen),
    // rotation (radians -> code 50 degrees), line-spacing style (73 -> alignV,
    // 1 at-least / 2 exact) and line-spacing factor (44 -> interlin), plus the
    // style name (7). libdxfrw's writeMText is a no-op for AC1009 (R12 has no
    // MTEXT), so at that version the entity is dropped; count it as skipped so
    // the caller's written/skipped tally is honest (matches the HATCH/R12 note).
    void writeMText(const LCEntity &e) {
        if (writerVersion() <= DRW::AC1009) {
            ++m_skipped;
            return;
        }
        DRW_MText t;
        fillCommon(t, e);
        t.basePoint.x = e.p1x; t.basePoint.y = e.p1y; t.basePoint.z = e.p1z;
        t.height = e.height;
        t.text   = (e.textValue && e.textValue[0]) ? std::string(e.textValue) : std::string();
        t.widthscale = e.mtextRectWidth;            // code 41: reference/wrap width
        t.angle  = e.startAngle * 180.0 / M_PI;     // radians -> DXF degrees
        t.style  = (e.styleName && e.styleName[0]) ? std::string(e.styleName) : std::string("STANDARD");
        // Attachment point (code 71): DRW_MText keeps it in `textgen`. Clamp to the
        // valid 1..9 (TopLeft..BottomRight) range; default TopLeft.
        t.textgen = (e.mtextAttachment >= 1 && e.mtextAttachment <= 9)
                        ? e.mtextAttachment : DRW_MText::TopLeft;
        // Line-spacing style (code 73) lives in alignV for MTEXT (1 at-least, 2 exact);
        // the line-spacing factor (code 44) in interlin.
        t.alignV = (e.mtextLineSpacingStyle == 2)
                       ? static_cast<DRW_Text::VAlign>(2)
                       : static_cast<DRW_Text::VAlign>(1);
        t.interlin = (e.mtextLineSpacingFactor > 0) ? e.mtextLineSpacingFactor : 1.0;
        emitMText(&t);
    }

    // ----- SOLID ---------------------------------------------------------
    // Emit a DXF SOLID (the inverse of FlatteningReader::emitSolid). The POD
    // stores its 3-4 corners in RING order; DXF orders a quad's 3rd/4th corner
    // "bow-tie" (3 and 4 swapped relative to a ring), so re-apply that swap when
    // mapping ring -> DXF: base=ring0, sec=ring1, third=ring3, four=ring2. A
    // triangle (3 corners) stores third==four. A degenerate (<3 corner) solid is
    // skipped (counted), matching the reader dropping it on read.
    void writeSolid(const LCEntity &e) {
        if (e.vertexCount < 3 || e.vertices == nullptr) {
            ++m_skipped;
            return;
        }
        DRW_Solid s;
        fillCommon(s, e);
        const LCVertex &r0 = e.vertices[0];
        const LCVertex &r1 = e.vertices[1];
        const LCVertex &r2 = e.vertices[2];
        s.basePoint.x  = r0.x; s.basePoint.y  = r0.y; s.basePoint.z  = 0.0;
        s.secPoint.x   = r1.x; s.secPoint.y   = r1.y; s.secPoint.z   = 0.0;
        if (e.vertexCount >= 4) {
            const LCVertex &r3 = e.vertices[3];
            // ring [r0,r1,r2,r3] -> DXF base/sec/third/four = r0,r1,r3,r2
            s.thirdPoint.x = r3.x; s.thirdPoint.y = r3.y; s.thirdPoint.z = 0.0;
            s.fourPoint.x  = r2.x; s.fourPoint.y  = r2.y; s.fourPoint.z  = 0.0;
        } else {
            // triangle: DXF stores third == four (the reader collapses it back).
            s.thirdPoint.x = r2.x; s.thirdPoint.y = r2.y; s.thirdPoint.z = 0.0;
            s.fourPoint.x  = r2.x; s.fourPoint.y  = r2.y; s.fourPoint.z  = 0.0;
        }
        emitSolid(&s);
    }

    // Append a single ARC edge to a hatch boundary loop for a bulged segment
    // a->b. DXF bulge = tan(includedAngle/4): positive bulges LEFT of the
    // directed chord (CCW), negative RIGHT (CW). We recover the arc center,
    // radius and start/end angles from the chord + bulge (the inverse of the
    // bulge expansion in Resolve.expandPolyline) and emit a DRW_Arc edge so the
    // curved boundary round-trips as a true arc rather than a chord. `isccw` is
    // set from the bulge sign so the read-back sweep matches.
    static void appendBulgeArcEdge(DRW_HatchLoop &hl,
                                   double ax, double ay, double bx, double by,
                                   double bulge) {
        const double included = 4.0 * std::atan(bulge);   // signed sweep
        const double cdx = bx - ax, cdy = by - ay;
        const double chordLen = std::sqrt(cdx * cdx + cdy * cdy);
        if (chordLen < 1e-12) {
            auto edge = std::make_shared<DRW_Line>();
            edge->basePoint.x = ax; edge->basePoint.y = ay; edge->basePoint.z = 0.0;
            edge->secPoint.x  = bx; edge->secPoint.y  = by; edge->secPoint.z  = 0.0;
            hl.objlist.push_back(edge);
            return;
        }
        const double radius = std::fabs(chordLen / (2.0 * std::sin(included / 2.0)));
        const double mx = (ax + bx) * 0.5, my = (ay + by) * 0.5;
        const double half = chordLen * 0.5;
        const double apothem = std::sqrt(std::max(0.0, radius * radius - half * half));
        const double dirx = cdx / chordLen, diry = cdy / chordLen;
        const double lnx = -diry, lny = dirx;                 // left normal
        const double apexSide = (bulge >= 0.0) ? 1.0 : -1.0;
        const double centerSign = -std::copysign(1.0, std::cos(included / 2.0));
        const double off = apexSide * centerSign * apothem;
        const double ccx = mx + lnx * off, ccy = my + lny * off;
        const double staang = std::atan2(ay - ccy, ax - ccx);
        const double endang = std::atan2(by - ccy, bx - ccx);

        auto arc = std::make_shared<DRW_Arc>();
        arc->basePoint.x = ccx; arc->basePoint.y = ccy; arc->basePoint.z = 0.0;
        arc->radious = radius;
        // The read-back tessellation walks staangle -> endangle in the `isccw`
        // direction, so keep staangle at a's angle and endangle at b's angle (the
        // a->b traversal order of the loop). The signed angular sweep around the
        // center is -included (matches Resolve.expandPolyline); a non-negative
        // sweep is CCW. included shares bulge's sign, so isccw == (bulge <= 0).
        arc->staangle = staang;
        arc->endangle = endang;
        arc->isccw = (bulge <= 0.0) ? 1 : 0;
        hl.objlist.push_back(arc);
    }

    // ----- HATCH ---------------------------------------------------------
    // Emit a DXF HATCH (the inverse of FlatteningReader::emitHatch). Each POD
    // loop is a ring of vertices; we emit it as an EDGE boundary: a straight
    // DRW_Line for a zero-bulge segment, a DRW_Arc for a bulged one (so a curved
    // boundary round-trips as a true arc). libdxfrw's writeHatch only supports
    // edge boundaries (its polyline-boundary branch is an unimplemented stub).
    // On read, readHatchLoop picks up each LINE edge's basePoint as a plain vertex
    // and recovers each ARC edge as a SINGLE bulged vertex (the exact inverse of
    // appendBulgeArcEdge, see appendBulgeArcVertex), so a bulged boundary
    // round-trips losslessly — both the arc geometry AND the DXF bulge encoding.
    // solidFill, the pattern name and the pattern
    // scale/angle (codes 41/52) round-trip. HATCH only exists for R2000+; for
    // R12 writeHatch is a no-op in libdxfrw, so the entity is silently dropped at
    // that version (rare export).
    void writeHatch(const LCEntity &e) {
        DRW_Hatch h;
        fillCommon(h, e);
        h.solid = (e.solidFill != 0) ? 1 : 0;
        h.hpattern = h.solid;   // pattern-fill flag follows solid (1 solid, 0 pattern)
        h.name = (e.textValue && e.textValue[0]) ? std::string(e.textValue)
                                                 : std::string(h.solid ? "SOLID" : "ANSI31");
        // Pattern scale (code 41) + angle (code 52). libdxfrw writes these only for a
        // PATTERN hatch (!solid); angle is emitted in DXF degrees, so convert back.
        h.scale = (e.hatchScale != 0.0) ? e.hatchScale : 1.0;
        h.angle = e.hatchAngle * 180.0 / M_PI;

        if (e.loopCount > 0 && e.loops != nullptr &&
            e.vertexCount > 0 && e.vertices != nullptr) {
            for (int li = 0; li < e.loopCount; ++li) {
                const LCLoop &loop = e.loops[li];
                const int start = loop.offset;
                const int count = loop.count;
                if (start < 0 || count < 2 || start + count > e.vertexCount) continue;
                // Edge boundary (type 0, not the polyline bit 2): a chain of edges
                // closing back to the first vertex. A vertex with a nonzero bulge
                // (DXF tan(includedAngle/4) of the edge that FOLLOWS it) becomes an
                // ARC edge so a curved boundary round-trips as a real arc, not a
                // chord; a zero-bulge vertex becomes a straight LINE edge.
                auto hl = std::make_shared<DRW_HatchLoop>(0);
                for (int j = 0; j < count; ++j) {
                    const LCVertex &a = e.vertices[start + j];
                    const LCVertex &b = e.vertices[start + ((j + 1) % count)];
                    if (std::fabs(a.bulge) > 1e-12) {
                        appendBulgeArcEdge(*hl, a.x, a.y, b.x, b.y, a.bulge);
                    } else {
                        auto edge = std::make_shared<DRW_Line>();
                        edge->basePoint.x = a.x; edge->basePoint.y = a.y; edge->basePoint.z = 0.0;
                        edge->secPoint.x  = b.x; edge->secPoint.y  = b.y; edge->secPoint.z  = 0.0;
                        hl->objlist.push_back(edge);
                    }
                }
                hl->update();
                h.appendLoop(hl);
            }
        }
        h.loopsnum = static_cast<int>(h.looplist.size());
        emitHatch(&h);
    }

    // ----- DIMENSION -----------------------------------------------------
    // Emit a DXF DIMENSION (the inverse of FlatteningReader's emitDim*). We build
    // the matching DRW_Dim* subclass (dxfRW::writeDimension dispatches on eType)
    // and set the shared base fields + the per-variant defining points. The
    // DIMENSION's rendered geometry normally lives in an associated anonymous
    // *block* (code 2); we do NOT author that block — we leave the block name
    // empty, so libdxfrw writes the DIMENSION with no `2` reference (its
    // writeDimension only emits code 2 when the name is non-empty) and forces the
    // type-70 "named block" bit (|32) itself. A real CAD app regenerates the block
    // on open; our own reader + resolve() regenerate the visual, so the entity's
    // definition alone is a faithful, lossless round-trip. DIMENSION (like MTEXT)
    // only exists for R2000+; at R12 dxfRW::writeDimension is a no-op, so the
    // entity is dropped — count it as skipped so the tally stays honest.
    void writeDimension(const LCEntity &e) {
        if (writerVersion() <= DRW::AC1009) {
            ++m_skipped;
            return;
        }
        const DRW_Coord def{e.p1x, e.p1y, e.p1z};
        const DRW_Coord def1{e.dimDef1x, e.dimDef1y, e.dimDef1z};
        const DRW_Coord def2{e.dimDef2x, e.dimDef2y, e.dimDef2z};
        const DRW_Coord def5{e.dimDef5x, e.dimDef5y, e.dimDef5z};
        const DRW_Coord arc{e.dimArcx, e.dimArcy, e.dimArcz};

        // Build the shared base into a DRW_Dimension, then copy-construct the
        // concrete subtype from it (the DRW_Dim* copy ctors take a DRW_Dimension).
        DRW_Dimension base;
        fillCommon(base, e);
        base.setDefPoint(def);
        if (e.dimHasText) {
            base.setTextPoint(DRW_Coord{e.dimTextx, e.dimTexty, e.dimTextz});
        }
        if (e.textValue && e.textValue[0]) base.setText(std::string(e.textValue));
        base.setStyle((e.styleName && e.styleName[0])
                          ? std::string(e.styleName) : std::string("STANDARD"));
        base.setAlign(e.dimAlign);
        base.setTextLineStyle(e.dimLineStyle);
        base.setTextLineFactor(e.dimLineFactor);
        if (e.dimHasTextRotation) base.setDir(e.dimTextRotation);

        switch (e.dimType) {
        case LC_DIM_LINEAR: {
            base.type = 0;                       // type-70 low nibble: linear
            DRW_DimLinear d(base);
            d.setDef1Point(def1);
            d.setDef2Point(def2);
            d.setAngle(e.dimAngle * 180.0 / M_PI);     // radians -> DXF degrees
            d.setOblique(e.dimOblique * 180.0 / M_PI);
            emitDimension(&d);
            break; }
        case LC_DIM_ALIGNED: {
            base.type = 1;                       // aligned
            DRW_DimAligned d(base);
            d.setDef1Point(def1);
            d.setDef2Point(def2);
            emitDimension(&d);
            break; }
        case LC_DIM_ANGULAR: {
            base.type = 2;                       // 2-line angular
            DRW_DimAngular d(base);
            d.setFirstLine1(def1);
            d.setFirstLine2(def2);
            d.setSecondLine1(def5);
            // secondLine2 == defPoint (code 10), already set on base.
            d.setDimPoint(arc);                  // code 16: arc-through point
            emitDimension(&d);
            break; }
        case LC_DIM_DIAMETRIC: {
            base.type = 3;                       // diametric
            DRW_DimDiametric d(base);
            d.setDiameter1Point(def5);           // code 15
            // diameter2Point == defPoint (code 10), already set on base.
            emitDimension(&d);
            break; }
        case LC_DIM_RADIAL: {
            base.type = 4;                       // radial
            DRW_DimRadial d(base);
            // centerPoint == defPoint (code 10), already set on base.
            d.setDiameterPoint(def5);            // code 15: radius point
            emitDimension(&d);
            break; }
        case LC_DIM_ANGULAR3P: {
            base.type = 5;                       // 3-point angular
            DRW_DimAngular3p d(base);
            d.setFirstLine(def1);                // code 13: point1
            d.setSecondLine(def2);               // code 14: point2
            d.SetVertexPoint(def5);              // code 15: vertex
            // dimPoint == defPoint (code 10), already set on base.
            emitDimension(&d);
            break; }
        case LC_DIM_ORDINATE: {
            base.type = 6;                       // ordinate
            // X-datum carries the type-70 bit 0x40 (libdxfrw's writeDimension
            // emits ent->type verbatim — see writeDimension's writeInt16(70,...)).
            if (e.dimOrdinateX) base.type |= 0x40;
            DRW_DimOrdinate d(base);
            d.setFirstLine(def1);                // code 13: feature point
            d.setSecondLine(def2);               // code 14: leader end
            // originPoint == defPoint (code 10), already set on base.
            emitDimension(&d);
            break; }
        case LC_DIM_ARC_LENGTH: {
            // Arc-length has no DXF DIMENSION subtype in libdxfrw (and upstream
            // LibreCAD does not round-trip LC_DimArc through DXF either). Persist
            // its geometry via the 3-point-angular form (vertex = arc center, the
            // two rays = the arc endpoints, the dim point = the dim-arc location)
            // so the file stays valid and re-readable; the arc-length's full
            // fidelity round-trips through the engine's Codable value model.
            base.type = 5;                       // 3-point angular carrier
            // The dim point (code 10) is the dim-arc location (carried in dimArc*),
            // NOT the center (which is in p1). Override the base def point.
            base.setDefPoint(DRW_Coord{e.dimArcx, e.dimArcy, e.dimArcz});
            DRW_DimAngular3p d(base);
            d.setFirstLine(def1);                // arc start point (code 13)
            d.setSecondLine(def2);               // arc end point (code 14)
            d.SetVertexPoint(DRW_Coord{e.cx, e.cy, e.cz});  // center (code 15)
            emitDimension(&d);
            break; }
        default:
            ++m_skipped;
            break;
        }
    }
};

// Map the public LCDxfVersion enum onto libdxfrw's DRW::Version; default R2000.
inline DRW::Version toDrwVersion(int v) {
    switch (v) {
    case LC_DXF_R12:   return DRW::AC1009;
    case LC_DXF_R14:   return DRW::AC1014;
    case LC_DXF_R2000: return DRW::AC1015;
    case LC_DXF_R2004: return DRW::AC1018;
    case LC_DXF_R2007: return DRW::AC1021;
    case LC_DXF_R2018: return DRW::AC1032;
    default:           return DRW::AC1015;
    }
}

}  // namespace

// --------------------------------------------------------------------------
//  C ABI
// --------------------------------------------------------------------------

extern "C" LCStatus lc_dxf_read(const char *path, LCEntityList **out) {
    if (path == nullptr || path[0] == '\0' || out == nullptr) {
        return LC_ERR_INVALID_PATH;
    }
    // try/catch keeps any libdxfrw exception (or std::bad_alloc) from crossing
    // the C boundary; a clean read failure and an escaping exception both map to
    // LC_ERR_READ_FAILED.
    try {
        auto *list = new LCEntityList();
        FlatteningReader reader(list);
        dxfRW dxf(path);
        // ext=false: skip the (slower) extended/raw parse path.
        const bool ok = dxf.read(&reader, /*ext=*/false);
        if (!ok) {
            delete list;
            return LC_ERR_READ_FAILED;
        }
        // Link captured IMAGEs to their IMAGEDEFs (path + pixel size) BEFORE block
        // flattening, so a block-embedded image lands in its block's members.
        reader.finalizeImages();
        // Flatten the collected block definitions + their members into the list's
        // contiguous arrays (after parsing, so interned block-name pointers stay
        // valid and member windows are correct).
        reader.finalizeBlocks();
        // Reconstruct the single paper-space layout (paper-space P1) from the
        // observed paper content + PLOTSETTINGS. After finalizeImages/Blocks so any
        // paper-space block image is already counted as paper content.
        reader.finalizeLayouts();
        *out = list;
        return LC_OK;
    } catch (...) {
        return LC_ERR_READ_FAILED;
    }
}

extern "C" LCStatus lc_dwg_read(const char *path, LCEntityList **out) {
    if (path == nullptr || path[0] == '\0' || out == nullptr) {
        return LC_ERR_INVALID_PATH;
    }
    // Identical to lc_dxf_read except the parser: DWG is binary, so libdxfrw
    // routes it through `dwgRW` instead of `dxfRW`. The SAME FlatteningReader
    // (DRW_Interface subclass) flattens every entity/layer/block into the same
    // POD model — the read path downstream of this call is byte-for-byte shared.
    try {
        auto *list = new LCEntityList();
        FlatteningReader reader(list);
        dwgRW dwg(path);
        const bool ok = dwg.read(&reader, /*ext=*/false);
        if (!ok) {
            delete list;
            return LC_ERR_READ_FAILED;
        }
        reader.finalizeImages();
        reader.finalizeBlocks();
        reader.finalizeLayouts();
        *out = list;
        return LC_OK;
    } catch (...) {
        return LC_ERR_READ_FAILED;
    }
}

extern "C" int lc_entity_list_count(const LCEntityList *list) {
    return list ? static_cast<int>(list->entities.size()) : 0;
}

extern "C" const LCEntity *lc_entity_list_entities(const LCEntityList *list) {
    if (list == nullptr || list->entities.empty()) return nullptr;
    return list->entities.data();
}

extern "C" int lc_entity_list_geometry_count(const LCEntityList *list) {
    return list ? list->geometryCount : 0;
}

extern "C" int lc_layer_count(const LCEntityList *list) {
    return list ? static_cast<int>(list->layers.size()) : 0;
}

extern "C" const LCLayer *lc_layers(const LCEntityList *list) {
    if (list == nullptr || list->layers.empty()) return nullptr;
    return list->layers.data();
}

extern "C" int lc_block_count(const LCEntityList *list) {
    return list ? static_cast<int>(list->blocks.size()) : 0;
}

extern "C" const LCBlock *lc_blocks(const LCEntityList *list) {
    if (list == nullptr || list->blocks.empty()) return nullptr;
    return list->blocks.data();
}

extern "C" int lc_block_entity_count(const LCEntityList *list) {
    return list ? static_cast<int>(list->blockEntities.size()) : 0;
}

extern "C" const LCEntity *lc_block_entities(const LCEntityList *list) {
    if (list == nullptr || list->blockEntities.empty()) return nullptr;
    return list->blockEntities.data();
}

extern "C" const LCHeader *lc_header(const LCEntityList *list) {
    return list ? &list->header : nullptr;
}

extern "C" int lc_header_var_count(const LCEntityList *list) {
    return list ? static_cast<int>(list->headerVars.size()) : 0;
}

extern "C" LCHeaderVar lc_header_var(const LCEntityList *list, int idx) {
    LCHeaderVar empty{};   // name == NULL signals out-of-range / NULL list.
    if (list == nullptr || idx < 0 ||
        idx >= static_cast<int>(list->headerVars.size())) {
        return empty;
    }
    return list->headerVars[static_cast<size_t>(idx)];
}

extern "C" int lc_dimstyle_count(const LCEntityList *list) {
    return list ? static_cast<int>(list->dimStyles.size()) : 0;
}

extern "C" const LCDimStyle *lc_dimstyles(const LCEntityList *list) {
    if (list == nullptr || list->dimStyles.empty()) return nullptr;
    return list->dimStyles.data();
}

extern "C" int lc_layout_count(const LCEntityList *list) {
    return list ? static_cast<int>(list->layouts.size()) : 0;
}

extern "C" const LCLayout *lc_layouts(const LCEntityList *list) {
    if (list == nullptr || list->layouts.empty()) return nullptr;
    return list->layouts.data();
}

extern "C" int lc_viewport_count(const LCEntityList *list) {
    return list ? static_cast<int>(list->viewports.size()) : 0;
}

extern "C" const LCViewport *lc_viewports(const LCEntityList *list) {
    if (list == nullptr || list->viewports.empty()) return nullptr;
    return list->viewports.data();
}

extern "C" void lc_entity_list_free(LCEntityList *list) {
    delete list;
}

extern "C" int32_t lc_aci_to_rgb(int32_t aci) {
    // 0 == ByBlock, 256 == ByLayer, out-of-range -> inherit. Mirrors
    // RS_FilterDXFRW::numberToColor's sentinel handling.
    if (aci <= 0 || aci > 255) {
        return -1;
    }
    const unsigned char *c = DRW::dxfColors[aci];
    return (static_cast<int32_t>(c[0]) << 16)
         | (static_cast<int32_t>(c[1]) << 8)
         |  static_cast<int32_t>(c[2]);
}

extern "C" LCStatus lc_dxf_count_entities(const char *path, int *out_count) {
    LCEntityList *list = nullptr;
    const LCStatus status = lc_dxf_read(path, &list);
    if (status != LC_OK) {
        return status;
    }
    if (out_count != nullptr) {
        *out_count = list->geometryCount;
    }
    lc_entity_list_free(list);
    return LC_OK;
}

extern "C" LCStatus lc_dxf_write(const char *path,
                                 const LCEntity *entities, int entityCount,
                                 const LCLayer *layers, int layerCount,
                                 const LCBlock *blocks, int blockCount,
                                 const LCEntity *blockEntities, int blockEntityCount,
                                 int version,
                                 int *out_skipped,
                                 const LCHeader *header,
                                 const LCDimStyle *dimStyles, int dimStyleCount,
                                 const LCViewport *viewports, int viewportCount,
                                 const LCHeaderVar *headerVars, int headerVarCount) {
    if (out_skipped != nullptr) {
        *out_skipped = 0;
    }
    if (path == nullptr || path[0] == '\0') {
        return LC_ERR_INVALID_PATH;
    }
    // A negative count with a NULL array is a programmer error; treat a
    // non-positive count as "no items" and clamp to a NULL-safe path.
    if ((entityCount > 0 && entities == nullptr) ||
        (layerCount  > 0 && layers   == nullptr) ||
        (blockCount  > 0 && blocks   == nullptr) ||
        (blockEntityCount > 0 && blockEntities == nullptr) ||
        (dimStyleCount > 0 && dimStyles == nullptr) ||
        (viewportCount > 0 && viewports == nullptr) ||
        (headerVarCount > 0 && headerVars == nullptr)) {
        return LC_ERR_INVALID_PATH;
    }
    // try/catch keeps any libdxfrw exception (or std::bad_alloc) from crossing
    // the C boundary; a clean write failure and an escaping exception both map
    // to LC_ERR_WRITE_FAILED.
    try {
        dxfRW dxf(path);
        WritingInterface iface(&dxf, entities, entityCount, layers, layerCount,
                               blocks, blockCount, blockEntities, blockEntityCount,
                               header, dimStyles, dimStyleCount,
                               viewports, viewportCount,
                               headerVars, headerVarCount);
        // bin=false -> ASCII DXF (matches the reader and rs_filterdxfrw).
        const bool ok = dxf.write(&iface, toDrwVersion(version), /*bin=*/false);
        if (!ok) {
            return LC_ERR_WRITE_FAILED;
        }
        if (out_skipped != nullptr) {
            *out_skipped = iface.skipped();
        }
        return LC_OK;
    } catch (...) {
        return LC_ERR_WRITE_FAILED;
    }
}

extern "C" LCStatus lc_dwg_write(const char *path,
                                 const LCEntity *entities, int entityCount,
                                 const LCLayer *layers, int layerCount,
                                 const LCBlock *blocks, int blockCount,
                                 const LCEntity *blockEntities, int blockEntityCount,
                                 int version,
                                 int *out_skipped,
                                 const LCHeader *header,
                                 const LCDimStyle *dimStyles, int dimStyleCount,
                                 const LCViewport *viewports, int viewportCount,
                                 const LCHeaderVar *headerVars, int headerVarCount) {
    (void)version;   // DWG write is R2000-only; the arg is accepted for ABI symmetry.
    if (out_skipped != nullptr) {
        *out_skipped = 0;
    }
    if (path == nullptr || path[0] == '\0') {
        return LC_ERR_INVALID_PATH;
    }
    if ((entityCount > 0 && entities == nullptr) ||
        (layerCount  > 0 && layers   == nullptr) ||
        (blockCount  > 0 && blocks   == nullptr) ||
        (blockEntityCount > 0 && blockEntities == nullptr) ||
        (dimStyleCount > 0 && dimStyles == nullptr) ||
        (viewportCount > 0 && viewports == nullptr) ||
        (headerVarCount > 0 && headerVars == nullptr)) {
        return LC_ERR_INVALID_PATH;
    }
    // The DWG counterpart of lc_dxf_write: same PODs, same WritingInterface, but
    // driven through dwgRW (its dwgWriter15) at the only version it supports,
    // R2000 (AC1015). try/catch keeps any exception from crossing the C boundary.
    try {
        dwgRW dwg(path);
        WritingInterface iface(&dwg, entities, entityCount, layers, layerCount,
                               blocks, blockCount, blockEntities, blockEntityCount,
                               header, dimStyles, dimStyleCount,
                               viewports, viewportCount,
                               headerVars, headerVarCount);
        // bin is ignored by dwgRW (DWG is always binary); pass false for symmetry.
        const bool ok = dwg.write(&iface, DRW::AC1015, /*bin=*/false);
        if (!ok) {
            return LC_ERR_WRITE_FAILED;
        }
        if (out_skipped != nullptr) {
            *out_skipped = iface.skipped();
        }
        return LC_OK;
    } catch (...) {
        return LC_ERR_WRITE_FAILED;
    }
}
