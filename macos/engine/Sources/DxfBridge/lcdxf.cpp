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
#include <cmath>
#include <cstdint>
#include <deque>
#include <exception>
#include <string>
#include <vector>

#include "libdxfrw.h"
#include "drw_interface.h"
#include "drw_objects.h"   // DRW::dxfColors[][3]

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

    // Stable-address backing pools (deque: pointers survive growth).
    std::deque<std::string>          strings;
    std::deque<std::vector<LCVertex>> vertexPool;
    std::deque<std::vector<double>>  doublePool;
    std::deque<std::vector<LCLoop>>  loopPool;
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

    // ----- string / array pooling ----------------------------------------
    const char *intern(const std::string &s) {
        m_out->strings.push_back(s);
        return m_out->strings.back().c_str();
    }
    const char *intern(const char *s) {
        return intern(std::string(s ? s : ""));
    }

    // Fill the common (layer/linetype/color/lineweight) attributes from any
    // DRW_Entity. Ported from rs_filterdxfrw.cpp setEntityAttributes.
    void fillCommon(LCEntity &e, const DRW_Entity &src) {
        e.layer = intern(src.layer);
        e.lineType = intern(src.lineType);
        e.color = src.color;
        e.color24 = src.color24;
        e.lineWeightMM100 = DRW_LW_Conv::lineWidth2dxfInt(src.lWeight);
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
        e.ratio = 1.0;
        e.degree = 0;
        e.closed = 0;
        e.height = 0.0;
        e.hAlign = 0;
        e.vAlign = 0;
        e.solidFill = 0;
        e.mtextRectWidth = 0.0;
        e.mtextAttachment = 1;            // TopLeft default
        e.mtextLineSpacingStyle = 1;      // at-least
        e.mtextLineSpacingFactor = 1.0;
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
    void addHeader(const DRW_Header *data) override { (void)data; }
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

    void addDimStyle(const DRW_Dimstyle &data) override { (void)data; }
    void addVport(const DRW_Vport &data) override { (void)data; }
    void addTextStyle(const DRW_Textstyle &data) override { (void)data; }
    void addAppId(const DRW_AppId &data) override { (void)data; }

    // ----- block structure (collected as no-ops; block expansion is a later
    //        owner's job — see ADR-001 / Block.swift) -----------------------
    void addBlock(const DRW_Block &data) override { (void)data; }
    void setBlock(const int handle) override { (void)handle; }
    void endBlock() override {}

    // ----- geometric entities --------------------------------------------
    void addPoint(const DRW_Point &data) override {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_POINT);
        fillCommon(e, data);
        e.p1x = data.basePoint.x; e.p1y = data.basePoint.y; e.p1z = data.basePoint.z;
        m_out->entities.push_back(e);
    }

    void addLine(const DRW_Line &data) override {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_LINE);
        fillCommon(e, data);
        e.p1x = data.basePoint.x; e.p1y = data.basePoint.y; e.p1z = data.basePoint.z;
        e.p2x = data.secPoint.x;  e.p2y = data.secPoint.y;  e.p2z = data.secPoint.z;
        m_out->entities.push_back(e);
    }

    // RAY / XLINE: infinite-length construction lines. Not in the frozen entity
    // model; collect as unsupported so Swift warns rather than silently drops.
    void addRay(const DRW_Ray &data) override { addUnsupportedEntity(data, "RAY"); }
    void addXline(const DRW_Xline &data) override { addUnsupportedEntity(data, "XLINE"); }

    void addArc(const DRW_Arc &data) override {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_ARC);
        fillCommon(e, data);
        e.cx = data.basePoint.x; e.cy = data.basePoint.y; e.cz = data.basePoint.z;
        e.radius = data.radious;
        e.startAngle = data.staangle;
        e.endAngle = data.endangle;
        m_out->entities.push_back(e);
    }

    void addCircle(const DRW_Circle &data) override {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_CIRCLE);
        fillCommon(e, data);
        e.cx = data.basePoint.x; e.cy = data.basePoint.y; e.cz = data.basePoint.z;
        e.radius = data.radious;
        m_out->entities.push_back(e);
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
        m_out->entities.push_back(e);
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
        m_out->entities.push_back(e);
    }

    void addPolyline(const DRW_Polyline &data) override {
        ++m_out->geometryCount;
        // Only the simple 2D polyline is flattened; 3D meshes / polyface meshes
        // (flags 0x10 / 0x40) are not in the frozen model -> unsupported warning.
        if ((data.flags & 0x10) || (data.flags & 0x40)) {
            LCEntity e = makeEntity(LC_ENT_UNSUPPORTED);
            fillCommon(e, data);
            e.typeName = intern("POLYLINE_MESH");
            m_out->entities.push_back(e);
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
        m_out->entities.push_back(e);
    }

    void addSpline(const DRW_Spline *data) override {
        ++m_out->geometryCount;
        if (data == nullptr) return;
        LCEntity e = makeEntity(LC_ENT_SPLINE);
        fillCommon(e, *data);
        e.degree = data->degree;
        e.closed = (data->flags & 0x1) ? 1 : 0;

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

        m_out->entities.push_back(e);
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
        m_out->entities.push_back(e);
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
        m_out->entities.push_back(e);
    }

    // ----- entities not in the frozen geometry model: count + warn --------
    void addInsert(const DRW_Insert &data) override { addUnsupportedEntity(data, "INSERT"); }
    void addTrace(const DRW_Trace &data) override { emitSolid(data); }
    void add3dFace(const DRW_3Dface &data) override { addUnsupportedEntity(data, "3DFACE"); }
    void addSolid(const DRW_Solid &data) override { emitSolid(data); }
    void addDimAlign(const DRW_DimAligned *data) override { addUnsupportedDim(data, "DIMENSION"); }
    void addDimLinear(const DRW_DimLinear *data) override { addUnsupportedDim(data, "DIMENSION"); }
    void addDimRadial(const DRW_DimRadial *data) override { addUnsupportedDim(data, "DIMENSION"); }
    void addDimDiametric(const DRW_DimDiametric *data) override { addUnsupportedDim(data, "DIMENSION"); }
    void addDimAngular(const DRW_DimAngular *data) override { addUnsupportedDim(data, "DIMENSION"); }
    void addDimAngular3P(const DRW_DimAngular3p *data) override { addUnsupportedDim(data, "DIMENSION"); }
    void addDimOrdinate(const DRW_DimOrdinate *data) override { addUnsupportedDim(data, "DIMENSION"); }
    void addLeader(const DRW_Leader *data) override { addUnsupportedDim(data, "LEADER"); }
    void addHatch(const DRW_Hatch *data) override { emitHatch(data); }
    void addViewport(const DRW_Viewport &data) override { addUnsupportedEntity(data, "VIEWPORT"); }
    void addImage(const DRW_Image *data) override { addUnsupportedDim(data, "IMAGE"); }
    void linkImage(const DRW_ImageDef *data) override { (void)data; } // definition, not entity

    // ----- misc read hooks (not collected) -------------------------------
    void addComment(const char *comment) override { (void)comment; }
    void addPlotSettings(const DRW_PlotSettings *data) override { (void)data; }

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
        m_out->entities.push_back(e);
    }

    // ----- HATCH ---------------------------------------------------------
    // A filled region described by one or more boundary loops. Each loop is read
    // into a contiguous window of this entity's flat vertex array; the per-loop
    // (offset,count) windows are stored in `loops`. Ported from addHatch in
    // rs_filterdxfrw.cpp: a polyline boundary (type & 2) walks its vertlist with
    // bulges; otherwise each edge entity (LINE/ARC/ELLIPSE/SPLINE) contributes
    // its vertices. Arc/ellipse edges are tessellated into straight segments here
    // (boundary-arc fidelity beyond the start point is layout backlog); bulges on
    // polyline edges are carried through. solidFill and the pattern name round-trip.
    void emitHatch(const DRW_Hatch *data) {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_HATCH);
        if (data) {
            fillCommon(e, *data);
        } else {
            e.layer = intern("0"); e.lineType = intern("BYLAYER");
            m_out->entities.push_back(e);
            return;
        }
        e.solidFill = data->solid ? 1 : 0;
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
        m_out->entities.push_back(e);
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
        // Edge boundary: walk each edge entity, appending its start point (and,
        // for arcs/ellipses, tessellated intermediate points) so the chained
        // edges form one ring.
        for (const auto &ent : loop.objlist) {
            if (!ent) continue;
            switch (ent->eType) {
            case DRW::LINE: {
                const auto *l = dynamic_cast<DRW_Line *>(ent.get());
                if (l) verts.push_back(LCVertex{l->basePoint.x, l->basePoint.y, 0.0});
                break;
            }
            case DRW::ARC: {
                const auto *a = dynamic_cast<DRW_Arc *>(ent.get());
                if (a) tessellateArc(a->basePoint.x, a->basePoint.y, a->radious,
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

    // Common path for an entity passed by const-ref that we don't flatten.
    template <typename T>
    void addUnsupportedEntity(const T &data, const char *name) {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_UNSUPPORTED);
        fillCommon(e, data);
        e.typeName = intern(name);
        m_out->entities.push_back(e);
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
        m_out->entities.push_back(e);
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
    WritingInterface(dxfRW *dxf,
                     const LCEntity *entities, int entityCount,
                     const LCLayer *layers, int layerCount)
        : m_dxf(dxf),
          m_entities(entities), m_entityCount(entityCount < 0 ? 0 : entityCount),
          m_layers(layers), m_layerCount(layerCount < 0 ? 0 : layerCount) {}

    int skipped() const { return m_skipped; }

    // ----- attribute mapping (inverse of FlatteningReader::fillCommon) -----
    void fillCommon(DRW_Entity &ent, const LCEntity &src) {
        ent.layer    = (src.layer    && src.layer[0])    ? std::string(src.layer)    : std::string("0");
        ent.lineType = (src.lineType && src.lineType[0]) ? std::string(src.lineType) : std::string("BYLAYER");
        ent.color    = src.color;
        ent.color24  = src.color24;
        // src.lineWeightMM100 holds the DXF lineweight integer (mm*100 / sentinel
        // -1/-2/-3), exactly what dxfInt2lineWidth expects.
        ent.lWeight  = DRW_LW_Conv::dxfInt2lineWidth(src.lineWeightMM100);
    }

    // ----- the table/entity callbacks libdxfrw drives during write() -------
    void writeLayers() override {
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
    }

    // libdxfrw drives this once; emit the minimal standard linetypes LibreCAD
    // also writes so referencing CONTINUOUS/BYLAYER/BYBLOCK names resolve.
    void writeLTypes() override {
        writeStdLType("CONTINUOUS", "Solid line");
        writeStdLType("ByLayer", "");
        writeStdLType("ByBlock", "");
    }

    void writeTextstyles() override {
        // A single "Standard" text style keeps R2000 readers happy even though
        // we emit no TEXT entities yet.
        DRW_Textstyle ts;
        ts.name = "Standard";
        m_dxf->writeTextstyle(&ts);
    }

    // ----- header: leave libdxfrw's defaults (it fills $ACADVER etc.) -------
    void writeHeader(DRW_Header &data) override { (void)data; }

    // ----- required no-ops --------------------------------------------------
    void writeBlocks() override {}
    void writeBlockRecords() override {}
    void writeVports() override {}
    void writeDimstyles() override {}
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
    dxfRW *m_dxf;
    const LCEntity *m_entities;
    int m_entityCount;
    const LCLayer *m_layers;
    int m_layerCount;
    int m_skipped = 0;

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
        case LC_ENT_TEXT:       writeText(e);       break;
        case LC_ENT_SOLID:      writeSolid(e);      break;
        case LC_ENT_HATCH:      writeHatch(e);      break;
        default:                ++m_skipped;        break; // SPLINE / UNSUPPORTED / ...
        }
    }

    void writePoint(const LCEntity &e) {
        DRW_Point p;
        fillCommon(p, e);
        p.basePoint.x = e.p1x; p.basePoint.y = e.p1y; p.basePoint.z = e.p1z;
        m_dxf->writePoint(&p);
    }

    void writeLine(const LCEntity &e) {
        DRW_Line l;
        fillCommon(l, e);
        l.basePoint.x = e.p1x; l.basePoint.y = e.p1y; l.basePoint.z = e.p1z;
        l.secPoint.x  = e.p2x; l.secPoint.y  = e.p2y; l.secPoint.z  = e.p2z;
        m_dxf->writeLine(&l);
    }

    void writeCircle(const LCEntity &e) {
        DRW_Circle c;
        fillCommon(c, e);
        c.basePoint.x = e.cx; c.basePoint.y = e.cy; c.basePoint.z = e.cz;
        c.radious = e.radius;
        m_dxf->writeCircle(&c);
    }

    void writeArc(const LCEntity &e) {
        DRW_Arc a;
        fillCommon(a, e);
        a.basePoint.x = e.cx; a.basePoint.y = e.cy; a.basePoint.z = e.cz;
        a.radious  = e.radius;
        a.staangle = e.startAngle;   // POD already carries CCW start/end
        a.endangle = e.endAngle;
        m_dxf->writeArc(&a);
    }

    void writeEllipse(const LCEntity &e) {
        DRW_Ellipse el;
        fillCommon(el, e);
        el.basePoint.x = e.cx;  el.basePoint.y = e.cy;  el.basePoint.z = e.cz;
        el.secPoint.x  = e.p2x; el.secPoint.y  = e.p2y; el.secPoint.z  = e.p2z;
        el.ratio    = e.ratio;
        el.staparam = e.startAngle;
        el.endparam = e.endAngle;
        m_dxf->writeEllipse(&el);
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
        m_dxf->writeLWPolyline(&pol);
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
        m_dxf->writeText(&t);
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
        m_dxf->writeSolid(&s);
    }

    // ----- HATCH ---------------------------------------------------------
    // Emit a DXF HATCH (the inverse of FlatteningReader::emitHatch). Each POD
    // loop is a ring of vertices; we emit it as an EDGE boundary of DRW_Line
    // segments (libdxfrw's writeHatch only supports edge boundaries — its
    // polyline-boundary branch is an unimplemented stub). Each ring of N vertices
    // becomes N closing line edges (vertex[i] -> vertex[(i+1)%N]); on read,
    // readHatchLoop picks up each edge's basePoint, recovering exactly the N ring
    // vertices. solidFill and the pattern name round-trip. Boundary-arc fidelity
    // (bulges) is not preserved across this edge-line tessellation — noted in the
    // backlog. HATCH only exists for R2000+; for R12 writeHatch is a no-op in
    // libdxfrw, so the entity is silently dropped at that version (rare export).
    void writeHatch(const LCEntity &e) {
        DRW_Hatch h;
        fillCommon(h, e);
        h.solid = (e.solidFill != 0) ? 1 : 0;
        h.hpattern = h.solid;   // pattern-fill flag follows solid (1 solid, 0 pattern)
        h.name = (e.textValue && e.textValue[0]) ? std::string(e.textValue)
                                                 : std::string(h.solid ? "SOLID" : "ANSI31");

        if (e.loopCount > 0 && e.loops != nullptr &&
            e.vertexCount > 0 && e.vertices != nullptr) {
            for (int li = 0; li < e.loopCount; ++li) {
                const LCLoop &loop = e.loops[li];
                const int start = loop.offset;
                const int count = loop.count;
                if (start < 0 || count < 2 || start + count > e.vertexCount) continue;
                // Edge boundary (type 0, not the polyline bit 2): a chain of LINE
                // edges closing back to the first vertex.
                auto hl = std::make_shared<DRW_HatchLoop>(0);
                for (int j = 0; j < count; ++j) {
                    const LCVertex &a = e.vertices[start + j];
                    const LCVertex &b = e.vertices[start + ((j + 1) % count)];
                    auto edge = std::make_shared<DRW_Line>();
                    edge->basePoint.x = a.x; edge->basePoint.y = a.y; edge->basePoint.z = 0.0;
                    edge->secPoint.x  = b.x; edge->secPoint.y  = b.y; edge->secPoint.z  = 0.0;
                    hl->objlist.push_back(edge);
                }
                hl->update();
                h.appendLoop(hl);
            }
        }
        h.loopsnum = static_cast<int>(h.looplist.size());
        m_dxf->writeHatch(&h);
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
                                 int version,
                                 int *out_skipped) {
    if (out_skipped != nullptr) {
        *out_skipped = 0;
    }
    if (path == nullptr || path[0] == '\0') {
        return LC_ERR_INVALID_PATH;
    }
    // A negative count with a NULL array is a programmer error; treat a
    // non-positive count as "no items" and clamp to a NULL-safe path.
    if ((entityCount > 0 && entities == nullptr) ||
        (layerCount  > 0 && layers   == nullptr)) {
        return LC_ERR_INVALID_PATH;
    }
    // try/catch keeps any libdxfrw exception (or std::bad_alloc) from crossing
    // the C boundary; a clean write failure and an escaping exception both map
    // to LC_ERR_WRITE_FAILED.
    try {
        dxfRW dxf(path);
        WritingInterface iface(&dxf, entities, entityCount, layers, layerCount);
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
